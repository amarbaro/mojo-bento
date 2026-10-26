"""Run tests/cases/store.txt against bento.store.ModelStore; prints what tools/store_oracle.py prints for BentoML's ModelStore.

usage: store_cases CASES FIXTURE WORKDIR
"""
from std.os import listdir
from std.os.path import isdir
from std.sys import argv
from posix import reap, spawn
from bento.store import ModelStore, Item, parse_time, weights, LATEST, MODEL_YAML


def item_line(it: Item) -> String:
    return "item " + it.tag.text() + " " + it.created


def tree(root: String, rel: String, mut rows: List[String]) raises:
    for name in listdir(root + "/" + rel if rel else root):
        var r = rel + "/" + String(name) if rel else String(name)
        var p = root + "/" + r
        if isdir(p):
            rows.append(r + "/")
            tree(root, r, rows)
        else:
            var raw = List[UInt8]()
            with open(p, "r") as f:
                raw = f.read_bytes()
            var line = r + " " + String(len(raw))
            if String(name) == LATEST:
                line += " = " + String(unsafe_from_utf8=raw)
            elif String(name) == MODEL_YAML:
                for l in String(unsafe_from_utf8=raw).split("\n"):
                    if String(l).startswith("creation_time:"):
                        line += " " + String(l)
            rows.append(line)


def run(op: String, args: List[String], store: ModelStore) raises -> List[String]:
    var out = List[String]()
    if op == "list":
        for it in store.list(args[0] if len(args) > 0 else String()):
            out.append(item_line(it))
        if len(out) == 0:
            out.append("(none)")
    elif op == "get":
        out.append(item_line(store.get(args[0])))
    elif op == "register":
        _ = store.register(args[0], args[1])
        out.append("ok")
    elif op == "delete":
        store.delete(args[0])
        out.append("ok")
    elif op == "weights":
        for w in weights(store.get(args[0])):
            out.append("weight " + w.file + " " + w.kind + " " + String(w.tensors))
        if len(out) == 0:
            out.append("(none)")
    elif op == "micros":
        out.append(String(parse_time(args[0].replace("_", " "))))
    elif op == "tree":
        tree(store.root, String(), out)
        # Python sorts (path, extra) tuples; every path is unique, so sorting the lines by path is the same
        for i in range(1, len(out)):
            var j = i
            while j > 0 and out[j - 1].split(" ")[0] > out[j].split(" ")[0]:
                out.swap_elements(j - 1, j)
                j -= 1
    else:
        raise Error("FAIL store_cases: unknown op " + op)
    return out^


def main() raises:
    var a = argv()
    var work = String(a[3])
    _ = reap(spawn(["rm", "-rf", work]), True)
    _ = reap(spawn(["mkdir", "-p", work]), True)
    var root = work + "/models"
    if reap(spawn(["cp", "-r", String(a[2]), root]), True).value() != 0:
        raise Error("FAIL store_cases: cannot copy the fixture")
    var abs_root = root
    if not abs_root.startswith("/"):
        raise Error("FAIL store_cases: WORKDIR must be absolute")
    var store = ModelStore(root)
    for raw in open(String(a[1]), "r").read().split("\n"):
        var line = String(raw)
        if line.byte_length() == 0 or line.startswith("#"):
            continue
        print("> " + line)
        var w = List[String]()
        for x in line.split(" "):
            w.append(String(x))
        var args = List[String]()
        for k in range(1, len(w)):
            args.append(w[k])
        try:
            for l in run(w[0], args, store):
                print(l)
        except e:
            print("error " + String(e).replace(root, "$ROOT"))
