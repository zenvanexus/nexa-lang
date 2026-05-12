# Phase 5 — JIT Compilation

**Project:** Lua/LuaJIT-shaped scripting language in Zig
**Phase goal:** Add a JIT compilation tier that lifts hot code from the optimized interpreter to native code. Targets a meaningful speedup over Phase 4 (the floor) without committing to the multi-year scope of a LuaJIT-class trace JIT (the ceiling).

**Predecessors:** All prior phases. Phase 4's ICs, hidden classes, number specialization, and superinstructions are not just useful — they're load-bearing. The JIT consumes them as type feedback and reuses their dispatch patterns as compilation targets.

---

## A note on this phase

The previous phases had clear bounds. "Build a tree-walking interpreter," "ship a register VM with NaN-boxed values," "implement Lua patterns and `coroutine.*`" — these are well-scoped engineering tasks. The implementation difficulty is real, the design space is finite, and the exit criteria are crisp.

**Phase 5 is qualitatively different.** A production-grade JIT for a dynamic language is open-ended research. Mike Pall spent ~7 years on LuaJIT (and continues to). PyPy has 20+ contributor-years invested. V8's Crankshaft, then TurboFan, then Maglev, then Turboshaft — Google has rewritten its Lua-shaped-language JIT four times, each iteration a multi-year effort by a dedicated team.

This phase, written honestly, is **a decision document and a sketch**, not an implementation plan. The decision is: *which* JIT do we build, given the resources available? The sketch is what each option looks like.

---

## 1. Goals & Non-Goals

### Goals

- Choose a JIT scope that's achievable in 6–18 months by a small team, not 5+ years by a larger one.
- Ship something that produces a measurable speedup over Phase 4's optimized interpreter — at minimum 2x on the benchmark suite, with a stretch target of 5x.
- Reuse Phase 4's IC and shape infrastructure as type feedback for compilation; do not build a parallel system.
- Maintain correctness: the JIT must be semantically transparent. JIT'd code and interpreted code must be observationally indistinguishable except through `os.clock()`.
- Honest deopt path: when speculation fails (shape changed, type changed, metatable replaced), the system reverts cleanly to the interpreter without losing state.

### Non-Goals

- Match LuaJIT performance. LuaJIT is the work of one extraordinarily good systems engineer over a decade. We are not going to match it; we're going to ship a *useful* JIT.
- Method-level whole-function compilation as the primary unit. Function-level JITs (HotSpot, V8 TurboFan) are bigger projects than trace JITs for dynamic languages because they have to handle the full type-uncertainty surface up front.
- Native code on platforms beyond x86-64 and AArch64. Other targets (RISC-V, 32-bit ARM, Wasm) are extensions, not Phase 5.
- Ahead-of-time compilation. JIT only.
- Self-modifying code beyond what deopt patching requires.
- Multi-threaded compilation. The compiler runs on the mutator thread (with bounded budgets) or on a single dedicated compiler thread. No parallel-compilation infrastructure.

---

## 2. Scope Decision

Three serious options, in order of ambition.

### Option A — Full Tracing JIT (LuaJIT-class)

Record hot loops as straight-line traces, optimize the linear IR, generate native code via a hand-rolled assembler. The architecture LuaJIT and PyPy use.

**Pros:**

- Genuinely competitive with LuaJIT on the favorable workloads.
- The IC and shape infrastructure from Phase 4 fits this model perfectly — IC fast-path success becomes a trace guard, shape stability becomes a specialization key.
- It's the *right* answer architecturally for this style of language.

**Cons:**

- 2–3 years of focused work for a small team, possibly more.
- Hand-rolled assembler (DynASM-equivalent) for two architectures = ~6 months on its own.
- Trace optimizer (SSA, LICM, alias analysis, allocation sinking, redundancy elimination) = ~6 months.
- Side-trace stitching and trace-tree management is a known time sink.
- High risk of "works on benchmarks, slow on real code" without sustained tuning.

**Effort estimate: 18–36 months.**

### Option B — Copy-and-Patch JIT (recommended)

Pre-compile small "stencils" — one per opcode or per common pattern — at *Zig* compile time. At runtime, the JIT pastes stencils together end-to-end and patches in immediates (constants, register numbers, branch targets). No instruction selection, no register allocator, no traditional codegen pipeline. Reference: Xu and Kjolstad, "Copy-and-Patch Compilation" (PLDI 2021).

