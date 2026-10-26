#!/usr/bin/env python3
"""B2 gate: every row of tests/cases/b2.txt goes to BentoML (tools/oracle_service.py) and to the Mojo service
(tests/b2_service.mojo); status, content-type, allow and the body bytes must be equal.

  b2_oracle.py CASES BENTO_PORT MOJO_PORT
Row: name<TAB>METHOD<TAB>/path<TAB>content-type or -<TAB>body (escapes decoded; {c*N} repeats)
"""
import codecs
import http.client
import re
import sys


def load(path):
    rows = []
    for ln in open(path, encoding="utf-8"):
        ln = ln.rstrip("\n")
        if not ln or ln.startswith("#"):
            continue
        name, method, target, ctype, body = (ln.split("\t") + [""])[:5]
        body = re.sub(r"\{(.)\*(\d+)\}", lambda m: m.group(1) * int(m.group(2)), body)
        rows.append((name, method, target, None if ctype == "-" else ctype, codecs.escape_decode(body)[0]))
    return rows


def ask(port, method, target, ctype, body):
    c = http.client.HTTPConnection("127.0.0.1", port, timeout=10)
    hdr = {"Content-Type": ctype} if ctype else {}
    c.request(method, target, body=body if method != "GET" else None, headers=hdr)
    r = c.getresponse()
    data = r.read()
    allow = r.getheader("allow")
    if allow:  # starlette joins a Python set: its order changes with every process, the set is the contract
        allow = ", ".join(sorted(allow.split(", ")))
    out = (r.status, r.getheader("content-type"), allow, data)
    c.close()
    return out


def main():
    rows, bp, mp = load(sys.argv[1]), int(sys.argv[2]), int(sys.argv[3])
    fails = 0
    for name, method, target, ctype, body in rows:
        want, got = ask(bp, method, target, ctype, body), ask(mp, method, target, ctype, body)
        if want != got:
            fails += 1
            print("FAIL %s\n  bentoml %r\n  mojo    %r" % (name, want, got))
    print("b2: %d rows, %d failed" % (len(rows), fails))
    sys.exit(1 if fails else 0)


main()
