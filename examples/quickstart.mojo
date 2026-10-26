"""One endpoint, answered without a socket: parse raw HTTP bytes, hand them to a Service, print the answer.
To serve it on a port instead, replace `ask` by `Server(Service(Add()), "127.0.0.1", 3000).serve(4)`."""
from json import Json
from bento.endpoint import Service, Endpoint, Field, T_INT
from bento.http import Limits, Request, Response, parse_request


struct Add(Endpoint):
    comptime name = "add"

    def __init__(out self):
        pass

    def fields(self) -> List[Field]:
        return [Field("a", T_INT), Field("b", T_INT)]

    def call(self, args: Json) raises -> Json:
        return Json.of(args.get("a").int() + args.get("b").int())


def ask(svc: Service[Add], body: String) raises:
    var raw = "POST /add HTTP/1.1\r\nhost: x\r\ncontent-type: application/json\r\ncontent-length: " + String(
        body.byte_length()
    ) + "\r\n\r\n" + body
    var req = Request()
    var parsed = parse_request(raw.as_bytes(), req, Limits())
    if parsed.status != 0:
        raise Error("bad request, status " + String(parsed.status))
    var resp = Response()
    svc.handle(req, resp)
    print(resp.status, String(unsafe_from_utf8=Span(resp.body)))


def main() raises:
    var svc = Service(Add())
    ask(svc, '{"a": 1, "b": 2}')  # 200 3
    ask(svc, '{"a": "x", "b": 2}')  # 400, BentoML's validation error body
