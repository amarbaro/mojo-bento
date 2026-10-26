"""B2: endpoints. An Endpoint is a struct with a comptime `name`, an input schema and a `call` from validated
arguments to a JSON result. `Service[*Es]` is a Handler that serves `POST /<name>` for each of them and
answers like BentoML does: pydantic-style 400 bodies for bad input, `[{"error": msg}]` for an HttpError,
a fixed 500 for anything else, text/plain for a string result and JSON for the rest."""
from std.atomic import Atomic, Ordering
from std.builtin.rebind import downcast, rebind
from std.time import perf_counter_ns
from json import Json, parse, STR, INT, FLOAT, BOOL, NULL, ARR, OBJ
from bento.http import Request, Response
from bento.metrics import CONTENT_TYPE, Metrics
from bento.pyerr import GENERIC_500, issue, json_invalid, quote, validation_body
from bento.server import Handler

comptime T_STR = 0
comptime T_INT = 1
comptime T_FLOAT = 2
comptime T_BOOL = 3
comptime T_LIST = 4  # of Field.item
comptime _HTTP = "bento-http:"


struct Field(Copyable, Movable):
    var name: String
    var kind: Int
    var item: Int  # element kind of a T_LIST
    var required: Bool
    var default: Json

    def __init__(out self, name: String, kind: Int, item: Int = T_STR):
        """A required field."""
        self.name = name
        self.kind = kind
        self.item = item
        self.required = True
        self.default = Json()

    def __init__(out self, name: String, kind: Int, default: Json):
        """An optional field; `default` is used as is when the key is absent."""
        self.name = name
        self.kind = kind
        self.item = T_STR
        self.required = False
        self.default = default.copy()


trait Routable(Movable, Deinitable):
    """What Service routes on: a name and an input model. Implement Endpoint or StreamEndpoint."""

    comptime name: StaticString

    def fields(self) -> List[Field]:
        """The input model, in the order issues are reported."""
        ...


trait Endpoint(Routable):
    def call(self, args: Json) raises -> Json:
        """`args` is an object holding every field, validated and coerced (defaults filled in).
        A string result is sent as text/plain, anything else as JSON."""
        ...


trait StreamEndpoint(Routable):
    def stream(self, args: Json, mut resp: Response) raises:
        """Send results as they exist: `emit(resp, item)` per item (BentoML's wire form: one chunk each),
        or `resp.sse(data, event, id)` for text/event-stream frames. Raising before the first send answers like
        any endpoint error; raising later ends the stream where it stands, as BentoML does."""
        ...


def emit(mut resp: Response, item: Json) raises:
    """One item of a generator endpoint as one chunk: a string as is, anything else as Python's json.dumps."""
    if item.kind() == STR:
        resp.write(item.str())
    else:
        resp.write(item.dumps(False))


def http_error(status: Int, message: String) -> Error:
    """Raise this from `call` for a 4xx the client should see: BentoML answers `[{"error": message}]`
    (401 and 403 give {"error": "Authorization error"}, 5xx the generic 500 body)."""
    return Error(_HTTP, status, ":", message)


# ---------------------------------------------------------------- pydantic's lax validation of JSON input

def _loc(name: String, idx: Int = -1) -> Json:
    var loc = Json.array()
    loc.push(Json.of(name))
    if idx >= 0:
        loc.push(Json.of(idx))
    return loc^


def _parse_int(s: String, mut out: Int) -> Bool:
    var t = String(s.strip())
    var b = t.as_bytes()
    var i = 1 if len(b) > 0 and (b[0] == 45 or b[0] == 43) else 0
    if i >= len(b) or len(b) - i > 18:
        return False
    var n = 0
    for k in range(i, len(b)):
        if b[k] < 48 or b[k] > 57:
            return False
        n = n * 10 + Int(b[k]) - 48
    out = -n if b[0] == 45 else n
    return True


def _bool_word(s: String) -> Int:
    """1/0 for the words pydantic reads as true/false, -1 otherwise."""
    var t = String(s.strip()).lower()
    if t == "1" or t == "on" or t == "t" or t == "true" or t == "y" or t == "yes":
        return 1
    if t == "0" or t == "off" or t == "f" or t == "false" or t == "n" or t == "no":
        return 0
    return -1


