"""Run a script of store operations through BentoML's own ModelStore on a copy of the fixture.

usage: store_oracle.py CASES FIXTURE WORKDIR   (oracle venv)  -> stdout is what tests/store_cases.mojo must print too.
Ops: list [TAG] | get TAG | register TAG CTIME | delete TAG | weights TAG | micros TIMESTAMP (_ for a space) | tree
Each op prints `> <line>` then `item NAME:VER CTIME`, `ok`, `weight FILE KIND N`, tree lines, or `error TYPE: MESSAGE`
(the store root shown as $ROOT).
"""
import json
import os
import shutil
import struct
import sys
from datetime import datetime, timedelta, timezone

from bentoml._internal.models import ModelStore
from bentoml._internal.models.model import ModelContext, ModelInfo
from bentoml._internal.tag import Tag


def item_line(m):
    return f"item {m.tag} {m.creation_time.isoformat()}"


def weights(root, item):
    out = []
    for fn in sorted(os.listdir(item.path)):
        p = os.path.join(item.path, fn)
        if fn.endswith(".safetensors"):
            raw = open(p, "rb").read()
            (n,) = struct.unpack("<Q", raw[:8])
            hdr = json.loads(raw[8 : 8 + n])
            out.append(f"weight {fn} safetensors {len([k for k in hdr if k != '__metadata__'])}")
        elif fn.endswith(".gguf"):
            raw = open(p, "rb").read()
            out.append(f"weight {fn} gguf {struct.unpack('<Q', raw[8:16])[0]}")
    return out or ["(none)"]


def tree(root):
    rows = []
    for d, dirs, files in os.walk(root):
        for x in dirs:
            rows.append((os.path.relpath(os.path.join(d, x), root) + "/", ""))
        for x in files:
            p = os.path.join(d, x)
            rel = os.path.relpath(p, root)
            extra = f" {os.path.getsize(p)}"
            if x == "latest":
                extra += " = " + open(p).read()
            elif x == "model.yaml":
                extra += " " + [l for l in open(p).read().splitlines() if l.startswith("creation_time:")][0]
            rows.append((rel, extra))
    return [f"{r}{e}" for r, e in sorted(rows)]


def run(op, args, store, root):
    if op == "list":
        items = store.list(args[0]) if args else store.list()
        return [item_line(m) for m in items] or ["(none)"]
    if op == "get":
        return [item_line(store.get(args[0]))]
    if op == "register":
        tag = Tag.from_taglike(args[0])
        with store.register(tag) as p:
            info = ModelInfo(
                tag=tag, module="", labels={}, options={}, metadata={},
                context=ModelContext(framework_name="mojo", framework_versions={}, bentoml_version="mojo-bento", python_version="-"),
                signatures={}, api_version="v1", creation_time=datetime.fromisoformat(args[1]),
            )
            with open(os.path.join(p, "model.yaml"), "w") as f:
                info.dump(f)
        return ["ok"]
    if op == "delete":
        store.delete(args[0])
        return ["ok"]
    if op == "weights":
        return weights(root, store.get(args[0]))
    if op == "micros":
        dt = datetime.fromisoformat(args[0].replace("_", " "))
        return [str((dt - datetime(1970, 1, 1, tzinfo=timezone.utc)) // timedelta(microseconds=1))]
    if op == "tree":
        return tree(root)
    raise SystemExit(f"FAIL store_oracle: unknown op {op}")


def main(cases, fixture, work):
    root = os.path.abspath(os.path.join(work, "models"))
    shutil.rmtree(work, ignore_errors=True)
    shutil.copytree(fixture, root)
    store = ModelStore(root)
    for line in open(cases).read().splitlines():
        if not line.strip() or line.startswith("#"):
            continue
        print(f"> {line}")
        w = line.split()
        try:
            out = run(w[0], w[1:], store, root)
        except Exception as e:
            out = [f"error {type(e).__name__}: {e}".replace(root, "$ROOT")]
        print("\n".join(out))


main(*sys.argv[1:4])
