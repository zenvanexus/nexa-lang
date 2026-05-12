# Project Layout

**Project:** Lua/LuaJIT-shaped scripting language in Zig
**Document scope:** Repository structure, naming conventions, build organization, and where every file referenced by the phase specs actually lives. The phase specs describe *what* gets built; this doc describes *where it goes*.

This is the layout the project converges to as it crosses Phase 5. Earlier phases inhabit a subset.

---

## 1. Top-Level

```
nexa/                             # language code name; repo may differ
├── build.zig                     # main build script
├── build.zig.zon                 # package manifest, dependencies
├── README.md
├── LICENSE                       # MIT or Apache-2.0; pick one
├── CONTRIBUTING.md
├── CHANGELOG.md
│
├── src/                          # production source
├── tests/                        # integration tests, snapshots, fuzz harnesses
├── bench/                        # benchmark suite
├── tools/                        # build-time and dev tools
├── docs/                         # design specs, postmortems, user docs
├── examples/                     # usage examples
├── vendor/                       # vendored dependencies (libffi)
│
├── .github/                      # CI configuration
│   └── workflows/
│       ├── build.yml
│       ├── bench.yml
│       └── stencil-drift.yml
│
└── .gitignore
```

### Why these top-level boundaries

- **`src/` vs `tests/`.** Unit tests live inline in source via `test "..." { ... }` blocks (Zig convention); `tests/` is for anything that doesn't fit inline — snapshot corpora, ported Lua test suites, fuzz harnesses, multi-file integration scenarios.
- **`bench/` is its own thing.** Benchmarks have different cadence (run on dedicated hardware, gated by CI separately) and different conventions (must build a verifier, must use `std.time` correctly). Keeping them separate from tests prevents accidental contamination.
- **`tools/` is build-time only.** Anything in `tools/` runs at build time (stencil extractor) or as a dev aid (disassemblers). Nothing in `tools/` ends up in the shipped VM binary.
- **`vendor/`** holds libffi only, until a need for more arises. Vendoring is preferred over package-manager dependencies for anything ABI-critical.

---

## 2. `src/` — Production Source

