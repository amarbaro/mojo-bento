#!/usr/bin/env python3
"""Oracle for the B1 raw-HTTP gate (tests/cases/http.txt).

Two reference servers answer the same raw bytes as the Mojo server (tests/echo_server.mojo):
  h11     a blocking-socket server whose parsing is h11's (the authority on what a request is),
          plus the policy h11 leaves to the server (limits, versions, Content-Length + Transfer-Encoding)
  stdlib  http.server.BaseHTTPRequestHandler, checked only on the rows flagged `hs`

Each side's answer is normalised to: status, content-type, content-length and body of every 2xx
response (status alone for errors), then whether the server closed the connection.

  http_oracle.py check CASES PORT      Mojo server on PORT against the h11 oracle, every row
  http_oracle.py selfcheck CASES       h11 oracle against http.server on the `hs` rows
"""
import codecs
from concurrent.futures import ThreadPoolExecutor
import hashlib
import http.server
import re
import socket
import subprocess
import sys
import threading
import time

import h11

HEAD_MAX = 8192  # must equal Limits(...) in tests/echo_server.mojo
BODY_MAX = 1024
IDLE = 0.4  # silence that ends a case


def load(path):
    cases = []
    for ln in open(path, encoding="utf-8"):
        ln = ln.rstrip("\n")
        if not ln or ln.startswith("#"):
            continue
        name, flags, raw = ln.split("\t", 2)
        raw = re.sub(r"\{(.)\*(\d+)\}", lambda m: m.group(1) * int(m.group(2)), raw)
        cases.append((name, set(f for f in flags.split(",") if f), codecs.escape_decode(raw)[0]))
    return cases


def echo_body(method, target, minor, headers, body):
    s = b"%s %s HTTP/1.%d\n" % (method, target, minor)
    for n, v in headers:
        s += n + b": " + v + b"\n"
    return s + b"body-len: %d\nbody: " % len(body) + body


# ---------------------------------------------------------------- h11 oracle

def reply(sock, status, body=b"", close=False, head=False):
    reason = {200: b"OK", 100: b"Continue"}.get(status, b"Error")
    out = b"HTTP/1.1 %d %s\r\n" % (status, reason)
    if status != 100:
        out += b"content-type: text/plain\r\ncontent-length: %d\r\n" % len(body)
    if close:
        out += b"connection: close\r\n"
    out += b"\r\n"
    if not head and status != 100:
        out += body
    sock.sendall(out)


def h11_conn(sock):
    """One connection. h11 parses; the status codes for what h11 does not police are this file's policy."""
    conn = h11.Connection(h11.SERVER, max_incomplete_event_size=10**9)
    req, body, told, eof = None, b"", False, False
    while True:
        try:
            ev = conn.next_event()
        except (h11.RemoteProtocolError, h11.LocalProtocolError) as e:
            if not eof:
                reply(sock, e.error_status_hint, close=True)
            return  # EOF inside a message: closed, no response
        if ev is h11.NEED_DATA:
            if req is not None and not told and conn.they_are_waiting_for_100_continue:
                told = True
                reply(sock, 100)
            data = sock.recv(65536)
            eof = not data
            conn.receive_data(data)
            if req is None and len(conn._receive_buffer) > HEAD_MAX:
                reply(sock, 431, close=True)  # head not complete within the cap
                return
            continue
        if isinstance(ev, h11.ConnectionClosed):
            return
        if isinstance(ev, h11.Request):
            hs = list(ev.headers)
            names = [n for n, _ in hs]
            if int(ev.http_version.split(b".")[0]) != 1:
                reply(sock, 505, close=True)
                return
            if b"transfer-encoding" in names and b"content-length" in names:
                reply(sock, 400, close=True)  # smuggling shape: refused (h11 lets TE win)
                return
            cl = [v for n, v in hs if n == b"content-length"]
            if cl and int(cl[0].split(b",")[0]) > BODY_MAX:
                reply(sock, 413, close=True)
                return
            req, body, told = (ev.method, ev.target, 0 if ev.http_version == b"1.0" else 1, hs), b"", False
        elif isinstance(ev, h11.Data):
            body += bytes(ev.data)
            if len(body) > BODY_MAX:
                reply(sock, 413, close=True)
                return
        elif isinstance(ev, h11.EndOfMessage):
            method, target, minor, hs = req
            toks = [t.strip().lower() for n, v in hs if n == b"connection" for t in v.split(b",")]
            keep = minor == 1 and b"close" not in toks  # h11 never keeps an HTTP/1.0 connection
            reply(sock, 200, echo_body(method, target, minor, hs, body), close=not keep, head=method == b"HEAD")
            if not keep:
                return
            conn.send(h11.Response(status_code=200, headers=[(b"content-length", b"0")]))
            conn.send(h11.EndOfMessage())
            conn.start_next_cycle()
            req = None


def serve_h11(sock):
    try:
        h11_conn(sock)
    except (ConnectionError, OSError):
        pass
    finally:
        try:
            sock.shutdown(socket.SHUT_RDWR)
        except OSError:
            pass
        sock.close()


# ---------------------------------------------------------------- http.server oracle

