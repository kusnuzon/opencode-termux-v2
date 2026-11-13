# 🚀 OpenCode V2 for Termux (Android arm64)

One command gets **OpenCode V2** (the 2.x line of
[anomalyco/opencode](https://github.com/anomalyco/opencode)) running on Termux —
glibc loader, background service, and memory handled for you.

> ℹ️ Not affiliated with the official project. Only the official payload
> (`@opencode/cli-linux-arm64`) is downloaded, with its sha512 verified.

## ✨ What you get

- 🤖 `opencode-v2` — TUI, `run` for one-shot prompts, `service` for the daemon
- 🧬 glibc shim + automatic `LD_PRELOAD` cleanup (Android/bionic friendly)
- 🧠 cross-session memory — `MEMORY.md` + `RECENT.md`, loaded every session
- 🏷️ session titles without calling a model (no free-tier errors)
- 🩺 `opencode-v2 doctor` — service, plugins, disk, version in one screen
- 🧷 fully isolated from OpenCode V1 (own DB, state, cache, logs)

## 📦 Prerequisites

Termux on Android **aarch64**, not root, ~700 MB free (glibc runtime + payload).
Dependencies are installed by the script.

## ⚡ 1-Click Install

```bash
curl -fsSL -H "Accept: application/vnd.github.raw" \
  https://api.github.com/repos/kusnuzon/opencode-termux-v2/contents/install.sh | bash
```

Done — `opencode-v2` is ready.

> The GitHub API is used on purpose: mobile networks keep
> `raw.githubusercontent.com` cached for hours, so the raw URL can serve an old
> installer. From a clone: `./install.sh`.

## 🧰 What the installer does

1. 📦 base dependencies first (`curl tar unzip gzip coreutils ca-certificates jq
   python git sqlite wget openssh gh nodejs yq shellcheck ncdu htop`), optionally
   `tesseract chromium` (`--no-extra` to skip); heals `curl` if glibc broke it
2. 🧬 glibc runtime (`glibc-repo`, `glibc`, `termux-exec-glibc`)
3. ⬇️ official `@opencode/cli-linux-arm64` payload (~100 MB), **sha512 verified**
4. 📂 binary → `$PREFIX/share/opencode-v2/opencode.real` + launcher in `$PREFIX/bin`
5. 🔌 plugins → `~/.config/opencode/plugins/` (`memory.js`, `session-title.js`,
   `update-notice.js`) + tools in `~/.config/opencode/bin/` (`session-digest.py`, `kuota`)
6. ▶️ background service start + smoke test, **automatic rollback** on failure

Options: `--no-memory`, `--no-plugin`, `--check`.

## ⌨️ Everyday commands

| Command | Purpose |
|---|---|
| `opencode-v2` | interactive TUI |
| `opencode-v2 run "prompt"` | single run, no TUI |
| `opencode-v2 service status` | daemon status |
| `opencode-v2 service start\|stop\|restart` | control the daemon |
| `opencode-v2 doctor` | full diagnosis |
| `opencode-v2 upgrade` | update to the latest version |
| `opencode-v2 --version` | installed version |

## 🧠 Cross-session memory (default)

| File | Contents |
|---|---|
| `plugins/memory.js` | `memory_save` tool (V1 + V2 compatible) |
| `plugins/session-title.js` | titles from your first message, no model call |
| `memory/MEMORY.md` | long-term facts (template, filled by the tool) |
| `memory/AGENTS.md` | working-rules template |
| `memory/opencode.jsonc` | `instructions`: MEMORY.md + RECENT.md |
| `plugins/session-digest.py` | builds `RECENT.md` (recent sessions + open items) |
| `plugins/update-notice.js` | shows a codemux update notice inside the session |
| `plugins/kuota.py` → `kuota` | estimates the remaining free-model quota |
| `~/.bashrc` hook | refreshes `RECENT.md` on every opencode start |

This repo ships **mechanism only** — nobody's private memory is stored here, and
existing files on your device are never overwritten.

## 🧩 Why the hacks?

V2 is a glibc (Bun) binary; Android uses bionic. So it runs through the loader:

```bash
$PREFIX/glibc/lib/ld-linux-aarch64.so.1 --library-path $PREFIX/glibc/lib ./opencode
```

V2 also respawns itself via `process.execPath`, which on Termux points at the
*loader* → `serve: cannot open shared object file`. The launcher therefore starts
`opencode serve --service` itself and registers it in
`~/.opencode-v2/state/opencode/service.json`; the client finds the daemon and
never spawns a child.

## 🧷 Isolation from OpenCode V1

| | OpenCode V1 | OpenCode V2 |
|---|---|---|
| Command | `opencode` | `opencode-v2` |
| Database | `~/.local/share/opencode/` | `~/.opencode-v2/data/opencode/` |
| State | `~/.local/state/opencode/` | `~/.opencode-v2/state/opencode/` |
| Cache | `~/.cache/opencode/` | `~/.opencode-v2/cache/opencode/` |
| Log | `~/.local/share/opencode/log/` | `~/.opencode-v2/log/server.log` |

Config (`~/.config/opencode`), skills (`~/.agents/skills`) and plugins are
**shared**, so providers, models and memory stay the same in both.

## 🩺 Troubleshooting

```bash
opencode-v2 doctor
cat ~/.opencode-v2/log/server.log
```

| Symptom | Fix |
|---|---|
| `error while loading shared libraries` | `pkg install glibc-repo glibc termux-exec-glibc` |
| `version 'LIBC' not found` | stale launcher with old `LD_PRELOAD` → `opencode-v2 upgrade` |
| `libc.so: invalid ELF header` | missing shim → `opencode-v2 upgrade` (creates `libc.so → libc.so.6`) |
| `serve: error while loading shared libraries` | daemon not registered → `opencode-v2 service restart` |
| `Tool result declared output without an output schema` | plugin returned `output`; V2 wants `content` |
| TUI won't open | `opencode-v2 run "hello"` to check the server |

More: [`docs/TERMUX.md`](docs/TERMUX.md) · [`docs/MIGRATION-V1.md`](docs/MIGRATION-V1.md)

## 🗑️ Uninstall

```bash
opencode-v2 uninstall      # already installed
# or
curl -fsSL -H "Accept: application/vnd.github.raw" \
  https://api.github.com/repos/kusnuzon/opencode-termux-v2/contents/uninstall.sh | bash
```

`--purge` also removes V2 data, sessions and logs. V1 is untouched. To manage
both versions from one command, use [codemux](https://github.com/kusnuzon/codemux).

## 📜 License

MIT — see [LICENSE](LICENSE).
