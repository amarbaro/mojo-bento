"""safetensors files for Mojo: read (the whole file mmapped read-only, tensor data as zero-copy
spans) and write, with the rules of the reference implementation (huggingface/safetensors 0.6):
same accepted and rejected files, same bytes written."""
from std.ffi import external_call
from std.os import listdir
from std.os.path import exists
from json import parse, Json, INT, STR, ARR, OBJ

comptime MAX_HEADER = 100_000_000
# The reference's dtype enum in order; the writer lays tensors out by it, highest first.
comptime _DTYPES = "BOOL F4 F6_E2M3 F6_E3M2 U8 I8 F8_E5M2 F8_E4M3 F8_E8M0 I16 U16 F16 BF16 I32 U32 F32 F64 I64 U64"


def _rank(dtype: String) -> Int:
    var i = 0
    for t in _DTYPES.split(" "):
        if t == dtype:
            return i
        i += 1
    return -1


def dtype_bits(dtype: String) -> Int:
    """Bits per element (4 for F4, 6 for F6_*), 0 for an unknown dtype."""
    var r = _rank(dtype)
    return 0 if r < 0 else (8 if r == 0 else (4 if r == 1 else (6 if r < 4 else (8 if r < 9 else (16 if r < 13 else (32 if r < 16 else 64))))))


@fieldwise_init
struct TensorInfo(Copyable, Movable):
    var name: String
    var dtype: String
    var shape: List[Int]
    var begin: Int  # offsets inside the data section, as in the header
    var end: Int

    def numel(self) -> Int:
        var n = 1
        for d in self.shape:
            n *= d
        return n

    def nbytes(self) -> Int:
        return self.end - self.begin


@fieldwise_init
struct _Key(Comparable, Copyable):
    """Sort key: by s, then a, then b; i is the index it sorts."""

    var s: String
    var a: Int
    var b: Int
    var i: Int

    def __lt__(self, o: Self) -> Bool:
        return self.s < o.s or (self.s == o.s and (self.a < o.a or (self.a == o.a and self.b < o.b)))

    def __eq__(self, o: Self) -> Bool:
        return self.s == o.s and self.a == o.a and self.b == o.b


def _text(j: Json, off: UInt32, n: UInt32) -> String:
    return String(unsafe_from_utf8=Span(j.buf)[Int(off) : Int(off) + Int(n)])


