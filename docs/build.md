# bento build / serve

```
scripts/bento build SERVICE.toml OUT   compile, ship runtime libs, copy models, write lock + systemd unit
scripts/bento serve OUT [PORT]         run the service from OUT (OUT/bento-serve does the same, from anywhere)
scripts/bento verify OUT               every file against OUT/bento.lock (sha256)
```

`SERVICE.toml` is flat, one key per line: `name`, `version`, `entry` (Mojo file, relative to the toml), `args`
(`{port}` and `{models}` substituted at serve), `store` (BentoML-layout model store), `models = ["name:tag", ...]`
(`name` or `name:latest` follow the store's `latest`). Example: `tests/b7/service.toml`.

Layout of OUT, about 2.5 MB plus models:

```
bin/<name>  bin/bento        the service (RUNPATH $ORIGIN/../lib) and this script
lib/                         the Modular runtime libs the binary loads (libKGENCompilerRTShared, libAsyncRT*, libMSupportGlobals)
models/<name>/<ver>/ latest  copied with --reflink=auto (free on btrfs)
service.toml  bento.lock  <name>.service  bento-serve
```

Gate `b7` (`tests/run.sh b7`, local only: needs bwrap, patchelf and readelf): the bento is moved, then served inside bwrap with only /usr and the bento visible (no
$HOME, no Mojo venv); the 74 B2 rows answer byte-equal to BentoML. A copy without lib/ fails to start in the same
sandbox (negative control). `verify` rejects a changed model file; a model missing from the store fails the build.

Differences from BentoML's `bentoml build`: no Python env, no Docker image, no bentofile include/exclude globs; the
unit runs ExecStart only (no sd_notify Type, since the B2 service does not notify).
