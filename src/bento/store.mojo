"""B5: a model store on BentoML's layout, ported from `_internal/store.py` + `tag.py` (Apache-2.0, see NOTICE).

    <root>/<name>/<version>/model.yaml + the model's files (*.safetensors, *.gguf, anything)
    <root>/<name>/latest      the version `get("name")` answers with

A store written by BentoML opens here and the reverse. Errors are `Error("<Type>: <message>")` with BentoML's types
(`NotFound`, `BentoMLException`, `ValueError`) and its messages. Differences: `register` needs `name:version` (BentoML's
store gets the version from the Model layer), and when a version prefix matches several directories they are listed
sorted (BentoML lists them in directory order).
"""
from std.os import listdir, makedirs, remove, rmdir
from std.os.path import exists, isdir
from safetensors import SafeTensors
from gguf import Gguf

comptime LATEST = "latest"
comptime MODEL_YAML = "model.yaml"
comptime _TAG_INVALID = "a tag's name or version must consist of lowercase alphanumeric characters, '_', '-', or '.', and must start and end with an alphanumeric character"
comptime _TAG_LONG = "a tag's name or version must be at most 63 characters in length"


def _alnum(c: UInt8) -> Bool:
    return (c >= 48 and c <= 57) or (c >= 97 and c <= 122)


def _tag_part(value: String) raises -> String:
    """Lowercase and validate one tag component (name or version)."""
    var v = value.lower()
    var b = v.as_bytes()
    var errors = List[String]()
    if len(b) > 63:
        errors.append(_TAG_LONG)
    var ok = len(b) > 0 and _alnum(b[0]) and _alnum(b[len(b) - 1])
    for i in range(len(b)):
        if not (_alnum(b[i]) or b[i] == 45 or b[i] == 46 or b[i] == 95):
            ok = False
    if not ok:
        errors.append(_TAG_INVALID)
    if len(errors) > 0:
        var msg = v + " is not a valid BentoML tag: " + errors[0]
        if len(errors) > 1:
            msg += ", and " + errors[1]
        raise Error("ValueError: " + msg)
    return v


@fieldwise_init
struct Tag(Copyable, Movable):
    var name: String
    var version: String  # empty: no version

    @staticmethod
    def parse(s: String) raises -> Tag:
        """BentoML's `Tag.from_str`: `name` or `name:version`."""
        var i = s.find(":")
        if i < 0:
            return Tag(_tag_part(s), String())
        var name = String(s[byte=0:i])
        var version = String(s[byte = i + 1 :])
        if version.byte_length() == 0:
            raise Error("BentoMLException: " + s + " contains trailing ':'. Maybe you meant to use `" + s + ":latest`?")
        try:
            return Tag(_tag_part(name), _tag_part(version))
        except:
            raise Error("BentoMLException: Invalid Tag " + s)

    def path(self) -> String:
        return self.name if self.version.byte_length() == 0 else self.name + "/" + self.version

    def text(self) -> String:
        """`name:version`."""
        return self.path().replace("/", ":")


def _days_from_civil(y: Int, m: Int, d: Int) -> Int:
    var yy = y - 1 if m <= 2 else y
    var era = yy // 400
    var yoe = yy - era * 400
    var doy = (153 * (m + (-3 if m > 2 else 9)) + 2) // 5 + d - 1
    var doe = yoe * 365 + yoe // 4 - yoe // 100 + doy
    return era * 146097 + doe - 719468


def parse_time(s: String) raises -> Int:
    """`YYYY-MM-DDTHH:MM:SS[.ffffff][+HH:MM|-HH:MM|Z]` (Python's isoformat) to UTC microseconds since the epoch."""
    var b = s.as_bytes()
    if len(b) < 19 or b[4] != 45 or b[7] != 45 or (b[10] != 84 and b[10] != 32) or b[13] != 58 or b[16] != 58:
        raise Error("BentoMLException: bad creation_time '" + s + "'")
    var y = Int(String(s[byte=0:4]))
    var mo = Int(String(s[byte=5:7]))
    var d = Int(String(s[byte=8:10]))
    var h = Int(String(s[byte=11:13]))
    var mi = Int(String(s[byte=14:16]))
    var sec = Int(String(s[byte=17:19]))
    var us = 0
    var i = 19
    if i < len(b) and b[i] == 46:
        i += 1
        var digits = 0
        while i < len(b) and b[i] >= 48 and b[i] <= 57:
            if digits < 6:
                us = us * 10 + Int(b[i] - 48)
                digits += 1
            i += 1
        while digits < 6:
            us *= 10
            digits += 1
    var off = 0
    if i < len(b) and (b[i] == 43 or b[i] == 45):
        var sign = 1 if b[i] == 43 else -1
        off = sign * (Int(String(s[byte = i + 1 : i + 3])) * 3600 + Int(String(s[byte = i + 4 : i + 6])) * 60)
    var days = _days_from_civil(y, mo, d)
    return ((days * 86400 + h * 3600 + mi * 60 + sec - off) * 1_000_000) + us


