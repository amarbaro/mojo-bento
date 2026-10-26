"""The B1 test service: answers every request with a description of what the parser saw, so the
raw-HTTP gate can compare it with the oracle (tools/http_oracle.py)."""
from std.sys import argv
from posix import block_signals
from bento.http import Request, Response, Limits
from bento.server import Server, Handler


struct Echo(Handler):
    def __init__(out self):
        pass

    def draining(self):
        pass

    def handle(self, req: Request, mut resp: Response) raises:
        var s = req.method + " " + req.target + " HTTP/1." + String(req.minor) + "\n"
        for i in range(len(req.names)):
            s += req.names[i] + ": " + req.values[i] + "\n"
        s += "body-len: " + String(len(req.body)) + "\nbody: "
        resp.add("content-type", "text/plain")
        resp.body.extend(s.as_bytes())
        resp.body.extend(Span(req.body))


def main() raises:
    block_signals([2, 15])
    var args = argv()
    var port = Int(args[1]) if len(args) > 1 else 0
    var srv = Server(Echo(), "127.0.0.1", port, Limits(8192, 1024))
    print("LISTEN", srv.port(), flush=True)
    srv.serve(4, True)