struct SafeTensors(Movable):
    """One .safetensors file. tensors are sorted by name; data(name) points into the mapping."""

    var path: String
    var base: Int  # address of the read-only mapping
    var size: Int
    var data_start: Int  # 8 + header length
    var tensors: List[TensorInfo]
    var meta_keys: List[String]
    var meta_vals: List[String]

    def __init__(out self, path: String) raises:
        self.path = path.copy()
        self.base = 0
        self.data_start = 0
        self.tensors = List[TensorInfo]()
        self.meta_keys = List[String]()
        self.meta_vals = List[String]()
        var p = path.copy()
        var fd = external_call["open64", Int32](p.as_c_string_span().ptr(), Int32(0o2000000))
        if fd < 0:
            raise Error("safetensors: cannot open ", path)
        self.size = Int(external_call["lseek64", Int64](fd, Int64(0), Int32(2)))
        if self.size >= 8:
            self.base = external_call["mmap", Int](Int(0), self.size, Int32(1), Int32(2), fd, Int64(0))
        _ = external_call["close", Int32](fd)
        if self.size < 8:
            raise Error("safetensors: ", path, ": header too small")
        if self.base == -1:
            raise Error("safetensors: cannot mmap ", path)
        var n = 0
        for k in range(8):
            n |= Int(self._byte(k)) << (8 * k)
        if n > MAX_HEADER or n < 0:
            raise Error("safetensors: ", path, ": header too large")
        if 8 + n > self.size:
            raise Error("safetensors: ", path, ": invalid header length")
        self.data_start = 8 + n
        var j: Json
        try:
            j = parse(Span(self.bytes())[8 : 8 + n])
        except e:
            raise Error("safetensors: ", path, ": invalid JSON in header: ", e)
        self._header(j)

    def _byte(self, i: Int) -> UInt8:
        return self.bytes()[i]

    def bytes(self) -> Span[UInt8, origin_of(self)]:
        """The whole file."""
        return Span(unsafe_ptr=Pointer[UInt8, origin_of(self)](unsafe_from_address=self.base), length=self.size)

    def _header(mut self, j: Json) raises:
        """One pass over the parsed nodes (preorder, each with its subtree size), then the
        reference's validate(): sorted by offsets, the tensors tile the data section exactly."""
        if j.kind() != OBJ:
            raise Error("safetensors: ", self.path, ": header is not an object")
        var k = 1
        while k < Int(j.n[0].size):
            var v = j.n[k]
            var key = _text(j, v.koff, v.klen)
            var end = k + Int(v.size)
            if key == "__metadata__":
                if v.kind != OBJ:
                    raise Error("safetensors: ", self.path, ": __metadata__ is not an object")
                for c in range(k + 1, end):
                    if j.n[c].kind != STR:
                        raise Error("safetensors: ", self.path, ": metadata value is not a string")
                    self.meta_keys.append(_text(j, j.n[c].koff, j.n[c].klen))
                    self.meta_vals.append(_text(j, j.n[c].soff, j.n[c].slen))
                k = end
                continue
            var dtype = String()
            var shape = List[Int]()
            var off = List[Int]()
            var seen = 0
            var c = k + 1
            while v.kind == OBJ and c < end:
                var f = j.n[c]
                var name = _text(j, f.koff, f.klen)
                if name == "dtype" and f.kind == STR:
                    dtype = _text(j, f.soff, f.slen)
                    seen |= 1
                elif (name == "shape" or name == "data_offsets") and f.kind == ARR:
                    for e in range(c + 1, c + Int(f.size)):
                        if j.n[e].kind != INT or j.n[e].num < 0:
                            raise Error("safetensors: ", self.path, ": bad ", name, " for tensor ", key)
                        (shape if name == "shape" else off).append(Int(j.n[e].num))
                    seen |= 2 if name == "shape" else 4
                elif name == "dtype" or name == "shape" or name == "data_offsets":
                    seen |= 8
                c += Int(f.size)
            if seen != 7 or len(off) != 2:
                raise Error("safetensors: ", self.path, ": bad entry for tensor ", key)
            if dtype_bits(dtype) == 0:
                raise Error("safetensors: ", self.path, ": unknown dtype ", dtype)
            self.tensors.append(TensorInfo(key, dtype, shape^, off[0], off[1]))
            k = end
        var order = List[_Key](capacity=len(self.tensors))
        for i in range(len(self.tensors)):
            order.append(_Key("", self.tensors[i].begin, self.tensors[i].end, i))
        sort(order)
        var at = 0
        for o in order:
            ref t = self.tensors[o.i]
            if t.begin != at or t.end < t.begin:
                raise Error("safetensors: ", self.path, ": invalid offset for tensor ", t.name)
            if t.numel() * dtype_bits(t.dtype) != t.nbytes() * 8:
                raise Error("safetensors: ", self.path, ": invalid shape, data type, or offset for tensor ", t.name)
            at = t.end
        if at != self.size - self.data_start:
            raise Error("safetensors: ", self.path, ": incomplete metadata, file not fully covered")
        var names = List[_Key](capacity=len(self.tensors))
        for i in range(len(self.tensors)):
            names.append(_Key(self.tensors[i].name, 0, 0, i))
        sort(names)
        var ts = List[TensorInfo](capacity=len(self.tensors))
        for i in range(len(names)):
            if i and names[i].s == names[i - 1].s:
                raise Error("safetensors: ", self.path, ": duplicate tensor ", names[i].s)
            ts.append(self.tensors[names[i].i].copy())
        self.tensors = ts^

    def find(self, name: String) -> Int:
        """Index into tensors, -1 when absent (binary search)."""
        var lo = 0
        var hi = len(self.tensors)
        while lo < hi:
            var mid = (lo + hi) // 2
            if self.tensors[mid].name < name:
                lo = mid + 1
            else:
                hi = mid
        return lo if lo < len(self.tensors) and self.tensors[lo].name == name else -1

    def data(self, i: Int) -> Span[UInt8, origin_of(self)]:
        """The raw bytes of tensors[i], no copy."""
        return self.bytes()[self.data_start + self.tensors[i].begin : self.data_start + self.tensors[i].end]

    def data(self, name: String) raises -> Span[UInt8, origin_of(self)]:
        var i = self.find(name)
        if i < 0:
            raise Error("safetensors: ", self.path, ": no tensor ", name)
        return self.data(i)

    def metadata(self, key: String) -> Optional[String]:
        for i in range(len(self.meta_keys)):
            if self.meta_keys[i] == key:
                return self.meta_vals[i].copy()
        return None

    def __deinit__(deinit self):
        if self.base > 0:
            _ = external_call["munmap", Int32](self.base, self.size)


def _put(mut out: List[UInt8], s: String):
    out.extend(s.as_bytes())


