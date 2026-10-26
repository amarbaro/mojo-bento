"""GGUF files for Mojo: a reader over a read-only mmap of the whole file (header, key-values and
tensor table parsed in place, tensor data as zero-copy spans) and a writer that produces the
bytes gguf-py's GGUFWriter produces for the same calls."""
from std.ffi import external_call
from std.memory import bitcast

comptime MAGIC = 0x46554747  # "GGUF"
comptime T_UINT8 = 0
comptime T_INT8 = 1
comptime T_UINT16 = 2
comptime T_INT16 = 3
comptime T_UINT32 = 4
comptime T_INT32 = 5
comptime T_FLOAT32 = 6
comptime T_BOOL = 7
comptime T_STRING = 8
comptime T_ARRAY = 9
comptime T_UINT64 = 10
comptime T_INT64 = 11
comptime T_FLOAT64 = 12
# ggml types as gguf-py 0.19 knows them, by type id: elements and bytes per block (0 = unknown id)
comptime _BLOCK = [1, 1, 32, 32, 0, 0, 32, 32, 32, 32, 256, 256, 256, 256, 256, 256, 256, 256, 256, 256, 32, 256, 256, 256, 1, 1, 1, 1, 1, 256, 1, 0, 0, 0, 256, 256, 0, 0, 0, 32, 64, 128]
comptime _BYTES = [4, 2, 18, 20, 0, 0, 22, 24, 34, 40, 84, 110, 144, 176, 210, 292, 66, 74, 98, 50, 18, 110, 82, 136, 1, 2, 4, 8, 8, 56, 2, 0, 0, 0, 54, 66, 0, 0, 0, 17, 36, 18]


def _width(t: Int) -> Int:
    """Bytes of a fixed-width value type; 0 for string, array and unknown."""
    return 1 if t in [0, 1, 7] else (2 if t in [2, 3] else (4 if t in [4, 5, 6] else (8 if t in [10, 11, 12] else 0)))


def type_size(ttype: Int) -> Tuple[Int, Int]:
    """(elements per block, bytes per block) of a ggml type; (0, 0) when unknown."""
    if ttype < 0 or ttype >= len(materialize[_BLOCK]()):
        return (0, 0)
    return (materialize[_BLOCK]()[ttype], materialize[_BYTES]()[ttype])


def pad_to(n: Int, align: Int) -> Int:
    return (n + align - 1) // align * align


@fieldwise_init
struct KV(Copyable, Movable):
    var key: String
    var vtype: Int
    var atype: Int  # element type of an array, -1 otherwise
    var count: Int  # array length, 1 otherwise
    var start: Int  # value payload in the file: [start, end), after the type tag
    var end: Int


@fieldwise_init
struct TensorInfo(Copyable, Movable):
    var name: String
    var dims: List[Int]  # GGUF order: ne0 (fastest) first
    var ttype: Int
    var offset: Int  # relative to the data section
    var nbytes: Int

    def numel(self) -> Int:
        var n = 1
        for d in self.dims:
            n *= d
        return n