**Pros:**

- Dramatically simpler than tracing JIT or any backend library. Implementation is O(months), not O(years).
- Stencil generation leverages Zig's `comptime` plus offline tooling — we compile Zig functions to native code and extract them as stencils at build time.
- No assembler maintenance: stencils are produced by the C compiler we already trust.
- Easy to port: stencils for ARM64 generated the same way, just a different compiler target.
- Speedups of 2–4x over interpreters reported in the literature for similar systems (PostgreSQL JIT, V8's Sparkplug uses related techniques).

**Cons:**

- Generated code is not as good as a real optimizing JIT. ~50% of LuaJIT's interpreter-mode-relative speedup, in the literature.
- Per-opcode stencils don't cross opcode boundaries, so optimization opportunities like constant propagation and dead store elimination are missed.
- Some optimizations (LICM, allocation sinking) are essentially impossible in this model.

**Effort estimate: 6–10 months.**

### Option C — Specializing Interpreter Tier

No native code generation. Instead, when a function gets hot, *recompile* its bytecode into a new bytecode that has all the type guards baked in as superinstructions and all the IC slots pre-resolved. Same dispatch loop, more aggressive specialization.

**Pros:**

- Doesn't require any new infrastructure beyond what Phase 4 has.
- Trivially correct — it's still interpreted code.
- 3–4 months of work, mostly in the bytecode compiler.

**Cons:**

- 1.3–1.7x speedup ceiling. Won't get within striking distance of LuaJIT.
- Marketing-wise, "tier-2 interpreter" is harder to sell than "JIT" even if the win is real.

**Effort estimate: 3–4 months.**

### Recommendation

**Ship Option B.** The reasoning:

1. Option A is a multi-year commitment with high risk of "almost-finished" purgatory. For a research project (not a product company), the opportunity cost is too high.

2. Option C is incremental over Phase 4 but gives up the JIT-narrative entirely. If we're going to claim a JIT exists, it should generate native code.

3. Option B hits a real sweet spot: 2–4x speedup achievable in under a year, code generation is real (the result is native instructions), and the implementation strategy plays to Zig's strengths (`comptime` stencil generation, easy cross-compile for ARM stencils).

The rest of this document focuses on Option B. §11 sketches Option A briefly for completeness.

---

## 3. Copy-and-Patch — How It Works

The core idea is dirt-simple: a JIT is a code-paster.

### Stencils

A **stencil** is a pre-compiled fragment of native code that implements one bytecode operation, with placeholders ("holes") for runtime values like register numbers and immediates.

For example, the stencil for `ADD A, B, C` (integer fast path):

```
mov  rax, [rbp + 8 * <B>]        ; load reg B          ← hole: B
mov  rdx, [rbp + 8 * <C>]        ; load reg C          ← hole: C
mov  rcx, rax
sar  rcx, 47                     ; check NaN-box tag
cmp  rcx, TAG_NUMBER             ; type guard
jne  <DEOPT>                     ; deopt to interp     ← hole: deopt target
add  rax, rdx                    ; integer add
mov  [rbp + 8 * <A>], rax        ; store result        ← hole: A
```

### Generation at Zig compile time

We write *each opcode handler twice*:

1. The interpreted version (already exists, from Phase 1) — runs in the dispatch loop.
2. A "stencil source" version — Zig functions tagged with `__attribute__((noinline))` or equivalent, with parameters that become stencil holes.

At Zig build time, an offline tool compiles the stencil source to object code, extracts each function's machine code into a stencil binary blob, and emits a Zig file with the stencils as constants:

```zig
// auto-generated stencils.zig
pub const stencil_op_add_int = StencilDef{
    .code = &.{ 0x48, 0x8B, 0x45, /* ... */ },
    .holes = &.{
        .{ .offset = 3, .kind = .reg_b },
        .{ .offset = 7, .kind = .reg_c },
        .{ .offset = 19, .kind = .deopt_target },
        .{ .offset = 26, .kind = .reg_a },
    },
};
```

### Patching at runtime

The JIT walks bytecode, looks up the stencil for each opcode, copies the bytes into a write-then-execute buffer, and patches the holes with concrete values:

```zig
fn emit(jit: *Jit, op: Op, args: anytype) !void {
    const stencil = stencils[@intFromEnum(op)];
    const dst = jit.code.append(stencil.code);
    inline for (stencil.holes) |hole| {
        const value = resolveHole(hole.kind, args);
        patch(dst, hole.offset, hole.kind, value);
    }
}
```

The output is native code that runs at native speed. No interpretation, no dispatch.

### What we DON'T have

- **No instruction selection.** The C compiler chose instructions when it built the stencils.
- **No register allocator.** Stencils use a fixed register convention (e.g., RBP = register base, RBX = VM pointer, scratch in RAX/RCX/RDX).
- **No optimizer.** Each opcode is independent.
- **No code that crosses opcode boundaries.** A `LOADK; ADD` pair generates the LOADK stencil followed by the ADD stencil, with no constant folding between.

These are real losses. Phase 4's superinstructions partially compensate by giving us pre-fused multi-opcode stencils.

---

## 4. JIT Triggering

When does code get JIT'd?

### Hotness counter

Each `Proto` has a hotness counter, decremented on entry. When it hits zero, JIT.

```zig
pub const Proto = struct {
    // ... existing fields
    hotness:    i32 = INITIAL_HOTNESS,   // typically 1000
    jit_code:   ?*JitCode = null,
};
```

The interpreter loop, on `CALL` to a Lua function:

```
fn op_call(...):
    proto.hotness -= 1
    if proto.hotness <= 0 and proto.jit_code == null:
        compile_function(proto)
    if proto.jit_code != null:
        return call_native(proto.jit_code, ...)
    else:
        # interpret as before
```

Once `jit_code` is populated, future calls dispatch into native code directly.

### Compilation budget

Compilation is bounded:

- Per-function: skip JIT for functions with `code.len > 1024` instructions. Large functions don't fit the copy-and-patch model well; let them keep interpreting.
- Per-cycle: at most one function compiled per `CALL` opcode invocation. If multiple functions cross the threshold simultaneously, they compile across multiple invocations. Avoids latency spikes.
- Total: a global compilation budget per second (e.g., 50ms wall-clock). When exceeded, compilations are deferred. Prevents sustained pause from a script that's churning hot functions.

### Tier-up from interpreter to JIT mid-execution

For long-running functions (a `while true do ... end` server loop), we want to JIT *during* the loop, not just on the next call. **On-stack replacement (OSR)** is the technique:

- Backwards-branch handlers check hotness too.
- If a long-running loop crosses the threshold, compile the function and *splice the native code into the running execution* at the next safe point.

OSR is finicky (live values must transfer correctly between interpreter and native frame). For Phase 5, defer OSR — only JIT on function entry. Document this as a known limitation that affects scripts with one big loop.

---

## 5. Type Specialization via Phase 4 Feedback

The IC and shape feedback from Phase 4 is the JIT's input.

### IC feedback at compile time

When we compile `TGETS R[A], R[B], "x"`, we look at the IC cell:

- **Monomorphic, shape S, offset 7:** emit the *fast-path-only* stencil that asserts shape match and loads from offset 7. Deopt branch on mismatch.
- **Polymorphic, 2–4 shapes:** emit a small dispatch testing each cached shape, fall through to deopt on miss.
- **Megamorphic or uninitialized:** emit the slow-path stencil (full hash lookup).

This is *speculative compilation*. We're betting the IC's recorded behavior continues to hold; if it doesn't, we deopt.

### Number specialization

`ADD` with both operands recently observed as integer-valued doubles → emit the integer-add stencil with type guards + overflow check. Deopt on guard failure or overflow.

If only one was integer (say B) → emit a "guard B is integer, treat C as double" specialized stencil.

### Shape stability

The JIT compilation captures specific shape IDs. If a shape is invalidated (by metatable replacement, by promotion to dictionary mode, etc.), every JIT'd function that captured that shape must be invalidated. Mechanism: a side table mapping `shape_id → list of *JitCode that depend on it`. On invalidation, walk the list, mark each as stale; next call falls back to interpreter and triggers recompilation.

---

## 6. Deoptimization

The lifeline of any speculative JIT.

### What deopt looks like

A type guard fails. The stencil's deopt branch jumps to a deopt handler that:

1. Reads the current state (registers, IP-equivalent, current frame).
2. Reconstructs the equivalent interpreter state — register values copied to the interpreter's stack, IP set to the interpreted opcode that was about to execute.
3. Returns into the interpreter loop.

### Deopt metadata

Each deopt site carries a small descriptor:

```zig
const DeoptInfo = struct {
    bytecode_pc:  u32,            // which instruction to resume at
    reg_layout:   []RegMapping,    // how native registers map to VM registers
    // (in Phase 5 with copy-and-patch, this is mostly trivial — we use a fixed layout)
};
```

With fixed register layout (which copy-and-patch requires anyway), deopt metadata is tiny — usually just the bytecode PC.

### Deopt cost

A deopt is "expensive" at maybe 1µs, but the assumption is that deopts are rare. If a function deopts on every other invocation, recompile with the failing-guard's case included as a polymorphic path, or fall back permanently to interpreter.

### Deopt threshold

Per-function deopt counter. If a function deopts more than N times (say 50), give up: mark `jit_code = null`, bump hotness threshold by 10x, let it interpret. Some functions are inherently polymorphic and JIT'ing them is a loss.

---

## 7. Calling Convention

Native frames need to coexist with interpreted frames on the same stack.

### Frame layout

Every frame, native or interpreted, follows the same layout from the GC's perspective:

```
stack[ ... ]
   .... values
   register 0
   register 1
   ...
   register N
```

For native code, RBP points to register 0. The native code accesses registers as `[RBP + 8*N]`. Calls into native code set up RBP and jump.

### Crossing the boundary

- **Interpreter → JIT:** when `CALL` finds `jit_code != null`, jump to the JIT'd code's entry point. Args are already on the stack at the right offsets.
- **JIT → interpreter:** at function return, JIT'd code restores the previous frame and `ret`s. Return values are already in place. The interpreter's dispatch loop resumes at the post-`CALL` instruction.
- **JIT → JIT:** direct native-to-native call. This is the fast path that gives us most of our speedup.

### GC integration

JIT'd code emits write barriers exactly like the interpreter does (a single inline check + branch to a barrier handler stencil). The GC walks the same stack the same way — there are no native registers holding GC-rooted values across opcodes; everything is in the register-based VM stack.

This is one of the genuine wins of register-based bytecode: GC integration is uniform across interpreter and JIT.

---

## 8. Memory Management for Compiled Code

Native code lives in a separate allocator from GC-managed memory.

```zig
pub const CodeArena = struct {
    pages:   std.ArrayList([]align(page_size) u8),
    cursor:  [*]u8,
    end:     [*]u8,
    perms:   enum { rw, rx },
};
```

Allocation: bump-allocate from the current writable page. When code is "finalized" (all patching done), `mprotect` the page to read+execute. Subsequent writes go to a fresh page.

### Reclamation

When a `JitCode` is invalidated and unreachable, its memory should be reclaimed. But native code can't be "freed" piecewise from a bump arena. Options:

- **Per-function pages:** each compiled function gets its own page. Reclamation is `munmap`. Wastes memory for small functions.
- **Reference counting + compaction:** track per-function bytes; when a page's references drop to zero, free it.
- **No reclamation:** accept that compiled code accumulates. Set a global cap (e.g., 64MB); when reached, flush *all* code and require recompilation. Reference Lua programs rarely produce enough distinct hot functions to hit this in practice.

For Phase 5, **start with no reclamation**. If long-running workloads expose it as a problem, add reference counting. This decision is reversible.

### W^X discipline

Modern systems require memory to be writable XOR executable, never both. The pattern is:

1. `mprotect(page, PROT_READ | PROT_WRITE)` while patching.
2. After patching: `mprotect(page, PROT_READ | PROT_EXEC)`.
3. Flush instruction cache on ARM64 (`__builtin___clear_cache`); x86-64 is coherent automatically.

Some platforms (iOS, hardened Linux configurations) require `MAP_JIT` or per-thread W-or-X switching (`pthread_jit_write_protect_np` on macOS). Document the platform support matrix; we target x86-64 Linux + macOS + ARM64 macOS as Phase 5 baseline.

---

## 9. Stencil Generation at Build Time

The non-obvious part. How do you turn Zig functions into stencils?

### Approach 1: Compile to object code, parse with a script

A Zig build step compiles `stencil_source.zig` with `-O ReleaseSmall -fno-stack-check -fno-pie` (and other flags to keep the output simple). A small extractor tool:

1. Reads the resulting `.o` file.
2. For each function symbol, extracts its bytes.
3. Identifies hole locations by examining relocations.
4. Emits the `StencilDef` constant.

The extractor is ~500 lines of Zig that links to a minimal ELF/Mach-O parser.

### Approach 2: GHC-style continuation-passing stencils

A more sophisticated technique used by some research compilers: write each stencil as a *continuation* that takes the next stencil as a tail-call argument. The compiler's tail-call elimination then produces stencils that flow into each other naturally.

This is more elegant but requires aggressive tail-call optimization (which Zig has via `@call(.always_tail, ...)`, but combining it with the stencil-extraction toolchain is more delicate).

### Approach 3: GCC's `-fno-asynchronous-unwind-tables` + asm goto

The `mimalloc` JIT and PostgreSQL's JIT use this approach. Less portable to non-GCC compilers; not suitable for our Zig + LLVM stack.

**Recommendation:** Start with Approach 1. It's the most explicit and the easiest to debug when stencil extraction goes wrong (which it will).

### Compile-time vs runtime tradeoff

Stencils are generated *once* at build time and shipped as data in the VM binary. There's no runtime compilation infrastructure beyond the patcher. This is the inverse of LLVM-based JITs, where most of the JIT logic lives in the runtime.

The tradeoff: regenerating stencils requires a rebuild. New opcodes can't be added without recompiling the VM. For our workflow this is fine; we're not building a JIT plugin system.

---

## 10. Testing

### Differential against Phase 4

Every Phase 5 change must produce identical output to Phase 4 on the entire corpus. The JIT is correctness-preserving by definition.

### Determinism stress

Run the corpus 100x with the JIT enabled. Output must be identical across runs. Same for the interpreter. Any nondeterminism is a bug — usually uninitialized register slots in stencils.

### Deopt stress

A test mode that *forces deopt on every guard*. The system should still produce correct output (just slowly). Validates that deopt paths are wired correctly throughout.

### Compilation pressure

Synthetic load: 10⁵ different small functions, each called enough times to JIT, all distinct shapes. Verifies the compilation budget is enforced and that memory pressure from compiled code is bounded.

### Cross-platform validation

Stencils must work identically on x86-64 Linux, x86-64 macOS, ARM64 macOS, and ARM64 Linux. Each platform gets its own CI configuration; the corpus must pass on all of them.

### Microbenchmark wins

For each of the 30 benchmarks from Phase 4, measure JIT vs. interpreter. Target geometric-mean speedup ≥ 2x; stretch ≥ 5x on numeric microbenchmarks.

### Long-running stability

Phase 4's 24-hour soak, with JIT enabled. No leaks, no slowdown, no deopt cascades.

---

## 11. Sketch of Option A — Tracing JIT (for completeness)

If a future phase decides to build a real tracing JIT on top of the copy-and-patch infrastructure, here's the architecture in brief.

### Trace recording

A trace is a linear sequence of operations recorded from a single execution path. Recording starts at a hot loop header (or function entry, or any backwards-branch site that's been hit > N times). The recorder runs alongside the interpreter, building an IR node for each executed bytecode. Recording stops on:

- **Loop closure:** trace returns to its start.
- **Trace too long:** > 500 IR nodes, abort.
- **Unsupported opcode:** abort.
- **Trace abort guards:** failed assumption (not a guard inserted into the trace, but the recorder itself bailed).

### Linear SSA IR

Roughly 80 IR opcodes covering: loads, stores, arithmetic (specialized by type), comparisons, allocation, type guards, calls, GC barriers, control. LuaJIT's IR is the reference — well-documented, public.

### Optimizations on traces

Linear traces enable optimizations that are easy on traces but hard on general control flow:

- **Common subexpression elimination** — trivial on linear IR.
- **Loop-invariant code motion** — hoist out of the loop body to the loop header.
- **Allocation sinking** — boxed values that don't escape the trace become unboxed.
- **Type specialization** — once a guard establishes a type, downstream operations specialize.
- **Snapshot / deopt-info management** — every guard carries the metadata to reconstruct interpreter state.

### Backend

Hand-rolled assembler (DynASM-equivalent) with linear-scan register allocation. ~4–6 months for one architecture.

Or: lean on Cranelift or LLVM. Cuts assembler time but adds a heavyweight runtime dependency. Cranelift is the realistic middle ground (Rust ecosystem, designed for JITs, BSD-licensed).

### Side traces

When a guard fails, the failing path itself becomes a candidate for tracing. Side traces attach to the parent trace at the guard, forming a "trace tree." Tree management is its own subsystem; LuaJIT's `lj_trace.c` is the reference.

### Realistic effort

- Trace recorder + IR: 4 months
- Optimizer: 6 months
- Backend (one architecture): 6 months
- Side traces + trace trees: 3 months
- Tuning, benchmarking, fixing: 6 months
- **Total: 24+ months for a small team.**

This is why Option B is the recommendation. Option A is what you do if the project finds a maintainer who wants to spend 2+ years on it specifically.

---

## 12. Exit Criteria

For Option B (the recommended path):

- [ ] Stencil generation pipeline works end-to-end on x86-64 Linux
- [ ] All Phase 0–4 opcodes have stencils (including superinstructions from Phase 4)
- [ ] Hotness counter triggers JIT compilation correctly; budgets are enforced
- [ ] Type guards using IC feedback emit correct fast-path code
- [ ] Deopt path tested under "force-deopt-every-guard" mode; output matches interpreter
- [ ] Cross-platform: x86-64 Linux, x86-64 macOS, ARM64 macOS — same corpus passes on each
- [ ] W^X discipline enforced; instruction cache flushed on ARM64
- [ ] GC: write barriers emitted by JIT; mark phase walks JIT'd frames identically to interpreted
- [ ] Microbenchmark suite: geomean ≥ 2x speedup vs. Phase 4 interpreter
- [ ] Soak test (24h with JIT enabled) passes; no leaks; bounded code-arena memory
- [ ] No regression on Phase 0–4 corpora; differential tests green
- [ ] `zig fmt` clean, `zig build test` green

---

## 13. Deliverables

| Path                              | Contents                                              |
|-----------------------------------|-------------------------------------------------------|
| `src/jit/stencil_source.zig`      | Per-opcode stencil sources                            |
| `tools/stencil_extract.zig`       | Build-time extraction tool                            |
| `src/jit/stencils.zig`            | Auto-generated; stencil constants                     |
| `src/jit/jit.zig`                 | Compilation driver, hotness, budgets                  |
| `src/jit/codegen.zig`             | Stencil patching, code arena allocation               |
| `src/jit/deopt.zig`               | Deopt entry points, state reconstruction              |
| `src/jit/code_arena.zig`          | W^X memory management for native code                 |
| `src/jit/feedback.zig`            | Reading Phase 4 IC and shape feedback into the JIT    |
| `src/jit/abi_x64.zig`             | x86-64 calling convention specifics                   |
| `src/jit/abi_arm64.zig`           | ARM64 calling convention specifics                    |
| `src/jit/cache_flush.zig`         | Platform i-cache flush wrappers                       |
| `tests/jit/`                      | Differential, deopt-stress, cross-platform tests      |
| `bench/jit/`                      | JIT-vs-interpreter benchmark suite                    |
| `docs/phase-5-postmortem.md`      | Decisions, surprises, future possibilities            |
| `docs/jit-platform-support.md`    | Platform matrix and known limitations                 |

---

## 14. Estimated Effort

For Option B:

| Component                              | Estimate    |
|----------------------------------------|-------------|
| Stencil source design + first 10 opcodes | 4 weeks   |
| Stencil extraction tool                | 3 weeks     |
| Code arena (W^X, page management)      | 2 weeks     |
| Compilation driver + hotness           | 2 weeks    |
| Patcher + hole resolution              | 3 weeks     |
| Type-specialized stencils (using IC)   | 4 weeks     |
| Deopt path                             | 4 weeks     |
| All remaining opcodes + superinstrs    | 6 weeks     |
| ARM64 port (second architecture)       | 6 weeks     |
| Performance work                       | 4–6 weeks   |
| Testing harness, deopt stress, soak    | 3 weeks     |
| Documentation                          | 2 weeks     |

**Total: 9–12 months for a single dedicated engineer.**

Option A: 24+ months. Option C: 3–4 months but no native code.

---

## 15. Open Questions

1. **Which stencil-extraction approach.** Approach 1 (object-file parsing) is recommended; verify it handles position-independent code correctly on macOS, where Mach-O relocations differ from ELF.

2. **Stencil register convention.** Fixed register layout means we lose register-allocation gains. Worth it for the simplicity. But: which registers do we pin? Conventional choice: RBP = register base, R12–R15 reserved for VM/state. Verify this leaves enough scratch for complex stencils.

3. **Variadic operations.** Some opcodes (`CALL` with N args, `CONCAT` over N values, `RETURN` with N values) are variadic in N. Stencils need to be parameterized. Two options: a fixed family (stencils for N=0,1,2,3,4, fall-through to a slow-path for larger), or a runtime loop inside one stencil. Probably ship the fixed family for small N + slow path for large.

4. **Can we JIT FFI calls?** A static-FFI fast-path call site is a perfect JIT target — known signature, known address. Worth doing? Probably yes, for ~3 weeks of additional work; gives a real speedup on FFI-heavy code (which is typical in real Lua programs).

5. **OSR (on-stack replacement) timing.** Documented as deferred. If a real workload reveals one giant function that never tier-ups, revisit. Could be 2–3 weeks of follow-up work.

6. **Self-modifying code policy.** Patching deopt branches in-place when a deopt cause is determined to be permanent ("permanent miss patches") is a known optimization. Skip in Phase 5; risks W^X complexity. Defer.

7. **Concurrent compilation thread.** Compiling on the mutator thread costs latency on the JIT trigger. A dedicated compiler thread compiles in the background while interpreted code keeps running. Adds threading complexity to a previously single-threaded VM. Defer; revisit only if the latency is observably bad in real workloads.

8. **Profile-guided stencil specialization.** Stencils could themselves be generated multiple times — one per common (shape, key, type) trio observed in profiling. The "stencils" become a small library of pre-specialized variants. Smarter than the basic copy-and-patch but much closer to a real codegen system. Defer.

9. **Code-arena memory cap.** I suggested 64MB as a starting cap. Validate against real workloads; some game-scripting use cases may hit this with a realistic distribution of distinct hot functions.

10. **Documentation honesty.** When the README says "JIT-compiled," users will compare to LuaJIT and be disappointed by the relative perf. Worth documenting clearly: "we ship a copy-and-patch JIT delivering 2–4x speedup over the interpreter; for higher peaks, use LuaJIT." Set expectations explicitly.

---

## 16. What Comes After Phase 5?

If Phase 5 ships and the project continues, plausible follow-ups (none committed to here):

- **Phase 6a:** Trace recorder bolted on top of the copy-and-patch JIT. The stencils become the building blocks of larger compiled traces. This is a credible path from Option B to something approaching Option A, incrementally.
- **Phase 6b:** AOT compilation of bytecode to native via the same stencil infrastructure. Useful for embedded targets where startup time matters.
- **Phase 6c:** WebAssembly target. Stencils generated for Wasm; the same JIT runs in a browser.
- **Phase 6d:** Multi-threaded mutator. Pervasive change; requires GC redesign. Probably the right time to consider it is when there's a concrete user with a real workload that demands it.
- **Phase 6e:** Generational GC, if Phase 4's measurement said no but workloads have changed.

These are open-ended; whether any are worth doing depends on what the project is for and who's using it by then.

---

## A closing note

Phases 0 through 4 build a complete, correct, fast interpreter for a Lua/LuaJIT-shaped language in Zig. That's a real artifact, and it's deliverable.

Phase 5 — at the Option B scope — adds a real native-code JIT that nearly doubles or quadruples performance, also deliverable.

Phase 5 — at the Option A scope — is a research project that may take 3+ years and may end up close to LuaJIT's interpreter mode but not its JIT. Whether that's worth doing is a question of who's funding it and why. For a research vehicle exploring "what does a Lua-shaped language look like in Zig," Option B is the right finish line.

If the project ships through Phase 5 Option B, it's already a respectable Lua-shaped language with a real native-code tier and unique-to-the-project advantages (static-FFI fast path, comptime opcode infrastructure, two-layer embedding API). That's a complete and shippable product.

Anything beyond is a future you decide on after seeing how Phase 5 lands.
