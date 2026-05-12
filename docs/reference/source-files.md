# Source files and extensions

Nexa stays **Lua-shaped at the script layer** and uses **Zig the way Lua uses C**: for the runtime, embedding, native performance, and build integration. File extensions follow that split.

## Script layer (Lua-style)

| Extension | Role |
|-----------|------|
| **`.lua`** | Default for portable Nexa scripts: examples, tests, user programs. Prefer this whenever semantics match common Lua 5.1 / LuaJIT usage and you want drop-in familiarity. |
| **`.nexa`** | Optional, for scripts that rely on **Nexa-only** syntax or semantics once those exist. Use sparingly—the corpus and tooling can treat `.lua` as the baseline. |

The bytecode VM, optimizer, and JIT (later phases) all consume **the same source text**; they do not introduce a new *required* script extension.

## Implementation layer (Zig)

| Extension | Role |
|-----------|------|
| **`.zig`** | VM, compiler, standard library, platform shims, **`build.zig`**, and host code that embeds Nexa (Layer A API) or exposes the C ABI (Layer B). Same conceptual slot as **`.c`** in Lua+C: systems code, not the scripting dialect on disk. |

Native work that in Lua+C would live in `.c` / `.h` generally lives in **`src/**/*.zig`** (and `tools/`, `bench/` harnesses) in this repository.

## Not “language extensions”

These are artifacts or internal formats, not replacements for `.lua`:

- Serialized bytecode or dumps (whatever naming the `nexa` CLI uses, e.g. `-c` output).
- JIT stencil objects, generated Zig, caches (`zig-out/`, `.zig-cache/`).

Document CLI output names when those commands exist.

## Tests and examples

- **`tests/snapshots/`** — use **`.lua`** (and **`.expected`**) pairs unless a test is explicitly host-side Zig.
- **`examples/`** — prefer **`.lua`** for language demos; use **`.zig`** for minimal embedders next to `build.zig`.

## Summary

- **`.lua`** (primary) and optional **`.nexa`** = what you run as Nexa language source.  
- **`.zig`** = how Nexa is built and embedded—**Lua + C**, but **Lua-shaped + Zig**.
