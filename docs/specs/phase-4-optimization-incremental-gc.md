# Phase 4 — Optimization, Incremental GC, and Polish

**Project:** Lua/LuaJIT-shaped scripting language in Zig
**Phase goal:** Take the language from "correct but plain interpreter" to "fast plain interpreter" — close the gap to LuaJIT's interpreter-only mode (LuaJIT with `-joff`), which historically runs ~3–5x faster than reference Lua. The major levers are inline caches, table shape tracking (hidden classes), superinstructions, number specialization, incremental GC, and weak tables. JIT compilation remains Phase 5.

**Predecessors:** All prior phases. The optimization opcodes plug into the Phase 1 bytecode infrastructure; the incremental GC plugs into the Phase 1.5 abstraction the spec set up explicitly for this; weak tables plug into the existing GC mark phase; debug hooks plug into the Phase 1 dispatch loop.

---

## 1. Goals & Non-Goals

### Goals

- **Inline caches** for table reads (`TGETS`, `TGETV`) and writes (`TSETS`, `TSETV`). Monomorphic-fast, polymorphic-OK, megamorphic-fallback.
- **Table shape tracking** (hidden classes): tables that behave like records get V8/SpiderMonkey-style shape transitions, enabling IC fast paths in tight inner loops.
- **Superinstructions**: compile-time-fused common opcode pairs, generated via `comptime` from a profile-derived table.
- **Number specialization**: an internal fast path for arithmetic when both operands are integer-valued doubles. Externally, the language stays single-`f64` — this is purely a hot-path optimization, not a language change.
- **Incremental GC**: implement what the Phase 1.5 spec was designed to slot into. Stepped mark, stepped sweep, atomic phase, real write barriers.
- **Weak tables**: `__mode = "k" | "v" | "kv"` with correct ephemeron semantics.
- **Optional generational GC**: ship as a runtime-selectable mode alongside incremental, matching Lua 5.4's API. Decide based on Phase 1 performance data; default to incremental.
- **Debug hooks**: `debug.sethook` wired into the dispatch loop. Off costs nothing; on costs ~10–20%.
- **`bit.*` library**: LuaJIT's BitOp library, ABI-compatible.
- **Performance target**: within 30% of LuaJIT's interpreter-only mode (`-joff`) on the standard suite. (LuaJIT with JIT is Phase 5's concern.)

### Non-Goals

- Trace-recording JIT, method JIT, native code generation. Phase 5.
- Profile-guided optimization (PGO) of the interpreter binary itself — that's a build-system concern, not a language design one.
- Parallel mutator. Single-threaded mutator + collector, as before.
- `__close` / to-be-closed variables (Lua 5.4 feature). We're targeting LuaJIT-shape; not in scope.
- Bitwise operators as native syntax (Lua 5.3+). Use `bit.*` library, matching LuaJIT.
- UTF-8 library (Lua 5.3+). Skip.
- Compaction or moving GC. Phase 1.5 committed to non-moving; we honor that.
- Removing the dynamic-FFI path or making any backwards-incompatible API change.

---

## 2. Performance Methodology

Before any optimization work, establish baseline measurement.

### Benchmark suite

Curate ~30 benchmarks covering:

- **Microbenchmarks**: tight loops, arithmetic, table reads/writes, string concatenation, function calls.
- **Algorithmic**: recursive Fibonacci, naive primality, Mandelbrot rasterizer, n-queens, JSON parser written in Lua.
- **Real workloads**: minified Lua programs from the wild (Neovim config, Roblox-style script, Redis Lua scripts).

Each benchmark has a stable input and a verifier that checks the output, so a "fast but wrong" optimization is rejected.

### Measurement protocol

- Run on a quiesced machine (no concurrent build, screensaver off, fixed CPU governor).
- N=20 iterations, drop outliers, report median + IQR.
- Three baselines: us at start of Phase 4, **LuaJIT with `-joff`** (interpreter-only), reference Lua 5.1. Each benchmark run on all three.
- The target is "≤ 1.3x slower than LuaJIT `-joff`" averaged geometric-mean across the suite.

