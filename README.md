# Nexa

**Nexa** is a Lua- / LuaJIT-shaped scripting language implemented in Zig. This Git repository is **`nexa-lang`** on GitHub: [github.com/zenvanexus/nexa-lang](https://github.com/zenvanexus/nexa-lang). The language code name is **Nexa** (your local checkout directory may still be named something else).

## Requirements

- [Zig](https://ziglang.org/) **0.15.2** (see `build.zig.zon`).

## Commands

| Command | Description |
|--------|-------------|
| `zig build` | Build and install the `nexa` host to `zig-out/bin/` |
| `zig build run` | Build (if needed) and run the host |
| `zig build test` | Run library, executable, and snapshot harness tests |
| `zig build fmt` | Run `zig fmt` on `src/`, `tests/`, and `build.zig` |
| `zig build fmt-check` | Fail CI-style if sources are not formatted |

## Scripts vs Zig

Nexa keeps **Lua-shaped** scripts (primarily **`.lua`**, optionally **`.nexa`** for Nexa-only features later) and uses **`.zig`** for the runtime and embedding—the same split as **Lua + C**, but with Zig. Details: **[docs/reference/source-files.md](docs/reference/source-files.md)**. See also **[CONTRIBUTING.md](CONTRIBUTING.md)**.

## Layout

- **`src/`** — VM, parser, and types (see `docs/project-layout.md` §2).
- **`docs/specs/`** — Phase design specifications.
- **`docs/project-layout.md`** — Where code and tests belong as phases land.
- **`tests/snapshots/`** — Snapshot corpus and runner (execution vs. expected output is wired in later phases).

## License

MIT — see [LICENSE](LICENSE).