class Std(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *a):
        pass

    def _echo(self):
        body = b""
        if self.headers.get("transfer-encoding", "").lower() == "chunked":
            while True:
                size = int(self.rfile.readline().split(b";")[0], 16)
                if size == 0:
                    while self.rfile.readline() not in (b"\r\n", b""):
                        pass
                    break
                body += self.rfile.read(size)
                self.rfile.readline()
        else:
            body = self.rfile.read(int(self.headers.get("content-length", 0)))
        hs = [(k.lower().encode(), v.encode("latin-1")) for k, v in self.headers.items()]
        payload = echo_body(self.command.encode(), self.path.encode(), int(self.request_version[-1]), hs, body)
        self.send_response_only(200)
        self.send_header("content-type", "text/plain")
        self.send_header("content-length", str(len(payload)))
        self.end_headers()
        if self.command != "HEAD":
            self.wfile.write(payload)

    do_GET = do_POST = do_HEAD = do_OPTIONS = do_PURGE = _echo


def serve_std(sock):
    try:
        srv = type("S", (), {"server_name": "x", "server_port": 0})()
        Std(sock, ("127.0.0.1", 0), srv)
    except (ConnectionError, OSError):
        pass
    finally:
        sock.close()


# ---------------------------------------------------------------- client

def exchange(port, raw, flags):
    s = socket.create_connection(("127.0.0.1", port))
    s.settimeout(IDLE)
    split = next((int(f[6:]) for f in flags if f.startswith("split:")), None)
    if "trickle" in flags:
        for i in range(len(raw)):
            s.sendall(raw[i : i + 1])
            time.sleep(0.002)
    elif split is not None:
        s.sendall(raw[:split])
        time.sleep(0.15)
        s.sendall(raw[split:])
    else:
        s.sendall(raw)
    if "half" in flags:
        s.shutdown(socket.SHUT_WR)
    data, closed = b"", False
    s.settimeout(3)  # a slow first byte is not silence; after it, IDLE ends the case
    while True:
        try:
            x = s.recv(65536)
            s.settimeout(IDLE)
        except socket.timeout:
            break
        except ConnectionError:
            closed = True
            break
        if not x:
            closed = True
            break
        data += x
    s.close()
    return normalise(data, "head" in flags) + (" |closed" if closed else " |open")


def digest(b):
    return "%r..%d.%s" % (b[:70], len(b), hashlib.md5(b).hexdigest()[:8])


def normalise(data, head):
    out = []
    while data:
        end = data.find(b"\r\n\r\n")
        if end < 0:
            out.append("TRUNCATED %r" % data[:60])
            break
        lines = data[:end].split(b"\r\n")
        status = int(lines[0].split()[1])
        hdr = {}
        for ln in lines[1:]:
            k, v = ln.split(b":", 1)
            hdr[k.strip().lower()] = v.strip()
        data = data[end + 4 :]
        if status == 100:
            out.append("100")
            continue
        n = int(hdr.get(b"content-length", 0))
        body = b"" if head else data[:n]
        data = data[0 if head else n :]
        if status < 300:
            out.append("%d ct=%s cl=%d body=%s" % (status, hdr.get(b"content-type", b"").decode(), n, digest(body)))
        else:
            out.append(str(status))
    return "; ".join(out)


def start(serve):
    ls = socket.socket()
    ls.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    ls.bind(("127.0.0.1", 0))
    ls.listen(64)

    def loop():
        while True:
            try:
                c, _ = ls.accept()
            except OSError:
                return
            threading.Thread(target=serve, args=(c,), daemon=True).start()

    threading.Thread(target=loop, daemon=True).start()
    return ls.getsockname()[1]


def spawn(kind):
    """An oracle server in its own process (threads of two servers sharing a GIL made closes late)."""
    p = subprocess.Popen([sys.executable, __file__, "serve", kind], stdout=subprocess.PIPE, text=True)
    return p, int(p.stdout.readline())


def main():
    if sys.argv[1] == "serve":
        print(start(serve_h11 if sys.argv[2] == "h11" else serve_std), flush=True)
        threading.Event().wait()
    mode, cases = sys.argv[1], load(sys.argv[2])
    procs = []
    try:
        ph, hp = spawn("h11")
        procs.append(ph)
        if mode == "check":
            other, label, rows = int(sys.argv[3]), "mojo  ", cases
        else:
            ps, other = spawn("std")
            procs.append(ps)
            label, rows = "stdlib", [c for c in cases if "hs" in c[1]]
        def one(row):
            return exchange(hp, row[2], row[1]), exchange(other, row[2], row[1])

        fails = 0
        with ThreadPoolExecutor(8) as pool:  # rows are independent connections
            for (name, _, _), (want, got) in zip(rows, pool.map(one, rows)):
                if want != got:
                    fails += 1
                    print("FAIL %s\n  h11    %s\n  %s %s" % (name, want, label, got))
        print("%s: %d rows, %d failed" % (mode, len(rows), fails))
    finally:
        for q in procs:
            q.kill()
    sys.exit(1 if fails else 0)


if __name__ == "__main__":
    main()