### Regression CI

Every PR that touches dispatch, opcodes, or GC runs the benchmark suite. Geometric-mean regression > 5% blocks merge unless explicitly accepted.

This infrastructure is **the most important thing in Phase 4**. Without it, you're optimizing in the dark. Build it before the first IC line is written.

---

## 3. Inline Caches

The single highest-leverage optimization.

### The pattern

Hot Lua code does the same table lookup repeatedly:

```lua
for i = 1, 1000000 do
    sum = sum + obj.x       -- TGETS at this site reads `x` 1M times
end
```

Without ICs: every `TGETS` does a full hash lookup — hash the key, walk the chain, return the value. Maybe 30–50 cycles in the cache-hot case.

With ICs: the call site remembers the *shape* of `obj` and the *offset* of `x` within that shape. Next call, if shape matches, single load — ~3 cycles.

### Cache cell layout

Each IC site has an inline cache cell, stored alongside the bytecode:

```zig
pub const ICell = packed struct(u64) {
    shape_id:   u32,    // 0 = uninitialized
    offset:     u16,    // slot offset within the shape
    state:      enum(u4) { uninit, mono, poly, mega },
    _padding:   u12,
};
```

Storage: a parallel array `cache_cells: []ICell` with one entry per IC-eligible instruction. Indexed by instruction position.

### Per-instruction handling

For `TGETS R[A], R[B], K[C]` (read field whose name is constant):

```zig
fn op_tgets(vm: *VM, ip: [*]const Instruction, regs: [*]Value) callconv(.C) void {
    const inst = ip[0];
    const cell_idx = computeCellIdx(vm, ip);
    const cell = &vm.cache_cells[cell_idx];

    const t = regs[inst.bc.abc.b].asTable() orelse return slowPath(...);

    switch (cell.state) {
        .mono => {
            if (t.shape_id == cell.shape_id) {
                regs[inst.a] = t.slots[cell.offset];
                return tailNext();
            }
            // Shape miss → transition to polymorphic
            transitionToPoly(cell, t, ...);
            return slowPath(...);
        },
        .poly => {
            // Linear scan of small set of (shape, offset) pairs (max 4)
            // Fall through to slowPath if no hit
        },
        .mega => return slowPath(...),
        .uninit => {
            // First execution → record
            const offset = lookupSlow(t, key);
            cell.* = .{ .shape_id = t.shape_id, .offset = offset, .state = .mono };
            regs[inst.a] = t.slots[offset];
            return tailNext();
        },
    }
}
```

### Polymorphic ICs

A small linear-scan table of (shape_id, offset) pairs, capped at ~4 entries. Beyond that, fall back to megamorphic, which is just the slow path. Empirically, 4 is enough for almost all real code; benchmarking will tell us if we should bump it.

### Cache invalidation

Two events invalidate caches:

- **Shape change** of a tracked table (key added or removed). Resolved by giving the table a new shape; existing IC cells now "miss" naturally and will re-record.
- **Metatable change**. If the metatable changes, all caches keyed on the old shape must be invalidated. Resolved by making metatable-changes bump a global generation counter that ICs check (cheap addition to the cache hit path).

### Eligible opcodes

| Opcode    | Cache contents                                   |
|-----------|--------------------------------------------------|
| `TGETS`   | `(shape_id, offset)` for string-keyed read       |
| `TSETS`   | `(shape_id, offset)` for string-keyed write      |
| `TGETB`   | `(shape_id, array_index)` for small-int read     |
| `GGET`    | `(globals_shape, offset)` for global read        |
| `GSET`    | `(globals_shape, offset)` for global write       |
| Method calls (`TGETS` + `CALL`) | extended IC: shape + offset + class hint |

`TGETV` (general-key reads) gets only a partial benefit; if the key is consistently a constant string, the parser can lower it to `TGETS`. Otherwise IC the key-class.

---

## 4. Hidden Classes (Table Shapes)

ICs need *shapes* to key on. Without shapes, every table is its own world and ICs can't share state across sites.

### What a shape is

