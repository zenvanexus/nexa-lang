# Phase 1.5 — Garbage Collector Spec

**Project:** Lua/LuaJIT-shaped scripting language in Zig
**Spec scope:** GC design that ships in Phase 1, plus the forward-looking abstractions Phase 4 will plug into.
**Relationship to Phase 1:** Companion document. The Phase 1 spec covers GC at the level needed to understand how it interacts with the VM; this document covers it at the level needed to *implement* it.

---

## 1. Goals & Non-Goals

### Goals

- A correct stop-the-world tri-color mark-sweep collector for Phase 1.
- Object model and write-barrier API that Phase 4's incremental and (optional) generational variants can swap into without VM source changes.
- Predictable memory overhead: ≤ 16 bytes per object header on 64-bit, ≤ 1.5x peak live-set as collection threshold ceiling.
- Pluggable backing allocator. The GC owns *what gets traced*; the user owns *where memory comes from*.
- Stress modes that collect on every allocation and at every safe point, used by the test corpus to surface barrier and root bugs.
- Clean separation between the scanning engine and the per-type marking logic — adding a new GC-managed type should be ~30 lines.

### Non-Goals (Phase 1)

- Incremental collection. Stop-the-world only. Tri-color and barriers are present but barriers are no-ops.
- Generational collection.
- Finalizers (`__gc`). Hooks present, semantics deferred to Phase 4 (they interact non-trivially with incremental marking).
- Weak tables. Same reasoning as finalizers.
- Concurrent / parallel GC. Single-threaded mutator, single-threaded collector.
- `__gc` resurrection semantics.
- Compaction or moving collection. Mark-sweep is non-moving; any future move to a moving collector is out of scope here.

---

## 2. Object Model

### GcHeader

Every collectable object embeds `GcHeader` as its first field. This guarantees:

- A `*GcHeader` can be obtained from any object pointer via `@ptrCast` (since it's at offset zero).
- An object pointer can be recovered from a `*GcHeader` plus its `type_tag` via the same cast.

```zig
pub const Color = enum(u2) {
    white_a, // current-white-A
    white_b, // current-white-B
    gray,
    black,
};

pub const GcType = enum(u4) {
    string,
    table,
    function,    // Lua closure
    cfunction,   // host C closure
    userdata,
    proto,
    upvalue_cell,
    thread,      // Phase 2
};

pub const GcHeader = struct {
    next:     ?*GcHeader,    // intrusive: VM.gc.allgc list
    color:    Color,
    type_tag: GcType,
    flags:    u2,            // type-specific small bits (e.g. table.has_finalizer)
    // tail padding to 8 bytes — verified at compile time
};

comptime {
    if (@sizeOf(GcHeader) != 16) @compileError("GcHeader must be 16 bytes");
    if (@offsetOf(GcHeader, "next") != 0) @compileError("next must be first");
}
```

### Why two whites

In stop-the-world mode, one white would suffice — every object is white at the start of the cycle, gets marked, anything still white at sweep is dead. But Phase 4 wants incremental marking, which means the mutator can allocate objects *during* a marking cycle. Such objects must not be swept (they may be referenced by mutator code we haven't paused to inspect), but they also haven't been traced yet.

Solution: two whites, A and B. The "current" white flips at the start of each cycle.

- Pre-cycle: all live objects are color X (say `white_a`).
- Cycle start: flip current white to `white_b`. Any allocations during the cycle are colored `white_b` and are considered live by definition.
- Marking: walk roots, mark reachable objects gray then black. Untouched objects remain `white_a`.
- Sweep: free `white_a` objects; flip `white_b` objects to `white_a` (becoming next cycle's "stale white").

In Phase 1's stop-the-world implementation, no allocations happen during marking, so this reduces to one-white in practice. The two-white machinery is kept so Phase 4 doesn't need to change the color scheme.

---

## 3. Per-Type Layouts

All types embed `GcHeader` as their first field, so the GC can walk objects via `*GcHeader` and dispatch on `type_tag`.

```zig
pub const String = struct {
    gc:        GcHeader,
    hash:      u32,
    len:       u32,
    is_short:  bool,           // short strings are interned
    bytes:     [*]const u8,    // immutable, allocated as flexible-array-style trailing bytes
};

pub const Table = struct {
    gc:        GcHeader,
    array:     [*]Value,
    array_len: u32,
    array_cap: u32,
    hash:      HashPart,
    metatable: ?*Table,
    mm_flags:  u8,             // metamethod-cache flags (see Phase 1 §13)
    gclist:    ?*GcHeader,     // intrusive: VM.gc.gray queue when color == .gray
};

pub const Function = struct {
    gc:        GcHeader,
    proto:     *const Proto,   // Proto is GC-managed
    upvalues:  []*UpvalueCell, // each cell is GC-managed
    gclist:    ?*GcHeader,
};

pub const Userdata = struct {
    gc:        GcHeader,
    metatable: ?*Table,
    type_id:   u32,            // host-defined
    payload_size: u32,
    // payload bytes follow inline
};

pub const Proto = struct {
    gc:        GcHeader,
    code:      []const Instruction,
    constants: []const Value,        // may contain *String
    upval_descs: []const UpvalueDesc,
    nested:    []const *Proto,        // each is GC-managed
    source:    *String,
    // ... see Phase 1 §8
    gclist:    ?*GcHeader,
};

pub const UpvalueCell = struct {
    gc:        GcHeader,
    state: union(enum) {
        open:   *Value,    // pointer into a live frame's register slot
        closed: Value,     // value copied here when frame popped
    },
    // gclist not needed: upvalue cells reference a single Value, traced inline
};
```

### Which types need `gclist`

Only types whose marking work *itself* allocates work units (i.e. whose tracing has fanout > 0 and is worth queuing rather than recursing) need a `gclist` field for the gray queue.

| Type           | Has gclist? | Why                                                 |
|----------------|:-----------:|------------------------------------------------------|
| `String`       | no          | No outgoing references                               |
| `Userdata`     | no          | Single metatable ref, traced inline                  |
| `UpvalueCell`  | no          | Single `Value`, traced inline                        |
| `Table`        | **yes**     | Many entries; needs deferred work                    |
| `Function`     | **yes**     | Upvalues + proto                                     |
| `Proto`        | **yes**     | Constants + nested protos                            |

Strings, userdata, and upvalue cells go directly from white to black during marking (no gray state). The gray queue contains only objects with `gclist`.

---

## 4. Allocator Integration

The GC wraps the user-supplied `std.mem.Allocator`. The user retains control over *where* memory comes from; the GC controls *what is traced and when collection runs*.

```zig
pub const Gc = struct {
    backing:       std.mem.Allocator,
    vm:            *VM,                  // back-reference for root scanning

    allgc:         ?*GcHeader,           // intrusive list of all collectables
    gray_head:     ?*GcHeader,           // gray queue
    sweep_cursor:  ?**GcHeader,          // for incremental sweep (Phase 4)

    current_white: Color,                // .white_a or .white_b
    state:         enum { idle, marking, sweeping },

    bytes_in_use:  usize,
    threshold:     usize,
    pause:         u16,                  // gcpause analog, default 200 (%)
    step_mul:      u16,                  // gcstepmul analog, Phase 4

    pub fn create(self: *Gc, comptime T: type) !*T {
        if (self.bytes_in_use > self.threshold) try self.collect();

        const ptr = try self.backing.create(T);
        ptr.gc = .{
            .next = self.allgc,
            .color = self.current_white,
            .type_tag = comptime gcTypeOf(T),
            .flags = 0,
        };
        self.allgc = &ptr.gc;
        self.bytes_in_use += @sizeOf(T);
        return ptr;
    }

    pub fn createWithTrailing(self: *Gc, comptime T: type, trailing_bytes: usize) !*T {
        // For String, Userdata — header struct + inline payload.
        const total = @sizeOf(T) + trailing_bytes;
        if (self.bytes_in_use + total > self.threshold) try self.collect();
        const raw = try self.backing.alignedAlloc(u8, @alignOf(T), total);
        const ptr: *T = @ptrCast(@alignCast(raw.ptr));
        ptr.gc = .{ ... };
        self.allgc = &ptr.gc;
        self.bytes_in_use += total;
        return ptr;
    }
};
```

### Why not use Zig's `Allocator` interface for collection

The GC needs typed knowledge of every allocation to thread it onto the `allgc` list and to size it for `bytes_in_use`. A type-erased `Allocator` would lose that. The right layering is: the *GC* exposes typed `create*` methods to the VM; the GC *consumes* a backing `Allocator` for raw memory. Users wanting to control memory pass a custom backing allocator (arena, pool, mmap-backed) and the GC machinery is unchanged.

---

## 5. Roots

The complete root set for Phase 1:

| Source                    | Iteration                                                                  |
|---------------------------|----------------------------------------------------------------------------|
| VM stack                  | `stack[0 .. stack_top]` — every `Value` slot                              |
| Open upvalue list         | Each `UpvalueCell` in `vm.open_upvals`                                     |
| Call stack                | Each `CallInfo.func` (a `*Function`)                                       |
| Globals table             | `vm.globals` (a `*Table`)                                                  |
| String interner table     | All `*String` in the intern map are roots until weak-string-interner lands |
| Active error frames       | `error_value` field of each `ErrorFrame`                                   |
| Currently-raising error   | `vm.error_value` if set                                                    |
| Registry                  | Lua-level registry (singleton table for C-API references — Phase 3)        |

Coroutines (Phase 2) extend this by walking each thread's stack, call stack, and open upvalues.

---

## 6. Mark Phase

Tri-color, iterative (no recursion).

```
function mark_phase(gc):
    # Step 1: flip current white
    gc.current_white = if gc.current_white == .white_a then .white_b else .white_a
    other_white = if gc.current_white == .white_a then .white_b else .white_a

    # Step 2: mark roots
    for each root R in roots(gc.vm):
        mark(gc, R)

    # Step 3: drain gray queue
    while gc.gray_head is not null:
        obj = pop_gray(gc)
        scan(gc, obj)
        obj.color = .black

function mark(gc, obj):
    if obj.color != other_white: return  # already live or in progress
    if obj has no outgoing refs:
        obj.color = .black                # skip gray state
    else:
        obj.color = .gray
        push_gray(gc, obj)

function scan(gc, obj):
    switch obj.type_tag:
        .table:
            mark all array entries
            mark all hash entries (key and value)
            mark metatable (if any)
        .function:
            mark proto
            mark each upvalue cell
        .proto:
            mark each constant value
            mark source string
            mark each nested proto
        .upvalue_cell:
            mark its current value (open: deref the stack slot; closed: the inline Value)
        # strings, userdata: scanned inline by mark(), never reach scan()
```

### Marking a `Value`

```zig
fn markValue(gc: *Gc, v: Value) void {
    const ptr = v.asGcPtr() orelse return;  // numbers, nil, bool: nothing to do
    markObject(gc, ptr);
}

fn markObject(gc: *Gc, hdr: *GcHeader) void {
    const otherWhite: Color = if (gc.current_white == .white_a) .white_b else .white_a;
    if (hdr.color != otherWhite) return;

    switch (hdr.type_tag) {
        .string, .userdata, .upvalue_cell, .cfunction => {
            // No fanout (or trivial fanout handled inline) — go straight to black
            hdr.color = .black;
            // Userdata still has metatable — handle inline:
            if (hdr.type_tag == .userdata) {
                const ud: *Userdata = @fieldParentPtr("gc", hdr);
                if (ud.metatable) |mt| markObject(gc, &mt.gc);
            }
            // UpvalueCell similarly — mark the cell's contained value
            if (hdr.type_tag == .upvalue_cell) {
                const cell: *UpvalueCell = @fieldParentPtr("gc", hdr);
                switch (cell.state) {
                    .open => |slot| markValue(gc, slot.*),
                    .closed => |val| markValue(gc, val),
                }
            }
        },
        .table, .function, .proto, .thread => {
            hdr.color = .gray;
            pushGray(gc, hdr);
        },
    }
}
```

### Bounded work

The gray queue drains in a single pass under stop-the-world. Under Phase 4 incremental, `scan` becomes step-bounded by counting bytes traced and yielding back to the mutator at quota.

---

## 7. Sweep Phase

Walk the intrusive `allgc` list. Free anything still in `other_white`; flip surviving whites for the next cycle.

```zig
fn sweep(gc: *Gc) void {
    const other_white: Color = if (gc.current_white == .white_a) .white_b else .white_a;

    var pp: *?*GcHeader = &gc.allgc;
    while (pp.*) |hdr| {
        if (hdr.color == other_white) {
            // dead
            pp.* = hdr.next;
            freeObject(gc, hdr);
        } else {
            // live; reset color to current_white for next cycle
            hdr.color = gc.current_white;
            pp = &hdr.next;
        }
    }

    gc.threshold = gc.bytes_in_use * gc.pause / 100;
    gc.state = .idle;
}

fn freeObject(gc: *Gc, hdr: *GcHeader) void {
    const size = sizeOfObject(hdr);    // type-dispatched
    switch (hdr.type_tag) {
        .string => {
            const s: *String = @fieldParentPtr("gc", hdr);
            stringInternerRemove(gc.vm, s);
            gc.backing.free(@as([*]u8, @ptrCast(s))[0..size]);
        },
        .table => {
            const t: *Table = @fieldParentPtr("gc", hdr);
            gc.backing.free(t.array[0..t.array_cap]);
            t.hash.deinit(gc.backing);
            gc.backing.destroy(t);
        },
        // ... per-type teardown
    }
    gc.bytes_in_use -= size;
}
```

### String interner removal

Strings are referenced from the global interner. When a string dies, we must remove its entry. The interner is **not** a strong reference (otherwise no string would ever die). Implementation: the interner is a hash table of `*String` keyed by content; sweep removes dead strings before freeing them.

This is a place where Lua uses a subtle "weak ref-like" treatment without using its general weak-table machinery. Document it explicitly because it's easy to mess up.

---

## 8. Write Barriers

Phase 1 implements barriers as no-ops but exposes the API the VM uses. Phase 4 swaps in real barrier logic.

### The invariant

Tri-color invariant: **a black object never points to a white object.**

If a mutator stores a white reference into a black object, the white object can be missed by the marking pass.

Two strategies preserve the invariant:

- **Forward barrier** (mark the white target gray when stored): `barrier(black_owner, white_target) → mark(target) gray`.
- **Backward barrier** (revert the black owner to gray): `barrier(black_owner, white_target) → owner.color = gray; push_gray(owner)`.

Lua uses *forward barrier on most types*, *backward barrier on tables* (because tables get many writes; reverting once is cheaper than forward-marking every entry).

### API

```zig
/// Called before a write that could install a reference into `owner`.
/// `value` is the new reference being stored.
pub inline fn barrier(gc: *Gc, owner: *anyopaque, value: Value) void {
    if (comptime gc_mode == .stop_the_world) return;
    barrierSlow(gc, owner, value);
}

fn barrierSlow(gc: *Gc, owner_raw: *anyopaque, value: Value) void {
    const owner: *GcHeader = @ptrCast(@alignCast(owner_raw));
    if (owner.color != .black) return;
    const target = value.asGcPtr() orelse return;
    if (target.color != otherWhite(gc)) return;

    // Forward by default; backward for tables.
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

### Where barriers are emitted

Every store of a `Value` into a heap object:

| Site                           | Owner type    | Comment                                  |
|--------------------------------|---------------|------------------------------------------|
| `TSETV` / `TSETS` / `TSETB`    | `*Table`      | Store into table                         |
| `USET`                         | `*UpvalueCell`| Store into closed upvalue                |
| `setmetatable`                 | `*Table`      | Metatable replacement                    |
| Userdata user-value setter     | `*Userdata`   | Phase 3+                                 |

**Stack writes do not need barriers.** The stack is scanned as roots every cycle; it's never colored.

---

## 9. Trigger Heuristic

```
threshold = bytes_in_use_at_end_of_last_collection * pause / 100
```

Default `pause = 200` means collect when memory has doubled since the last collection. Lua's default is also 200.

Tunables exposed (Phase 4 will add `step_mul`):

| Knob          | Default | Effect                                                      |
|---------------|---------|-------------------------------------------------------------|
| `pause`       | 200     | Higher → less frequent collection, higher peak memory       |
| `step_mul`    | 200     | Phase 4: incremental work-per-allocation multiplier         |
| `min_threshold` | 64 KB | Don't collect below this; avoids thrashing on small heaps   |

---

## 10. Stress Modes (test-only)

Two compile-time flags trigger pathological collection schedules. Both must pass the entire snapshot corpus.

```zig
const GcStressMode = enum { off, every_alloc, every_safepoint };
```

- **`every_alloc`**: every `gc.create*` call runs a full collection before allocating. Surfaces missed roots and barrier bugs (anything that should be live but isn't reachable from a root will be freed and use-after-freed).
- **`every_safepoint`**: full collection at every backwards branch and at every `CALL` / `RETURN`. Surfaces issues where a register is treated as dead by the GC scanner but is still in use by an in-flight expression.

These modes are gated by `comptime` so they cost nothing in release builds.

---

## 11. Debugging Support

A small inspector module — invaluable when the inevitable bugs land:

```zig
pub fn dumpHeap(gc: *Gc, writer: anytype) !void {
    var hdr = gc.allgc;
    var counts = std.EnumArray(GcType, usize).initFill(0);
    while (hdr) |h| : (hdr = h.next) {
        counts.set(h.type_tag, counts.get(h.type_tag) + 1);
    }
    inline for (std.meta.fields(GcType)) |f| {
        try writer.print("{s}: {d}\n", .{ f.name, counts.get(@enumFromInt(f.value)) });
    }
}

pub fn assertReachable(gc: *Gc, target: *GcHeader) bool {
    // For tests: returns true iff `target` is reachable from roots.
    // Simulates a marking pass without sweeping.
}

pub fn findReferrers(gc: *Gc, target: *GcHeader) []const *GcHeader {
    // For debugging leaks: who keeps `target` alive?
}
```

The Lua reference implementation has nothing like this and debugging GC issues there is *miserable*. Building it in costs ~100 lines and pays off immediately.

---

## 12. Performance Characteristics (Phase 1 target)

Phase 1 is not optimized — but we should know what we're shipping.

| Metric                       | Phase 1 target                              |
|------------------------------|---------------------------------------------|
| Per-object overhead          | 16 bytes (`GcHeader`)                       |
| Mark throughput              | ≥ 200 MB/s of live heap (single thread)     |
| Sweep throughput             | ≥ 500 MB/s                                  |
| Pause time (1 MB live)       | ≤ 5 ms                                      |
| Pause time (10 MB live)      | ≤ 50 ms                                     |
| Memory overhead at threshold | ≤ 2x peak live set                          |

The 10 MB / 50 ms pause is a meaningful constraint: anything bigger and the case for incremental GC (Phase 4) becomes urgent rather than nice-to-have.

---

## 13. Forward-Looking: Incremental GC (Phase 4 sketch)

Three changes from stop-the-world; everything else carries over.

### Change 1: Stepped marking

`scan` becomes:

```zig
fn markStep(gc: *Gc, work_budget: usize) void {
    var work: usize = 0;
    while (gc.gray_head) |hdr| {
        if (work >= work_budget) return;
        popGray(gc);
        work += scanObject(gc, hdr);
        hdr.color = .black;
    }
    // Gray queue drained — transition to atomic phase
    atomicPhase(gc);
    gc.state = .sweeping;
}
```

Work is measured in bytes traced; the budget is computed from `bytes_allocated_since_last_step * step_mul / 100`.

### Change 2: Stepped sweep

```zig
fn sweepStep(gc: *Gc, count_budget: usize) void {
    var swept: usize = 0;
    while (swept < count_budget) {
        const slot = gc.sweep_cursor.?.*;
        const hdr = slot orelse {
            gc.state = .idle;
            return;
        };
        if (hdr.color == otherWhite(gc)) {
            gc.sweep_cursor.?.* = hdr.next;
            freeObject(gc, hdr);
        } else {
            hdr.color = gc.current_white;
            gc.sweep_cursor = &hdr.next;
        }
        swept += 1;
    }
}
```

### Change 3: Atomic phase

Even incremental GC needs a stop-the-world atomic phase between marking and sweeping to:

- Re-scan the VM stack (mutator may have written there during marking)
- Process weak tables (Phase 4)
- Mark finalizables (Phase 4)
- Flip current white

This pause is short — proportional to root size, not heap size. With a few MB of stack it's sub-millisecond.

### Barriers stop being no-ops

`barrierSlow` runs its real logic. Hot-path stores incur an extra branch.

---

## 14. Forward-Looking: Generational GC (optional, Phase 4+)

Lua 5.4 added a generational mode as an *alternative* to incremental, sharing the same tri-color machinery. Worth considering whether to ship it.

### Two generations

- **Young**: recently allocated objects.
- **Old**: survived ≥ 2 minor collections.

### Two cycle types

- **Minor cycle**: collect young only. Fast, frequent.
- **Major cycle**: collect everything. Slow, infrequent. Same as incremental cycle.

### The interesting part: barrier-back

To avoid scanning the entire old generation during minor cycles, every old→young pointer must be findable. Solution: when an old object stores a young reference, the *old object becomes a remembered-set entry* (concretely: it's added to a list of "potentially-pointing-into-young" objects). The barrier becomes:

```
on store(old_owner, young_value):
    add old_owner to remembered_set
    old_owner.color = touched
```

Minor cycle scans: roots ∪ remembered_set.

### Decision deferred

Generational vs incremental-only is a real fork. Lua ships both as runtime-selectable modes. We can do the same — both layered on the same tri-color core — but committing to *whether* we ship generational is a Phase 4 decision, made with measurements from Phase 1 in hand.

---

## 15. Forward-Looking: Weak Tables (Phase 4)

Lua's `__mode` field on a metatable triggers weak semantics:

| `__mode` value | Behavior                                          |
|----------------|---------------------------------------------------|
| `"k"`          | Weak keys: entries with unreachable keys removed  |
| `"v"`          | Weak values: entries with unreachable values removed |
| `"kv"`         | Weak both                                         |

Implementation sketch:

- During marking, weak tables are *collected* into a list rather than fully traced.
- In the atomic phase (or end-of-mark in stop-the-world), walk the weak-table list. For each entry, check whether the weakly-held side is still white. If so, remove the entry.
- Weak-keyed tables also need attention to ephemerons (key-reachability implies value-reachability) — Lua handles these in a fixpoint loop in the atomic phase.

This is one of the trickier parts of a correct Lua GC. Phase 4 work.

---

## 16. Forward-Looking: Finalizers (Phase 4)

`__gc` lets Lua code run when an object becomes unreachable. The semantics are surprisingly subtle:

1. When `setmetatable(t, {__gc = fn})` runs, `t` is marked as "has finalizer."
2. When marking finds a finalizable object unreachable, it's *resurrected*: re-marked live, moved to a `to_be_finalized` queue.
3. After collection, finalizers run (mutator code, can allocate, can resurrect via side effects).
4. Object is reconsidered on the next cycle. If still unreachable, it's freed (without re-running the finalizer).

Resurrection violates the simple "mark phase determines what's live" property. The tri-color machinery handles it cleanly because resurrection is just "mark gray and push." But the *ordering* — finalizables are determined after main marking — needs care.

Phase 1 tracks which objects have finalizers (a `Table.has_finalizer` flag bit) but does not invoke them. Phase 4 wires up the queue and the post-collection hook.

---

## 17. Threading Model (Phase 1: single)

Phase 1 assumes single-threaded mutator + single-threaded collector. The barrier API is `inline`-able branchless no-op in stop-the-world; in Phase 4 incremental, it's a single-threaded forward/backward barrier.

### Future: multi-threaded mutator

Out of scope for the foreseeable future, but the design avoids painting into a corner:

- The intrusive `allgc` list assumes single-writer. Multi-mutator would need per-thread allocation lists merged at collection.
- The gray queue is single-writer.
- Barriers would need to become atomic, not just inline branches.

These changes are pervasive; if multi-mutator ever becomes a goal, the GC is one of the modules with the most rework.

---

## 18. Testing Strategy

GC bugs are *the* class of bug where you don't know there's a problem until much later. Aggressive testing is mandatory.

### Unit tests

- Allocation threading: allocate N objects, walk `allgc`, count = N.
- Color transitions: white → gray → black, no skips except for fanout-zero types.
- Barrier emission: every VM store path emits a barrier (verify by stub-instrumenting `barrierSlow` and grepping bytecode tests).
- Sweep correctness: alloc N, drop refs to half, collect, walk `allgc`, count = N/2.
- String interner: dead strings removed from interner during sweep; lookup of a dead string after collection returns a fresh `*String`.
- Two-white flipping: after K cycles, every alive object has the current white color.

### Stress tests (compile-time gated)

- `every_alloc` mode runs the entire snapshot corpus.
- `every_safepoint` mode runs the entire snapshot corpus.
- A torture test: tight loop allocating tables in a deeply nested closure, with `__index` metamethods, while occasionally raising and catching errors. Should run for 10⁶ iterations with bounded memory.

### Differential tests

- Same input, run with stress modes on and off. Output must match exactly.
- Run with backing allocator = `GeneralPurposeAllocator{ .safety = true }`; no leaks, no use-after-free.

### Pause-time benchmarks

Synthetic heaps at 1 MB, 10 MB, 100 MB live; measure mark, sweep, total pause. Track regression over time.

---

## 19. Exit Criteria (for the Phase 1 GC slice)

- [ ] All collectable types implement `GcHeader` correctly; `comptime` assertions hold
- [ ] Stop-the-world cycle completes correctly on the snapshot corpus
- [ ] String interner removes dead strings during sweep; no use-after-free under stress
- [ ] Barrier API in place (no-op implementation); every VM store path is traced and emits barrier calls
- [ ] `every_alloc` and `every_safepoint` stress modes both pass full corpus
- [ ] No leaks under `GeneralPurposeAllocator{ .safety = true }` after running corpus
- [ ] Performance targets in §12 met
- [ ] Heap inspector (`dumpHeap`, `assertReachable`, `findReferrers`) implemented and used by ≥ 5 unit tests
- [ ] Postmortem documents which barriers were hardest to place correctly — input to Phase 4 incremental work

---

## 20. Open Questions / Decisions to Revisit

1. **String interner as weak set.** Phase 1 treats interner entries as strong roots and removes during sweep. Phase 4's weak-table implementation may unify this with general weak refs. Worth checking the unification doesn't pessimize the common case.
2. **Userdata payload alignment.** Inline trailing payloads must respect alignment of the host's data type. Currently the `createWithTrailing` API handles this via `alignedAlloc`; verify that all userdata creation paths go through it.
3. **`gclist` as a separate field vs reuse.** Lua reuses one field for both gray-queue chaining and weak-table chaining; we currently use a single `gclist` per type. If weak tables introduce a second list, may need to either add a second field or implement Lua's reuse trick.
4. **Sweep cursor invalidation.** Phase 4 incremental sweep keeps a cursor into `allgc`. If the mutator allocates during sweep, the new object goes onto the head of `allgc`, *before* the cursor — and is colored `current_white`, which the sweep won't free. Verify this property holds (it should, by construction, but worth a unit test).
5. **`pcall` interaction.** When `pcall` catches an error, the error value (and anything it references) becomes a root via `error_value`. If the error is later released, those references should die naturally. Verify with a test that holds an error value briefly and then drops it.
6. **GcType enum stability for bytecode dump.** If we ship bytecode dumps that contain `Value`s referencing GC types, the `GcType` enum becomes part of the on-disk format. Either guarantee enum value stability or version the dump format.
7. **Cost of `@fieldParentPtr` everywhere.** It's compile-time-resolved and zero-cost in optimized builds, but verify that debug builds don't suffer dramatically. If so, consider inlining hints.
8. **Backing allocator failure.** If `backing.create()` returns OutOfMemory mid-cycle, the cycle should complete cleanly (no half-state). Verify by a stress test with a deliberately-failing allocator at varying allocation counts.