```
src/
├── main.zig                      # CLI entry point (`nexa` binary)
├── repl.zig                      # interactive REPL
│
├── parser/                       # Phase 0 frontend (reused unchanged through Phase 5)
│   ├── lex.zig
│   ├── ast.zig
│   ├── parse.zig
│   ├── resolve.zig
│   └── source_info.zig           # source location, line tracking
│
├── value.zig                     # Value type (Phase 0 tagged union, Phase 1 NaN-boxed)
├── op.zig                        # Op enum + op_table + comptime generators
├── bytecode.zig                  # Instruction encoding/decoding/disassembly
├── proto.zig                     # Proto, UpvalueDesc
├── compile.zig                   # Bytecode compiler (consumes resolved AST)
├── dump.zig                      # Bytecode serialize/deserialize
│
├── vm/                           # the runtime
│   ├── vm.zig                    # VM struct, top-level driver
│   ├── handlers.zig              # one function per opcode
│   ├── dispatch.zig              # tail-call-threaded dispatch helpers
│   ├── frame.zig                 # CallInfo, Frame, stack management
│   ├── error.zig                 # ErrorFrame, pcall, error_value mechanics
│   └── error_format.zig          # source:line: error formatting, traceback
│
├── types/                        # the eight (nine, with cdata) value types' representations
│   ├── string.zig                # String + interner
│   ├── table.zig                 # Table (Phase 1 hybrid → Phase 4 shape-tracked)
│   ├── function.zig              # Lua closure, host function
│   ├── userdata.zig              # full + light userdata
│   ├── thread.zig                # coroutine (Phase 2)
│   └── upvalue.zig               # UpvalueCell, open/closed
│
├── gc/                           # garbage collector (Phase 1.5)
│   ├── gc.zig                    # Gc struct, top-level entry
│   ├── header.zig                # GcHeader, Color, GcType
│   ├── mark.zig                  # marking phase
│   ├── sweep.zig                 # sweeping phase
│   ├── barrier.zig               # write-barrier API (no-op stop-the-world; real Phase 4)
│   ├── inc.zig                   # incremental machinery (Phase 4)
│   ├── gen.zig                   # generational machinery (Phase 4, optional)
│   ├── weak.zig                  # weak tables (Phase 4)
│   ├── finalize.zig              # __gc finalizers (Phase 2 wires; Phase 4 adapts)
│   └── debug_dump.zig            # dumpHeap, assertReachable, findReferrers
│
├── shape/                        # hidden classes (Phase 4.5)
│   ├── shape.zig                 # Shape data structure
│   ├── transition.zig            # transition logic, child caching
│   ├── field_index.zig           # key → offset open-addressing table
│   ├── child_map.zig             # inline-or-hash transition map
│   ├── demote.zig                # shape → dictionary mode
│   └── stats.zig                 # diagnostics
│
├── ic/                           # inline caches (Phase 4)
│   ├── cell.zig                  # ICell layout
│   ├── lookup.zig                # mono/poly/mega state machine
│   ├── invalidate.zig            # generation counter, shape-driven misses
│   └── method_chain.zig          # method-call IC chain hints
│
├── super/                        # superinstruction infrastructure (Phase 4)
│   ├── defs.zig                  # the table of fused opcodes
│   ├── fuse.zig                  # peephole fusion pass over emitted bytecode
│   └── handlers.zig              # generated fused handlers
│
├── meta/                         # metamethod machinery
│   ├── lookup.zig                # cache flags, slow-path lookup
│   ├── arith.zig                 # __add, __sub, ... slow paths
│   ├── compare.zig               # __eq, __lt, __le
│   └── index.zig                 # __index, __newindex chains
│
├── lib/                          # standard library — one file per Lua module
│   ├── base.zig                  # print, type, tostring, tonumber, error, etc.
│   ├── coroutine.zig             # coroutine.* (Phase 2)
│   ├── string/
│   │   ├── lib.zig               # string.* dispatch
│   │   ├── format.zig            # string.format implementation
│   │   ├── pattern.zig           # Lua pattern matcher
│   │   └── basic.zig             # len, sub, upper, lower, rep, byte, char
│   ├── table.zig                 # table.* (insert, remove, concat, sort, ...)
│   ├── math.zig                  # math.* + xoshiro256** PRNG
│   ├── os.zig                    # os.*
│   ├── io.zig                    # io.* with file userdata + __gc
│   ├── debug.zig                 # debug.* (traceback, getinfo, ...)
│   ├── bit.zig                   # bit.* (Phase 4) — BitOp-compatible
│   └── package.zig               # require, package.loaded, package.path
│
├── api/                          # embedding APIs
│   ├── lua.zig                   # Layer A: Zig-native API (`Lua` struct)
│   ├── register.zig              # comptime registerFn wrapper generation
│   ├── sandbox.zig               # SandboxOptions enforcement
│   └── c_abi.zig                 # Layer B: lua_* C ABI exports
│
├── ffi/                          # FFI subsystem (Phase 3)
│   ├── cdata.zig                 # CData value type, NaN-box integration
│   ├── ctype.zig                 # CType representation
│   ├── static.zig                # comptime staticImports for compile-time bindings
│   ├── dispatch.zig              # static fast path / libffi slow path routing
│   ├── libffi_glue.zig           # libffi binding, ffi_cif cache
│   ├── loader.zig                # ffi.load, dlopen/GetProcAddress
│   ├── callback.zig              # libffi closures, trampolines
│   ├── metatype.zig              # ffi.metatype machinery
│   ├── lib.zig                   # the `ffi` Lua library
│   ├── api.zig                   # Zig-side static-import registration
│   │
│   └── cparse/                   # C declaration parser (Phase 3.5)
│       ├── lex.zig
│       ├── decl_spec.zig
│       ├── declarator.zig
│       ├── compound.zig
│       ├── bitfield.zig
│       ├── const_expr.zig
│       ├── attribute.zig
│       ├── layout.zig
│       ├── namespace.zig
│       ├── error.zig
│       └── parser.zig            # top-level entry
│
├── jit/                          # JIT subsystem (Phase 5)
│   ├── jit.zig                   # compilation driver, hotness, budgets
│   ├── stencil_def.zig           # StencilDef, Hole, HoleKind, HoleMeaning types
│   ├── stencil_source.zig        # the authored stencils
│   ├── stencils.x86_64-linux.zig    # auto-generated, committed
│   ├── stencils.x86_64-macos.zig    # auto-generated, committed
│   ├── stencils.aarch64-macos.zig   # auto-generated, committed
│   ├── code_arena.zig            # W^X memory management
│   ├── patcher.zig               # emit, patch, finalize
│   ├── patch_ctx.zig             # PatchCtx, hole resolution
│   ├── deopt.zig                 # deopt entry points, state reconstruction
│   ├── feedback.zig              # reading IC and shape feedback
│   ├── abi/
│   │   ├── x86_64.zig
│   │   └── aarch64.zig
│   └── cache_flush.zig           # platform i-cache flush wrappers
│
└── platform/                     # OS- and arch-specific shims
    ├── mmap.zig                  # cross-platform mmap with PROT_*
    ├── dlopen.zig                # dlopen / GetProcAddress / dlsym wrappers
    └── jit_protect.zig           # macOS pthread_jit_write_protect_np, etc.
```

