# Migrating from OpenCode V1 to V2 (on Termux)

This document explains what changes, what stays the same, and how to run V1 and
V2 side by side safely.

## Overview

| Aspect | V1 (`opencode`) | V2 (`opencode-v2`) |
|---|---|---|
| Version | 1.19.x | 2.x |
| Binary format | glibc ELF (Bun) | glibc ELF (Bun) |
| npm package | `opencode-ai` | `@opencode/cli` + `@opencode/cli-linux-arm64` |
| Plugin API | `server()` | `setup()` |
| Tool result | `string` | `{ content: string }` |
| Compaction hook | `experimental.session.compacting` | `session.hook("compaction", ...)` |
| DB schema | `session`, `part`, `message` | `session_v2`, `instruction_*`, `kv` |

The two versions **must not share a database**. This repo automatically points V2
at `~/.opencode-v2/`, so the V1 DB (`~/.local/share/opencode/opencode.db`) is
never touched.

## What is still shared

- `~/.config/opencode/opencode.jsonc` — global configuration (model, provider,
  permissions, `instructions`).
- `~/.config/opencode/MEMORY.md` — cross-session memory.
- `~/.config/opencode/plugins/` — plugins.
- `~/.agents/skills/` — skills.
- `~/.local/share/opencode/auth.json` — provider credentials (V2 uses this too,
  because the config and auth directories still belong to global OpenCode).

## The `memory.js` plugin is now dual-compatible

This plugin used to run only on V1:

```js
import { tool } from "@opencode-ai/plugin"
export const MemoryPlugin = async () => ({ tool: { memory_save: tool({...}) } })
```

Now a single file is used by V1 **and** V2:

```js
export default {
  id: "memory",
  async setup(ctx) {           // called by V2
    await ctx.tool.transform((editor) => {
      editor.add({ name: "memory_save", description, input, async execute(input) {
        return { content: saveEntry(input) }   // V2: content, not output
      }})
    })
    await ctx.session.hook("compaction", async (event) => {
      event.system.push({ type: "text", text: COMPACT_PROMPT })
    })
  },
  async server() {             // called by V1
    const { tool } = await import("@opencode-ai/plugin")
    return { tool: { memory_save: tool({...}) }, "experimental.session.compacting": ... }
  },
}
```

Why both work:

- V1 (>= 1.18.29) reads the **default export**; if the object has `server()`,
  V1 calls `server()` and ignores the other exports.
- V2 reads the **default export**; it uses the `id` + `setup()` fields. The
  `server()` field is ignored by V2.
- The V1-only `tool` helper is imported **dynamically** inside `server()`, so it
  is never resolved when V2 loads the module.

If an old (V1-only) plugin is left in the plugins folder, V2 will load it too
and fail: V2 looks for `setup()`, does not find it → the plugin is skipped/errors.
That is why a single dual-compatible file is the safest choice.

### Important difference in V2 tool results

V2 validates tool results:

- A tool **without** an `output` schema → the result **must** use `content`
  (a string, or an array of `{ type: "text", text }`).
- Returning `output` without an output schema → the error
  `Tool result declared output without an output schema` (the process *crashes*,
  it is not a normal error).

So `execute` on V2 returns:

```js
return { content: "Saved to MEMORY.md (...)" }
```

## V2 configuration differences

- `tui.json` → `cli.json`.
- `experimental.todo` is off by default in V2 → enable it if you use it:

  ```jsonc
  { "experimental": { "todo": true } }
  ```

- LSP is **not supported** in V2 (a V1 feature).
- `external_directory` defaults to *allowed* in V2 (looser than V1).

## Preparation before installing V2

1. Make sure there is enough disk: the V2 binary is ~209 MB plus a temporary
   tarball of ~100 MB → set aside **>= 400 MB** free.
2. Make sure the glibc runtime is ready (the installer also does this
   automatically):

   ```bash
   pkg install glibc-repo glibc termux-exec-glibc
   ```

3. Note down the V1 version in use:

   ```bash
   opencode --version
   ```

## Safe order of operations

```bash
# 1. install V2 (V1 is not touched)
( curl -fsSL -H "Accept: application/vnd.github.raw" \
    https://api.github.com/repos/kusnuzon/opencode-termux-v2/contents/install.sh \
  || curl -fsSL https://raw.githubusercontent.com/kusnuzon/opencode-termux-v2/main/install.sh ) | bash

# 2. check
opencode-v2 doctor
opencode-v2 --version

# 3. use it
opencode-v2
```

## Rollback

If V2 misbehaves, V1 still works because the database, state, and commands are
separate:

```bash
opencode          # V1 as usual
```

Removing V2 entirely:

```bash
opencode-v2 uninstall            # or: uninstall.sh
opencode-v2 uninstall --purge    # also data/sessions/logs
```