struct Gguf(Movable):
    """One GGUF v2/v3 little-endian file, mmapped read-only. kvs and tensors keep file order.
    known_types=False accepts ggml types this library does not know (forks add their own): such a
    tensor gets nbytes -1, no bounds check, and an empty data() span."""

    var path: String
    var base: Int
    var size: Int
    var pos: Int
    var version: Int
    var alignment: Int
    var data_offset: Int
    var kvs: List[KV]
    var tensors: List[TensorInfo]

    def __init__(out self, path: String, known_types: Bool = True) raises:
        self.path = path.copy()
        self.base = 0
        self.pos = 0
        self.version = 0
        self.alignment = 32
        self.data_offset = 0
        self.kvs = List[KV]()
        self.tensors = List[TensorInfo]()
        var p = path.copy()
        var fd = external_call["open64", Int32](p.as_c_string_span().ptr(), Int32(0o2000000))
        if fd < 0:
            raise Error("gguf: cannot open ", path)
        self.size = Int(external_call["lseek64", Int64](fd, Int64(0), Int32(2)))
        if self.size > 0:
            self.base = external_call["mmap", Int](Int(0), self.size, Int32(1), Int32(2), fd, Int64(0))
        _ = external_call["close", Int32](fd)
        if self.base == -1:
            self.base = 0
            raise Error("gguf: cannot mmap ", path)
        if self._u(4) != MAGIC:
            raise Error("gguf: ", path, ": bad magic")
        self.version = self._u(4)
        if self.version & 0xFFFF == 0:
            raise Error("gguf: ", path, ": big-endian files are not supported")
        if self.version != 2 and self.version != 3:
            raise Error("gguf: ", path, ": version ", self.version, " not supported")
        var n_tensors = self._u(8)
        var n_kv = self._u(8)
        for _ in range(n_kv):
            var key = self._str()
            var vtype = self._u(4)
            var start = self.pos
            var atype = -1
            var count = 1
            if vtype == T_ARRAY:
                atype = self._u(4)
                count = self._u(8)
                self.pos = start
            self._skip(vtype)
            for o in self.kvs:
                if o.key == key:
                    raise Error("gguf: ", path, ": duplicate key ", key)
            self.kvs.append(KV(key^, vtype, atype, count, start, self.pos))
        var a = self.find("general.alignment")
        if a >= 0:
            if self.kvs[a].vtype != T_UINT32:
                raise Error("gguf: ", path, ": general.alignment is not uint32")
            self.alignment = self.int(a)
            if self.alignment == 0 or self.alignment & (self.alignment - 1) != 0:
                raise Error("gguf: ", path, ": alignment ", self.alignment, " is not a power of two")
        for _ in range(n_tensors):
            var name = self._str()
            var dims = List[Int]()
            for _ in range(self._u(4)):
                dims.append(self._u(8))
            var ttype = self._u(4)
            var bs = type_size(ttype)
            if bs[0] == 0 and known_types:
                raise Error("gguf: ", path, ": tensor ", name, " has unknown type ", ttype)
            var t = TensorInfo(name^, dims^, ttype, self._u(8), -1)
            if bs[0]:
                t.nbytes = t.numel() * bs[1] // bs[0]
            self.tensors.append(t^)
        self.data_offset = pad_to(self.pos, self.alignment)
        for i in range(len(self.tensors)):
            ref t = self.tensors[i]
            if t.nbytes >= 0 and self.data_offset + t.offset + t.nbytes > self.size:
                raise Error("gguf: ", path, ": tensor ", t.name, " runs past the end of the file")
            for j in range(i):
                if self.tensors[j].name == t.name:
                    raise Error("gguf: ", path, ": duplicate tensor ", t.name)

    def bytes(self) -> Span[UInt8, origin_of(self)]:
        """The whole file."""
        return Span(unsafe_ptr=Pointer[UInt8, origin_of(self)](unsafe_from_address=self.base), length=self.size)

    def _u(mut self, n: Int) raises -> Int:
        if self.pos + n > self.size:
            raise Error("gguf: ", self.path, ": truncated at byte ", self.pos)
        var v = 0
        var b = self.bytes()
        for i in range(n):
            v |= Int(b[self.pos + i]) << (8 * i)
        self.pos += n
        return v

    def _str(mut self) raises -> String:
        var n = self._u(8)
        if n > self.size - self.pos:
            raise Error("gguf: ", self.path, ": truncated string at byte ", self.pos)
        self.pos += n
        return String(from_utf8_lossy=self.bytes()[self.pos - n : self.pos])

    def _skip(mut self, t: Int) raises:
        if t == T_STRING:
            _ = self._str()
        elif t == T_ARRAY:
            var et = self._u(4)
            var n = self._u(8)
            if _width(et):
                if n > (self.size - self.pos) // _width(et):
                    raise Error("gguf: ", self.path, ": truncated array at byte ", self.pos)
                self.pos += n * _width(et)
            else:
                for _ in range(n):
                    self._skip(et)
        elif _width(t):
            _ = self._u(_width(t))
        else:
            raise Error("gguf: ", self.path, ": unknown value type ", t)

    def find(self, key: String) -> Int:
        """Index into kvs, -1 when absent."""
        for i in range(len(self.kvs)):
            if self.kvs[i].key == key:
                return i
        return -1

    def value(self, i: Int) -> Span[UInt8, origin_of(self)]:
        """The raw payload of kvs[i] (for an array: element type, count, elements)."""
        return self.bytes()[self.kvs[i].start : self.kvs[i].end]

    def _scalar(self, t: Int, at: Int) -> Int:
        var v = 0
        var b = self.bytes()
        for k in range(_width(t)):
            v |= Int(b[at + k]) << (8 * k)
        var bits = 8 * _width(t)
        return v - (1 << bits) if t in [1, 3, 5] and v >= 1 << (bits - 1) else v

    def int(self, i: Int) raises -> Int:
        """An integer or bool value (signed types sign-extended; uint64 above 2^63 wraps)."""
        var t = self.kvs[i].vtype
        if not _width(t) or t == T_FLOAT32 or t == T_FLOAT64:
            raise Error("gguf: ", self.kvs[i].key, " is not an integer")
        return self._scalar(t, self.kvs[i].start)

    def float(self, i: Int) raises -> Float64:
        var t = self.kvs[i].vtype
        var v = self._scalar(t, self.kvs[i].start)
        if t == T_FLOAT32:
            return Float64(bitcast[DType.float32](UInt32(v)))
        if t == T_FLOAT64:
            return bitcast[DType.float64](UInt64(v))
        return Float64(self.int(i))

    def str(self, i: Int) raises -> String:
        if self.kvs[i].vtype != T_STRING:
            raise Error("gguf: ", self.kvs[i].key, " is not a string")
        return String(from_utf8_lossy=self.value(i)[8:])

    def strs(self, i: Int) raises -> List[String]:
        """The elements of a string array."""
        if self.kvs[i].atype != T_STRING:
            raise Error("gguf: ", self.kvs[i].key, " is not a string array")
        var out = List[String](capacity=self.kvs[i].count)
        var at = self.kvs[i].start + 12
        for _ in range(self.kvs[i].count):
            var n = self._scalar(T_UINT64, at)
            out.append(String(from_utf8_lossy=self.bytes()[at + 8 : at + 8 + n]))
            at += 8 + n
        return out^

    def ints(self, i: Int) raises -> List[Int]:
        """The elements of an integer or bool array."""
        var t = self.kvs[i].atype
        if not _width(t) or t == T_FLOAT32 or t == T_FLOAT64:
            raise Error("gguf: ", self.kvs[i].key, " is not an integer array")
        var out = List[Int](capacity=self.kvs[i].count)
        for k in range(self.kvs[i].count):
            out.append(self._scalar(t, self.kvs[i].start + 12 + k * _width(t)))
        return out^

    def tensor(self, name: String) -> Int:
        """Index into tensors, -1 when absent."""
        for i in range(len(self.tensors)):
            if self.tensors[i].name == name:
                return i
        return -1

    def data(self, i: Int) -> Span[UInt8, origin_of(self)]:
        """The bytes of tensors[i], no copy."""
        var at = self.data_offset + self.tensors[i].offset
        return self.bytes()[at : at + max(self.tensors[i].nbytes, 0)]

    def __deinit__(deinit self):
        if self.base:
            _ = external_call["munmap", Int32](self.base, self.size)


