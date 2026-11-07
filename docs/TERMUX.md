# Technical notes: OpenCode V2 on Termux

This document records every trap found while getting OpenCode V2 to run on
Termux (Android arm64), along with the fix. It is useful if an upstream version
change brings back a similar problem.

## 1. glibc binary on Android

OpenCode V2 (like V1) is a **glibc** binary bundled with Bun. Android uses
**bionic**. Termux provides glibc through a separate package:

```bash
pkg install glibc-repo glibc termux-exec-glibc
```

The result:

- Loader: `$PREFIX/glibc/lib/ld-linux-aarch64.so.1`
- Libraries: `$PREFIX/glibc/lib`

Running the binary:

```bash
$PREFIX/glibc/lib/ld-linux-aarch64.so.1 --library-path $PREFIX/glibc/lib ./opencode --version
```

### Trap: never export `LD_LIBRARY_PATH`

```bash
# DON'T:
export LD_LIBRARY_PATH=$PREFIX/glibc/lib
```

If this variable is exported into the global environment, **every** bionic child
process also looks for glibc and fails, for example:

```
CANNOT LINK EXECUTABLE "tail": $PREFIX/glibc/lib/libc.so has bad ELF magic
```

That is why this repo only uses `--library-path` on the loader invocation,
without exporting `LD_LIBRARY_PATH`.

### Trap: `patchelf` corrupts the binary

`patchelf --set-interpreter` / `--set-rpath` on a 209 MB Bun binary produces a
**broken** binary (segfault when run; the file changes by ~185 million bytes).
**Do not use `patchelf`**.

### Trap: the bionic `LD_PRELOAD` breaks the glibc process

The interactive Termux shell sets:

```
LD_PRELOAD=/data/data/com.termux/files/usr/lib/libtermux-exec-ld-preload.so
```

That library is **bionic** (it needs `libc.so` + symbols with the `LIBC` version
tag). The glibc loader also honors `LD_PRELOAD`, so it tries to load the bionic
library into the glibc process and fails:

```
opencode.real: $PREFIX/glibc/lib/libc.so.6: version `LIBC' not found
  (required by $PREFIX/lib/libtermux-exec-ld-preload.so)
```

GLIBC_LD_PRELOAD has the same problem (the Termux loader reads it too).

**Fix**: strip `LD_PRELOAD` before running the glibc binary. The same pattern is
used by the native OpenCode V1 helper (`unsetenv("LD_PRELOAD")`) and by the
official Termux `glibc-runner` (`unset LD_PRELOAD` on its first line). The
`sanitize_glibc_env()` function in `lib/common.sh` does this, and it is called
from the launcher, `daemon_start`, and `opencode_client`.

The **glibc** variant of `libtermux-exec.so`
(`$PREFIX/glibc/lib/libtermux-exec.so`) **must not** be used as a replacement: it
interposes `execve`, but bionic child processes still receive an `LD_PRELOAD`
pointing at the glibc library, and the result is:

```
CANNOT LINK EXECUTABLE "$PREFIX/bin/bash": library "libc.so.6" not found:
  needed by $PREFIX/glibc/lib/libtermux-exec.so in namespace (default)
```

Once `LD_PRELOAD` is stripped, bionic child processes are normal again: `exec`
of a bionic binary, Termux shebang scripts, `git`, and `/system/bin/sh` all work
(already verified).

## 2. `process.execPath` = the loader path

V2 starts its background service by spawning `process.execPath`. On Termux,
`process.execPath` is not the real binary but:

```
/data/data/com.termux/files/usr/glibc/lib/ld-linux-aarch64.so.1
```

As a result V2 always spawns:

```
execve(loader, ["serve", ...])
```

Which makes the loader look for a shared library named `serve` → failure:

```
serve: error while loading shared libraries: serve: cannot open shared object file
```

### Fix: start the daemon manually

The launcher in this repo starts its own daemon:

```bash
setsid "$LOADER" --library-path "$GLIBC_LIB" "$REAL" serve --service \
  >> "$SERVER_LOG" 2>&1 </dev/null &
```

The daemon registers itself in `~/.opencode-v2/state/opencode/service.json`:

```json
{ "pid": 1234, "url": "http://127.0.0.1:PORT", "version": "2.1.2", ... }
```

When the V2 client starts, it looks for a registered daemon first and uses it
→ **no spawn** → no failing child process.

### Trap: `service set disabled true`

The `disabled` setting forces V2 into *standalone* mode → forces a spawn →
failure. Make sure:

```bash
opencode-v2 service set disabled false   # or unset
```

This repo runs the daemon explicitly, so this mode is irrelevant.

## 3. V1 vs V2 data isolation

V2 reads its data locations from `XDG_DATA_HOME`, `XDG_STATE_HOME`, and
`XDG_CACHE_HOME`. The `OPENCODE_DB` variable only affects the CLI (not the
server), so it is not enough for full isolation.

The approach in this repo:

```bash
XDG_DATA_HOME=$HOME/.opencode-v2/data
XDG_STATE_HOME=$HOME/.opencode-v2/state
XDG_CACHE_HOME=$HOME/.opencode-v2/cache
```

The effect:

- V2 data → `~/.opencode-v2/data/opencode/opencode.db`
- V2 state → `~/.opencode-v2/state/opencode/service.json`
- V1 DB → `~/.local/share/opencode/opencode.db` (untouched)

The DB schemas differ too: V1 uses the `session`, `part`, and `message` tables;
V2 uses `session_v2`, `instruction_*`, and `kv`. So **never** copy a V1 DB into
V2.

## 4. Plugin API differences

| | V1 | V2 |
|---|---|---|
| Entry point | `server()` on the default export | `setup(ctx)` on the default export |
| Tool registration | `tool: { name: tool({...}) }` | `ctx.tool.transform(e => e.add({ name, description, input, execute }))` |
| Input schema | `tool.schema.string()` (Zod-like) | plain JSON Schema |
| Tool result | `string` | `{ content: string }` |
| Compaction hook | `"experimental.session.compacting"` | `ctx.session.hook("compaction", ...)` → `event.system.push({ type: "text", text })` |

V2 validates tool results strictly: a tool that does not declare an `output`
schema **must not** return `output` (it crashes with
`Tool result declared output without an output schema`). Always use `content`.

## 5. Skills

`~/.agents/skills/<name>/SKILL.md` is still detected by V2 (auto-discovery),
just like V1. No special action needed.

## 6. Size & disk

- npm tarball `@opencode/cli-linux-arm64`: ~97 MB (compressed).
- Extracted binary: ~209 MB.
- Space requirement: set aside **>= 400 MB** free during the install.

If disk is tight, clear old caches first:

```bash
npm cache clean --force
pip cache purge
rm -rf $PREFIX/tmp/*
```

## 7. Quick diagnosis

```bash
opencode-v2 doctor
cat ~/.opencode-v2/log/server.log
opencode-v2 service status
```

If the TUI does not open but `opencode-v2 run "halo"` works, the problem is in
the display layer (TERM/ICU), not the server.