def _read(path: String) raises -> String:
    with open(path, "r") as f:
        return f.read()


def _write(path: String, text: String) raises:
    with open(path, "w") as f:
        f.write(text)


def _rmtree(path: String) raises:
    for name in listdir(path):
        var p = path + "/" + name
        if isdir(p):
            _rmtree(p)
        else:
            remove(p)
    rmdir(path)


def _dirs(path: String) raises -> List[String]:
    """Names of the subdirectories of `path`, sorted."""
    var out = List[String]()
    for name in listdir(path):
        if isdir(path + "/" + name):
            var n = String(name)
            var j = len(out)
            out.append(n)
            while j > 0 and out[j - 1] > out[j]:
                out.swap_elements(j - 1, j)
                j -= 1
    return out^


def _scalar(line: String, key: String) -> Optional[String]:
    """The value of a top-level `key: value` yaml line, quotes removed."""
    if not line.startswith(key + ":"):
        return None
    var v = String(line[byte = key.byte_length() + 1 :].strip())
    if v.byte_length() >= 2 and (v.startswith("'") or v.startswith('"')):
        var inner = String(v[byte = 1 : v.byte_length() - 1])
        v = inner^
    return v


struct Item(Copyable, Movable):
    var tag: Tag
    var path: String  # directory of the item
    var created: String  # creation_time exactly as model.yaml has it (Python isoformat)
    var micros: Int

    def __init__(out self, var tag: Tag, path: String, created: String, micros: Int):
        self.tag = tag^
        self.path = path
        self.created = created
        self.micros = micros

    def file(self, rel: String) -> String:
        return self.path + "/" + rel


struct WeightFile(Copyable, Movable):
    var file: String
    var kind: String  # "safetensors" | "gguf"
    var tensors: Int

    def __init__(out self, file: String, kind: String, tensors: Int):
        self.file = file
        self.kind = kind
        self.tensors = tensors


def weights(item: Item) raises -> List[WeightFile]:
    """The *.safetensors and *.gguf files of `item` (sorted), each opened with its library to count tensors."""
    var names = List[String]()
    for name in listdir(item.path):
        var n = String(name)
        if n.endswith(".safetensors") or n.endswith(".gguf"):
            var j = len(names)
            names.append(n)
            while j > 0 and names[j - 1] > names[j]:
                names.swap_elements(j - 1, j)
                j -= 1
    var out = List[WeightFile]()
    for n in names:
        if n.endswith(".safetensors"):
            out.append(WeightFile(n, "safetensors", len(SafeTensors(item.file(n)).tensors)))
        else:
            out.append(WeightFile(n, "gguf", len(Gguf(item.file(n)).tensors)))
    return out^