def _coerce(v: Json, kind: Int, item: Int, name: String, idx: Int, mut out: Json, mut issues: Json):
    """Set `out` to v coerced to `kind`, or append the issue pydantic would report."""
    var k = v.kind()
    if kind == T_STR:
        if k == STR:
            out = v.copy()
        else:
            issues.push(issue("string_type", _loc(name, idx), "Input should be a valid string"))
    elif kind == T_INT:
        var n = 0
        if k == INT:
            out = v.copy()
        elif k == BOOL:
            out = Json.of(v.int())
        elif k == FLOAT:
            var f = v.num()
            if f == Float64(Int(f)) and f > -9.2e18 and f < 9.2e18:
                out = Json.of(Int(f))
            else:
                issues.push(issue("int_from_float", _loc(name, idx), "Input should be a valid integer, got a number with a fractional part"))
        elif k == STR:
            if _parse_int(v.str(), n):
                out = Json.of(n)
            else:
                issues.push(issue("int_parsing", _loc(name, idx), "Input should be a valid integer, unable to parse string as an integer"))
        else:
            issues.push(issue("int_type", _loc(name, idx), "Input should be a valid integer"))
    elif kind == T_FLOAT:
        if k == INT or k == FLOAT:
            out = Json.of(v.num())
        elif k == BOOL:
            out = Json.of(Float64(v.int()))
        elif k == STR:
            try:
                out = Json.of(Float64(String(v.str().strip())))
            except:
                issues.push(issue("float_parsing", _loc(name, idx), "Input should be a valid number, unable to parse string as a number"))
        else:
            issues.push(issue("float_type", _loc(name, idx), "Input should be a valid number"))
    elif kind == T_BOOL:
        var w = -2
        if k == BOOL:
            w = v.int()
        elif k == INT or k == FLOAT:
            w = 1 if v.num() == 1.0 else (0 if v.num() == 0.0 else -1)
        elif k == STR:
            w = _bool_word(v.str())
        if w >= 0:
            out = Json.of(w == 1)
        elif w == -1:
            issues.push(issue("bool_parsing", _loc(name, idx), "Input should be a valid boolean, unable to interpret input"))
        else:
            issues.push(issue("bool_type", _loc(name, idx), "Input should be a valid boolean"))
    else:
        if k != ARR:
            issues.push(issue("list_type", _loc(name, idx), "Input should be a valid array"))
            return
        out = Json.array()
        for i in range(v.len()):
            var el = Json()
            _coerce(v.at(i), item, T_STR, name, i, el, issues)
            out.push(el)


def validate(fields: List[Field], body: Json, mut args: Json, mut issues: Json):
    """Fill `args` from `body` the way BentoML's input model does; failures go to `issues`."""
    args = Json.object()
    if body.kind() != OBJ:
        issues.push(issue("model_type", Json.array(), "Input should be an object"))
        return
    for f in fields:
        if not body.has(f.name):
            if f.required:
                issues.push(issue("missing", _loc(f.name), "Field required"))
            else:
                args.set(f.name, f.default)
            continue
        var out = Json()
        _coerce(body.get(f.name), f.kind, f.item, f.name, -1, out, issues)
        args.set(f.name, out)


# ---------------------------------------------------------------- the service

def _json_response(status: Int, body: String) -> Response:
    return Response.text(status, body, "application/json")


def _error_response(e: Error) -> Response:
    var msg = String(e)
    if not msg.startswith(_HTTP):
        return _json_response(500, GENERIC_500)
    var rest = msg[byte = _HTTP.byte_length() :]
    var colon = rest.find(":")
    var status = 500
    try:
        status = Int(rest[byte=0:colon])
    except:
        pass
    var text = String(rest[byte = colon + 1 :])
    if status == 401 or status == 403:
        return _json_response(status, '{"error":"Authorization error"}')
    if status >= 500:
        return _json_response(500 if status == 500 else status, GENERIC_500)
    return _json_response(status, "[{\"error\":" + quote(text) + "}]")