### Notes on `src/` organization

**Flat at the core, nested at the edges.** `value.zig`, `op.zig`, `bytecode.zig`, `proto.zig`, `compile.zig`, `dump.zig` live at the top of `src/` because they're the central VM contract — every other module imports them. Putting them in `src/core/` would just add `core.` noise to every import.

**Subdirectories for genuinely separable subsystems.** `ffi/`, `jit/`, `gc/`, `shape/`, `ic/`, `super/`, `meta/`, `lib/` are each independently complex and have internal structure worth honoring. Their public surface is one or two `pub` declarations from a top-level file in the directory; everything else is an implementation detail.

**Per-module file inside subdirectories.** `src/lib/string/` has multiple files (`format.zig`, `pattern.zig`, `basic.zig`) because the Lua `string` library has three independently-complex pieces. Most other library modules are single-file.

**`platform/` is the bottom of the stack.** Anything that needs `#ifdef`-style platform branching goes here. The rest of the VM imports a clean Zig API and never sees `builtin.os.tag` directly.

---

## 3. `tests/` — Integration Tests

```
tests/
├── snapshots/                    # Phase 0+: corpus of (.lua, .expected) pairs
│   ├── arithmetic/
│   ├── strings/
│   ├── tables/
│   ├── closures/
│   ├── control_flow/
│   ├── error_handling/
│   ├── metatables/               # Phase 1+
│   ├── coroutines/               # Phase 2+
│   └── runner.zig                # snapshot harness
│
├── lua-tests/                    # ported subset of upstream lua-tests
│   ├── ported/                   # the ported .lua files
│   ├── upstream-pin.txt          # which upstream commit we ported from
│   └── runner.zig
│
├── differential/                 # cross-tier equivalence
│   ├── tree-vs-bytecode/         # Phase 1 vs Phase 0
│   ├── interp-vs-jit/            # Phase 5 vs Phase 4
│   └── runner.zig
│
├── ic/                           # IC behavior + invalidation (Phase 4)
├── shape/                        # shape transitions, demotion, edge cases (Phase 4.5)
│   ├── unit/
│   ├── edge_cases/
│   ├── fuzz/
│   └── convergence/
│
├── gc/                           # GC behaviour (Phase 1.5+)
│   ├── stop_the_world/
│   ├── stress/                   # every_alloc, every_safepoint, every_step
│   ├── weak/                     # ephemerons, weak modes
│   ├── finalize/
│   └── soak/                     # 24-hour stability
│
├── coroutine/                    # Phase 2
├── pattern/                      # Phase 2 string patterns
│
├── ffi/                          # Phase 3
│   ├── cparse/                   # C parser unit tests
│   │   ├── lexer/
│   │   ├── declarators/
│   │   ├── layout_fuzz/          # random struct layouts vs. host compiler
│   │   ├── luajit_compat/
│   │   └── real_headers/         # zlib, sqlite3, libpng, openssl
│   ├── static/                   # comptime-imports tests
│   ├── dynamic/                  # cdef + libffi tests
│   ├── callbacks/
│   └── luajit_compat/            # full FFI test suite port
│
├── stencil/                      # Phase 5.5
│   ├── round_trip/               # per-stencil emit-patch-execute equivalence
│   ├── extractor/                # extractor against curated .o files
│   ├── cross_arch/               # same source, different arch
│   └── stress/                   # random-pad, branch-out-of-range, deopt-every
│
├── jit/                          # Phase 5
│   ├── differential/
│   ├── deopt_stress/
│   └── soak/
│
├── embed_zig/                    # Zig host scenarios (Phase 2)
└── embed_c/                      # C host scenarios (Phase 2)
    ├── harness.c
    └── build.zig                 # builds and links the C harness
```

