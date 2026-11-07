# OpenCode V2 for Termux (Android arm64)

One-command installer for **OpenCode V2** — the 2.x line of
[anomalyco/opencode](https://github.com/anomalyco/opencode) — on Termux on
Android (aarch64/arm64).

OpenCode V2 is an open-source AI CLI for the terminal: an agent that can read
and write files, run commands, search the web, use MCP servers, and work across
sessions. This repo makes V2 **usable on Termux**, where Android has no glibc by
default.

> This repo is not affiliated with the official opencode project. It only pulls
> the official binary payload from the npm registry
> (`@opencode/cli-linux-arm64`).

---

## Install (one command)

```bash
curl -fsSL -H "Accept: application/vnd.github.raw" \
  https://api.github.com/repos/kusnuzon/opencode-termux-v2/contents/install.sh | bash
```

Done. The `opencode-v2` command is ready to use.

> Why go through the GitHub API instead of `raw.githubusercontent.com`? Some
> networks (mobile in particular) keep `raw.githubusercontent.com` in a proxy
> cache for hours — the file you download can be an old version. The GitHub API
> is always fresh. Raw alternative (may lag by a few minutes):
>
> ```bash
> curl -fsSL https://raw.githubusercontent.com/kusnuzon/opencode-termux-v2/main/install.sh | bash
> ```

Or from a clone:

```bash
git clone https://github.com/kusnuzon/opencode-termux-v2
cd opencode-termux-v2
./install.sh
```

## Available commands

| Command | Purpose |
|---|---|
| `opencode-v2` | Interactive mode (TUI) |
| `opencode-v2 run "prompt"` | Single run, no TUI |
| `opencode-v2 service status` | Background service status |
| `opencode-v2 service start\|stop\|restart` | Manage the background service |
| `opencode-v2 doctor` | Full diagnosis (service, plugins, disk, version) |
| `opencode-v2 upgrade` | Update to the latest version |
| `opencode-v2 --version` | Show the installed version |

## What the installer does

1. Installs base dependencies first: `curl tar unzip gzip coreutils
   ca-certificates jq python git sqlite wget openssh gh nodejs yq shellcheck
   ncdu htop`, then optionally `tesseract chromium` (+ `x11-repo`; skip with
   `--no-extra`). If the glibc packages break `curl`
   (`cannot locate symbol SSL_set_quic_…`), `curl`/`libcurl`/`openssl` are
   reinstalled automatically, and downloads fall back to `wget`/`python`.
2. Ensures the Termux glibc runtime (`glibc-repo`, `glibc`, `termux-exec-glibc`).
3. Downloads the official `@opencode/cli-linux-arm64` payload (~100 MB) from the
   npm registry, **verifying the sha512 checksum** from the registry metadata.
4. Extracts the binary to `$PREFIX/share/opencode-v2/opencode.real`.
5. Installs the `$PREFIX/bin/opencode-v2` launcher.
6. Installs the bundled plugins into `~/.config/opencode/plugins/`:
   `memory.js` (the `memory_save` tool, dual V1+V2) and `session-title.js`
   (session titles without calling a model — avoids free-tier errors).
7. Starts the background service + smoke test, with automatic rollback if any
   step fails.

## Cross-session memory (default)

Memory/AGENTS/RECENT are installed **automatically** on a normal install. Use
`--no-memory` to skip them; use `--no-plugin` to skip the plugins.

This repository **stores nobody's private memory**. It ships only the mechanism;
the memory content stays on your device.

```bash
curl -fsSL -H "Accept: application/vnd.github.raw" \
  https://api.github.com/repos/kusnuzon/opencode-termux-v2/contents/install.sh | bash
```

What gets installed (**existing files are never overwritten**):

| File | Content |
|---|---|
| `plugins/memory.js` → `~/.config/opencode/plugins/` | `memory_save` tool (V1+V2) |
| `plugins/session-title.js` → `~/.config/opencode/plugins/` | automatic session titles without a model |
| `memory/MEMORY.md` → `~/.config/opencode/MEMORY.md` | empty template, filled through the `memory_save` tool |
| `memory/AGENTS.md` → `~/.config/opencode/AGENTS.md` | working-rules template |
| `memory/opencode.jsonc` → `~/.config/opencode/opencode.jsonc` | `instructions`: MEMORY.md + RECENT.md |
| `plugins/session-digest.py` → `~/.config/opencode/bin/` | builds `RECENT.md` from the V1 + V2 session DBs |
| `~/.bashrc` hook | refreshes `RECENT.md` every time `opencode`/`opencode-v2` starts |

The result: `MEMORY.md` holds long-term facts, `RECENT.md` holds summaries of the
last few sessions, and both load automatically at the start of a new session —
with no private data going to GitHub.

> Existing memory on the device is not lost: the installer skips files that
> already exist. For backups, save `~/.config/opencode/` yourself (e.g. in a
> private repo).

## Why the hacks?

V2 is a **glibc** binary (Bun). Android uses **bionic**. Termux provides glibc
through the `glibc-repo` package, so the binary only needs to be run through the
loader:

```bash
$PREFIX/glibc/lib/ld-linux-aarch64.so.1 --library-path $PREFIX/glibc/lib ./opencode
```

The second problem is subtler: **V2 always starts its background service by
spawning `process.execPath`**. On Termux, `process.execPath` is the *loader
path*, not the real binary, so the child process always fails:

```
serve: error while loading shared libraries: serve: cannot open shared object file
```

The fix in this repo: **the launcher starts the `opencode serve --service`
daemon itself** (through the loader), and the daemon registers itself in
`~/.opencode-v2/state/opencode/service.json`. The V2 client finds that registered
daemon and **never spawns** → no child fails.

## Isolation from OpenCode V1

V1 and V2 can coexist. `opencode-v2` uses its own directories:

| | OpenCode V1 | OpenCode V2 |
|---|---|---|
| Command | `opencode` | `opencode-v2` |
| Database | `~/.local/share/opencode/` | `~/.opencode-v2/data/opencode/` |
| State | `~/.local/state/opencode/` | `~/.opencode-v2/state/opencode/` |
| Cache | `~/.cache/opencode/` | `~/.opencode-v2/cache/opencode/` |
| Log | `~/.local/share/opencode/log/` | `~/.opencode-v2/log/server.log` |

Global configuration (`~/.config/opencode/opencode.jsonc`), skills
(`~/.agents/skills`), and plugins **are shared** — so providers, models,
permissions, and memory stay the same for both.

## Memory plugin (cross-session memory)

`~/.config/opencode/plugins/memory.js` is now **dual-compatible**: V1 calls
`server()`, V2 calls `setup()`. One file, two versions, and the `memory_save`
tool exists in both.

The plugin writes to `~/.config/opencode/MEMORY.md` (a file already listed as
`instructions` in the config) and installs a *compaction* hook so the model
moves important facts into memory before the context is compressed.

Full documentation: [`docs/MIGRATION-V1.md`](docs/MIGRATION-V1.md).

## Session title plugin

`~/.config/opencode/plugins/session-title.js` builds a session title from the
user's first message through the V2 `session.hook("title", ...)` hook —
**without calling a model**, so it avoids the `FreeTierError` / "Free usage
limit reached" that leaves sessions untitled. Under V1 the plugin is harmless
(it only provides `server()`).

To get AI-generated titles again (e.g. once the upstream bug is fixed), delete or
rename that file. Check the status with `opencode-v2 doctor`.

## Troubleshooting

```bash
opencode-v2 doctor        # check everything
cat ~/.opencode-v2/log/server.log
```

Common problems:

| Symptom | Cause & fix |
|---|---|
| `error while loading shared libraries` | glibc runtime missing: `pkg install glibc-repo glibc termux-exec-glibc` |
| `version 'LIBC' not found (required by .../libtermux-exec-ld-preload.so)` | The Termux shell sets `LD_PRELOAD` to a bionic library; the glibc loader loads it too and fails. This launcher version drops `LD_PRELOAD` automatically — `opencode-v2 upgrade` |
| `libc.so: invalid ELF header` | Library shim missing — `opencode-v2 upgrade` (or `install.sh`) creates the `libc.so -> libc.so.6` symlink in `$PREFIX/share/opencode-v2/lib/compat` |
| `serve: error while loading shared libraries` | Daemon not registered — `opencode-v2 service restart` |
| `Tool result declared output without an output schema` | A plugin tool returned `output` without an output schema — return `content` instead in V2 |
| TUI won't open | `opencode-v2 run "hello"` to confirm the server is healthy |

Architecture details and technical notes: [`docs/TERMUX.md`](docs/TERMUX.md).

## Uninstall

```bash
bash <(curl -fsSL -H "Accept: application/vnd.github.raw" \
  https://api.github.com/repos/kusnuzon/opencode-termux-v2/contents/uninstall.sh)
```

Add `--purge` to also delete V2 data/sessions/logs. OpenCode V1 is left untouched.
If V2 is already installed, it is easier: `opencode-v2 uninstall`.

## License

MIT — see [LICENSE](LICENSE).
