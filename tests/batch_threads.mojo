"""Batcher under real threads: results reach the right caller, batches stay within max_batch_size and do form,
a failing run_batch fails exactly its batch, an overloaded queue drops with the documented error, close() is clean.
"""
from std.ffi import external_call
from std.memory import alloc
from std.atomic import Atomic, Ordering
from std.testing import assert_equal, assert_true
from bento.batch import Batcher, OVERLOADED

comptime WORKERS = 16
comptime PER_WORKER = 25
comptime MAX_BATCH = 8


@fieldwise_init
struct Req(Copyable, Movable):
    var v: Int
    var stats: Int  # address of Int[3]: calls, largest batch, sleep_us each batch takes (run_batch runs one at a time)


def run_batch(reqs: List[Req]) raises -> List[Int]:
    var s = MutPointer[Int, MutUntrackedOrigin](unsafe_from_address=reqs[0].stats)
    s[0] += 1
    s[1] = max(s[1], len(reqs))
    _ = external_call["usleep", Int32](Int32(s[2]))
    var out = List[Int]()
    for r in reqs:
        if r.v == 13:
            raise Error("poison 13")
        out.append(r.v * 2)
    return out^


def run_batch_conc(reqs: List[Req]) raises -> List[Int]:
    """Like run_batch, but counts the batches running at once (stats viewed as Int32: active, most seen at once)."""
    var s = MutPointer[Int32, MutUntrackedOrigin](unsafe_from_address=reqs[0].stats)
    var now = Atomic[Int32].fetch_add(s, 1) + 1
    var seen = Atomic[Int32].load[ordering=Ordering.ACQUIRE](s.unsafe_offset(1))
    while now > seen and Atomic[Int32].compare_exchange(s.unsafe_offset(1), seen, now):
        pass
    _ = external_call["usleep", Int32](Int32(20_000))
    var out = List[Int]()
    for r in reqs:
        out.append(r.v * 2)
    _ = Atomic[Int32].fetch_add(s, -1)
    return out^


@fieldwise_init
struct Ctx(Movable):
    var b: Int  # address of the shared Batcher
    var stats: Int
    var id: Int
    var bad: Int  # results that were wrong
    var errs: Int  # items that raised
    var n: Int  # items to submit


def worker(arg: Int) abi("C") -> Int:
    var c = MutPointer[Ctx, MutUntrackedOrigin](unsafe_from_address=arg)
    for k in range(c[].n):
        var v = 1_000_000 + c[].id * 1000 + k
        try:
            if MutPointer[Batcher[Req, Int], MutUntrackedOrigin](unsafe_from_address=c[].b)[].submit(Req(v, c[].stats)) != v * 2:
                c[].bad += 1
        except:
            c[].errs += 1
    return 0


def run_workers(b: Int, stats: Int, n: Int) raises -> Tuple[Int, Int]:
    var ctxs = alloc[Ctx](n)
    var tids = alloc[UInt64](n)
    for i in range(n):
        ctxs.unsafe_offset(i).unsafe_write(Ctx(b, stats, i, 0, 0, PER_WORKER))
        var rc = external_call["pthread_create", Int32](tids.unsafe_offset(i), Int(0), worker, Int(ctxs.unsafe_offset(i)))
        assert_equal(rc, 0)
    var bad = 0
    var errs = 0
    for i in range(n):
        _ = external_call["pthread_join", Int32](tids[i], Int(0))
        bad += ctxs[i].bad
        errs += ctxs[i].errs
    return (bad, errs)


def main() raises:
    var stats = alloc[Int](3)
    stats[0] = 0
    stats[1] = 0
    stats[2] = 2000
    # many workers, 2 ms per batch: everything correct, batches form, none exceeds max_batch_size
    var b = Batcher[Req, Int](run_batch, 10_000, MAX_BATCH)
    var bp = Int(Pointer(to=b))
    var r = run_workers(bp, Int(stats), WORKERS)
    assert_equal(r[0], 0, "wrong results")
    assert_equal(r[1], 0, "unexpected errors")
    var st = b.stats()
    assert_equal(st[1], WORKERS * PER_WORKER)
    assert_true(stats[1] <= MAX_BATCH, "batch larger than max_batch_size: " + String(stats[1]))
    assert_true(stats[1] > 1, "no batch ever held more than one item")
    assert_true(stats[0] < WORKERS * PER_WORKER, "no batching: one call per item")
    print("batched", WORKERS * PER_WORKER, "items into", stats[0], "calls, largest", stats[1])
    # a poisoned item fails its whole batch and nothing else
    var one = b.submit(Req(21, Int(stats)))
    assert_equal(one, 42)
    var failed = False
    try:
        _ = b.submit(Req(13, Int(stats)))
    except e:
        failed = True
        assert_equal(String(e), "poison 13")
    assert_true(failed, "poisoned batch did not raise")
    assert_equal(b.submit(Req(22, Int(stats))), 44)
    b.close()
    var closed = False
    try:
        _ = b.submit(Req(1, Int(stats)))
    except e:
        closed = True
        assert_equal(String(e), "batcher: closed")
    assert_true(closed, "submit after close did not raise")
    # overload: a batch takes 120 ms, max_latency 30 ms, so queued items are dropped, never hang
    stats[2] = 120_000
    var slow = Batcher[Req, Int](run_batch, 30, 4)
    var sp = Int(Pointer(to=slow))
    var o = run_workers(sp, Int(stats), 8)
    assert_equal(o[0], 0, "wrong results under overload")
    assert_true(o[1] > 0, "no item was dropped under overload")
    slow.close()
    print("overload dropped", o[1], "of", 8 * PER_WORKER, "-", OVERLOADED)
    # close() while one batch runs and one item waits behind it: the running one finishes, the queued one fails
    stats[2] = 150_000
    var last = Batcher[Req, Int](run_batch, 10_000, 1)
    var lp = Int(Pointer(to=last))
    var cx = alloc[Ctx](2)
    var tids = alloc[UInt64](2)
    for i in range(2):
        cx.unsafe_offset(i).unsafe_write(Ctx(lp, Int(stats), i, 0, 0, 1))
        assert_equal(external_call["pthread_create", Int32](tids.unsafe_offset(i), Int(0), worker, Int(cx.unsafe_offset(i))), 0)
        _ = external_call["usleep", Int32](Int32(40_000))
    last.close()
    for i in range(2):
        _ = external_call["pthread_join", Int32](tids.unsafe_offset(i)[], Int(0))
    assert_equal(cx[0].errs + cx[1].errs, 1, "exactly the queued item should fail on close")
    assert_equal(cx[0].bad + cx[1].bad, 0)
    # max_inflight 2: two batches run at once, every answer still its own
    var cs = alloc[Int32](4)
    for i in range(4):
        cs.unsafe_offset(i).unsafe_write(0)
    var two = Batcher[Req, Int](run_batch_conc, 10_000, 4, 2)
    var tp = Int(Pointer(to=two))
    var t = run_workers(tp, Int(cs), WORKERS)
    assert_equal(t[0], 0, "wrong results with max_inflight 2")
    assert_equal(t[1], 0, "errors with max_inflight 2")
    assert_equal(Int(cs.unsafe_offset(1)[]), 2, "batches never overlapped, or overlapped more than max_inflight")
    two.close()
    print("PASS batch-threads")
