"""B4: request metrics in Prometheus text format, named like BentoML's (bentoml_service_request_total,
_in_progress, _duration_seconds). Counters are atomics in one flat Int64 table, so handlers on any thread update
them without a lock and /metrics reads them while they move."""
from std.atomic import Atomic, Ordering

comptime _NB = 16  # BentoML's duration buckets; the last holds everything past 180 s
comptime _NC = 12  # status slots, see _slot
comptime _STRIDE = 1 + _NC * (2 + _NB)  # per endpoint: in_progress, then per status: count, sum_ns, buckets
comptime CONTENT_TYPE = "text/plain; version=0.0.4; charset=utf-8"
comptime _CodePtr = Pointer[Int64, MutUntrackedOrigin]


def _bound(i: Int) -> Float64:
    if i == 0:
        return 0.005
    if i == 1:
        return 0.01
    if i == 2:
        return 0.025
    if i == 3:
        return 0.05
    if i == 4:
        return 0.1
    if i == 5:
        return 0.25
    if i == 6:
        return 0.5
    if i == 7:
        return 1.0
    if i == 8:
        return 2.5
    if i == 9:
        return 5.0
    if i == 10:
        return 10.0
    if i == 11:
        return 30.0
    if i == 12:
        return 60.0
    if i == 13:
        return 120.0
    return 180.0


def _label(i: Int) -> String:
    if i == 0:
        return "0.005"
    if i == 1:
        return "0.01"
    if i == 2:
        return "0.025"
    if i == 3:
        return "0.05"
    if i == 4:
        return "0.1"
    if i == 5:
        return "0.25"
    if i == 6:
        return "0.5"
    if i == 7:
        return "1.0"
    if i == 8:
        return "2.5"
    if i == 9:
        return "5.0"
    if i == 10:
        return "10.0"
    if i == 11:
        return "30.0"
    if i == 12:
        return "60.0"
    if i == 13:
        return "120.0"
    if i == 14:
        return "180.0"
    return "+Inf"


def _slot(status: Int) -> Int:
    """The tracked status codes; others fold into their class (2xx/3xx to 200, other 4xx to 400, other 5xx to 500)."""
    if status == 400:
        return 1
    if status == 401:
        return 2
    if status == 403:
        return 3
    if status == 404:
        return 4
    if status == 405:
        return 5
    if status == 413:
        return 6
    if status == 422:
        return 7
    if status == 429:
        return 8
    if status == 503:
        return 10
    if status == 500 or status >= 500:
        return 9
    if status >= 400:
        return 1
    return 0


def _code(slot: Int) -> String:
    if slot == 0:
        return "200"
    if slot == 1:
        return "400"
    if slot == 2:
        return "401"
    if slot == 3:
        return "403"
    if slot == 4:
        return "404"
    if slot == 5:
        return "405"
    if slot == 6:
        return "413"
    if slot == 7:
        return "422"
    if slot == 8:
        return "429"
    if slot == 9:
        return "500"
    if slot == 10:
        return "503"
    return "599"


struct Metrics(Movable):
    var service: String
    var endpoints: List[String]  # "/add", index = the endpoint's position in the Service
    var cells: List[Int64]
    var p: _CodePtr

    def __init__(out self, service: String, var endpoints: List[String]):
        self.service = service
        self.cells = List[Int64](length=len(endpoints) * _STRIDE, fill=0)
        self.p = _CodePtr(unsafe_from_address=Int(self.cells.unsafe_ptr()))
        self.endpoints = endpoints^

    def begin(self, e: Int):
        _ = Atomic[Int64].fetch_add(self.p + e * _STRIDE, 1)

    def end(self, e: Int, status: Int, ns: Int):
        var base = self.p + e * _STRIDE
        _ = Atomic[Int64].fetch_add(base, -1)
        var row = base + 1 + _slot(status) * (2 + _NB)
        _ = Atomic[Int64].fetch_add(row, 1)
        _ = Atomic[Int64].fetch_add(row + 1, Int64(ns))
        var b = _NB - 1
        for i in range(_NB - 1):
            if Float64(ns) <= _bound(i) * 1e9:
                b = i
                break
        _ = Atomic[Int64].fetch_add(row + 2 + b, 1)

    def render(self) -> String:
        var out = String()
        var lab = ',service_name="' + self.service + '",service_version="not available"'
        out += "# HELP bentoml_service_request_in_progress Multiprocess metric\n# TYPE bentoml_service_request_in_progress gauge\n"
        for e in range(len(self.endpoints)):
            out += 'bentoml_service_request_in_progress{endpoint="' + self.endpoints[e] + '"' + lab + "} " + String(Float64(self.cells[e * _STRIDE])) + "\n"
        out += "# HELP bentoml_service_request_total Multiprocess metric\n# TYPE bentoml_service_request_total counter\n"
        for e in range(len(self.endpoints)):
            for s in range(_NC):
                var n = self.cells[e * _STRIDE + 1 + s * (2 + _NB)]
                if n > 0 or s == 0 or s == 9:
                    out += 'bentoml_service_request_total{endpoint="' + self.endpoints[e] + '",http_response_code="' + _code(s) + '"' + lab + "} " + String(Float64(n)) + "\n"
        out += "# HELP bentoml_service_request_duration_seconds Multiprocess metric\n# TYPE bentoml_service_request_duration_seconds histogram\n"
        for e in range(len(self.endpoints)):
            for s in range(_NC):
                var row = e * _STRIDE + 1 + s * (2 + _NB)
                var count = self.cells[row]
                if count == 0:
                    continue
                var head = 'endpoint="' + self.endpoints[e] + '",http_response_code="' + _code(s) + '"'
                var cum = Int64(0)
                for b in range(_NB):
                    cum += self.cells[row + 2 + b]
                    out += "bentoml_service_request_duration_seconds_bucket{" + head + ',le="' + _label(b) + '"' + lab + "} " + String(Float64(cum)) + "\n"
                out += "bentoml_service_request_duration_seconds_count{" + head + lab + "} " + String(Float64(count)) + "\n"
                out += "bentoml_service_request_duration_seconds_sum{" + head + lab + "} " + String(Float64(self.cells[row + 1]) / 1e9) + "\n"
        return out^
