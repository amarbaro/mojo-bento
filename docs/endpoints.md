# Endpoints

`src/bento/{endpoint,pyerr}.mojo`. Gate `b2` (`tests/run.sh b2`), 74 rows in `tests/cases/b2.txt`: each goes
to BentoML 1.4.39 (`tools/oracle_service.py`, started by the gate) and to `tests/b2_service.mojo`; status,
content-type, allow and body bytes must be equal.

## Use

```mojo
struct Add(Endpoint):
    comptime name = "add"
    def __init__(out self): pass
    def fields(self) -> List[Field]: return [Field("a", T_INT), Field("b", T_INT)]
    def call(self, args: Json) raises -> Json: return Json.of(args.get("a").int() + args.get("b").int())

var srv = Server(Service(Echo(), Add()), "127.0.0.1", 3000)
```

`Service[*Es: Endpoint]` is a Handler: `POST /<name>`. `Field(name, kind)` is required, `Field(name, kind, default)`
optional; kinds `T_STR T_INT T_FLOAT T_BOOL`, `T_LIST` with an element kind. `call` gets an object holding every
field, coerced. A string result is `text/plain; charset=utf-8`; any other Json is `application/json` laid out like
Python's `json.dumps` (`", "`, `": "`, ASCII-escaped).

## What BentoML does, and so do we

| Case | Answer |
|---|---|
| invalid input | 400 `{"error":"N validation error for Input","detail":[{type,loc,msg,url}...]}` (always "error", never "errors"), compact, issues in field order |
| bad JSON | 400, one `json_invalid` issue whose msg is serde_json's text with line and column |
| body empty | read as `{}` |
| body not an object | `model_type` issue |
| `raise http_error(4xx, m)` | status, `[{"error":"m"}]` (UTF-8 raw); 401/403 `{"error":"Authorization error"}`; 5xx and any other error: the fixed 500 body |
| unknown path | 404 `Not Found` text/plain |
| known path, other method | 405 `Method Not Allowed`, `allow: POST` |
| extra input keys, query string | ignored |

pydantic's lax coercion is reproduced for what the rows cover: str to int/float (stripped), integral float and
bool to int, 0/1 and the words yes/no/on/off/true/false/t/f/y/n to bool, int to float, JSON arrays element by
element with `loc` `[name, index]`. `PYDANTIC` (pyerr.mojo) is the version in every issue url: it follows the BentoML in the dev group of `pyproject.toml`.

## Not covered

Ints past Int64 (Python keeps big ints), NaN/Infinity output (BentoML sends null), form and multipart bodies
(BentoML parses `text=hi`; we read JSON only), the trailing-slash redirect, serde messages for malformed
numbers and escapes (they fall back to `expected value`).

## Batching

An endpoint that wants batching holds a `Batcher[In, Out]` (batch.md) and calls `submit` from its worker thread.
