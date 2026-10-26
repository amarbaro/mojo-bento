"""TCP and epoll over libc: what mojo-posix (unix sockets, poll) does not carry. Linux x86-64: the kernel
packs `struct epoll_event` to 12 bytes there."""
from std.ffi import external_call
from posix import close
from posix._sys import CLOEXEC, NONBLOCK, EINTR, EAGAIN, errno, error

comptime EPOLLIN = 1
comptime EPOLLOUT = 4
comptime EPOLLERR = 8
comptime EPOLLHUP = 0x10
comptime EPOLLRDHUP = 0x2000
comptime EPOLLONESHOT = 1 << 30
comptime _ADD = 1
comptime _DEL = 2
comptime _MOD = 3
comptime _EV = 12  # sizeof(struct epoll_event), packed


def _ipv4(host: String) raises -> UInt32:
    """Network-order address of a dotted quad; "localhost" is 127.0.0.1, "" and "*" are 0.0.0.0."""
    if host == "" or host == "*":
        return 0
    var h = host
    if h == "localhost":
        h = "127.0.0.1"
    var parts = h.split(".")
    if len(parts) != 4:
        raise Error("net: not an IPv4 address: ", host)
    var out = UInt32(0)
    for i in range(4):
        var v = Int(parts[i])
        if v < 0 or v > 255:
            raise Error("net: not an IPv4 address: ", host)
        out |= UInt32(v) << UInt32(8 * i)  # first octet in the low byte = network order on a little-endian host
    return out


def tcp_listen(host: String, port: Int, backlog: Int = 1024) raises -> Int32:
    """A non-blocking, close-on-exec listening socket on host:port (port 0 picks one; see local_port)."""
    var addr = List[UInt8](length=16, fill=0)
    addr[0] = 2  # AF_INET
    addr[2] = UInt8((port >> 8) & 0xFF)
    addr[3] = UInt8(port & 0xFF)
    var ip = _ipv4(host)
    for i in range(4):
        addr[4 + i] = UInt8((ip >> UInt32(8 * i)) & 0xFF)
    var fd = external_call["socket", Int32](Int32(2), Int32(1 | CLOEXEC | NONBLOCK), Int32(0))
    if fd < 0:
        raise error("socket")
    var one = Int32(1)
    _ = external_call["setsockopt", Int32](fd, Int32(1), Int32(2), Pointer(to=one), Int32(4))  # SO_REUSEADDR
    var rc = external_call["bind", Int32](fd, addr.unsafe_ptr(), Int32(16))
    var what = "bind " + host + ":" + String(port)
    if rc == 0:
        rc = external_call["listen", Int32](fd, Int32(backlog))
        what = "listen"
    _ = addr[0]
    if rc != 0:
        var e = error(what)
        close(fd)
        raise e^
    return fd


def local_port(fd: Int32) -> Int:
    """The port a socket is bound to; -1 on error."""
    var addr = List[UInt8](length=16, fill=0)
    var len = Int32(16)
    if external_call["getsockname", Int32](fd, addr.unsafe_ptr(), Pointer(to=len)) != 0:
        return -1
    return (Int(addr[2]) << 8) | Int(addr[3])


def tcp_accept(fd: Int32) raises -> Int32:
    """The next waiting connection (non-blocking, close-on-exec, TCP_NODELAY), or -1 when none waits."""
    while True:
        var c = external_call["accept4", Int32](fd, Int(0), Int(0), Int32(CLOEXEC | NONBLOCK))
        if c >= 0:
            var one = Int32(1)
            _ = external_call["setsockopt", Int32](c, Int32(6), Int32(1), Pointer(to=one), Int32(4))  # TCP_NODELAY
            return c
        var e = errno()
        if e == EAGAIN or e == 103 or e == 24 or e == 23:  # ECONNABORTED, EMFILE, ENFILE: drop it, keep serving
            return -1
        if e != EINTR:
            raise error("accept")


def epoll_create() raises -> Int32:
    var ep = external_call["epoll_create1", Int32](Int32(CLOEXEC))
    if ep < 0:
        raise error("epoll_create1")
    return ep


def _ctl(ep: Int32, op: Int, fd: Int32, events: Int) -> Bool:
    var ev = List[UInt8](length=_EV, fill=0)
    var p = ev.unsafe_ptr().unsafe_bitcast[Int32]()
    p[unsafe_offset=0] = Int32(events)
    p[unsafe_offset=1] = fd
    var rc = external_call["epoll_ctl", Int32](ep, Int32(op), fd, p)
    _ = ev[0]
    return rc == 0


def epoll_add(ep: Int32, fd: Int32, events: Int) -> Bool:
    return _ctl(ep, _ADD, fd, events)


def epoll_rearm(ep: Int32, fd: Int32, events: Int) -> Bool:
    """Re-enable a EPOLLONESHOT descriptor."""
    return _ctl(ep, _MOD, fd, events)


def epoll_del(ep: Int32, fd: Int32):
    _ = _ctl(ep, _DEL, fd, 0)


struct EpollBuf(Movable):
    """Room for the events of one epoll_wait."""

    var raw: List[UInt8]
    var cap: Int

    def __init__(out self, cap: Int = 1):
        self.cap = cap
        self.raw = List[UInt8](length=cap * _EV, fill=0)

    def wait(self, ep: Int32, timeout_ms: Int) -> Int:
        """Ready events (0 on timeout or a signal)."""
        var n = Int(external_call["epoll_wait", Int32](ep, self.raw.unsafe_ptr(), Int32(self.cap), Int32(timeout_ms)))
        return n if n > 0 else 0

    def fd(self, i: Int) -> Int32:
        return self.raw.unsafe_ptr().unsafe_bitcast[Int32]()[unsafe_offset=3 * i + 1]

    def events(self, i: Int) -> Int:
        return Int(self.raw.unsafe_ptr().unsafe_bitcast[Int32]()[unsafe_offset=3 * i])
