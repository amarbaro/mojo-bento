#!/usr/bin/env python3
"""B6 gate.
  b6_oracle.py wire CASES BENTO_PORT MOJO_PORT   generator endpoints: the bytes on the wire (status, content-type,
        transfer-encoding, every chunk) equal BentoML's, over HTTP/1.1 and 1.0, with and without keep-alive
  b6_oracle.py sse MOJO_PORT                     text/event-stream frames parsed by httpx-sse equal what was sent;
        the first event arrives long before the last one exists; a client that leaves mid-stream frees the worker
Row: name<TAB>version<TAB>path<TAB>body<TAB>flags   (flags: keepalive = a second request follows on the same connection)
"""
import codecs
import socket
import sys
import time

import httpx
import httpx_sse


def load(path):
    rows = []
    for ln in open(path, encoding="utf-8"):
        ln = ln.rstrip("\n")
        if ln and not ln.startswith("#"):
            name, ver, target, body, flags = (ln.split("\t") + [""])[:5]
            rows.append((name, ver, target, codecs.escape_decode(body)[0], set(f for f in flags.split(",") if f)))
    return rows


def read_response(s, buf):
    """(status, headers, chunks or [body], leftover, eof) of one response read from the socket."""
    while b"\r\n\r\n" not in buf:
        x = s.recv(65536)
        if not x:
            return None
        buf += x
    head, buf = buf.split(b"\r\n\r\n", 1)
    lines = head.split(b"\r\n")
    status = int(lines[0].split()[1])
    hdr = {}
    for ln in lines[1:]:
        k, v = ln.split(b":", 1)
        hdr[k.strip().lower().decode()] = v.strip().decode()
    chunks, eof = [], False
    if hdr.get("transfer-encoding") == "chunked":
        while True:
            while b"\r\n" not in buf:
                buf += s.recv(65536)
            line, buf = buf.split(b"\r\n", 1)
            size = int(line, 16)
            while len(buf) < size + 2:
                buf += s.recv(65536)
            if size == 0:
                buf = buf[2:]
                break
            chunks.append(buf[:size])
            buf = buf[size + 2 :]
    elif "content-length" in hdr:
        n = int(hdr["content-length"])
        while len(buf) < n:
            buf += s.recv(65536)
        chunks, buf = [buf[:n]], buf[n:]
    else:
        while True:
            x = s.recv(65536)
            if not x:
                break
            buf += x
        chunks, buf, eof = [buf], b"", True
    return status, hdr, chunks, buf, eof


def fetch(port, ver, target, body, keepalive):
    s = socket.create_connection(("127.0.0.1", port))
    s.settimeout(10)
    conn = b"" if keepalive else b"Connection: close\r\n"
    s.sendall(b"POST %s HTTP/%s\r\nHost: x\r\nContent-Type: application/json\r\n%sContent-Length: %d\r\n\r\n%s" % (target.encode(), ver.encode(), conn, len(body), body))
    first = read_response(s, b"")
    out = [(first[0], first[1].get("content-type"), first[1].get("transfer-encoding"), first[2])]
    if keepalive:
        s.sendall(b"GET /healthz HTTP/1.1\\r\\nHost: x\\r\\nConnection: close\\r\\n\\r\\n".replace(b"\\r\\n", b"\r\n"))
        second = read_response(s, first[3])
        out.append(("then", second[0] if second else None, second[2] if second else None))
    s.settimeout(0.3)
    try:
        closed = s.recv(1) == b""
    except socket.timeout:
        closed = False
    except ConnectionError:
        closed = True
    s.close()
    return out, closed


def wire(cases, bp, mp):
    fails = 0
    rows = load(cases)
    for name, ver, target, body, flags in rows:
        want, got = fetch(bp, ver, target, body, "keepalive" in flags), fetch(mp, ver, target, body, "keepalive" in flags)
        if want != got:
            fails += 1
            print("FAIL %s\n  bentoml %r\n  mojo    %r" % (name, want, got))
    print("b6 wire: %d rows, %d failed" % (len(rows), fails))
    return fails


def events(client, n):
    with httpx_sse.connect_sse(client, "POST", "/events", json={"n": n}) as src:
        assert src.response.headers["content-type"].startswith("text/event-stream"), src.response.headers
        return [(e.event, e.data, e.id) for e in src.iter_sse()]


def sse(port):
    base = "http://127.0.0.1:%d" % port
    with httpx.Client(base_url=base, timeout=10) as c:
        got = events(c, 5)
        want = [("tick" if i % 2 == 0 else "message", "line1\nline2 é %d" % i, str(i)) for i in range(5)]
        want.append(("message", "[DONE]", str(4)))  # id persists as the last event id
        assert got == want, "events:\n got  %r\n want %r" % (got, want)
        assert events(c, 0) == [("message", "[DONE]", "")], "empty stream"
        raw = c.post("/events", json={"n": 2}).content
        assert raw.startswith(b"event: tick\nid: 0\ndata: line1\ndata: line2 \xc3\xa9 0\n\n"), raw[:80]
        # incremental delivery: 6 items 150 ms apart; the first must reach us long before the generator is done
        t0 = time.time()
        arrivals = []
        with c.stream("POST", "/slow", json={"n": 6, "ms": 150}) as r:
            for part in r.iter_raw():
                arrivals.append(time.time() - t0)
        assert arrivals[0] < 0.12 and arrivals[-1] > 0.7 and len(arrivals) >= 6, "buffered, not streamed: %r" % arrivals
        # a client that walks away mid-stream must not hold the worker: leave 8 times (workers: 4), then still serve
        for _ in range(8):
            s = socket.create_connection(("127.0.0.1", port))
            body = b'{"n":1000000,"ms":1}'
            s.sendall(b"POST /slow HTTP/1.1\r\nHost: x\r\nContent-Length: %d\r\n\r\n%s" % (len(body), body))
            s.recv(200)
            s.close()
        t1 = time.time()
        ok = False
        while time.time() - t1 < 5:
            try:
                if c.post("/add", json={"a": 1, "b": 2}, timeout=1).text == "3":
                    ok = True
                    break
            except httpx.HTTPError:
                pass
        assert ok, "workers still held 5 s after 8 clients left mid-stream"
        # the last abandoned stream is noticed on its next write, a few ms after /add answers: poll, don't read once
        t2 = time.time()
        while True:
            idle = [s for s in c.get("/metrics").text.splitlines() if s.startswith("bentoml_service_request_in_progress") and 'endpoint="/slow"' in s]
            if (idle and idle[0].endswith(" 0.0")) or time.time() - t2 > 5:
                break
            time.sleep(0.05)
        assert idle and idle[0].endswith(" 0.0"), "in_progress for /slow still not 0 after 5 s: %r" % idle
    print("b6 sse: httpx-sse parsed 6 events equal to those sent; first of 6 slow items after %.0f ms, last after %.0f ms; 8 mid-stream disconnects freed the workers in %.2f s" % (arrivals[0] * 1000, arrivals[-1] * 1000, time.time() - t1))
    return 0


if sys.argv[1] == "wire":
    sys.exit(1 if wire(sys.argv[2], int(sys.argv[3]), int(sys.argv[4])) else 0)
sys.exit(sse(int(sys.argv[2])))