### Notes on `tests/`

- **Snapshots are the foundation.** Most behavior is verified through snapshot tests — pairs of `.lua` and `.expected` files. The corpus grows monotonically: a feature added in Phase N adds snapshots, and they keep passing through every later phase. Regression in Phase 5 = a Phase 0 snapshot starts failing.
- **Differential tests are the safety net.** Every optimization phase introduces a new tier (bytecode VM, JIT). Differential testing against the previous tier ensures the optimization is correctness-preserving. They're cheap to run and catch nearly every JIT bug before deeper investigation.
- **Fuzz harnesses are gated.** Fuzz tests live alongside their unit-test siblings but aren't run on every PR — they run nightly (or on-demand). They produce reproducer corpora when they find a crash.

---

## 4. `bench/` — Benchmarks

```
bench/
├── runner.zig                    # benchmark harness, statistics, regression CI
├── reporter.zig                  # output formatting, baseline tracking
│
├── micro/                        # tight microbenchmarks
│   ├── arith_int.lua
│   ├── arith_double.lua
│   ├── table_read_hot.lua
│   ├── table_write_hot.lua
│   ├── string_concat.lua
│   ├── function_call.lua
│   └── loop_overhead.lua
│
├── algorithmic/
│   ├── fib_recursive.lua
│   ├── primes_sieve.lua
│   ├── nqueens.lua
│   ├── mandelbrot.lua
│   └── json_parse.lua
│
├── workloads/                    # real-ish programs from the wild
│   ├── neovim_config_subset.lua
│   ├── redis_script.lua
│   ├── roblox_style.lua
│   └── README.md                 # provenance of each workload
│
├── ffi/                          # FFI-specific microbenchmarks (Phase 3)
│   ├── static_call.zig           # invokes static FFI from a Zig harness
│   ├── dynamic_call.zig
│   └── callback_storm.zig
│
├── shape/                        # OO-pattern benchmarks (Phase 4.5)
│   └── deltablue.lua
│
├── jit/                          # JIT-vs-interpreter (Phase 5)
│   └── README.md                 # what each measures, target numbers
│
└── baselines/
    ├── lua-5.1.csv               # measured baseline data
    ├── luajit-joff.csv
    ├── luajit-jon.csv
    └── README.md                 # how the baseline data was collected
```

### Notes on `bench/`

- **Each benchmark has a verifier.** A benchmark that produces wrong output but runs fast is useless. The runner checks output hashes against expected values.
- **Baselines are committed CSVs.** Updating a baseline requires a deliberate PR with explanation. Performance numbers don't drift silently.
- **The runner integrates with CI.** Per Phase 4 §2, geomean regression > 5% blocks merge unless explicitly accepted.

---

## 5. `tools/` — Build-Time and Dev Tools

