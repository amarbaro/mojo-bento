"""ModelStore.delete removes a symlinked directory inside an item as a link; the target survives.

usage: store_symlink WORKDIR   (absolute; recreated)
"""
from std.os.path import exists
from std.sys import argv
from posix import reap, spawn
from bento.store import ModelStore


def main() raises:
    var work = String(argv()[1])
    _ = reap(spawn(["rm", "-rf", work]), True)
    _ = reap(spawn(["mkdir", "-p", work + "/shared"]), True)
    with open(work + "/shared/w.bin", "w") as f:
        f.write("weights")
    var store = ModelStore(work + "/models")
    var dir = store.register("m:v1", "2026-01-01T00:00:00+00:00")
    _ = reap(spawn(["ln", "-s", work + "/shared", dir + "/weights"]), True)
    try:
        store.delete("m:v1")
    except e:
        print("delete raised:", e)
    if exists(dir) or not exists(work + "/shared/w.bin"):
        raise Error("FAIL store_symlink: item left behind or link target deleted")
    print("PASS store_symlink")
