"""Build the model-store fixture tests/cases/store-fixture/ with BentoML itself (run with the oracle venv).

usage: .venv/bin/python -I tools/store_fixture.py
Layout is whatever bentoml's ModelStore writes: <name>/<version>/model.yaml + files, <name>/latest.
Creation times are pinned afterwards (model.yaml is rewritten) so every run builds identical bytes.
"""
import json
import os
import shutil
import struct
import sys

from bentoml._internal.models import Model, ModelStore
from bentoml._internal.models.model import ModelContext

OUT = "tests/cases/store-fixture"


def safetensors(n_tensors):
    hdr = {f"t{i}": {"dtype": "F32", "shape": [1], "data_offsets": [4 * i, 4 * i + 4]} for i in range(n_tensors)}
    h = json.dumps(hdr, separators=(",", ":")).encode()
    h += b" " * (-len(h) % 8)
    return struct.pack("<Q", len(h)) + h + b"\0" * (4 * n_tensors)


def gguf_empty():
    key, val = b"general.architecture", b"llama"
    body = struct.pack("<IQQ", 3, 0, 1) + struct.pack("<Q", len(key)) + key + struct.pack("<IQ", 8, len(val)) + val
    body = b"GGUF" + body
    return body + b"\0" * (-len(body) % 32)


# name, version, ctime, extra files, pin `latest` to (None: leave what ModelStore wrote, "": remove it)
MODELS = [
    ("iris", "aaaa1111", "2026-01-01T00:00:00+00:00", {"model.safetensors": safetensors(2)}, None),
    ("iris", "aaaa2222", "2026-02-01T10:00:00.500000+00:00", {}, None),
    ("iris", "bbbb3333", "2026-03-01T12:30:45.123456+00:00", {"model.safetensors": safetensors(3), "notes.txt": b"hello\n"}, None),
    ("llama-7b", "q4", "2026-02-15T08:00:00+00:00", {"model.gguf": gguf_empty(), "tokenizer.json": b"{}"}, None),
    ("tiny_st", "v0.1.0", "2025-12-31T23:59:59.999999+00:00", {"model.safetensors": safetensors(1)}, None),
    ("nolatest", "v1", "2026-05-01T00:00:00+00:00", {}, ""),
    ("nolatest", "v2", "2026-04-01T00:00:00+00:00", {}, ""),
    ("stale", "s1", "2026-06-01T00:00:00+00:00", {}, "gone"),
    ("stale", "s2", "2026-06-02T00:00:00+00:00", {}, "gone"),
    ("onlyver", "x1", "2026-07-01T00:00:00+00:00", {}, None),
    ("ties", "t1", "2026-08-08T08:08:08+00:00", {}, ""),
    ("ties", "t2", "2026-08-08T08:08:08+00:00", {}, ""),
    ("ties", "t3", "2026-08-08T08:08:08+00:00", {}, ""),
]

shutil.rmtree(OUT, ignore_errors=True)
store = ModelStore(OUT)
for name, ver, ctime, files, latest in MODELS:
    m = Model.create(
        f"{name}:{ver}", module="", api_version="v1", signatures={},
        context=ModelContext(framework_name="mojo", framework_versions={}, bentoml_version="mojo-bento", python_version="-"),
    )
    for fn, data in files.items():
        with open(os.path.join(m.path, fn), "wb") as f:
            f.write(data)
    m.flush()
    m.save(store)
    yml = os.path.join(OUT, name, ver, "model.yaml")
    text = open(yml).read()
    old = [l for l in text.splitlines() if l.startswith("creation_time:")][0]
    open(yml, "w").write(text.replace(old, f"creation_time: '{ctime}'"))
    if latest is not None:
        lp = os.path.join(OUT, name, "latest")
        if latest == "":
            os.remove(lp)
        else:
            open(lp, "w").write(latest)
print("fixture", OUT, "ok", file=sys.stderr)
