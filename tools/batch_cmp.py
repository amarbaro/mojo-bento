"""Compare two batch-replay outputs: ids and statuses exact, times to 2 ns, optimizer params to 1e-6 relative.

usage: batch_cmp.py EXPECTED GOT   -> prints PASS or the first differences, exit 0/1.
"""
import sys


def rows(path):
    return [l.split() for l in open(path).read().splitlines() if l.strip()]


def close(kind, i, x, y):
    if kind == "param" and i > 0:
        return abs(float(x) - float(y)) <= 1e-6 * max(abs(float(x)), abs(float(y))) + 1e-12
    return abs(float(x) - float(y)) <= 2e-9


def main(a, b):
    ra, rb = rows(a), rows(b)
    bad = []
    if len(ra) != len(rb):
        bad.append(f"row count {len(ra)} != {len(rb)}")
    for k, (x, y) in enumerate(zip(ra, rb)):
        kind = x[0]
        ok = len(x) == len(y) and x[0] == y[0]
        if ok:
            for i, (p, q) in enumerate(zip(x, y)):
                if i == 0 or p == q:
                    continue
                num = (kind == "batch" and i in (1, 3)) or (kind == "res" and i == 2) or (kind == "param" and i > 0)
                if not (num and close(kind, i, p, q)):
                    ok = False
        if not ok:
            bad.append(f"row {k}: want {' '.join(x)} | got {' '.join(y)}")
        if len(bad) >= 5:
            break
    if bad:
        print("\n".join(bad))
        return 1
    print(f"PASS {len(ra)} rows")
    return 0


sys.exit(main(sys.argv[1], sys.argv[2]))