def _quote(mut out: List[UInt8], s: String):
    """A JSON string as serde_json writes it: UTF-8 kept, only quote, backslash and controls escaped."""
    out.append(34)
    for b in s.as_bytes():
        var c = Int(b)
        if c == 34 or c == 92:
            out.append(92)
            out.append(b)
        elif c < 32:
            var short = {8: "b", 9: "t", 10: "n", 12: "f", 13: "r"}.get(c)
            if short:
                _put(out, "\\" + short.value())
            else:
                _put(out, "\\u00" + chr(48 + c // 16) + chr(c % 16 + (48 if c % 16 < 10 else 87)))
        else:
            out.append(b)
    out.append(34)


struct Writer(Movable):
    """Collects tensors (copied) and metadata, then writes the file the reference writes for the
    same input, byte for byte: tensors ordered by dtype (highest first) then name, metadata keys
    sorted, header padded with spaces to a multiple of 8."""

    var tensors: List[TensorInfo]
    var blob: List[UInt8]  # each tensor's bytes, begin/end index into it
    var meta_keys: List[String]
    var meta_vals: List[String]

    def __init__(out self):
        self.tensors = List[TensorInfo]()
        self.blob = List[UInt8]()
        self.meta_keys = List[String]()
        self.meta_vals = List[String]()

    def add(mut self, name: String, dtype: String, shape: List[Int], data: Span[UInt8, _]) raises:
        var t = TensorInfo(name, dtype, shape.copy(), len(self.blob), len(self.blob) + len(data))
        if dtype_bits(dtype) == 0 or t.numel() * dtype_bits(dtype) != len(data) * 8:
            raise Error("safetensors: invalid shape, data type, or size for tensor ", name)
        for o in self.tensors:
            if o.name == name:
                raise Error("safetensors: duplicate tensor ", name)
        self.blob.extend(data)
        self.tensors.append(t^)

    def set_metadata(mut self, key: String, value: String):
        for i in range(len(self.meta_keys)):
            if self.meta_keys[i] == key:
                self.meta_vals[i] = value.copy()
                return
        self.meta_keys.append(key.copy())
        self.meta_vals.append(value.copy())

    def save(self, path: String) raises:
        var order = List[_Key](capacity=len(self.tensors))  # dtype rank highest first, then name
        for i in range(len(self.tensors)):
            order.append(_Key(chr(83 - _rank(self.tensors[i].dtype)) + self.tensors[i].name, 0, 0, i))  # 'S' - rank
        sort(order)
        var h: List[UInt8] = [123]
        if len(self.meta_keys):
            var mk = List[Int]()
            for i in range(len(self.meta_keys)):
                var k = len(mk)
                while k > 0 and self.meta_keys[i] < self.meta_keys[mk[k - 1]]:
                    k -= 1
                mk.insert(k, i)
            _put(h, '"__metadata__":{')
            for k in range(len(mk)):
                if k:
                    _put(h, ",")
                _quote(h, self.meta_keys[mk[k]])
                _put(h, ":")
                _quote(h, self.meta_vals[mk[k]])
            _put(h, "}")
        var at = 0
        for o in order:
            ref t = self.tensors[o.i]
            if len(h) > 1:
                _put(h, ",")
            _quote(h, t.name)
            _put(h, ':{"dtype":"' + t.dtype + '","shape":[')
            for d in range(len(t.shape)):
                _put(h, ("," if d else "") + String(t.shape[d]))
            _put(h, '],"data_offsets":[' + String(at) + "," + String(at + t.nbytes()) + "]}")
            at += t.nbytes()
        _put(h, "}")
        while len(h) % 8:
            h.append(32)
        var n = len(h)
        var head = List[UInt8](length=8, fill=0)
        for k in range(8):
            head[k] = UInt8((n >> (8 * k)) & 255)
        with open(path, "w") as f:
            f.write_bytes(head)
            f.write_bytes(h)
            for o in order:
                f.write_bytes(Span(self.blob)[self.tensors[o.i].begin : self.tensors[o.i].end])


struct Checkpoint(Movable):
    """A Hugging Face checkpoint directory: model.safetensors.index.json and its shards, or every
    model*.safetensors. Tensors are listed shard by shard (shards by file name), by name inside a
    shard: the order the HF converters visit them."""

    var shards: List[SafeTensors]

    def __init__(out self, dir: String) raises:
        self.shards = List[SafeTensors]()
        var parts = List[String]()
        var index = dir + "/model.safetensors.index.json"
        var wm = Json()
        if exists(index):
            with open(index, "r") as f:
                wm = parse(f.read_bytes()).get("weight_map")
            if wm.kind() != OBJ:
                raise Error("safetensors: ", index, ": no weight_map")
            for i in range(wm.len()):
                var f = wm.at(i).str()
                if f not in parts:
                    parts.append(f^)
        else:
            for f in listdir(dir):
                if f.startswith("model") and f.endswith(".safetensors"):
                    parts.append(f)
        if len(parts) == 0:
            raise Error("safetensors: no model*.safetensors in ", dir)
        sort(parts)
        for p in parts:
            self.shards.append(SafeTensors(dir + "/" + p))
        if exists(index):
            var total = 0
            for s in range(len(self.shards)):
                total += len(self.shards[s].tensors)
            if total != wm.len():
                raise Error("safetensors: weight_map names ", wm.len(), " tensors, the shards hold ", total)
            for i in range(wm.len()):
                var s = parts.index(wm.at(i).str())
                if self.shards[s].find(wm.key_at(i)) < 0:
                    raise Error("safetensors: ", wm.key_at(i), " is not in ", parts[s])