```
tools/
├── stencil_extract/              # Phase 5.5: turn .o into stencils.zig
│   ├── main.zig
│   ├── elf.zig
│   ├── macho.zig
│   ├── reloc_x64.zig
│   └── reloc_arm64.zig
│
├── stencil_disasm/               # disassemble a single stencil for debugging
│   └── main.zig
│
├── stencil_dump_patched/         # dump runtime-emitted JIT code
│   └── main.zig
│
├── stencil_diff/                 # semantic diff between two stencils.zig files
│   └── main.zig
│
├── lua_dump/                     # dump compiled bytecode in a readable form
│   └── main.zig
│
├── shape_inspect/                # walk a heap and print shape statistics
│   └── main.zig
│
└── benchstat/                    # bench output statistics; like Go's benchstat
    └── main.zig
```

### Notes on `tools/`

- **Each tool is a separate executable.** `zig build install` installs them all under `bin/` for development use. Production VM binaries don't include them.
- **Shared logic lives in `src/`.** When `lua_dump` needs to read bytecode, it imports `src/dump.zig`. The tool is just CLI wrapping.
- **Tools run at build time when needed.** `stencil_extract` is invoked by `build.zig` automatically; manual invocation is for debugging only.

---

## 6. `docs/` — Documentation

```
docs/
├── README.md                     # docs index
│
├── specs/                        # phase specifications (the docs we wrote)
│   ├── phase-0-tree-walking-interpreter.md
│   ├── phase-1-bytecode-vm.md
│   ├── phase-1.5-garbage-collector.md
│   ├── phase-2-coroutines-stdlib-embedding.md
│   ├── phase-3-ffi.md
│   ├── phase-3.5-c-parser.md
│   ├── phase-4-optimization-incremental-gc.md
│   ├── phase-4.5-shape-system.md
│   ├── phase-5-jit.md
│   └── phase-5.5-stencil-toolchain.md
│
├── postmortems/                  # one per phase as it ships
│   ├── phase-0-postmortem.md
│   ├── phase-1-postmortem.md
│   └── ...
│
├── adrs/                         # architecture decision records
│   ├── 0001-nan-boxing-vs-tagged-union.md
│   ├── 0002-register-vs-stack-bytecode.md
│   ├── 0003-incremental-gc-machinery-from-day-one.md
│   ├── 0004-libffi-vs-dyncall.md
│   ├── 0005-copy-and-patch-vs-tracing-jit.md
│   └── ...
│
├── reference/                    # user-facing language reference
│   ├── source-files.md           # .lua / .nexa vs .zig (Lua+C-style hybrid)
│   ├── language.md               # syntax and semantics
│   ├── stdlib.md                 # standard library reference
│   ├── ffi.md                    # FFI library reference
│   ├── embedding.md              # both Layer A and Layer B
│   └── compatibility.md          # divergences from Lua 5.1, LuaJIT
│
├── platform/                     # platform-specific notes
│   ├── ffi-bitfield-layout.md
│   ├── jit-platform-support.md
│   └── stencil-platform-notes.md
│
├── perf-methodology.md           # benchmark protocol, baselines, regression process
└── shape-tuning.md               # heuristic values, when to revisit
```

### Notes on `docs/`

- **`specs/` is the engineering bible.** What we built and why. Updated at the start of each phase, frozen at exit. Postmortems amend rather than replace.
- **`adrs/` are short focused decisions.** When you make a fork-in-the-road call (NaN-boxing vs. tagged union, libffi vs. dyncall, copy-and-patch vs. tracing), capture the alternatives, the decision, and the date in a 1–2 page ADR. ADRs are append-only — superseded ADRs link to their replacement.
- **`reference/` is for users.** Distinct from specs. A user reading "what does `string.format` do" should use the standard library reference under `reference/` once it exists—not phase specs. For extensions and the Lua-shaped vs Zig split, see [reference/source-files.md](reference/source-files.md).

---

## 7. `examples/` — Usage Examples

```
examples/
├── embed_minimal.c               # smallest possible C embedder
├── embed_zig.zig                 # smallest possible Zig embedder
├── embed_with_sandbox.zig        # locked-down sandbox example
├── ffi_libz.lua                  # Lua-side: zlib via FFI
├── ffi_static_libc.zig           # host-side: registering libc statically
├── coroutines_pipeline.lua       # producer/consumer pattern
├── metatable_class.lua           # OO via metatables
└── README.md                     # what each example demonstrates
```