def _input(fields: List[Field], req: Request, mut resp: Response, mut args: Json) -> Bool:
    """POST body to validated args. False: `resp` holds the answer (405, 400)."""
    if req.method != "POST":
        resp = Response.text(405, "Method Not Allowed")
        resp.add("allow", "POST")
        return False
    var issues = Json.array()
    var body = Json.object()
    if len(req.body) > 0:
        try:
            body = parse(Span(req.body))
        except e:
            var bad = Json.array()
            bad.push(issue("json_invalid", Json.array(), json_invalid(Span(req.body), String(e))))
            resp = _json_response(400, validation_body(bad))
            return False
    validate(fields, body, args, issues)
    if issues.len() > 0:
        resp = _json_response(400, validation_body(issues))
        return False
    return True


def _serve[E: Endpoint](ep: E, req: Request, mut resp: Response):
    var args = Json()
    if not _input(ep.fields(), req, resp, args):
        return
    try:
        var out = ep.call(args)
        if out.kind() == STR:
            resp = Response.text(200, out.str())
        else:
            resp = _json_response(200, out.dumps(False))
    except e:
        resp = _error_response(e)


def _serve_stream[E: StreamEndpoint](ep: E, req: Request, mut resp: Response):
    var args = Json()
    if not _input(ep.fields(), req, resp, args):
        return
    try:
        ep.stream(args, resp)
        resp.begin_stream("text/event-stream; charset=utf-8")  # a stream with no items still answers
    except e:
        if resp.state == 0:
            resp = _error_response(e)
            return
    resp.end_stream()


def _allow(mut resp: Response, methods: String):
    resp = Response.text(405, "Method Not Allowed")
    resp.add("allow", methods)


struct Service[*Es: Routable](Handler):
    """Serves `POST /<name>` per endpoint plus BentoML's built-ins: GET/HEAD /healthz, /livez, /readyz and
    GET /metrics (Prometheus text). /readyz answers 503 after `set_ready(False)` so a balancer drains the process
    before `Server.stop()`."""

    var eps: Tuple[*Self.Es]
    var metrics: Metrics
    var flags: List[Int32]  # [0]: ready
    var flag_p: Pointer[Int32, MutUntrackedOrigin]

    def __init__(out self, var *eps: *Self.Es, name: String = "mojo-bento"):
        self.eps = Tuple(*eps^)
        var paths = List[String]()
        comptime for i in range(Self.Es.__len__()):
            paths.append("/" + String(Self.Es[i].name))
        self.metrics = Metrics(name, paths^)
        self.flags = List[Int32](length=4, fill=0)
        self.flags[0] = 1
        self.flag_p = Pointer[Int32, MutUntrackedOrigin](unsafe_from_address=Int(self.flags.unsafe_ptr()))

    def draining(self):
        self.set_ready(False)

    def set_ready(self, ready: Bool):
        Atomic[Int32].store[ordering=Ordering.RELEASE](self.flag_p, Int32(1) if ready else Int32(0))

    def handle(self, req: Request, mut resp: Response) raises:
        var path = req.path
        if path == "/healthz" or path == "/livez" or path == "/readyz":
            if req.method != "GET" and req.method != "HEAD":
                _allow(resp, "GET, HEAD")
            elif path == "/readyz" and Atomic[Int32].load[ordering=Ordering.ACQUIRE](self.flag_p) == 0:
                resp = Response.text(503, "\n")
            else:
                resp = Response.text(200, "\n")
            return
        if path == "/metrics":
            if req.method != "GET" and req.method != "HEAD":
                _allow(resp, "GET, HEAD")
            else:
                resp = Response.text(200, self.metrics.render(), CONTENT_TYPE)
            return
        comptime for i in range(Self.Es.__len__()):
            comptime E = Self.Es[i]
            if path == "/" + String(E.name):
                var t0 = perf_counter_ns()
                self.metrics.begin(i)
                comptime if conforms_to(E, StreamEndpoint):
                    _serve_stream[downcast[E, StreamEndpoint]](rebind[downcast[E, StreamEndpoint]](self.eps[i]), req, resp)
                else:
                    _serve[downcast[E, Endpoint]](rebind[downcast[E, Endpoint]](self.eps[i]), req, resp)
                self.metrics.end(i, resp.status, Int(perf_counter_ns() - t0))
                return
        resp = Response.text(404, "Not Found")
