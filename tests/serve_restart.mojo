"""serve() closes what it opened: in one process, a Server holds K idle keep-alive clients, stop() and join;
every client must then read EOF, and after the Server is gone /proc/self/fd must be back to its old count
(listen socket, epoll fd and every accepted fd). Two rounds: the second Server must not inherit a leak."""
from std.ffi import external_call
from std.os import listdir
from posix import recv, send_all, close
from bento.http import Request, Response, Limits
from bento.server import Server, Handler


struct Ok(Handler):
    def __init__(out self):
        pass

    def draining(self):
        pass

    def handle(self, req: Request, mut resp: Response) raises:
        resp.body.extend("ok".as_bytes())


def _serve_main(arg: Int) abi("C") -> Int:
    var s = Pointer[Server[Ok], MutUntrackedOrigin](unsafe_from_address=arg)
    try:
        s[].serve(1)
    except:
        pass
    return 0


def _connect(port: Int) raises -> Int32:
    """A blocking client socket with a 3 s receive timeout, connected to 127.0.0.1:port."""
    var fd = external_call["socket", Int32](Int32(2), Int32(1), Int32(0))
    var tv = SIMD[DType.int64, 2](3, 0)
    _ = external_call["setsockopt", Int32](fd, Int32(1), Int32(20), Pointer(to=tv), Int32(16))  # SO_RCVTIMEO
    var addr = SIMD[DType.uint32, 4](UInt32(2) | (UInt32(port & 0xFF) << 24) | (UInt32(port >> 8) << 16), 0x0100007F, 0, 0)
    if external_call["connect", Int32](fd, Pointer(to=addr), Int32(16)) != 0:
        raise Error("connect failed")
    return fd


def _recv(fd: Int32) -> Int:
    var b = List[UInt8]()
    return recv(fd, b, True)


def _round(k: Int) raises:
    var srv = Server(Ok(), "127.0.0.1", 0, Limits(), 1024)
    var tid = UInt64(0)
    _ = external_call["pthread_create", Int32](Pointer(to=tid), Int(0), _serve_main, Int(Pointer(to=srv)))
    var clients = List[Int32]()
    var req = "GET / HTTP/1.1\r\nhost: x\r\n\r\n"
    for _ in range(k):
        var c = _connect(srv.port())
        _ = send_all(c, req.as_bytes())
        if _recv(c) <= 0:
            raise Error("no response")   # the connection is accepted and idle, keep-alive
        clients.append(c)
    srv.stop()
    _ = external_call["pthread_join", Int32](tid, Int(0))
    for c in clients:
        var n = _recv(c)
        if n != 0:
            raise Error("a client did not read EOF after serve() returned (recv ", n, ")")
        close(c)
    _ = srv.port()   # the thread holds a pointer to srv: keep it alive to here


def main() raises:
    var before = len(listdir("/proc/self/fd"))
    for _ in range(2):
        _round(6)
        var after = len(listdir("/proc/self/fd"))
        if after != before:
            raise Error("fd leak: ", before, " open before, ", after, " after a Server round")
    print("serve_restart: ok")