Examples are runnable. `zig build examples` builds them all; `zig build run-example -Dwhich=embed_minimal` runs one. They serve as both documentation and CI smoke tests.

---

## 8. `vendor/` — Vendored Dependencies

```
vendor/
└── libffi/
    ├── README.md                 # version, license, where it came from
    ├── upstream-pin.txt          # commit hash pinned
    └── (libffi source tree)
```

`vendor/` is intentionally minimal. Each dependency:

- Has a `README.md` explaining why it's vendored.
- Has an `upstream-pin.txt` recording the exact upstream commit.
- Builds via `build.zig` integration; we don't run libffi's autoconf machinery — we drive its build from Zig.

If a future phase adds another vendored dep (unlikely), it follows the same convention.

---

## 9. `build.zig` — Build Configuration

The build script is non-trivial. Sketch:

```zig
const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const phase = b.option(Phase, "phase", "Build through which phase") orelse .latest;

    // 1. Build libffi (vendored) — only when phase >= 3
    const libffi = if (@intFromEnum(phase) >= @intFromEnum(Phase.@"3"))
        addLibffi(b, target, optimize)
    else
        null;

    // 2. Build the stencil object and extract — only when phase >= 5
    const stencils_zig: ?std.Build.LazyPath = if (phase == .@"5") blk: {
        const obj = buildStencilObj(b, target, optimize);
        const extract = b.addRunArtifact(stencilExtractTool(b));
        extract.addArtifactArg(obj);
        const out = extract.addOutputFileArg("stencils.zig");
        break :blk out;
    } else null;

    // 3. Build the main VM library
    const vm_lib = b.addStaticLibrary(.{
        .name = "nexa",
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    if (libffi) |l| vm_lib.linkLibrary(l);
    if (stencils_zig) |s| {
        vm_lib.root_module.addAnonymousImport("stencils", .{ .root_source_file = s });
    }

    // 4. The main `nexa` binary
    const exe = b.addExecutable(.{
        .name = "nexa",
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    if (libffi) |l| exe.linkLibrary(l);
    b.installArtifact(exe);

    // 5. Tests, benches, examples (each get their own step)
    addTestStep(b, target, optimize);
    addBenchStep(b, target, optimize);
    addExamplesStep(b, target, optimize);
    addToolsStep(b, target, optimize);

    // 6. Stencil drift check (CI)
    if (phase == .@"5") {
        addStencilDriftStep(b, target, optimize);
    }
}

const Phase = enum {
    @"0", @"1", @"2", @"3", @"4", @"5",
    pub const latest: Phase = .@"5";
};
```

### Build steps

| Step                     | What it does                                         |
|--------------------------|------------------------------------------------------|
| `zig build`              | Build the `nexa` binary (current phase)            |
| `zig build test`         | Run all unit + integration tests                     |
| `zig build test-only -Dwhich=shape` | Run one test directory                  |
| `zig build bench`        | Run benchmarks; emit results                         |
| `zig build bench-compare`| Run benches, compare to baselines, fail if regression|
| `zig build examples`     | Build all examples                                   |
| `zig build run-example -Dwhich=embed_zig` | Build and run one example           |
| `zig build tools`        | Install dev tools to `bin/`                          |
| `zig build stencil-regen`| Re-extract stencils, overwrite committed files       |
| `zig build stencil-check`| Re-extract, diff against committed, fail if differ   |
| `zig build fuzz -Dwhich=cparse` | Run a fuzz harness                            |
| `zig build soak`         | Run the 24-hour stability harness                    |

### Phase gating

`zig build -Dphase=2` builds the project as it should look at end of Phase 2 — no FFI, no JIT, no Phase 4 optimizations. Used for:

- Reproducing earlier-phase behavior for differential tests.
- Working on Phase N without paying compile time for Phases > N.
- Clean exit-criteria validation: Phase 2 should pass `zig build test -Dphase=2 && zig build bench -Dphase=2`.