A shape is an *immutable* description of a table's structure: the ordered sequence of keys it currently has, the offsets each key resolves to, and a pointer to the parent shape (the shape this one transitioned from).

```zig
pub const Shape = struct {
    parent:       ?*const Shape,
    transition:   ?Transition,    // edge that produced this shape
    fields:       []const Field,  // sorted by offset
    field_index:  std.HashMap([]const u8, u16, ...),  // for fast lookup
    children:     ChildMap,       // shape transitions out of here
    metatable:    ?*Table,        // shapes split on metatable identity
    id:           u32,            // monotonic, used as IC key
    flags:        packed struct {
        is_dictionary_mode: bool,  // gave up on shape tracking
        _pad: u7,
    },
};

pub const Transition = struct {
    key:    []const u8,
    offset: u16,
};
```

### Transitions

When a table at shape S has a new key `k` set:

1. Look up `S.children["k"]`. If present, transition to that shape — no allocation.
2. Otherwise, create a new shape `S'` with the additional field, link `S → S'` via the children map, return `S'`.

This builds a *transition tree*: tables that are constructed in the same key order share shapes for free. Two tables built as `{x=1, y=2, z=3}` end up at the same shape regardless of when they were created.

### Layout strategy

Two flavors of table:

- **Shape-tracked tables**: have `shape_id != 0`, store fields in a flat slot array indexed by shape offset. Fast path in ICs. The Phase 1 array+hash representation becomes a special case of dictionary mode.
- **Dictionary-mode tables**: tables whose access pattern doesn't match a record (lots of integer keys, deletions, key-set churn). Fall back to the Phase 1 hybrid layout. No shape tracking; ICs see them as megamorphic and use slow path.

### When does a table go to dictionary mode

- Key deletion (transitioning a shape "backward" is awkward; bail to dictionary).
- Too many shape transitions on one table (>16 distinct shapes seen) — table is being used like a map, not a record.
- Mass operations (`table.insert` / `table.remove` over an array) keep array semantics through a separate fast path that's not shape-tracked but is still fast.

### Cost of shape tracking

The risk: tables that *should* be in dictionary mode but get tracked anyway suffer mild memory overhead and unnecessary shape allocation. The dictionary-mode fallback ensures correctness; the heuristics determine performance.

Reference: V8's "inline caches and hidden classes" papers, SpiderMonkey's "shape" implementation. Lua-specific consideration: integer keys (`t[1] = ...`) should go through the array part as in Phase 1, not contribute to shape transitions.

---

## 5. Superinstructions

Common opcode pairs fused into single opcodes. Reduces dispatch overhead (one tail-call instead of two) and enables inlined logic.

### Methodology

1. Profile the Phase 1/2/3 corpus, count adjacent-opcode-pair frequencies.
2. Top ~20 pairs become superinstruction candidates.
3. Generate fused handlers via `comptime` from the same op_table that drives ordinary opcodes.

### Likely candidates (corpus-dependent)

| Fused opcode      | Components               | Pattern                            |
|-------------------|--------------------------|------------------------------------|
| `LOADKADD`        | `LOADK; ADD`             | `local x = a + 5`                  |
| `MOVCALL`         | `MOV; CALL`              | parameter shuffling before call    |
| `TGETS_CALL`      | `TGETS; CALL`            | method calls (`obj:m()`)           |
| `GGET_CALL`       | `GGET; CALL`             | global function calls              |
| `LOADN_RETURN`    | `LOADN; RETURN`          | `return 0`-style                   |
| `MOVRETURN`       | `MOV; RETURN`            | `return x`                         |
| `ADD_MOV`         | `ADD; MOV`               | accumulator updates                |
| `JMP_TFORLOOP`    | `JMP; TFORLOOP`          | generic-for backedge               |

### Generation

Add a `superinstructions: []const SuperOp` table at compile time:

```zig
const super_ops = [_]SuperOp{
    .{ .name = "LOADK_ADD", .components = &.{ .loadk, .add }, .layout = ... },
    .{ .name = "TGETS_CALL", .components = &.{ .tgets, .call }, .layout = ... },
    // ...
};
```

