"""Replay an arrival trace (tests/cases/batch/*.trace) through bento.dispatch.Cork on a virtual clock.

usage: batch_replay TRACE. Prints what tools/batch_oracle.py prints for BentoML's CorkDispatcher on the same trace.
"""
from std.sys import argv
from bento.dispatch import Cork, IDLE, CANCEL, SLEEP, DISPATCH, TICKET


def ns_str(t: Float64) -> String:
    var ns = Int(t * 1e9 + 0.5)
    var frac = String(ns % 1_000_000_000)
    return String(ns // 1_000_000_000) + "." + String("0") * (9 - frac.byte_length()) + frac


def main() raises:
    var path = String(argv()[1])
    var max_latency = 0
    var max_batch = 0
    var dur_a = 0.0
    var dur_b = 0.0
    var jit = List[Float64]()
    var arr = List[Float64]()
    for raw in open(path, "r").read().split("\n"):
        var w = String(raw).split(" ")
        if len(w) < 2 or w[0].startswith("#"):
            continue
        if w[0] == "arrive":
            arr.append(Float64(Int(String(w[1]))) / 1e9)
        elif w[0] == "jitter_ns":
            for k in range(1, len(w)):
                jit.append(Float64(Int(String(w[k]))) / 1e9)
        elif w[0] == "max_latency_ms":
            max_latency = Int(String(w[1]))
        elif w[0] == "max_batch":
            max_batch = Int(String(w[1]))
        elif w[0] == "dur_a_ns":
            dur_a = Float64(Int(String(w[1]))) / 1e9
        elif w[0] == "dur_b_ns":
            dur_b = Float64(Int(String(w[1]))) / 1e9
    if len(jit) == 0:
        jit.append(0.0)

    var cork = Cork(max_latency, max_batch, 0.0)
    var res_t = List[Float64]()
    var res_ok = List[Bool]()
    for _ in range(len(arr)):
        res_t.append(0.0)
        res_ok.append(False)
    var lines = List[String]()
    var next_arr = 0
    var ctl_idle = True
    var ctl_wake = -1.0  # < 0: none scheduled
    var comp_t = -1.0
    var comp_start = 0.0
    var comp_ids = List[Int]()
    var comp_first = 0.0
    var comp_training = False
    var calls = 0
    var settled = 0
    while settled < len(arr):
        # earliest of: next arrival, controller wake, batch completion
        var now = 1e300
        var kind = -1
        if next_arr < len(arr):
            now = arr[next_arr]
            kind = 0
        if ctl_wake >= 0.0 and ctl_wake < now:
            now = ctl_wake
            kind = 1
        if comp_t >= 0.0 and comp_t < now:
            now = comp_t
            kind = 2
        if kind == 0:
            cork.enqueue(next_arr, now)
            next_arr += 1
            if not ctl_idle:
                continue
            ctl_idle = False
        elif kind == 2:
            for id in comp_ids:
                res_t[id] = now
                res_ok[id] = True
                settled += 1
            cork.done(now, comp_start, len(comp_ids), comp_first, comp_training)
            comp_t = -1.0
            continue
        else:
            ctl_wake = -1.0
        # the controller runs at `now`
        while True:
            var k = cork.step(now)
            if k == IDLE:
                ctl_idle = True
                break
            elif k == CANCEL:
                res_t[cork.out_id] = now
                settled += 1
            elif k == SLEEP:
                ctl_wake = now + TICKET
                break
            else:
                var n = len(cork.out_ids)
                var line = "batch " + ns_str(now) + " " + String(n) + " " + ns_str(now - cork.out_first)
                comp_ids = List[Int]()
                for id in cork.out_ids:
                    line += " " + String(id)
                    comp_ids.append(id)
                lines.append(line)
                comp_start = now
                comp_first = cork.out_first
                comp_training = cork.out_training
                comp_t = now + (dur_a * Float64(n) + dur_b + jit[calls % len(jit)])
                calls += 1
    for l in lines:
        print(l)
    for i in range(len(arr)):
        print("res", i, ns_str(res_t[i]), "ok" if res_ok[i] else "fb")
    var i = 0
    while i < len(cork.params):
        print("param", ns_str(cork.params[i]), cork.params[i + 1], cork.params[i + 2], cork.params[i + 3])
        i += 4