Implemented via `@import("config")` in source where things branch on phase. Default is `latest`.

---

## 10. `build.zig.zon` — Package Manifest

```zig
.{
    .name = .nexa,
    .version = "0.1.0",
    .minimum_zig_version = "0.15.2",
    .dependencies = .{
        // Currently no external Zig deps — libffi is vendored, not zon-managed.
    },
    .paths = .{
        "build.zig",
        "build.zig.zon",
        "src",
        "tools",
        "vendor",
        "LICENSE",
        "README.md",
    },
}
```

Version policy:

- `0.x.y` until first phase ships (Phase 0 alone is not yet "useful").
- `1.0.0` at end of Phase 2 (core Lua subset + embedding).
- `2.0.0` at end of Phase 4 (production-quality interpreter).
- `3.0.0` at end of Phase 5 (JIT shipped).

---

## 11. Naming Conventions

### Files

- **All-lowercase, snake_case.** `error_format.zig`, `string_intern.zig`. Zig convention.
- **One `pub`-facing type per file when natural.** `table.zig` defines `pub const Table`; `string.zig` defines `pub const String`. Multiple types are fine when they're tightly coupled (`gc/header.zig` exposes `GcHeader`, `Color`, `GcType`).
- **Library modules under `lib/` are named after the Lua module.** `lib/string.zig` → `string.*`. Simple.
- **No `lib_` prefix on filenames inside `lib/`.** `src/lib/string.zig`, not `src/lib/lib_string.zig`. The directory provides the namespace.

### Symbols

- **Types: `PascalCase`.** `Value`, `CType`, `GcHeader`, `JitCode`.
- **Functions: `camelCase`.** `markValue`, `tablePut`, `internShortString`. Zig convention.
- **Constants: `SCREAMING_SNAKE_CASE`.** `INITIAL_STACK_SIZE`, `MAX_REGISTER_COUNT`. Especially for compile-time constants.
- **Hole symbols: `HOLE_*`.** Stencil hole markers; the `_` prefix nothing else uses keeps them distinguishable.
- **Test names: `test "what behavior is asserted" { ... }`.** Sentence-shaped.

### Imports

Top-of-file import block:

```zig
const std = @import("std");
const builtin = @import("builtin");

const Value = @import("value.zig").Value;
const Op = @import("op.zig").Op;
const Table = @import("types/table.zig").Table;
```

- Std and builtin first.
- Project imports after.
- One import per name; no `usingnamespace` (deprecated in modern Zig anyway).

---

## 12. Cross-Cutting Conventions

### Error sets

Each subsystem defines its own error set:

```zig
pub const VmError = error{
    LuaError,             // user-raised
    TypeMismatch,
    StackOverflow,
    NotCallable,
    OutOfMemory,
};
```

The VM's main loop returns `VmError!void`. Callers handle the union; nobody catches generic `anyerror`.

### Allocators

- **GC subsystem owns its backing allocator.** `Gc` takes one `std.mem.Allocator` at init.
- **Anything else takes an allocator parameter.** No globals.
- **Phase 0 uses an arena.** Single arena for the AST and runtime values; freed at script end.
- **Tests use `std.testing.allocator`.** Catches leaks automatically.

### Source ownership

Every file has at most one "owner" subsystem. If `vm/handlers.zig` ends up importing from `ffi/` *and* `jit/` *and* `shape/`, that's a sign the responsibilities are tangled. The fix is usually to invert the dependency: handlers expose hooks; subsystems install themselves.

---

## 13. CI Configuration

`.github/workflows/build.yml`:

```yaml
name: build
on: [push, pull_request]

jobs:
  test:
    strategy:
      matrix:
        os: [ubuntu-latest, macos-latest]
        phase: ['2', '4', '5']
    runs-on: ${{ matrix.os }}
    steps:
      - uses: actions/checkout@v4
      - uses: goto-bus-stop/setup-zig@v2
        with:
          version: 0.14.0
      - run: zig fmt --check src/
      - run: zig build test -Dphase=${{ matrix.phase }}
      - run: zig build bench-compare -Dphase=${{ matrix.phase }}
        if: ${{ matrix.phase != '2' }}     # bench infra arrives in Phase 4

  stencil-drift:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: goto-bus-stop/setup-zig@v2
        with:
          version: 0.14.0
      - run: zig build stencil-check    # fails if regenerated stencils don't match committed
```