`comptime` generates the fused handler bodies from the component handlers, eliminating the dispatch between them. The compiler emits the fused opcode instead of the pair when it sees the pattern at code-gen time.

### Fusion in the compiler

A peephole pass on emitted bytecode: walk the instruction stream, recognize fusable pairs, replace them with the fused opcode. Has to handle jump retargeting carefully (a fused pair must be atomic — a jump must not land between the two components).

This is a small pass (~200 lines) but easy to break subtly. Aggressive testing required.

---

## 6. Number Specialization

LuaJIT's interpreter aggressively specializes arithmetic for the case where both operands are integer-valued doubles. The result is roughly 2x speedup on integer-heavy code without changing language semantics.

### Mechanism

For `ADD A, B, C`:

```zig
fn op_add(vm: *VM, ip: [*]const Instruction, regs: [*]Value) callconv(.C) void {
    const inst = ip[0];
    const b = regs[inst.bc.abc.b];
    const c = regs[inst.bc.abc.c];

    // Fast integer path
    if (b.isIntegerValuedDouble() and c.isIntegerValuedDouble()) {
        const bi = b.asIntegerSafe() orelse return slowDouble(...);
        const ci = c.asIntegerSafe() orelse return slowDouble(...);
        // Native i64 add with overflow check
        const sum = @addWithOverflow(bi, ci);
        if (sum.@"1" == 0) {
            regs[inst.a] = Value.fromInteger(sum.@"0");
            return tailNext();
        }
        // Overflow → fall through to double path
    }

    // Double path (unchanged)
    const bd = b.asDouble() orelse return slowMeta(...);
    const cd = c.asDouble() orelse return slowMeta(...);
    regs[inst.a] = Value.fromDouble(bd + cd);
    return tailNext();
}
```

### `Value.isIntegerValuedDouble()`

A double is integer-valued if it equals its `floor`. This is a single comparison after a `floor` op — a few cycles. Cheaper than reading a tag bit and accepting the false negatives on non-integer doubles.

Alternative: stash an "is integer" bit in a side table per-register, updated on every store. More complex, marginally faster. Defer.

### Representation honesty

Externally the language remains f64-only. Integer-valued doubles round-trip exactly through the integer fast path. Non-integer doubles take the slow path. No ABI break, no value-type addition.

---

## 7. Incremental GC

Phase 1.5 §13 was the design sketch. Phase 4 implements it. Most of the work is converting the existing stop-the-world routines into stepped versions and turning the no-op write barriers into real ones.

### Step driver

A new "GC step" function called from a few places:

```zig
pub fn step(gc: *Gc) void {
    if (gc.state == .idle) {
        if (gc.bytes_in_use < gc.threshold) return;
        startCycle(gc);
    }
    const work_budget = computeWorkBudget(gc);
    switch (gc.state) {
        .marking  => markStep(gc, work_budget),
        .sweeping => sweepStep(gc, work_budget),
        .idle     => unreachable,
    }
}
```

Called from:

- Allocation paths (`Gc.create*`) — drives the cycle in proportion to allocation rate.
- Backwards-branch opcodes (`JMP` with negative offset, `FORLOOP`, `TFORLOOP`) — drives the cycle on tight loops that don't allocate.
- Top of every `CALL` and `RETURN`.

Each call site does a small amount of GC work, paid out of a budget proportional to bytes allocated since the last step.

### Atomic phase

Between marking and sweeping, the collector holds the mutator briefly to:

- Re-scan all thread stacks (mutator may have stored references during marking).
- Walk the weak-table list (§8).
- Identify and queue finalizable objects (resurrect them).
- Flip the current-white color.
- Transition `state` to `.sweeping`.

Pause time is proportional to root size, not heap size — typically sub-millisecond.

### Real barriers

`barrierSlow` from Phase 1.5 §8 stops being a no-op:

```zig
fn barrierSlow(gc: *Gc, owner_raw: *anyopaque, value: Value) void {
    const owner: *GcHeader = @ptrCast(@alignCast(owner_raw));
    if (owner.color != .black) return;
    const target = value.asGcPtr() orelse return;
    if (target.color != otherWhite(gc)) return;

    switch (owner.type_tag) {
        .table => {
            owner.color = .gray;
            pushGray(gc, owner);
        },
        else => {
            markObject(gc, target);
        },
    }
}
```

The cost is one inline branch per heap store on the hot path. Empirically, this is in the noise for non-mutation-heavy code and ~5% on table-write-heavy code.

### Sweep cursor invariant

Phase 1.5 §20 question 4: when the mutator allocates during sweep, the new object is prepended to `allgc` at a position before the sweep cursor, with `current_white` color. The sweep walks forward and never sees it — correct. Verify with a unit test that allocates aggressively during sweep and observes no premature frees.

### Step tuning

Two knobs:

- `pause` (default 200): collect-when-memory-doubled threshold.
- `step_mul` (default 200): how much GC work per byte allocated. Higher → shorter cycles, more overhead per allocation.

Both runtime-tunable via `collectgarbage("setpause", n)` / `collectgarbage("setstepmul", n)`. Defaults match Lua's.

---

## 8. Weak Tables

A weak table is a table where keys, values, or both are *weakly* referenced — they don't keep the referenced objects alive. When the referent is collected, the entry vanishes.

### `__mode` field

```lua
local t = setmetatable({}, { __mode = "k" })   -- weak keys
```

Values: `"k"` (weak keys), `"v"` (weak values), `"kv"` (both).

### Mark-phase treatment

When marking encounters a weak table:

- For weak-value tables: mark only the keys; collect the table into a `weak_v_list`.
- For weak-key tables: mark only the values; collect into `weak_k_list`.
- For weak-both tables: mark neither; collect into `weak_kv_list`.

### Atomic-phase cleanup

After all strong marking has finished:

```
for table t in weak_v_list:
    for entry (k, v) in t:
        if v is collectable and v.color == otherWhite:
            remove entry

for table t in weak_kv_list:
    for entry (k, v) in t:
        if (k is collectable and k.color == otherWhite) or
           (v is collectable and v.color == otherWhite):
            remove entry

# Ephemeron loop for weak-key tables
repeat:
    progress = false
    for table t in weak_k_list:
        for entry (k, v) in t:
            if k is reachable and v is white:
                mark(v)
                progress = true
until not progress

for table t in weak_k_list:
    for entry (k, v) in t:
        if k is collectable and k.color == otherWhite:
            remove entry
```

The ephemeron loop is the subtle part: in a weak-keyed table, **the value is reachable iff the key is reachable**. But the key's reachability may itself depend on the value (e.g. circular structures). The fixpoint loop converges because each iteration marks more values; when no progress is made, the remaining whites are genuinely unreachable.

### Implementation note

Reuse the `gclist` field to chain weak tables (the `mark` phase puts them on the appropriate list instead of the gray queue). Phase 1.5 §20 question 3 flagged this as needing care; resolved by sharing the field with the gray queue but only one is in use at a time per object lifetime stage.

---

## 9. Generational GC (Optional)

Lua 5.4 ships a generational mode as an alternative to incremental, on the same tri-color machinery. Worth shipping if benchmarks justify it.

### Decision criteria

After incremental GC is working, measure:

- Median allocation lifetime on the corpus.
- 10⁹-allocation throughput, incremental vs. stop-the-world.
- Pause-time distribution on a 100MB heap.

If the heap shows the classical generational hypothesis (>80% of objects die young), generational beats incremental by a meaningful margin (>30% throughput improvement) and we ship it. Otherwise, skip — the implementation cost is real and a marginal win isn't worth it.

### Implementation if shipped

The Phase 1.5 §14 sketch is the design. Two cycle types (minor and major), barrier-back for old→young pointers, remembered-set tracking. ~3 weeks of additional work beyond incremental.

Runtime-selectable via `collectgarbage("generational" | "incremental")`.

---

## 10. Debug Hooks

`debug.sethook(hook, mask, count)` calls `hook` when matching events occur:

- Mask `"c"`: every function call.
- Mask `"r"`: every function return.
- Mask `"l"`: every line change (from one source line to a different one).
- `count`: every N instructions.

### Dispatch-loop integration

A flag `vm.hook_mask: u8` set by `sethook`. When zero, the hot path checks one byte and continues — negligible cost.

When non-zero, the relevant opcodes (`CALL`, `RETURN`, backwards branches) consult the mask and fire the hook callback. Line tracking requires the dispatch loop to compare each instruction's line (from `Proto.line_info`) against the previous.

The `count` hook adds a per-thread instruction counter, decremented every dispatch and checked against zero. ~3 cycles when the hook is off; ~10 cycles when on.

Total cost when hooks are off: < 1% on dispatch (one byte read + branch). When on: 10–20% depending on which masks are active.

### Reentry safety

Hooks call back into Lua. The hook callback runs on the same thread, with the same stack. It must not yield (would yield from inside a host call — disallowed in Phase 2). Errors in the hook propagate normally.

---

## 11. The `bit` Library (BitOp-Compatible)

LuaJIT's BitOp library is the de facto standard for bitwise operations on Lua 5.1-shape implementations. Implement it as a stdlib module.

| Function           | Semantics                                          |
|--------------------|----------------------------------------------------|
| `bit.tobit(x)`     | Normalize to int32 (modulo 2^32, signed)           |
| `bit.tohex(x, n)`  | Hex string with optional padding length            |
| `bit.bnot(x)`      | Bitwise NOT                                        |
| `bit.band(x, y, ...)` | Bitwise AND (variadic)                          |
| `bit.bor(x, y, ...)`  | Bitwise OR                                      |
| `bit.bxor(x, y, ...)` | Bitwise XOR                                     |
| `bit.lshift(x, n)`    | Left shift (logical)                            |
| `bit.rshift(x, n)`    | Right shift (logical)                           |
| `bit.arshift(x, n)`   | Right shift (arithmetic)                        |
| `bit.rol(x, n)`       | Rotate left                                     |
| `bit.ror(x, n)`       | Rotate right                                    |
| `bit.bswap(x)`        | Byte-swap (32-bit)                              |
| `bit.tobit`           | Normalization to int32                          |

All operations work on int32 with two's-complement wrap. Lua doubles are converted via `tobit` semantics (modulo 2^32, then sign-extended).

Implementation is mechanical (~200 lines). Speed isn't critical because hot bitwise code shouldn't go through the library — `bit.band(a, b)` is a function call. We can add fused opcodes (`BAND`, `BOR`, `BXOR`, `BSHL`, `BSHR`) as native bytecode ops in the same way as arithmetic, with the library just calling them — gives BitOp users the same fast path as `+` and `-`.

---

## 12. Testing Strategy

### Differential against Phase 3

The most important: every Phase 4 change must produce identical output to Phase 3 on the entire corpus. Optimizations are correctness-preserving by definition; any divergence is a bug.

### Microbenchmark regression CI

Per §2, every PR runs the bench suite. Geomean regression > 5% blocks merge.

### IC stress

A generated test corpus of 1000+ programs that hit IC fast paths, IC misses, polymorphic transitions, megamorphic fallbacks, metatable-replacement invalidations. Validate that observable behavior matches Phase 3.

### Shape-transition fuzzer

Random tables built by random key sequences, compared structurally to a reference (Phase 1 hybrid table). Verify that for any access pattern, the shape-tracked table and reference table return equal values.

### GC stress with barriers

Phase 1.5's `every_alloc` and `every_safepoint` modes already exercise this. Add `every_step` mode that steps the GC once per allocation (instead of fully collecting), which exercises the incremental-marking and incremental-sweeping codepaths intensively.

### Weak-table semantic suite

Port Lua's weak-table tests. Add ephemeron-specific tests (cycles, transitively-weak structures).

### Hook coverage

Every mask combination, every callback type, with and without `count`. Verify hooks fire at the right places, never twice for one event, never miss an event.

### Long-running stability

A 24-hour soak: a synthetic Lua program that allocates, mutates, finalizes, calls hooks, runs FFI, uses coroutines, and weak tables. Memory should be stable; no leaks; no slowdown over time.