def _le(mut out: List[UInt8], v: Int, n: Int):
    for k in range(n):
        out.append(UInt8((v >> (8 * k)) & 255))


def _lestr(mut out: List[UInt8], s: String):
    _le(out, s.byte_length(), 8)
    out.extend(s.as_bytes())


struct Writer(Movable):
    """Builds a GGUF v3 file as gguf-py's GGUFWriter does: KVs in the order first added (adding
    a key again replaces its value in place), tensors in the order added, each tensor's data
    padded to the alignment. A general.alignment uint32 KV sets the alignment."""

    var keys: List[String]
    var vals: List[List[UInt8]]  # type tag + payload
    var tensors: List[TensorInfo]
    var blob: List[UInt8]  # tensor data, unpadded; TensorInfo.offset indexes it
    var alignment: Int

    def __init__(out self):
        self.keys = List[String]()
        self.vals = List[List[UInt8]]()
        self.tensors = List[TensorInfo]()
        self.blob = List[UInt8]()
        self.alignment = 32

    def add_raw(mut self, key: String, vtype: Int, payload: Span[UInt8, _]) raises:
        """A value already encoded (Gguf.value gives one); vtype is its type tag."""
        var v = List[UInt8]()
        _le(v, vtype, 4)
        v.extend(payload)
        if key == "general.alignment":
            if vtype != T_UINT32 or len(payload) != 4:
                raise Error("gguf: general.alignment must be uint32")
            var a = Int(payload[0]) | Int(payload[1]) << 8 | Int(payload[2]) << 16 | Int(payload[3]) << 24
            if a == 0 or a & (a - 1) != 0:
                raise Error("gguf: alignment ", a, " is not a power of two")
            self.alignment = a
        for i in range(len(self.keys)):
            if self.keys[i] == key:
                self.vals[i] = v^
                return
        self.keys.append(key.copy())
        self.vals.append(v^)

    def add_int(mut self, key: String, vtype: Int, v: Int) raises:
        """Any integer type or T_BOOL."""
        if not _width(vtype) or vtype == T_FLOAT32 or vtype == T_FLOAT64:
            raise Error("gguf: type ", vtype, " is not an integer type")
        var p = List[UInt8]()
        _le(p, v, _width(vtype))
        self.add_raw(key, vtype, p)

    def add_float(mut self, key: String, vtype: Int, v: Float64) raises:
        var p = List[UInt8]()
        if vtype == T_FLOAT32:
            _le(p, Int(bitcast[DType.uint32](Float32(v))), 4)
        elif vtype == T_FLOAT64:
            _le(p, Int(bitcast[DType.uint64](v)), 8)
        else:
            raise Error("gguf: type ", vtype, " is not a float type")
        self.add_raw(key, vtype, p)

    def add_str(mut self, key: String, v: String) raises:
        var p = List[UInt8]()
        _lestr(p, v)
        self.add_raw(key, T_STRING, p)

    def add_strs(mut self, key: String, v: List[String]) raises:
        var p = List[UInt8]()
        _le(p, T_STRING, 4)
        _le(p, len(v), 8)
        for s in v:
            _lestr(p, s)
        self.add_raw(key, T_ARRAY, p)

    def add_ints(mut self, key: String, etype: Int, v: List[Int]) raises:
        if not _width(etype) or etype == T_FLOAT32 or etype == T_FLOAT64:
            raise Error("gguf: type ", etype, " is not an integer type")
        var p = List[UInt8]()
        _le(p, etype, 4)
        _le(p, len(v), 8)
        for x in v:
            _le(p, x, _width(etype))
        self.add_raw(key, T_ARRAY, p)

    def add_floats(mut self, key: String, etype: Int, v: List[Float64]) raises:
        var p = List[UInt8]()
        _le(p, etype, 4)
        _le(p, len(v), 8)
        for x in v:
            if etype == T_FLOAT32:
                _le(p, Int(bitcast[DType.uint32](Float32(x))), 4)
            elif etype == T_FLOAT64:
                _le(p, Int(bitcast[DType.uint64](x)), 8)
            else:
                raise Error("gguf: type ", etype, " is not a float type")
        self.add_raw(key, T_ARRAY, p)

    def add_tensor(mut self, name: String, dims: List[Int], ttype: Int, data: Span[UInt8, _]) raises:
        """dims in GGUF order (ne0 first); data is copied and must be exactly the type's size."""
        var bs = type_size(ttype)
        var t = TensorInfo(name, dims.copy(), ttype, len(self.blob), len(data))
        if bs[0] == 0 or t.numel() % bs[0] != 0 or t.numel() // bs[0] * bs[1] != len(data):
            raise Error("gguf: tensor ", name, ": ", len(data), " bytes do not fit type ", ttype, " and its dims")
        if dims and dims[0] % bs[0] != 0:
            raise Error("gguf: tensor ", name, ": ne0 is not a multiple of the block size ", bs[0])
        for o in self.tensors:
            if o.name == name:
                raise Error("gguf: duplicated tensor name ", name)
        self.blob.extend(data)
        self.tensors.append(t^)

    def save(self, path: String) raises:
        var h = List[UInt8]()
        _le(h, MAGIC, 4)
        _le(h, 3, 4)
        _le(h, len(self.tensors), 8)
        _le(h, len(self.keys), 8)
        for i in range(len(self.keys)):
            _lestr(h, self.keys[i])
            h.extend(Span(self.vals[i]))
        var off = 0
        for t in self.tensors:
            _lestr(h, t.name)
            _le(h, len(t.dims), 4)
            for d in t.dims:
                _le(h, d, 8)
            _le(h, t.ttype, 4)
            _le(h, off, 8)
            off += pad_to(t.nbytes, self.alignment)
        var zeros = List[UInt8](length=self.alignment, fill=0)
        with open(path, "w") as f:
            f.write_bytes(h)
            f.write_bytes(Span(zeros)[: pad_to(len(h), self.alignment) - len(h)])
            for t in self.tensors:
                f.write_bytes(Span(self.blob)[t.offset : t.offset + t.nbytes])
                f.write_bytes(Span(zeros)[: pad_to(t.nbytes, self.alignment) - t.nbytes])
