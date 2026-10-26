"""Write the arrival traces in tests/cases/batch/ (seeded; arrivals are random nanoseconds).

usage: .venv/bin/python -I tools/batch_traces.py
A trace in which two events of the virtual clock fall within 10 ns is rejected by the oracle (their order would
be heap luck, unreproducible); that case is regenerated with the next seed until the oracle accepts it.
"""
import random
import subprocess
import sys

OUT = "tests/cases/batch"


def poisson(r, n, rate, t0=0.0):
    t, out = t0, []
    for _ in range(n):
        t += r.expovariate(rate)
        out.append(t)
    return out


def bursts(r, n_bursts, size, gap, width):
    return [k * gap + r.random() * width for k in range(n_bursts) for _ in range(size)]


# name: (max_latency_ms, max_batch, dur_a, dur_b, jitter, arrivals(rng))
CASES = {
    "sparse": (100, 8, 0.0020423, 0.0047007, [0.0, 0.0002927, -0.0001903], lambda r: [0.05 * (i + 1) + r.random() * 0.01 for i in range(30)]),
    "poisson-300": (200, 8, 0.0015017, 0.0037411, [0.0, 0.0004021, -0.0002945, 9.39e-05], lambda r: poisson(r, 400, 300)),
    "burst-100": (500, 32, 0.0007519, 0.0094271, [0.0, 0.0004955], lambda r: [0.001 + r.random() * 0.005 for _ in range(100)]),
    "overload-cancel": (50, 8, 0.0094733, 0.0192251, [0.0, 0.0019789, -0.0010459], lambda r: poisson(r, 600, 420)),
    "batch1": (100, 1, 0.0031881, 0.0030325, [0.0, 0.0002037], lambda r: poisson(r, 120, 150)),
    "on-off": (300, 16, 0.0009365, 0.0084015, [0.0, 0.0006899, -0.0004267], lambda r: bursts(r, 8, 25, 0.8, 0.05)),
    "b-dominates": (300, 16, 9.47e-05, 0.0194637, [0.0, 0.0009705, -0.0004751], lambda r: poisson(r, 300, 400)),
    "jitter-heavy": (400, 12, 0.0019643, 0.0060401, [0.0, 0.0041771, -0.0028659, 0.0020229, 0.0, -0.0010195], lambda r: poisson(r, 350, 250)),
    "slow-20s": (5000, 8, 0.0093835, 0.0287651, [0.0, 0.0018777], lambda r: [0.2 * (i + 1) + r.random() * 0.1 for i in range(100)]),
    "single": (100, 8, 0.0020505, 0.0049493, [0.0], lambda r: [0.0123]),
    "tiny-latency": (5, 8, 0.0020241, 0.0039739, [0.0, 0.0009741], lambda r: poisson(r, 300, 400)),
    "small-batch-4": (250, 4, 0.0020557, 0.0048209, [0.0, 0.0005833, -0.0002083], lambda r: poisson(r, 300, 500)),
    # 30 s and longer: the optimizer refreshes every 5 s from real queue waits, so `wait` turns non-zero and corking bites
    "long-load": (300, 16, 0.0017317, 0.0120429, [0.0, 0.0006113, -0.0003907], lambda r: poisson(r, 3600, 120)),
    "long-heavy": (400, 32, 0.0009113, 0.0153071, [0.0, 0.0011873, -0.0007319, 0.0004117], lambda r: poisson(r, 6000, 200)),
    "long-bursty": (500, 24, 0.0013229, 0.0180017, [0.0, 0.0009241, -0.0005503], lambda r: bursts(r, 40, 30, 1.0, 0.3)),
    "rate-ramp": (300, 16, 0.0012631, 0.0061927, [0.0, 0.0005053, -0.0003011],
                  lambda r: poisson(r, 100, 50) + poisson(r, 300, 600, 2.0) + poisson(r, 100, 80, 3.0)),
}

for k, (name, (ml, mb, a, b, jit, gen)) in enumerate(CASES.items()):
    path = f"{OUT}/{name}.trace"
    for attempt in range(20):
        ns = sorted({int(t * 1e9) for t in gen(random.Random(100 * k + attempt))})
        with open(path, "w") as f:
            f.write(f"max_latency_ms {ml}\nmax_batch {mb}\ndur_a_ns {round(a * 1e9)}\ndur_b_ns {round(b * 1e9)}\njitter_ns {' '.join(str(round(j * 1e9)) for j in jit)}\n")
            f.writelines(f"arrive {x}\n" for x in ns)
        p = subprocess.run([sys.executable, "-I", "tools/batch_oracle.py", path], capture_output=True, text=True)
        if p.returncode == 0:
            print(f"{name}: seed attempt {attempt}, {len(ns)} arrivals")
            break
    else:
        sys.exit(f"FAIL traces: {name}: no tie-free seed in 20 attempts\n{p.stderr[-300:]}")