---

## 13. Exit Criteria

- [ ] Benchmark suite established with ≥ 30 benchmarks; baseline measured against LuaJIT `-joff` and Lua 5.1
- [ ] Geometric mean: ≤ 1.3x slower than LuaJIT `-joff` across the suite
- [ ] Inline caches operational on `TGETS`, `TSETS`, `GGET`, `GSET`, with mono/poly/mega state machine
- [ ] Hidden classes (table shapes) implemented; transition trees observable via debug hooks
- [ ] Dictionary-mode fallback works: tables that defeat shape tracking still produce correct results
- [ ] Superinstructions: ≥ 10 fused opcodes generated by the comptime infrastructure; emitted by the bytecode compiler peephole pass
- [ ] Number specialization: integer-valued double arithmetic takes the fast path; overflow correctly falls back to double
- [ ] Incremental GC: passes the entire Phase 1.5 / Phase 2 / Phase 3 test corpus under `every_step` stress mode
- [ ] Pause-time benchmark: 100MB live heap shows max single-pause < 5ms (vs. ~500ms under stop-the-world)
- [ ] Weak tables: pass the Lua weak-table reference tests, including ephemeron cases
- [ ] (If shipped) Generational GC: runtime-selectable; passes the same test corpus
- [ ] Debug hooks: `debug.sethook` works for all three masks plus count; off-cost < 1% on benchmarks
- [ ] `bit.*` library: BitOp-compatible; native fused opcodes for the common operations
- [ ] No regression on Phase 0–3 corpora; differential tests green
- [ ] No leaks under `GeneralPurposeAllocator{ .safety = true }`; soak test passes
- [ ] `zig fmt` clean, `zig build test` green

---

## 14. Deliverables

| Path                              | Contents                                              |
|-----------------------------------|-------------------------------------------------------|
| `src/ic.zig`                      | Inline cache cell types, dispatch, invalidation       |
| `src/shape.zig`                   | Hidden class implementation, transition tree          |
| `src/super.zig`                   | Superinstruction definitions and fusion peephole pass |
| `src/numspec.zig`                 | Number specialization helpers                         |
| `src/gc_inc.zig`                  | Incremental GC implementation                         |
| `src/gc_gen.zig`                  | Generational GC (if shipped)                          |
| `src/weak.zig`                    | Weak-table marking and atomic-phase cleanup           |
| `src/hooks.zig`                   | Debug hook integration                                |
| `src/lib_bit.zig`                 | `bit.*` library                                       |
| `src/handlers.zig` (modified)     | Updated handlers using ICs and number specialization  |
| `src/compile.zig` (modified)      | Bytecode compiler with peephole superinstruction pass |
| `bench/`                          | Benchmark suite with verifier and reporting           |
| `bench/runner.zig`                | Bench harness, statistical analysis, CI integration   |
| `tests/ic/`                       | IC behavior and invalidation tests                    |
| `tests/shapes/`                   | Shape transition fuzzer                               |
| `tests/gc_inc/`                   | Incremental GC stress                                 |
| `tests/weak/`                     | Weak table tests including ephemerons                 |
| `tests/hooks/`                    | Debug hook tests                                      |
| `tests/soak/`                     | 24-hour stability harness                             |
| `docs/perf-methodology.md`        | Bench protocol, baselines, regression process         |
| `docs/phase-4-postmortem.md`      | Decisions, surprises, inputs to Phase 5               |

---

## 15. Estimated Effort

5–7 months focused. Comparable to Phase 1 in size.

| Component                              | Estimate    |
|----------------------------------------|-------------|
| Benchmark suite + regression CI        | 2 weeks     |
| Inline caches                          | 4 weeks     |
| Hidden classes (shape tracking)        | 5–6 weeks   |
| Superinstructions                      | 2 weeks     |
| Number specialization                  | 1.5 weeks   |
| Incremental GC                         | 4–5 weeks   |
| Weak tables (incl. ephemerons)         | 2 weeks     |
| Generational GC (if shipped)           | 3 weeks     |
| Debug hooks                            | 2 weeks     |
| `bit.*` library + native opcodes       | 1.5 weeks   |
| Performance work to hit target         | 3–4 weeks   |
| Soak test + stability work             | 1.5 weeks   |
| Documentation + postmortem             | 1.5 weeks   |