Three jobs is the floor:
- `test` — correctness across phases and platforms
- `bench-compare` — regression gate
- `stencil-drift` — toolchain hermeticity

Add more as needed (long-running soaks nightly, fuzz on schedule, etc.).

---

## 14. Skeleton: Empty Project Bootstrap

To bring up an empty repository at Phase 0, the minimum file set is:

```
build.zig
build.zig.zon
README.md
.gitignore

src/
├── main.zig                      # `pub fn main() !void { ... }` — minimal stub
├── value.zig                     # the tagged Value union from Phase 0
├── parser/
│   ├── lex.zig                   # stub: pub fn tokenize(src) ![]Token
│   ├── ast.zig                   # the Stmt/Expr unions from Phase 0
│   ├── parse.zig                 # stub: pub fn parse(tokens) !*Block
│   └── resolve.zig               # stub: pub fn resolve(ast) !ResolvedAst
├── vm/
│   ├── vm.zig                    # stub
│   └── error.zig                 # stub
└── types/
    ├── string.zig                # stub
    └── table.zig                 # stub

tests/
└── snapshots/
    ├── runner.zig
    └── arithmetic/
        ├── 001_add.lua
        └── 001_add.expected

docs/
└── specs/
    └── phase-0-tree-walking-interpreter.md   # the spec doc, copied in
```

That's the Phase 0 starting point — about 15 files, all stubs except for the type definitions (which the spec specifies precisely). Filling in the stubs *per the spec* is the actual Phase 0 work.

Each subsequent phase adds files according to its spec's "Deliverables" section. The directory structure documented above is the eventual destination; reaching it is the project itself.

---

## 15. Open Questions

1. **Should `lib/` modules live in `src/lib/` or top-level alongside `vm/`?** Currently nested. Pro: clean separation between core VM and Lua-level libraries. Con: slightly deeper paths. Probably fine.

2. **Generated stencils committed or `.gitignore`'d?** Phase 5.5 §3 argues for committed (so non-toolchain builds work). This means accepting a large auto-generated Zig file in source control. Acceptable; documented as auto-generated.

3. **Do tests live in `tests/` or alongside source?** Both, currently. Inline `test "..." { ... }` blocks for unit-level; `tests/` for integration. The split is by *what's being tested*, not *where the test runs*. Could be confusing for newcomers; document in `CONTRIBUTING.md`.

4. **Where do platform shims live?** `src/platform/`. Alternatives: `src/os/`, `src/sys/`. `platform/` is clearer about intent (cross-platform abstractions, not OS bindings).

5. **`vendor/` vs zon dependencies for libffi.** Zig's package manager has matured but libffi isn't packaged for it yet. Vendoring is correct for now; revisit if upstream Zig packaging improves and someone packages libffi.

6. **Versioning during pre-1.0.** Should every Phase's release bump a meaningful version? Pre-1.0 versioning is informal; pick `0.<phase_number>.0` for phase exits, `0.<phase>.x` for patches. After 1.0 (end of Phase 2), follow strict semver.

7. **Formatting style enforcement.** `zig fmt` is the source of truth; `--check` runs in CI. No manual style guide beyond what `zig fmt` enforces. Period.

8. **Editor configuration.** Probably ship `.editorconfig` and `.zigversion`. Resist the temptation to ship VSCode-specific settings; keep editor-agnostic.

9. **Documentation generation.** Zig's autodoc emits HTML from source comments. Not used here yet; revisit when the Layer A API matures and a website is worth building.

10. **Examples as tests.** `examples/` should also be runnable as smoke tests in CI. Add an `examples` job that builds and runs each. Catches "the example fell behind the API" bugs.
