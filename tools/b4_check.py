#!/usr/bin/env python3
"""B4 metrics gate. b4_check.py metrics PORT: drive the Mojo service, then check GET /metrics with
prometheus_client's own parser and that every count matches what was sent (also under 8 threads).
b4_check.py drain PORT PID: SIGTERM must flip /readyz to 503 while /healthz stays 200, then the process exits."""
import http.client
import os
import signal
import sys
import threading
import time

from prometheus_client.parser import text_string_to_metric_families


def req(port, method, path, body=None):
    c = http.client.HTTPConnection("127.0.0.1", port, timeout=10)
    c.request(method, path, body=body, headers={"Content-Type": "application/json"} if body else {})
    r = c.getresponse()
    out = (r.status, r.getheader("content-type"), r.read())
    c.close()
    return out


def families(port):
    status, ctype, body = req(port, "GET", "/metrics")
    assert status == 200 and ctype.startswith("text/plain"), (status, ctype)
    fams = {f.name: f for f in text_string_to_metric_families(body.decode())}  # raises on any malformed line
    return fams


def total(fams, endpoint, code):
    f = fams["bentoml_service_request"]  # the parser strips the _total suffix of a counter
    return sum(s.value for s in f.samples if s.name.endswith("_total") and s.labels["endpoint"] == endpoint and s.labels["http_response_code"] == code)


def hist(fams, endpoint, code):
    f = fams["bentoml_service_request_duration_seconds"]
    pick = lambda suffix: [s for s in f.samples if s.name.endswith(suffix) and s.labels["endpoint"] == endpoint and s.labels["http_response_code"] == code]
    buckets = [(s.labels["le"], s.value) for s in pick("_bucket")]
    return buckets, sum(s.value for s in pick("_count")), sum(s.value for s in pick("_sum"))


def check(ok, what):
    if not ok:
        print("FAIL b4: " + what)
        sys.exit(1)


def metrics(port):
    f0 = families(port)
    check(set(f0) >= {"bentoml_service_request", "bentoml_service_request_in_progress", "bentoml_service_request_duration_seconds"}, "families %s" % sorted(f0))
    check(total(f0, "/add", "200") == 0 and total(f0, "/boom", "500") == 0, "counters start at zero")
    for _ in range(7):
        check(req(port, "POST", "/add", b'{"a":1,"b":2}')[0] == 200, "add ok")
    for _ in range(3):
        check(req(port, "POST", "/add", b'{"a":1}')[0] == 400, "add bad")
    for _ in range(2):
        check(req(port, "POST", "/boom", b"{}")[0] == 500, "boom")
    check(req(port, "POST", "/deny", b"{}")[0] == 403, "deny")
    req(port, "GET", "/nosuch")
    f1 = families(port)
    for ep, code, n in (("/add", "200", 7), ("/add", "400", 3), ("/boom", "500", 2), ("/deny", "403", 1)):
        check(total(f1, ep, code) == n, "%s %s count %s != %d" % (ep, code, total(f1, ep, code), n))
    b, count, ssum = hist(f1, "/add", "200")
    check(count == 7 and ssum > 0, "histogram count/sum %s %s" % (count, ssum))
    vals = [v for _, v in b]
    check(vals == sorted(vals) and b[-1] == ("+Inf", 7.0), "buckets cumulative and +Inf == count: %s" % b)
    check(all(s.value == 0 for s in f1["bentoml_service_request_in_progress"].samples), "in_progress back to 0")

    def worker():
        for _ in range(200):
            req(port, "POST", "/add", b'{"a":1,"b":2}')

    ts = [threading.Thread(target=worker) for _ in range(8)]
    [t.start() for t in ts]
    [t.join() for t in ts]
    f2 = families(port)
    check(total(f2, "/add", "200") == 7 + 1600, "8 threads x 200: counted %s, want 1607" % total(f2, "/add", "200"))
    check(hist(f2, "/add", "200")[1] == 1607, "histogram count after threads")
    print("b4 metrics: parser accepted %d families; counts exact (7 ok, 3x400, 2x500, 1x403, then 1600 from 8 threads)" % len(f2))


def drain(port, pid):
    os.kill(pid, signal.SIGTERM)
    time.sleep(0.1)
    ready, health = req(port, "GET", "/readyz")[0], req(port, "GET", "/healthz")[0]
    check(ready == 503 and health == 200, "during drain /readyz %s /healthz %s (want 503, 200)" % (ready, health))
    t0 = time.time()
    while time.time() - t0 < 5:
        try:
            state = open("/proc/%d/stat" % pid).read().rsplit(")", 1)[1].split()[0]
        except (FileNotFoundError, ProcessLookupError):  # gone, or already reaped by the shell
            state = "Z"
        if state == "Z":
            print("b4 drain: SIGTERM -> /readyz 503, /healthz 200, exited %.2fs later" % (time.time() - t0 + 0.1))
            return
        time.sleep(0.05)
    check(False, "process still running 5 s after SIGTERM")


if sys.argv[1] == "metrics":
    metrics(int(sys.argv[2]))
else:
    drain(int(sys.argv[2]), int(sys.argv[3]))