The "performance work to hit target" line is the buffer for the inevitable case where ICs alone don't get us to 1.3x LuaJIT `-joff`. Could expand or shrink based on what the bench suite says.

---

## 16. Inputs to Phase 5 (JIT)

Phase 5 (optional trace-recording JIT) inherits:

- The IC infrastructure is ~70% of what a JIT trace recorder needs. Trace recording is "speculate that the IC fast path will hold for the entire trace, compile native code accordingly, deopt if the speculation fails."
- The shape system: trace specialization keys on shape transitions. A trace is valid iff the shape sequence the recording observed continues to hold.
- The number specialization fast path: trace IR can use the integer specialization as a type guard, generating int64 native code for integer-valued double arithmetic.
- The superinstruction fusion: in a JIT, every superinstruction-eligible pattern is also a trace-recording optimization. Reuse the patterns.
- The benchmark suite: Phase 5 needs the same benchmark suite for measuring JIT speedups against the interpreter.
- The incremental GC: works fine alongside a JIT, as long as JITted code emits write barriers like the interpreter does. Phase 5 must respect this contract.

---

## 17. Open Questions

1. **Polymorphic IC capacity.** Default to 4 entries. Should it be tunable per call site? Adaptive (start small, grow on miss-storms)? V8 went through several iterations here; we'll start with a fixed cap and revisit if profiling justifies.

2. **Shape ID exhaustion.** 32-bit shape IDs allow 4B distinct shapes. In practice, a long-running program may exhaust this — particularly if every closure creates a new globals shape. Mitigation: shape canonicalization (two structurally-identical shapes share an ID). Defer until measured to be a problem.

3. **Dictionary-mode promotion thresholds.** When does a shape-tracked table give up and become dictionary mode? V8 uses a heuristic of >16 transitions on one object, but the right number for Lua depends on actual usage patterns. Tune empirically against the corpus.

4. **Cache invalidation cost vs. precision.** The "global generation counter" approach to metatable-change invalidation is coarse — every metatable change invalidates *all* method-call ICs. Per-shape generation counters are more precise but cost more per cache hit. Default to global counter; profile.

5. **Superinstruction maintenance burden.** Each fused opcode is a small amount of code, but they accumulate. Document the rule: a superinstruction earns its place only if it appears in the top-20 pair frequency and gives a measurable speedup on the bench suite. Otherwise, remove it.

6. **GC step driver placement.** Calling `gc.step()` from every backwards branch hurts tight loops. Calling only from allocation paths means non-allocating loops don't drive GC at all (a potential pause-time problem if a long-running loop holds many references). The compromise: drive from allocations *and* every Nth backwards branch. Tune N empirically.

7. **Weak-table allocation cost.** A weak table that survives many cycles incurs the per-cycle ephemeron-loop cost. Worth caching the loop's "fixed-point reached after K iterations" value to short-circuit subsequent cycles.

8. **Atomic-phase pause budget.** With many threads and many weak tables, the atomic phase grows. Set a soft target of 2ms; if exceeded, design a way to step parts of the atomic phase too (Lua doesn't, but it's a known limitation).

9. **Generational decision data.** What benchmark threshold for "ship generational"? My proposal: median allocation lifetime < 4 minor cycles AND ≥ 30% throughput win on the corpus. Both must hold.

10. **Hook fairness.** A `count` hook with `count = 1` fires every instruction — the slowest mode. Should we cap the minimum to prevent pathological scripts from disabling all optimizations? Probably not — it's a debug feature, users opt in. But document the cost loudly.

11. **Bench reproducibility.** CI runs on shared infrastructure with noisy neighbors. Median-of-N + IQR helps but doesn't eliminate. Worth running long-baseline runs on dedicated hardware quarterly to validate the CI numbers haven't drifted.
