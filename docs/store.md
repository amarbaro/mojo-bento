# Model store

`src/bento/store.mojo` is BentoML's `Store` + `Tag` (`_internal/store.py`, `tag.py`) on its directory layout:

```
<root>/<name>/<version>/model.yaml + the model's files (model.safetensors, model.gguf, tokenizer.json ...)
<root>/<name>/latest            text file: the version `get("name")` answers with
```

A store BentoML wrote opens here, and BentoML reads what this one writes (the gate checks both directions).

## API

`ModelStore(root)`:

| call | BentoML equivalent | notes |
|---|---|---|
| `list()` / `list("name")` / `list("name:ver")` | `Store.list` | sorted by name, then version; a missing name raises `NotFound` |
| `get("name")`, `get("name:latest")`, `get("name:ver")`, `get("name:prefix")` | `Store.get` | `latest` missing or stale: re-pointed at the newest by `creation_time`; a prefix must match one directory |
| `register("name:ver", created)` | `Store.register` + `ModelInfo.dump` | writes the same `model.yaml` field layout; `latest` moves when `created >=` the current latest's |
| `delete("name:ver")` / `delete("name")` / `delete("name:latest")` | `Store.delete` | no version: every version; the last one removes the name; `latest` re-points at the newest left |
| `weights(item)` | none | the `*.safetensors` / `*.gguf` files of an item, each opened with `src/safetensors` / `src/gguf`: `(file, kind, tensor count)` |

`Item` has `tag`, `path`, `created` (the isoformat string of `model.yaml`), `micros` (UTC), `file(rel)`.
Errors are `Error("<Type>: <message>")` with BentoML's types (`NotFound`, `BentoMLException`, `ValueError`) and messages,
including its quirks (`get("iris:")` suggests ``iris::latest``).

## Differences from BentoML

- `register` needs `name:version`; BentoML's store takes the version from the Model layer (`Tag.make_new_version`).
- `model.yaml` is read as flat `key: value` lines (`name`, `version`, `creation_time`); nested sections are ignored.
- A version prefix that matches several directories lists them sorted; BentoML lists them in directory order.
- Not ported: export/import, `file_size`, BentoCloud.

## Gate

Gate `b5`: `tests/gate-store.sh`: `tests/cases/store.txt` (78 ops) runs on a copy of `tests/cases/store-fixture/` (built by BentoML:
`tools/store_fixture.py`; 13 items in 7 names, including a missing and a stale `latest`, prefix collisions, three items with equal `creation_time`, a safetensors file,
a GGUF file). `tools/store_oracle.py` runs the ops through BentoML's `ModelStore`, `tests/store_cases.mojo` through this one;
the 368 output lines (items, errors with the root shown as `$ROOT`, and a `tree` dump with every file size, every `latest`
content and every `creation_time`) must be byte-equal. `store.expect` is the committed oracle output, regenerated and
compared when the dev environment (`uv sync`) exists.
