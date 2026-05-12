# Phase 5.5 — Stencil Generation Toolchain Spec

**Project:** Lua/LuaJIT-shaped scripting language in Zig
**Spec scope:** The build-time pipeline that turns Zig stencil source into binary blobs the runtime can paste together to form native code. Authoring conventions, compilation flags, object-file extraction, relocation handling, generated-output schema, runtime patching, and the failure modes that make or break this approach.
**Relationship to Phase 5:** Companion document. Phase 5 §3 and §9 describe what stencils *are* and sketch how they're produced; this doc is the implementation contract. The stencil toolchain is the highest-risk single piece of Phase 5 and the one most likely to surface platform-specific surprises.

---

## 1. Goals & Non-Goals

### Goals

- A repeatable, hermetic build pipeline: `stencil_source.zig` → object file → `stencils.zig` (auto-generated). Same input, same output, on every machine.
- Support x86-64 Linux, x86-64 macOS, ARM64 macOS as Phase 5 baseline; design extensible to ARM64 Linux and Windows later.
- A small, well-defined "stencil ABI" between authored Zig and the runtime patcher: hole kinds, calling conventions, register pinning. Authoring violations fail the build, not silently corrupt code.
- The runtime patcher is small (~300 lines) and deals only in copying bytes and applying relocation-style edits.
- Build failure modes are clearly diagnosable. When LLVM 22 emits a stencil with an unexpected relocation, the build tells you exactly where and why.
- Each stencil round-trips through a runtime-equivalence test before it's accepted: emit it, patch it with known holes, execute, compare to interpreted reference.

### Non-Goals

- Arbitrary compiler-version compatibility. We pin a Zig version and an LLVM version per release. Stencil source is sensitive to codegen; pinning is the correct design.
- Optimal stencil size. We accept the C compiler's instruction selection. If a stencil is one `mov` longer than necessary, that's fine.
- Stencil specialization beyond what authored variants provide. The toolchain doesn't generate stencils; it extracts them. New variants require new authored source.
- Self-modifying code, beyond the normal patch-then-execute pattern. No code that rewrites itself during execution.
- Targets beyond the Phase 5 baseline. Wasm, RISC-V, 32-bit ARM, COFF/PE — possible later, not Phase 5.5.
- A general-purpose JIT framework. The toolchain is purpose-built for our opcode set.

---

## 2. What a Stencil Is

A **stencil** is a sequence of native machine-code bytes that implements one bytecode operation (one opcode, or a fused superinstruction), with **holes** — positions where runtime-determined values get patched in before execution.

### A worked example

Consider `LOADK A, D` (load constant `K[D]` into register `R[A]`). Compiled to x86-64 with our stencil ABI, it might look like:

```asm
; Stencil bytes (24 bytes, with 3 holes):
mov  r10d, <D>           ; constant index — HOLE: imm32, 4 bytes at offset 2
mov  rax, [r13 + 8*r10]  ; load K[D] (r13 = constants base)
mov  [rbp + 8*<A>], rax  ; store to R[A] — HOLE: imm32 (in modrm disp32), at offset 14
jmp  <NEXT>              ; tail call — HOLE: pc_rel32, 4 bytes at offset 20
```

The toolchain produces:

```zig
pub const stencil_loadk = StencilDef{
    .code = "\x41\xBA\x00\x00\x00\x00" ++ "\x49\x8B\x04\xD5" ++ "\x48\x89\x85\x00\x00\x00\x00" ++ "\xE9\x00\x00\x00\x00",
    .holes = &.{
        .{ .offset = 2,  .kind = .imm32,    .meaning = .const_idx_d },
        .{ .offset = 14, .kind = .imm32,    .meaning = .reg_a_offset },
        .{ .offset = 20, .kind = .pc_rel32, .meaning = .next_handler },
    },
    .arch = .x86_64,
    .size = 24,
};
```

At runtime, the JIT pastes these 24 bytes into its code arena and patches the three holes with concrete values: the actual constant index, the actual register offset, and the address of the next handler.

### Properties

- **Position-independent enough to copy.** A stencil's bytes can be placed at any address; only the marked holes need patching.
- **No hidden state.** A stencil reads its inputs from registers/memory per the calling convention, writes its outputs the same way, and uses no thread-local storage, no globals beyond what the calling convention exposes.
- **Self-contained for one opcode.** A stencil ends with a tail call to the next stencil. Control never falls through; the patcher always patches the trailing branch.

---

## 3. Build Pipeline Overview

```
src/jit/stencil_source.zig
    │
    ▼ (1) zig build-obj   — compile to .o with specific flags
src/jit/stencils.<arch>.<os>.o
    │
    ▼ (2) tools/stencil_extract — parse .o, emit Zig
src/jit/stencils.<arch>.<os>.zig   (auto-generated)
    │
    ▼ (3) zig build       — normal compilation of the VM
build/<vm-binary>
```

Three discrete steps, each invokable independently for debugging.

### Step 1: stencil object compilation

`zig build-obj` with stencil-specific flags (§5). Output is a single object file per (arch, os) pair, containing one symbol per stencil function plus relocation entries.

This step is deterministic given the same Zig + LLVM version. Stencils compiled today must match stencils compiled six months from now if the toolchain is unchanged.

### Step 2: extraction

A small Zig tool (`tools/stencil_extract`) parses the object file. For each `stencil_*` symbol:

- Read the function's bytes from its section.
- Find every relocation that falls within the function.
- Map each relocation to a hole kind via §7's rules.
- Emit a `StencilDef` constant.

Output is a Zig source file declaring `pub const stencils: [N]StencilDef`. Step 3 consumes this.

### Step 3: VM compilation

Normal `zig build`. The auto-generated `stencils.<arch>.<os>.zig` is `@import`ed by the runtime patcher. The stencil bytes become read-only data in the final binary.

### Reproducibility

The toolchain commits the auto-generated Zig file to source control. Builds without the upstream toolchain (Zig + LLVM at the pinned versions) reuse the committed `stencils.zig`. Builds *with* the toolchain regenerate and verify byte-for-byte equality with what's committed. CI gates on this equality.

---

## 4. Stencil Source Authoring

### Calling convention

Every stencil is a function with this exact signature:

```zig
pub fn stencil_<name>(
    vm:   *VM,
    ip:   [*]const Instruction,
    regs: [*]Value,
) callconv(.C) void;
```

- `vm`: pointer to the VM struct. Pinned to a specific register per architecture (RDI on SysV, X0 on AArch64 — these are the C ABI's first-arg registers, so no pinning gymnastics needed).
- `ip`: instruction pointer for the *current* opcode. Stencils that need to access the instruction read from `ip[0]`.
- `regs`: pointer into the register stack. Stencils read and write `regs[i]`.

The `callconv(.C)` annotation is critical — without it, Zig may use a custom calling convention that doesn't match across stencils.

### Hole markers

Holes are introduced via `extern` variables that the runtime patcher will substitute:

```zig
pub extern const HOLE_REG_A: u8;
pub extern const HOLE_REG_B: u8;
pub extern const HOLE_REG_C: u8;
pub extern const HOLE_CONST_D: u32;
pub extern const HOLE_NEXT_HANDLER: *const fn (*VM, [*]const Instruction, [*]Value) callconv(.C) void;
pub extern const HOLE_DEOPT_HANDLER: *const fn (*VM, [*]const Instruction, [*]Value) callconv(.C) void;
```

The extraction tool recognizes these names and treats relocations against them as holes. Each `HOLE_*` is never *defined* — references to it produce relocations the runtime fills in. Multiple stencils can reference the same hole symbol.

### Authoring example

```zig
pub fn stencil_loadk(
    vm: *VM,
    ip: [*]const Instruction,
    regs: [*]Value,
) callconv(.C) void {
    const k = vm.curr_proto.constants[HOLE_CONST_D];
    regs[HOLE_REG_A] = k;
    return @call(.always_tail, &HOLE_NEXT_HANDLER, .{ vm, ip + 1, regs });
}

pub fn stencil_add_int(
    vm: *VM,
    ip: [*]const Instruction,
    regs: [*]Value,
) callconv(.C) void {
    const b = regs[HOLE_REG_B];
    const c = regs[HOLE_REG_C];

    // Type guard: both operands must be integer-valued doubles
    if (!b.isIntegerValuedDouble() or !c.isIntegerValuedDouble()) {
        return @call(.always_tail, &HOLE_DEOPT_HANDLER, .{ vm, ip, regs });
    }

    const bi = b.asIntegerSafe() orelse {
        return @call(.always_tail, &HOLE_DEOPT_HANDLER, .{ vm, ip, regs });
    };
    const ci = c.asIntegerSafe() orelse {
        return @call(.always_tail, &HOLE_DEOPT_HANDLER, .{ vm, ip, regs });
    };

    const sum = @addWithOverflow(bi, ci);
    if (sum.@"1" != 0) {
        return @call(.always_tail, &HOLE_DEOPT_HANDLER, .{ vm, ip, regs });
    }

    regs[HOLE_REG_A] = Value.fromInteger(sum.@"0");
    return @call(.always_tail, &HOLE_NEXT_HANDLER, .{ vm, ip + 1, regs });
}
```

Notice:

- `@call(.always_tail, ...)` is mandatory at every exit. Falling through to subsequent code is undefined.
- The deopt handler is itself a hole — different call sites may want different deopt points.
- The "next handler" is a single hole per stencil; the patcher resolves it to the next stencil's address at emit time.

### Variants

Some opcodes need multiple variants:

- `stencil_add_int` — both operands integer.
- `stencil_add_double` — both operands double.
- `stencil_add_meta` — fall through to metamethod dispatch.
- `stencil_add_generic` — Phase 1 slow path.

The JIT picks a variant based on IC feedback (Phase 4.5) at compilation time. Each variant is a separate authored function.

### Authoring rules (enforced by lint)

A small `comptime` analyzer in the build script validates each stencil:

| Rule                                                | Why                                                  |
|-----------------------------------------------------|------------------------------------------------------|
| Function signature is exactly `(.*VM, [*]const Instruction, [*]Value) callconv(.C) void` | Calling convention must match across all stencils  |
| Function body ends with `@call(.always_tail, ...)`  | Stencils never fall through                          |
| No references to non-`HOLE_*` global variables      | Stencils must be self-contained                      |
| No references to thread-local storage               | TLS adds platform-specific relocations we don't handle |
| No `volatile` operations                            | LLVM may emit memory-fence instructions we don't expect |
| No floating-point in hot stencils unless declared   | x87 / SSE state interactions complicate codegen      |
| No `try` / error returns                            | Errors propagate via the deopt handler, not via Zig's return |
| Function must be `pub` and prefixed `stencil_`      | Extraction tool keys on this naming                  |

Violations fail the build with a clear message identifying the rule and the offending stencil.

---

## 5. Compilation: Getting Clean Output From Zig

The trickiest part. We need the C compiler to produce code that the extractor can parse cleanly — no stack frames, no function prologue/epilogue noise beyond what's strictly necessary, no unexpected metadata sections.

### Build flags

```
zig build-obj src/jit/stencil_source.zig
    -O ReleaseSmall
    -fno-stack-check
    -fno-stack-protector
    -fno-pic                       # x86-64 Linux; macOS overrides below
    -fno-pie
    -fno-sanitize=undefined
    -fomit-frame-pointer
    -mno-red-zone                  # avoid leaf-function red-zone optimization
    -fno-unwind-tables
    -fno-asynchronous-unwind-tables
    --target=<arch>-<os>-musl       # static binary semantics; deterministic
```

`ReleaseSmall` (not `ReleaseFast`) because we want compact stencils, not aggressively-inlined ones. Aggressive inlining defeats the per-stencil model — if the compiler decides to merge two stencils into one super-function, the boundaries we need to extract are gone.

### Per-platform overrides

| Target            | Extra flags                                     |
|-------------------|-------------------------------------------------|
| x86-64 Linux      | (defaults above)                                |
| x86-64 macOS      | `-fpic` (macOS requires PIC); accept the cost   |
| ARM64 macOS       | `-fpic` (same)                                  |
| ARM64 Linux       | (when added) `-fno-pic`                         |

PIC on macOS introduces additional indirection through the GOT for function references — which the extractor handles as `pc_rel32` relocations against the GOT slot. Doable but adds a relocation type to support. Document this clearly.

### Per-function attributes

Each stencil source function carries Zig-level attributes:

```zig
pub fn stencil_loadk(...) callconv(.C) void {
    @setRuntimeSafety(false);     // no overflow checks etc. — we do them manually
    @setCold(false);
    @setEvalBranchQuota(1000);
    // ...
}
```

`@setRuntimeSafety(false)` is critical. Zig's safety checks insert traps that bloat stencils and reference symbols we don't want to deal with.

### What the compilation produces

A single `.o` file containing:

- A `.text` section with all stencil functions concatenated
- A symbol table with one entry per `stencil_*` function (with start address and size)
- A relocations table per section
- Standard ELF/Mach-O metadata (sections, segments, etc.) we mostly ignore

Stencil functions appear as **unique symbols** with non-zero size. The `_start_` and `_end_` of each function delimit its byte range. Relocations within that range are the function's holes.

### Variants for variants

The build emits *one stencil per source function*, no specialization. If you want `add_int` and `add_double`, write both as separate `stencil_add_int` and `stencil_add_double` functions.

---

## 6. Object File Extraction

The extraction tool reads the platform-appropriate object format.

### Supported formats

| Platform               | Format    | Library           |
|------------------------|-----------|-------------------|
| x86-64 Linux           | ELF64     | hand-rolled       |
| x86-64 macOS           | Mach-O 64 | hand-rolled       |
| ARM64 macOS            | Mach-O 64 | hand-rolled       |
| ARM64 Linux (future)   | ELF64     | hand-rolled       |
| x86-64 Windows (future)| COFF/PE   | hand-rolled       |

We don't link against an existing object-file library (libelf, llvm-objcopy). Instead, hand-roll a minimal parser — about 600 lines per format, both formats well-documented, both straightforward in the subset we need.

### ELF parsing (Linux)

```zig
const ElfStencilParser = struct {
    bytes: []const u8,
    header: ElfHeader,

    pub fn parse(bytes: []const u8) !ElfStencilParser { ... }

    pub fn iterStencils(self: *ElfStencilParser) StencilIterator { ... }
};

const Stencil = struct {
    name: []const u8,
    code: []const u8,
    relocations: []const Relocation,
};
```

Walk the symbol table (`.symtab`), filter for symbols starting with `stencil_`, look up each symbol's section + offset + size, slice out the bytes. Walk the relocation table for the same section, filter for relocations falling within the symbol's byte range.

ELF relocations we handle:

| Type                  | Meaning                                  | Hole kind     |
|-----------------------|------------------------------------------|---------------|
| `R_X86_64_PC32`       | 32-bit PC-relative                       | `pc_rel32`    |
| `R_X86_64_PLT32`      | Same as PC32 for our purposes            | `pc_rel32`    |
| `R_X86_64_64`         | 64-bit absolute                          | `imm64`       |
| `R_X86_64_32`         | 32-bit absolute                          | `imm32`       |
| `R_X86_64_32S`        | 32-bit absolute, sign-extended           | `imm32s`      |
| `R_AARCH64_CALL26`    | 26-bit branch (`bl`)                     | `aarch64_call`|
| `R_AARCH64_ABS64`     | 64-bit absolute                          | `imm64`       |
| `R_AARCH64_MOVW_*`    | 16-bit chunks for `movz`/`movk` sequence | `aarch64_movw`|
| `R_AARCH64_LDST*_LO12`| 12-bit immediate in load/store           | `aarch64_ldst`|

Anything else is an error: the toolchain refuses to extract a stencil whose relocations it can't categorize.

### Mach-O parsing (macOS)

Similar shape, different format. Symbols live in the `LC_SYMTAB` load command; relocations are per-section. Stencil function names are *underscore-prefixed* on macOS (`_stencil_loadk` instead of `stencil_loadk`) — the extractor strips the prefix before matching.

Mach-O relocations we handle (x86-64 and ARM64):

| Type                     | Hole kind    |
|--------------------------|--------------|
| `X86_64_RELOC_BRANCH`    | `pc_rel32`   |
| `X86_64_RELOC_GOT_LOAD`  | `pc_rel32_got`|
| `X86_64_RELOC_UNSIGNED`  | `imm64`      |
| `ARM64_RELOC_BRANCH26`   | `aarch64_call`|
| `ARM64_RELOC_PAGE21`     | `aarch64_page`|
| `ARM64_RELOC_PAGEOFF12`  | `aarch64_pageoff`|

The macOS PIC dance requires understanding `PAGE21`/`PAGEOFF12` — these split a 64-bit address into a 21-bit page (loaded by `adrp`) and a 12-bit offset (added by a subsequent instruction). We patch both halves coordinately.

### Hole identification

For each relocation:

1. Read the relocation's symbol index.
2. Look up the symbol name in the symbol table.
3. If name matches `HOLE_*`, it's a stencil hole — record its kind and offset within the stencil.
4. If name matches another `stencil_*`, it's an inter-stencil reference (we handle these specially: they become "next handler" placeholders).
5. Anything else is an error: the stencil references a symbol the extractor doesn't recognize. Fail the build.

### Relocations *within* a stencil's bytes

Some compiler-generated code uses local labels for branches *within* a single function. These appear as relocations against the section, not against named symbols. The extractor treats them as already-resolved at extraction time: it computes the relative offset and bakes it into the stencil bytes directly.

---

## 7. Per-Architecture Relocation Handling

Each hole kind has a fixed encoding format in the stencil bytes and a fixed patching procedure at runtime.

### x86-64 hole kinds

```zig
pub const HoleKind = enum(u8) {
    imm8,           // 1-byte immediate (register number)
    imm32,          // 4-byte immediate
    imm32s,         // 4-byte signed immediate
    imm64,          // 8-byte immediate
    pc_rel32,       // 4-byte PC-relative (branch / call to unknown target)
    pc_rel32_got,   // 4-byte PC-relative through GOT (macOS PIC)
};
```

### ARM64 hole kinds

```zig
pub const HoleKindArm64 = enum(u8) {
    imm64,           // 4-instruction movz/movk sequence
    aarch64_call,    // 26-bit branch in bl/b instruction
    aarch64_page,    // 21-bit page offset in adrp
    aarch64_pageoff, // 12-bit offset in following add/ldr/str
    aarch64_movw_g0, // movz/movk bits 0..15
    aarch64_movw_g1, // movk bits 16..31
    aarch64_movw_g2, // movk bits 32..47
    aarch64_movw_g3, // movk bits 48..63
};
```

ARM64 is the harder architecture. Loading a 64-bit immediate takes 4 instructions (`movz` + 3 `movk`s, each contributing 16 bits); each contributes a separate relocation. The `MOVW_*_G[0-3]` hole kinds correspond to the four positions.

### Hole metadata

```zig
pub const Hole = struct {
    offset:  u16,        // byte offset within the stencil
    kind:    HoleKind,
    meaning: HoleMeaning, // semantic role
    addend:  i32 = 0,     // relocation addend (rare but real)
};

pub const HoleMeaning = enum {
    reg_a, reg_b, reg_c, reg_d,
    const_idx,
    proto_idx,
    upvalue_idx,
    next_handler,
    deopt_handler,
    barrier_handler,
    metamethod_dispatch,
    // ... etc, ~20 meanings
};
```

`HoleMeaning` is the contract between the authored stencil source (via `HOLE_*` symbols) and the runtime patcher (which knows what each meaning resolves to). Adding a new meaning requires:

1. New `HOLE_*` symbol in `stencil_source.zig`.
2. Updated extractor mapping name → meaning.
3. Updated runtime patcher resolving meaning → concrete value.

### Patch table layout

The extractor's output lists holes in *offset-ascending* order, so the patcher can stream-patch without sorting:

```zig
pub const StencilDef = struct {
    name:  []const u8,
    code:  []const u8,
    holes: []const Hole,
    arch:  Arch,
};
```

---

## 8. The Generated `stencils.zig`

The extractor's output is a single Zig file:

```zig
// Auto-generated by tools/stencil_extract. DO NOT EDIT.
// Source: src/jit/stencil_source.zig
// Target: x86_64-linux

const StencilDef = @import("stencil_def.zig").StencilDef;
const Hole = @import("stencil_def.zig").Hole;

pub const stencils = [_]StencilDef{
    .{
        .name = "loadk",
        .code = "\x41\xBA\x00\x00\x00\x00\x49\x8B\x04\xD5\x48\x89\x85\x00\x00\x00\x00\xE9\x00\x00\x00\x00",
        .holes = &.{
            .{ .offset = 2,  .kind = .imm32,    .meaning = .const_idx },
            .{ .offset = 13, .kind = .imm32,    .meaning = .reg_a },
            .{ .offset = 18, .kind = .pc_rel32, .meaning = .next_handler },
        },
        .arch = .x86_64,
    },
    .{
        .name = "add_int",
        .code = "\x...",
        .holes = &.{ ... },
        .arch = .x86_64,
    },
    // ... ~100+ stencils
};

pub const stencil_index = std.ComptimeStringMap(usize, .{
    .{ "loadk", 0 },
    .{ "add_int", 1 },
    // ...
});
```

Two tables: the array-indexed `stencils` for runtime use, and the comptime-string-map `stencil_index` for the JIT compiler to look up by opcode name.

The file is committed to source control. The CI rebuilds and diffs against the committed version on every commit — divergence indicates either a compiler-version drift or unintended source change.

---

## 9. Runtime Patching

The runtime side: copy stencil bytes into the code arena, walk the holes, resolve each meaning to a concrete value, write the value at the indicated offset using the appropriate encoding.

### Patcher core

```zig
pub fn emit(jit: *Jit, stencil_idx: usize, ctx: PatchCtx) ![*]u8 {
    const stencil = stencils[stencil_idx];
    const dst = try jit.code_arena.append(stencil.code);

    for (stencil.holes) |hole| {
        const value = try ctx.resolve(hole.meaning);
        try patch(dst, hole, value);
    }

    return dst;
}

fn patch(dst: [*]u8, hole: Hole, value: u64) !void {
    const at = dst + hole.offset;
    switch (hole.kind) {
        .imm8 => at[0] = @truncate(value),

        .imm32 => {
            const v32: u32 = @truncate(value);
            @memcpy(at[0..4], std.mem.asBytes(&v32));
        },

        .imm64 => {
            @memcpy(at[0..8], std.mem.asBytes(&value));
        },

        .pc_rel32 => {
            const target_addr: i64 = @intCast(value);
            const here_addr: i64 = @intCast(@intFromPtr(at) + 4);  // PC after instruction
            const rel: i32 = @intCast(target_addr - here_addr + hole.addend);
            @memcpy(at[0..4], std.mem.asBytes(&rel));
        },

        .aarch64_call => {
            // bl/b is 26 bits, low 2 bits zero (instruction-aligned), encoded at bits [25:0]
            const target: i64 = @intCast(value);
            const here: i64 = @intCast(@intFromPtr(at));
            const offset_words: i32 = @intCast(@divExact(target - here, 4));
            if (offset_words < -(1 << 25) or offset_words >= (1 << 25)) return error.BranchOutOfRange;
            const masked: u32 = @as(u32, @bitCast(offset_words)) & 0x03FF_FFFF;
            const existing: u32 = std.mem.readInt(u32, at[0..4], .little);
            const new = (existing & 0xFC00_0000) | masked;
            @memcpy(at[0..4], std.mem.asBytes(&new));
        },

        .aarch64_page => {
            // adrp encodes a 21-bit page-relative offset across two fields
            const target_page = @intFromPtr(value) >> 12;
            const here_page = (@intFromPtr(at)) >> 12;
            const page_diff: i64 = @intCast(target_page - here_page);
            // ... encode into adrp instruction (immlo:immhi fields)
        },

        // ... etc.
    }
}
```

### `PatchCtx`

The patcher's caller provides resolution context:

```zig
pub const PatchCtx = struct {
    reg_a: u8,
    reg_b: u8,
    reg_c: u8,
    reg_d: u8,
    const_idx: u32,
    next_handler: *anyopaque,
    deopt_handler: *anyopaque,
    // ...

    pub fn resolve(self: PatchCtx, meaning: HoleMeaning) !u64 {
        return switch (meaning) {
            .reg_a => self.reg_a,
            .reg_b => self.reg_b,
            .reg_c => self.reg_c,
            .reg_d => self.reg_d,
            .const_idx => self.const_idx,
            .next_handler => @intFromPtr(self.next_handler),
            .deopt_handler => @intFromPtr(self.deopt_handler),
            // ...
        };
    }
};
```

The JIT driver constructs a `PatchCtx` per opcode it's compiling, walks the bytecode, calls `emit` for each opcode in sequence, and patches each stencil's `next_handler` hole to point at the address where the *next* stencil will land.

This requires either a two-pass approach (first compute all offsets, then patch) or careful forward-patching with placeholders. Two-pass is simpler; ship that.

### W^X discipline

Phase 5 §8 covered this. The patcher's contract:

1. Code arena pages are allocated `PROT_READ | PROT_WRITE` (or platform equivalent).
2. After all patching for a function is complete, the page is `mprotect`ed to `PROT_READ | PROT_EXEC`.
3. On ARM64, the instruction cache is flushed for the page range via `__builtin___clear_cache`.
4. macOS: `pthread_jit_write_protect_np` toggles the per-thread W vs X bit on Apple Silicon.

The patcher API enforces this:

```zig
pub fn finalize(jit: *Jit, fn_start: [*]u8, fn_size: usize) !void {
    try jit.code_arena.finalizeRange(fn_start, fn_size);  // mprotect + cache flush
}
```

A function is not callable until `finalize` has returned successfully.

---

## 10. The Code Arena

Phase 5 §8 sketched this; the toolchain's runtime side reuses it. Key responsibilities:

- Allocate pages of executable memory (`mmap` with `PROT_READ | PROT_WRITE`, later `mprotect` to `PROT_READ | PROT_EXEC`).
- Bump-allocate within the current writable page.
- Track the writable region's bounds; prevent writes outside it.
- Provide alignment guarantees (16-byte function entry alignment on x86-64; 4-byte on ARM64).
- Implement `finalizeRange` for W^X transition + i-cache flush.

```zig
pub const CodeArena = struct {
    pages:        std.ArrayList(Page),
    writable:     ?WritableRegion,

    pub const Page = struct {
        base: [*]u8,
        size: usize,
        state: enum { writable, executable },
    };

    pub fn append(self: *CodeArena, bytes: []const u8) ![*]u8 { ... }
    pub fn finalizeRange(self: *CodeArena, start: [*]u8, len: usize) !void { ... }
    pub fn flush(self: *CodeArena) void { ... }   // free everything
};
```

### Why a separate arena for executable code

GC-managed memory and JIT-emitted code have different allocation patterns and protection requirements. Mixing them is asking for memory-protection bugs and complicates W^X handling. The arena is its own subsystem with its own allocator (uses `std.os.mmap` directly, not the GC's backing allocator).

### Alignment

Stencils may need alignment for two reasons:

1. **Function-entry alignment:** branch targets benefit from being on certain boundaries. x86-64 microarchitectures prefer 16-byte alignment; ARM64 requires 4-byte (instruction word) alignment.
2. **Inline immediate alignment:** some immediates within stencils need to be naturally aligned (e.g., 64-bit constants used by `mov rax, imm64` benefit from 8-byte alignment for cache-line behavior).

The patcher pads with NOPs (or `BRK` traps in unreachable padding) to maintain alignment. The padding is included in the emitted byte count so subsequent stencils know where they land.

---

## 11. Cross-Platform Support Matrix

Phase 5.5 baseline:

| Platform               | Status       | Notes                                              |
|------------------------|--------------|----------------------------------------------------|
| x86-64 Linux           | Required     | Primary dev target, simplest case                  |
| x86-64 macOS           | Required     | PIC required; GOT indirection for some calls       |
| ARM64 macOS            | Required     | Apple Silicon; W^X via `pthread_jit_write_protect` |
| ARM64 Linux            | Phase 5.5+   | When tested, should be straightforward             |
| x86-64 Windows         | Future       | COFF/PE parsing, different calling convention      |
| ARM64 Windows          | Future       | Same complexity as macOS plus COFF                 |
| Wasm                   | Future       | Different model entirely; JIT-to-Wasm is research  |
| RISC-V                 | Future       | Add when there's user demand                       |

Each row in the matrix corresponds to a distinct (compiled stencil object, generated stencils.zig) pair. The build produces all required pairs; CI runs the soak suite on each.

### Calling-convention differences

The stencil ABI (`(.*VM, [*]const Instruction, [*]Value) callconv(.C) void`) abstracts over platform differences. `callconv(.C)` resolves to:

- SysV AMD64: RDI, RSI, RDX (first three register args), no callee-saves used, RAX for return (none here).
- AArch64 AAPCS: X0, X1, X2 (first three), no callee-saves, X0 return.
- Windows AMD64 (future): RCX, RDX, R8 — different first-three! Stencils would need re-extraction per Windows target.

Because we use C-ABI throughout, Zig handles this: stencils compiled with `--target=x86_64-windows` use Windows registers automatically. We don't need separate authored sources; only separate compiled outputs.

---

## 12. Testing Strategy

### Round-trip equivalence

Every stencil is verified equivalent to its interpreted counterpart:

```zig
test "stencil round-trip: loadk" {
    var jit = setupTestJit();
    defer jit.deinit();

    // Set up VM state with a constant table containing 42.0 at index 5
    var vm = setupTestVm(...);
    vm.curr_proto.constants[5] = Value.fromDouble(42.0);

    // Emit the loadk stencil patching K=5, A=3, NEXT=&halt_handler
    const code = try jit.emit(stencil_index.get("loadk").?, .{
        .reg_a = 3,
        .const_idx = 5,
        .next_handler = &halt_handler,
        // ...
    });
    try jit.finalize(code, 24);

    // Execute
    runStencil(code, &vm);

    try expectEqual(@as(f64, 42.0), vm.regs[3].asDouble().?);
}
```

100+ such round-trip tests, one per stencil at minimum, more for variants.

### Differential against interpreter

Every Phase 4 corpus test runs in three modes: interpreter only, JIT only, mixed (functions tier-up at hotness threshold). All three must produce identical output.

### Stencil byte equality

The committed `stencils.x86_64-linux.zig` is regenerated on CI; the new file must be byte-identical to the committed one. Drift indicates compiler-version skew or unintended source changes.

### Cross-arch consistency

For a given stencil (say, `add_int`), the x86-64 Linux version and the ARM64 macOS version must produce equivalent execution given the same `PatchCtx`. Verified by running the same Lua program on both.

### Hole-coverage check

The build verifies that every `HOLE_*` symbol declared in `stencil_source.zig` has a corresponding `HoleMeaning` in the runtime patcher's resolver, and vice versa. Missing wiring fails the build.

### Stress: deopt-every-guard

Phase 5 §10 mentioned this. Toggle via build flag: every guard always fires deopt. Output must still match the interpreter.

### Stress: random-pad-stencils

A test mode that inserts random NOP padding between emitted stencils. Branches that worked before (e.g., backwards `pc_rel32`) must still work. Catches accidental dependence on stencil placement.

### Long-running stability

Phase 4's 24-hour soak with the JIT enabled. Stencil emit/finalize cycles many times; `mprotect` calls many times; cache flushes many times. No crashes, no leaked pages, no `mprotect` failures.

---

## 13. Failure Modes and Debugging

### "Compiler-version drift"

Symptom: `stencils.x86_64-linux.zig` regenerated by CI doesn't match the committed version.
Root cause: LLVM minor version bump, Zig minor version bump.
Fix: regenerate, eyeball the diff, commit if reasonable. Set up alerting so this doesn't happen silently — it's *expected* periodically, but it should always be acknowledged.

### "Unexpected relocation type"

Symptom: extractor errors with "unhandled relocation type 0x42 in stencil_xyz at offset 38".
Root cause: compiler emitted code using a relocation our extractor doesn't recognize. Often happens when stencil source uses TLS, a global variable, or an unsupported intrinsic.
Fix: identify what in the source caused the relocation; rewrite the source to avoid it; or, if legitimately needed, add the relocation type to the extractor's table.

### "Stencil too large"

Symptom: a stencil exceeds an internal limit (default 256 bytes per stencil).
Root cause: complex semantics + unhelpful inlining. Sometimes the compiler decides to inline a function we wanted out-of-line.
Fix: add `@call(.never_inline, ...)` annotations, simplify the source, or split the stencil into multiple smaller ones.

### "Branch out of range"

Symptom: runtime patch error "BranchOutOfRange" when emitting a stencil.
Root cause: the code arena is too large, and a stencil's PC-relative branch can't reach its target.
Fix: emit a trampoline. The patcher detects out-of-range, allocates a small trampoline (a 64-bit indirect jump) nearby, and patches the original branch to target the trampoline. Adds latency but never fails.

### "W^X violation"

Symptom: SIGSEGV when calling JIT'd code on macOS.
Root cause: forgot `pthread_jit_write_protect_np` toggle, or wrote to a page after finalizing.
Fix: tighten the patcher API; make finalize the only path to executable state.

### Debugging tools

Three are essential:

- `stencil_disasm <name>` — dumps a stencil's bytes through `llvm-objdump` or our own minimal disassembler. Verifies "did the compiler produce what I expected?"
- `stencil_dump_patched <jit_code_addr>` — dumps emitted (post-patch) bytes for a runtime-emitted function. Verifies "did the patcher do the right thing?"
- `stencil_diff` — compares two `stencils.zig` files semantically (same hole layout, same effective bytes accounting for benign NOPs). Useful when investigating compiler-drift diffs.

Build all three early; debugging stencils without them is miserable.

---

## 14. Exit Criteria

- [ ] `stencil_source.zig` authoring conventions documented; lint enforcing the rules from §4 passes
- [ ] Build pipeline produces `stencils.x86_64-linux.o` deterministically; same input → same output
- [ ] Extractor parses ELF and Mach-O object files; recognizes all stencils and their relocations
- [ ] All hole kinds from §7 are encoded and patched correctly; round-trip test passes for each
- [ ] Generated `stencils.x86_64-linux.zig` and `stencils.aarch64-macos.zig` (and others as required) committed and CI-validated
- [ ] Code arena enforces W^X; pages move from RW to RX cleanly; macOS Apple Silicon `pthread_jit_write_protect_np` integrated
- [ ] All three baseline platforms (x86-64 Linux, x86-64 macOS, ARM64 macOS) pass the Phase 5 corpus
- [ ] Round-trip tests: every stencil passes individual round-trip equivalence
- [ ] Differential: JIT-emitted code and interpreter produce identical output across the corpus
- [ ] Branch-out-of-range trampolines work; verified by allocating a 4MB code arena and emitting branches that span it
- [ ] Debug tools (`stencil_disasm`, `stencil_dump_patched`, `stencil_diff`) implemented and used by the test suite
- [ ] Compiler-version drift detection: CI regenerates and diffs; mismatch fails build with clear message
- [ ] No leaks under `GeneralPurposeAllocator{ .safety = true }`; arena pages freed on shutdown
- [ ] `zig fmt` clean, `zig build test` green

---

## 15. Deliverables

| Path                              | Contents                                              |
|-----------------------------------|-------------------------------------------------------|
| `src/jit/stencil_source.zig`      | Authored stencil sources                              |
| `src/jit/stencil_def.zig`         | `StencilDef`, `Hole`, `HoleKind`, `HoleMeaning` types |
| `src/jit/stencils.x86_64-linux.zig` | Auto-generated, committed                           |
| `src/jit/stencils.x86_64-macos.zig` | Auto-generated, committed                           |
| `src/jit/stencils.aarch64-macos.zig` | Auto-generated, committed                          |
| `src/jit/code_arena.zig`          | W^X memory management                                 |
| `src/jit/patcher.zig`             | `emit`, `patch`, `finalize`                           |
| `src/jit/patch_ctx.zig`           | `PatchCtx` and resolve logic                          |
| `tools/stencil_extract/main.zig`  | Build-time extraction tool                            |
| `tools/stencil_extract/elf.zig`   | ELF parser                                            |
| `tools/stencil_extract/macho.zig` | Mach-O parser                                         |
| `tools/stencil_extract/reloc_x64.zig` | x86-64 relocation interpretation                  |
| `tools/stencil_extract/reloc_arm64.zig` | ARM64 relocation interpretation                 |
| `tools/stencil_disasm/main.zig`   | Stencil disassembly tool                              |
| `tools/stencil_dump_patched/main.zig` | Runtime-state dump tool                           |
| `tools/stencil_diff/main.zig`     | Semantic diff between two stencils.zig files          |
| `build.zig` (extended)            | Multi-target stencil build wired into the build graph |
| `tests/stencil/round_trip/`       | Per-stencil round-trip tests                          |
| `tests/stencil/extractor/`        | Extractor tests against curated `.o` files           |
| `tests/stencil/cross_arch/`       | Same-source-different-arch consistency tests          |
| `tests/stencil/stress/`           | Random pad, branch out of range, deopt-every          |
| `docs/stencil-toolchain.md`       | User-facing docs: how to add a new stencil           |
| `docs/stencil-platform-notes.md`  | Per-platform quirks and known issues                  |

---

## 16. Estimated Effort

3.5–4.5 months focused. Part of Phase 5's overall 9–12 month estimate.

| Component                              | Estimate    |
|----------------------------------------|-------------|
| Stencil ABI design + authoring conventions | 1 week  |
| Build pipeline (zig build-obj integration) | 1 week  |
| ELF parser                             | 1.5 weeks   |
| Mach-O parser                          | 2 weeks     |
| x86-64 relocation interpretation       | 1 week      |
| ARM64 relocation interpretation        | 2 weeks     |
| Generated `stencils.zig` schema + emitter | 1 week   |
| Runtime patcher (per hole kind)        | 2 weeks     |
| Code arena + W^X integration           | 1.5 weeks   |
| First 10 stencils end-to-end           | 2 weeks     |
| Debug tools                            | 1 week      |
| Cross-arch validation                  | 2 weeks     |
| Compiler-drift CI integration          | 4 days      |
| Stress tests + soak                    | 1.5 weeks   |
| Documentation                          | 1 week      |
| Bringup of full opcode coverage        | 2 weeks     |

The "first 10 stencils" line is the single most-important calendar block. After 10 stencils end-to-end, the toolchain is *known to work*; remaining stencils are mostly mechanical. Most projects underestimate the ramp-up to 10; budget honestly.

---

## 17. Open Questions

1. **Zig version pinning policy.** How often do we update? Conservative: pin once per Phase 5 release, regenerate stencils on update. Aggressive: track Zig nightly, auto-regenerate. Recommendation: conservative — Zig nightly churn would destabilize the build.

2. **LLVM-specific instruction selection.** Different LLVM minor versions sometimes choose different instruction sequences for the same input. This is a feature of LLVM, not a bug. Our diff tooling should distinguish "semantically equivalent but bytewise different" from "behavior changed." The `stencil_diff` tool covers this by comparing post-patch behavior, not raw bytes.

3. **Stencil specialization granularity.** Should we ship one `stencil_add` and have the JIT pick a deopt path, or three separate stencils (`add_int`, `add_double`, `add_meta`) selected at compile time? §4 picked the latter. Trade-off: more stencils to maintain vs. simpler runtime selection. Three is right.

4. **Branch-out-of-range trampoline layout.** Trampolines need to live in the code arena somewhere reachable from the originating branch. A "trampoline pool" near the originating page, allocated lazily, is the standard approach. Deferred to implementation; not a blocker.

5. **Compiler-emitted unwind info.** We compile with `-fno-unwind-tables`, but some platforms (macOS in particular) require minimal unwind info for debuggers and crash reporters. If users running JIT'd code complain about useless backtraces, consider opt-in unwind info per stencil. Defer.

6. **Apple Silicon W^X performance.** Toggling per-thread W/X bits has a cost (~50ns each call). Batching JIT compilation to amortize is straightforward. Worth measuring; if it's a bottleneck for short-running scripts, consider deferring W^X enforcement until first compilation completes.

7. **`__chkstk` and stack guards.** Windows builds (future) may require stack-probe instrumentation. Stencils with deep call chains might trigger probes. Disable via build flag or design stencils to use small stacks. Re-evaluate when adding Windows support.

8. **Hot reload of stencils.** Currently, changing `stencil_source.zig` requires a full rebuild. A "hot reload" mode that recompiles stencils and re-emits all JIT'd functions could speed development. Out of scope; defer.

9. **PIC GOT indirection cost on macOS.** macOS PIC routes some calls through the GOT, adding an indirect load. Measure; if this is a sustained cost, consider stitching together stencils such that internal calls don't need GOT (we control them; they're in the same emitted page).

10. **Stencil source review process.** Authoring stencils is delicate; a poorly-written one can produce wrong output that passes most tests. Recommend: every new stencil requires a paired round-trip test in the same PR, and a code review explicitly for the stencil source. Enforce via CODEOWNERS.

11. **Static analysis for authoring rules.** §4's authoring rules are enforced by a `comptime` analyzer in the build. Confidence in this analyzer is critical — a buggy analyzer admits broken stencils. Hand-validate the analyzer with a corpus of intentionally-rule-violating stencils.

12. **Stencil identification for profilers.** External profilers (perf, Instruments) can't symbolicate JIT'd code without help. Optionally emit a perf-map file mapping JIT'd address ranges to stencil names. Tiny amount of code; high value when investigating performance.

13. **Object-format library option.** Hand-rolling ELF and Mach-O parsers is ~1200 lines combined. An alternative is using Zig's `std.elf` (exists; reasonable quality) and any available Mach-O reader. Prefer standard library where available; fall back to hand-rolled where not.

14. **Where to store the committed stencils.** They're auto-generated but committed. They live under `src/jit/`. Potential confusion: developers may try to edit them directly. Add a header comment + `.gitattributes` `linguist-generated` annotation to make this obvious.