struct ModelStore(Copyable, Movable):
    var root: String

    def __init__(out self, root: String):
        self.root = root

    def _load(self, name: String, version: String) raises -> Item:
        var dir = self.root + "/" + name + "/" + version
        if not exists(dir + "/" + MODEL_YAML):
            raise Error("BentoMLException: Failed to load bento model because it does not contain a '" + MODEL_YAML + "'")
        var yname = String()
        var yver = String()
        var created = String()
        for line in _read(dir + "/" + MODEL_YAML).split("\n"):
            var l = String(line)
            var n = _scalar(l, "name")
            var v = _scalar(l, "version")
            var c = _scalar(l, "creation_time")
            if n:
                yname = n.value()
            if v:
                yver = v.value()
            if c:
                created = c.value()
        return Item(Tag(_tag_part(yname), _tag_part(yver)), dir, created, parse_time(created))

    def list(self, tag: String = "") raises -> List[Item]:
        """No tag: every item. `name`: its versions. `name:version`: that one, or none."""
        var out = List[Item]()
        if tag.byte_length() == 0:
            for d in _dirs(self.root):
                for it in self.list(d):
                    out.append(it.copy())
            return out^
        var t = Tag.parse(tag)
        if t.version.byte_length() == 0:
            var dir = self.root + "/" + t.name
            if not isdir(dir):
                raise Error("NotFound: no Models with name '" + t.name + "' found")
            var versions = List[String]()
            for v in _dirs(dir):
                versions.append(_tag_part(v))
            for v in versions:
                out.append(self._load(t.name, v))
        elif isdir(self.root + "/" + t.path()):
            out.append(self._load(t.name, t.version))
        return out^

    def _no_items(self, name: String) -> Error:
        return Error("NotFound: no Models with name '" + name + "' exist in BentoML store " + self.root)

    def _recreate_latest(self, mut t: Tag) raises:
        """Point `latest` at the newest item (BentoML does this when the file is missing or stale)."""
        var items: List[Item]
        try:
            items = self.list(t.name)
        except e:
            if String(e).startswith("NotFound:"):
                raise self._no_items(t.name)
            raise e^
        if len(items) == 0:
            raise self._no_items(t.name)
        var best = 0
        for i in range(1, len(items)):
            if items[i].micros > items[best].micros:  # stable newest-first: the first of equals wins
                best = i
        _write(self.root + "/" + t.name + "/" + LATEST, items[best].tag.version)
        t.version = items[best].tag.version

    def get(self, tag: String) raises -> Item:
        """`name` / `name:latest` (via the latest file), `name:version`, or a unique version prefix."""
        var t = Tag.parse(tag)
        if t.version.byte_length() == 0 or t.version == LATEST:
            var text = String()
            var readable = True
            try:
                text = String(_read(self.root + "/" + t.name + "/" + LATEST).strip())
            except:
                readable = False
            if readable:
                t.version = text
                if not exists(self.root + "/" + t.path()):
                    self._recreate_latest(t)
            else:
                self._recreate_latest(t)
        if exists(self.root + "/" + t.path()):
            return self._load(t.name, t.version)
        var matches = List[String]()
        if isdir(self.root + "/" + t.name):
            for d in _dirs(self.root + "/" + t.name):
                if d.startswith(t.version):
                    matches.append(d)
        if len(matches) == 1:
            return self._load(t.name, matches[0])
        if len(matches) > 1:
            var vers = String()
            for i in range(len(matches)):
                vers += (", " if i > 0 else "") + matches[i]
            raise Error("BentoMLException: Multiple " + t.name + " versions found: " + vers)
        raise Error(
            "NotFound: Model '" + tag + "' is not found in BentoML store " + self.root + ", you may need to run `bentoml models pull` first"
        )

    def register(self, tag: String, created: String) raises -> String:
        """Create `name:version` with a model.yaml stamped `created` (isoformat); returns its directory.
        The caller then copies the model's files in. `latest` moves here when this is the newest item."""
        var t = Tag.parse(tag)
        if t.version.byte_length() == 0:
            raise Error("BentoMLException: register needs name:version, got '" + tag + "'")
        _ = parse_time(created)
        var dir = self.root + "/" + t.path()
        if exists(dir):
            raise Error("BentoMLException: Item '" + t.text() + "' already exists in the store " + self.root)
        makedirs(dir)
        try:
            _write(
                dir + "/" + MODEL_YAML,
                "name: " + t.name + "\nversion: " + t.version + "\nmodule: ''\nlabels: {}\noptions: {}\nmetadata: {}\n"
                "context:\n  framework_name: mojo\n  framework_versions: {}\n  bentoml_version: mojo-bento\n  python_version: '-'\n"
                "signatures: {}\napi_version: v1\ncreation_time: '" + created + "'\n",
            )
        except e:
            _rmtree(dir)
            raise e^
        var latest = self.root + "/" + t.name + "/" + LATEST
        if not exists(latest) or self.get(t.text()).micros >= self.get(t.name).micros:
            _write(latest, t.version)
        return dir

    def delete(self, tag: String) raises:
        """Remove `name:version`, or every version of `name`; `latest` is re-pointed at the newest left."""
        var t = Tag.parse(tag)
        if t.version == LATEST:
            try:
                t.version = String(_read(self.root + "/" + t.name + "/" + LATEST).strip())
            except:
                return
        var path = self.root + "/" + t.path()
        if not exists(path):
            raise Error("NotFound: Model '" + tag + "' not found")
        _rmtree(path)
        if isdir(self.root + "/" + t.name):
            var versions = self.list(t.name)
            if len(versions) == 0:
                _rmtree(self.root + "/" + t.name)
            else:
                var newest = 0
                for i in range(1, len(versions)):
                    if versions[i].micros >= versions[newest].micros:  # sorted() keeps order of equals, [-1] is the last
                        newest = i
                _write(self.root + "/" + t.name + "/" + LATEST, versions[newest].tag.version)
