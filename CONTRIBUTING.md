# Contributing

## Scripts vs implementation

Nexa uses a **Lua-style script surface** and **Zig for the implementation layer** (like Lua + C). Conventions for **`.lua`**, **`.nexa`**, and **`.zig`** are documented in **[docs/reference/source-files.md](docs/reference/source-files.md)**. Follow that split when adding tests, examples, or host code.

## Zig style

- Run **`zig build fmt`** before submitting changes that touch Zig sources.
- CI runs **`zig build fmt-check`** and **`zig build test`**.

## Specs and layout

- Phase behavior: **`docs/specs/`**.
- Where files belong in the tree: **`docs/project-layout.md`**.
