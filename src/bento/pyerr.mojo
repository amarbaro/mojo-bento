"""Error bodies byte-equal to BentoML's: pydantic validation issues, serde_json parse messages and
starlette's JSONResponse layout (compact separators, UTF-8 not escaped)."""
from json import Json

comptime PYDANTIC = "2.14"  # the version in every issue url; BentoML 1.4.39 (the dev dependency in pyproject.toml) pins it
comptime GENERIC_500 = '{"error":"An unexpected error has occurred, please check the server log."}'


def quote(s: String) -> String:
    """json.dumps(s, ensure_ascii=False): quotes, backslash and C0 controls escaped, the rest raw."""
    var out = List[UInt8](capacity=s.byte_length() + 2)
    out.append(34)
    for c in s.as_bytes():
        if c == 34 or c == 92:
            out.append(92)
            out.append(c)
        elif c == 10:
            out.extend("\\n".as_bytes())
        elif c == 13:
            out.extend("\\r".as_bytes())
        elif c == 9:
            out.extend("\\t".as_bytes())
        elif c == 8:
            out.extend("\\b".as_bytes())
        elif c == 12:
            out.extend("\\f".as_bytes())
        elif c < 32:
            out.extend(("\\u00" + String(_hex(Int(c) >> 4)) + String(_hex(Int(c) & 15))).as_bytes())
        else:
            out.append(c)
    out.append(34)
    return String(unsafe_from_utf8=Span(out))


def _hex(n: Int) -> String:
    return chr(48 + n) if n < 10 else chr(87 + n)


def issue(kind: String, loc: Json, msg: String) -> Json:
    """One pydantic error entry, keys in the order `ValidationError.errors()` gives."""
    var j = Json.object()
    j.set("type", Json.of(kind))
    j.set("loc", loc)
    j.set("msg", Json.of(msg))
    j.set("url", Json.of("https://errors.pydantic.dev/" + PYDANTIC + "/v/" + kind))
    return j^


def validation_body(issues: Json) -> String:
    """BentoML's 400 body for a failed Input model. The count line is always singular ("2 validation
    error for Input"): BentoML formats it itself instead of using pydantic's text."""
    var root = Json.object()
    root.set("error", Json.of(String(issues.len()) + " validation error for Input"))
    root.set("detail", issues)
    return root.dumps()


def _col(b: Span[UInt8, _], idx: Int) -> String:
    """serde_json's "at line L column C" for the byte at idx (the last byte for an end of input)."""
    var line = 1
    var last = -1
    for i in range(min(idx, len(b))):
        if b[i] == 10:
            line += 1
            last = i
    return " at line " + String(line) + " column " + String(idx - last)


def _innermost(b: Span[UInt8, _], at: Int) -> UInt8:
    """The innermost bracket still open before `at`, outside strings: '{' or '['."""
    var stack = List[UInt8]()
    var in_str = False
    var i = 0
    while i < at and i < len(b):
        var c = b[i]
        if in_str:
            if c == 92:
                i += 1
            elif c == 34:
                in_str = False
        elif c == 34:
            in_str = True
        elif c == 123 or c == 91:
            stack.append(c)
        elif (c == 125 or c == 93) and len(stack) > 0:
            _ = stack.pop()
        i += 1
    return stack[len(stack) - 1] if len(stack) > 0 else 0


def _prev(b: Span[UInt8, _], at: Int) -> UInt8:
    var i = at - 1
    while i >= 0 and (b[i] == 32 or b[i] == 10 or b[i] == 13 or b[i] == 9):
        i -= 1
    return b[i] if i >= 0 else 0


def json_invalid(body: Span[UInt8, _], err: String) -> String:
    """pydantic's `Invalid JSON: <serde message> at line L column C` for what mojo-json rejected
    (`json: <what> at byte N`). Reproduced: EOF in a value, string, object or list; key must be a string;
    expected `:`; expected `,` or `}`/`]`; trailing comma; trailing characters; expected ident; expected value."""
    var parts = err.split(" at byte ")
    var what = String(parts[0])[byte=6:]
    var p = 0
    try:
        p = Int(parts[1]) if len(parts) > 1 else 0
    except:
        pass
    var n = len(body)
    var eof = n - 1
    var msg = "expected value"
    var at = p
    if what == "unexpected end":
        msg, at = "EOF while parsing a value", eof
    elif what == "unterminated string":
        msg, at = "EOF while parsing a string", eof
    elif what == "object key expected":
        if p >= n:
            msg, at = "EOF while parsing an object", eof
        elif body[p] == 125 and _prev(body, p) == 44:
            msg = "trailing comma"
        else:
            msg = "key must be a string"
    elif what == "':' expected":
        if p >= n:
            msg, at = "EOF while parsing an object", eof
        else:
            msg = "expected `:`"
    elif what == "',' or closing bracket expected":
        var obj = _innermost(body, p) == 123
        if p >= n:
            msg, at = "EOF while parsing " + ("an object" if obj else "a list"), eof
        else:
            msg = "expected `,` or `}`" if obj else "expected `,` or `]`"
    elif what == "extra data":
        msg = "trailing characters"
    elif what == "value expected" and p < n:
        var lit = String("true") if body[p] == 116 else (String("false") if body[p] == 102 else (String("null") if body[p] == 110 else String()))
        if body[p] == 93 and _prev(body, p) == 44:
            msg = "trailing comma"
        elif lit.byte_length() > 0:
            var k = 0
            while p + k < n and k < lit.byte_length() and body[p + k] == lit.as_bytes()[k]:
                k += 1
            msg, at = "expected ident", p + k
    return "Invalid JSON: " + msg + _col(body, at)
