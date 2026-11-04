"""validate() on a 100k-element list field: must stay linear (was O(n^2) through Json.at)."""
from std.time import perf_counter_ns
from json import parse, Json
from bento.endpoint import Field, validate, T_LIST, T_FLOAT


def main() raises:
    var s = String('{"values":[')
    for i in range(100_000):
        s += "1," if i < 99_999 else "1"
    s += "]}"
    var body = parse(s)
    var args = Json()
    var issues = Json.array()
    var t = perf_counter_ns()
    validate([Field("values", T_LIST, T_FLOAT)], body, args, issues)
    var ms = Int(perf_counter_ns() - t) // 1_000_000
    print("validate 100k list:", ms, "ms")
    if ms > 1000:
        raise Error("FAIL list_field_bench: quadratic list coercion")
