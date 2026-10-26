#!/usr/bin/env python3
"""Keep-alive request rate: http_bench.py PORT [PROCS=8] [SECONDS=3] [PIPELINE=1] [PATH BODY]. Each process holds
one connection, sends PIPELINE requests (GET /bench, or POST PATH with BODY), reads the responses, repeats.
Prints requests/s."""
import multiprocessing as mp
import socket
import sys
import time

REQ = b"GET /bench HTTP/1.1\r\nHost: x\r\n\r\n"


def client(port, secs, depth, q, REQ=REQ):
    s = socket.create_connection(("127.0.0.1", port))
    s.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
    n, end = 0, time.time() + secs
    while time.time() < end:
        s.sendall(REQ * depth)
        got = 0
        buf = b""
        while got < depth:
            buf += s.recv(65536)
            while True:
                i = buf.find(b"\r\n\r\n")
                if i < 0:
                    break
                cl = int(buf.lower().split(b"content-length: ")[1].split(b"\r\n")[0])
                if len(buf) < i + 4 + cl:
                    break
                buf = buf[i + 4 + cl :]
                got += 1
        n += depth
    q.put(n)


if __name__ == "__main__":
    port = int(sys.argv[1])
    procs = int(sys.argv[2]) if len(sys.argv) > 2 else 8
    secs = float(sys.argv[3]) if len(sys.argv) > 3 else 3
    depth = int(sys.argv[4]) if len(sys.argv) > 4 else 1
    if len(sys.argv) > 6:
        b = sys.argv[6].encode()
        REQ = b"POST %s HTTP/1.1\r\nHost: x\r\nContent-Type: application/json\r\nContent-Length: %d\r\n\r\n%s" % (sys.argv[5].encode(), len(b), b)
    q = mp.Queue()
    ps = [mp.Process(target=client, args=(port, secs, depth, q, REQ)) for _ in range(procs)]
    for p in ps:
        p.start()
    total = sum(q.get() for _ in ps)
    for p in ps:
        p.join()
    print("%d requests, %.0f req/s (%d connections, pipeline %d)" % (total, total / secs, procs, depth))
