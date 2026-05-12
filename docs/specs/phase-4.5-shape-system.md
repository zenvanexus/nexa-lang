# Phase 4.5 — Hidden Class / Shape System Spec

**Project:** Lua/LuaJIT-shaped scripting language in Zig
**Spec scope:** Hidden classes (table shape tracking) at implementation depth: data structures, transitions, dictionary-mode demotion, IC integration, metatable interaction, edge cases.
**Relationship to Phase 4:** Companion document. Phase 4 §4 is the high-level pitch and the architectural decision; this doc is what you implement from. Phase 4 §3 (inline caches) and this spec are tightly coupled — neither is useful without the other.

---

## 1. Goals & Non-Goals

### Goals

- A V8/SpiderMonkey-style hidden class system adapted to Lua's semantics.
- Tables that are used as records (constant key set, hot field access) get IC-friendly shape tracking; tables used as dictionaries (churning keys, integer key sets, large key counts) fall back gracefully.
- Pointer-identity shape comparison: two structurally-identical shapes are the same `*const Shape`.
- Field access on a shape-tracked table at a hot site is one shape check + one indexed load — comparable to a Zig struct field access.
- Dictionary-mode demotion is **always available and always correct** as the safety valve. Anything we can't shape-track, we dictionary-mode.
- No language semantic change: shape tracking is observable only through `os.clock()`. Every Lua program runs to the same result.

### Non-Goals

- Promotion from dictionary mode back to shape mode. Once a table is in dictionary mode, it stays.
- Shape-tracked array part. Phase 1's hybrid array+hash layout for integer keys is unchanged. Shapes apply only to the hash part with string keys.
- Cross-table shape inference (e.g., predicting that `t2` is structurally the same as `t1` because the constructor was the same). V8 has hints for this; we don't.
- Shape compaction or GC. Shapes live forever (reference-counted but never freed). The transition tree is bounded for any given program.
- Multi-threaded shape mutation. Single mutator only.

---

## 2. Conceptual Model

A **shape** describes the structure of a table at one point in time: which string keys it has, in what insertion order, and at which slot offsets they live. Shapes are immutable.

A table mutates by **transitioning** from one shape to another:

```
            (empty)
              │ +"x"
              ▼
            {x:0}
            ╱       ╲
   +"y" ╱           ╲ +"z"
       ▼             ▼
   {x:0, y:1}    {x:0, z:1}
```

Two tables built by the same sequence of additions converge on the same shape. The transition tree is a *trie*, not a graph — each shape has exactly one parent (except the empty root).

### Why this enables ICs

A field-read site like `obj.x` compiles to bytecode that reads `obj.slots[shape.field_index["x"]]`. If `obj`'s shape is stable across calls, the IC caches the offset and skips the field-index lookup — direct slot load.

### Why Lua makes this harder than V8

In JavaScript, objects start empty and accumulate fields by assignment. In Lua, tables are typically constructed with a body literal:

```lua
local p = {x=1, y=2}
```

The bytecode for this is `TNEW` followed by `TSETS x; TSETS y` — three operations, each transitioning the shape. The compiler can recognize this pattern and emit a single `TNEW_LITERAL` superinstruction (Phase 4 §5) that transitions through the whole chain at once, allocating the table at the final shape directly.

For dynamically-mutating tables (the rest), the trie-walk happens one transition at a time, and we hope the transitions cache.

---

## 3. Shape Data Structure

```zig
pub const Shape = struct {
    parent:       ?*const Shape,             // null for the root
    transition:   ?Transition,                // edge into this shape; null at root
    fields:       []const FieldInfo,          // sorted by offset; offset == array index
    field_index:  *const FieldIndex,          // open-addressing hash from key → offset
    children:     ChildMap,                   // outgoing transitions
    metatable:    ?*Table,                    // shapes split on metatable identity
    id:           u32,                        // global monotonic; used as IC key
    ref_count:    u32,                        // tables currently at this shape
    flags:        Flags,
};

pub const Transition = struct {
    key:          *String,                    // interned string key
    type_hint:    TypeHint,                   // expected value type; affects IC specialization
};

pub const FieldInfo = struct {
    key:          *String,
    offset:       u16,
    type_hint:    TypeHint,                   // refined as we observe writes
};

pub const TypeHint = enum(u8) {
    any,                                     // no specialization
    nil_,                                    // always nil (rare; usually an unused field)
    boolean,
    number_integer,                          // observed only as integer-valued doubles
    number_double,                           // observed as general doubles
    string_,
    table_,
    function_,
    cdata_,
};

pub const ChildMap = union(enum) {
    none,                                    // no children (yet)
    one: Transition,                         // singleton transition (common case)
    one_with_target: struct { t: Transition, child: *const Shape },
    many: *std.AutoHashMap(TransitionKey, *const Shape),
};

pub const Flags = packed struct(u8) {
    is_dictionary_seed: bool,                // shape created from dictionary-mode promotion (deferred)
    is_locked:          bool,                // metatable forbids field addition
    has_no_metatable:   bool,                // common case fast path
    _pad:               u5,
};
```

### Why a custom `ChildMap`

Most shapes have zero or one child transitions — full hash maps would be wasteful per-shape. The `union(enum)` pattern stays inline-allocated for the common cases (none, one) and only spills to a heap-allocated `HashMap` when a shape has many divergent successors (e.g., the empty root, which everything transitions out of).

### Field index lookup

`field_index` is a small open-addressing hash table mapping `*String → u16 offset`. Key comparison is pointer equality (strings are interned globally), so lookup is hash + pointer compare — typically ≤ 3 cache lines.

For shapes with ≤ 4 fields, we can skip the hash table and linear-scan `fields` instead. Threshold tuned empirically.

### Shape ID

Monotonic 32-bit counter. Used as IC cache key. 4B distinct shapes is enough for any plausible program; if exceeded, we wrap around and invalidate all ICs (graceful degradation).

---

## 4. Field Storage in Tables

A shape-tracked table has a slot array `[]Value` indexed by the shape's field offsets:

```zig
pub const Table = struct {
    gc:           GcHeader,

    // Array part (Phase 1, unchanged) — for integer keys
    array:        [*]Value,
    array_len:    u32,
    array_cap:    u32,

    // Hash/shape part — discriminated on `shape`
    shape:        ?*const Shape,             // null = dictionary mode
    slots:        [*]Value,                   // size = shape.fields.len when shape ≠ null
    slots_cap:    u16,

    // Used in dictionary mode only
    hash:         ?HashPart,

    metatable:    ?*Table,
    mm_flags:     u8,
    gclist:       ?*GcHeader,
};
```

### Slot array sizing

When a table transitions to a shape with N fields, `slots` must be at least N values long. We grow `slots_cap` in powers of two: 4, 8, 16, 32. Resize copies existing values. Most tables stabilize at 4–8 slots; rebudgets are infrequent.

### Discriminating shape vs dictionary

`shape == null` ⇒ dictionary mode. `shape != null` ⇒ shape mode, `slots` valid.

A few opcodes branch on this:

```zig
fn op_tgets_fast(vm: *VM, t: *Table, key: *String) !Value {
    if (t.shape) |s| {
        // Shape-mode fast path
        if (s.field_index.get(key)) |offset| {
            return t.slots[offset];
        }
        // Field not in this shape — try metatable (Phase 1 §13)
        return slowGet(vm, t, key);
    } else {
        // Dictionary mode
        return t.hash.?.get(Value.fromString(key)) orelse slowGet(vm, t, key);
    }
}
```

### Integer keys

The array part is unchanged from Phase 1. When `TGETB` (small-integer-key read) executes, it goes through the array part regardless of shape state. A table can have a populated array part *and* be shape-tracked on its hash part:

```lua
local t = {1, 2, 3, name="thing", count=10}   -- array {1,2,3}, shape {name, count}
```

This is the common case for "list with metadata" patterns. Both fast paths work in parallel.

---

## 5. Shape Transitions

### When a transition happens

A transition is triggered by **adding a new key** to a shape-mode table:

```zig
fn op_tsets(vm: *VM, t: *Table, key: *String, value: Value) !void {
    if (t.shape) |s| {
        // Existing field?
        if (s.field_index.get(key)) |offset| {
            barrier(vm.gc, t, value);
            t.slots[offset] = value;
            return;
        }
        // New field — transition
        const new_shape = try transition(vm, s, key, hintFor(value));
        try ensureSlotCapacity(vm, t, new_shape.fields.len);
        t.slots[new_shape.fields.len - 1] = value;
        t.shape = new_shape;
        s.ref_count -= 1;
        new_shape.ref_count += 1;
        return;
    }
    // Dictionary mode — Phase 1 §10
    return dictSet(vm, t, key, value);
}
```

### The `transition` function

```zig
fn transition(vm: *VM, parent: *const Shape, key: *String, hint: TypeHint) !*const Shape {
    // 1. Check if the transition already exists — return cached child
    if (parent.findChild(key, hint)) |existing| return existing;

    // 2. Allocate a new Shape with one more field
    const new_fields = try vm.gc.backing.alloc(FieldInfo, parent.fields.len + 1);
    @memcpy(new_fields[0..parent.fields.len], parent.fields);
    new_fields[parent.fields.len] = .{
        .key = key,
        .offset = @intCast(parent.fields.len),
        .type_hint = hint,
    };

    const new_index = try buildFieldIndex(vm.shape_arena, new_fields);

    const child = try vm.shape_arena.create(Shape);
    child.* = .{
        .parent = parent,
        .transition = .{ .key = key, .type_hint = hint },
        .fields = new_fields,
        .field_index = new_index,
        .children = .none,
        .metatable = parent.metatable,
        .id = vm.next_shape_id,
        .ref_count = 0,
        .flags = parent.flags,
    };
    vm.next_shape_id += 1;

    // 3. Wire into parent's children
    parent.addChild(.{ .key = key, .type_hint = hint }, child);

    return child;
}
```

### Trie property and convergence

Two tables that follow the same key-addition sequence end up at the same shape via cached transitions:

```lua
local function makePoint(x, y)
    return {x=x, y=y}
end
local p1 = makePoint(1, 2)
local p2 = makePoint(3, 4)
-- p1.shape == p2.shape (pointer equality)
```

Because `{x=x, y=y}` always emits `TNEW; TSETS x; TSETS y`, both tables walk: empty → {x} → {x,y}. The first walk allocates two new shapes; the second walk hits both as cached children.

### Type hint refinement

`type_hint` on a field starts as the type of the first observed write. Subsequent writes with a different type degrade the hint:

- `integer → double` is "compatible-ish"; we record `number_double` and let the IC use the looser hint.
- `integer → string` is incompatible; we degrade to `any`.

A degradation **does not** transition the shape — same field, same offset. Just less specialization for the JIT (Phase 5) to lean on.

---

## 6. Inline Cache Integration

The shape system exists *to feed ICs*. The integration:

### Cache cell content (recap from Phase 4 §3)

```zig
pub const ICell = packed struct(u64) {
    shape_id:   u32,
    offset:     u16,
    state:      enum(u4) { uninit, mono, poly, mega },
    _padding:   u12,
};
```

### Fast path for `TGETS R[A], R[B], K[C]`

```zig
fn op_tgets(vm: *VM, ip: [*]const Instruction, regs: [*]Value) callconv(.C) void {
    const inst = ip[0];
    const cell = &vm.cache_cells[icIndex(ip)];
    const t = regs[inst.bc.abc.b].asTable() orelse return slowMeta(...);

    // Fast path: shape-mode table with cached shape match
    if (t.shape) |s| {
        if (s.id == cell.shape_id) {
            regs[inst.a] = t.slots[cell.offset];
            return tailNext();
        }
    }

    // Cache miss — update or fall back
    return tgetsSlow(vm, ip, regs, cell);
}
```

The fast path is ~5 instructions on x86-64 (load shape pointer, load shape id, compare, branch, indexed load). Comparable to a Zig struct field access.

### Polymorphic transitions

When a cache cell sees a different shape than it has cached:

- **Mono → Poly:** The cell is upgraded; we now keep up to 4 (shape_id, offset) pairs in a small side table indexed by `cell - cache_cells.ptr`. The fast path becomes a linear scan.
- **Poly → Mega:** When the side table fills up, the cell becomes megamorphic. Future hits go to the slow path.

### Cache invalidation

Three invalidation events:

1. **Shape transition on the cached table.** The table's shape changed; the cached `(shape_id, offset)` no longer applies. Detected naturally by the shape ID compare on the next access.
2. **Dictionary-mode demotion.** The table's `shape` field becomes null; the next access misses (shape ID compare still works because `null.?` panics — actually we represent dictionary-mode as `shape_id == 0` so the compare always misses, no panic).
3. **Metatable replacement.** A `setmetatable` call may change which fields exist (because metatables provide `__index`). All ICs whose cached shape had a metatable need rechecking. Resolved by the global generation counter (Phase 4 §3 "Cache invalidation" — every `setmetatable` bumps it; ICs check it on hit). Coarse but cheap.

---

## 7. Metatable Interaction

Each shape carries the table's metatable identity (`Shape.metatable`). Two tables with the same fields but different metatables have *different shapes*.

### Why split on metatable

Field reads on a shape-tracked table fall back to metatable lookup when the field isn't in the shape. The IC needs to know whether to do this lookup — and that depends on the metatable. Two tables with same fields but different metatables behave differently on misses.

### setmetatable as a transition

```lua
local t = {x=1, y=2}
setmetatable(t, mt)
```

The `setmetatable` call causes a shape transition. Conceptually:

- Before: `t.shape = S1` where `S1.metatable = nil`, fields `{x, y}`.
- After: `t.shape = S2` where `S2.metatable = mt`, fields `{x, y}`.

`S2` is a sibling of `S1` in the shape tree (parent is the `{x, y}` shape with no metatable; transition labeled "set metatable to mt"). The implementation: when `setmetatable` runs on a shape-mode table, look up or create the corresponding metatable-bearing shape.

### The "no metatable" fast path

Most tables don't have metatables. Each shape has a `has_no_metatable: bool` flag in its `flags`. The IC fast path checks this — if set, skip the metatable lookup machinery entirely on misses.

### Shared metatables

Many tables share one metatable (e.g., all instances of a "class"):

```lua
local Animal = {}
Animal.__index = Animal
function Animal.new(name)
    return setmetatable({name=name}, Animal)
end
```

Every `Animal.new` call allocates a table, sets its metatable to `Animal`. All those tables share a shape (because they're all built `{name=name}` and then setmetatable'd to the same `mt`). One shape, one IC fast-path entry, full speed.

### Method-call IC extension

Method calls (`obj:method(...)`) compile to `TGETS; CALL`. The `TGETS` IC caches the field offset *if the method is on the table itself*; otherwise the lookup goes through `__index`. Phase 4 §3 mentioned an "extended IC" for method calls. The shape system supports this by:

1. The IC caches both the receiver shape AND a chain hint: "field came from receiver" or "field came from `__index` table at depth N."
2. On hit with the same shape, the IC walks N steps through known stable references (the metatable's `__index`).
3. If `__index` itself is a shape-mode table, its shape is cached too.

Validation: every `setmetatable` on a metatable-target invalidates these chain ICs (via the global counter). In practice, prototype tables don't change their structure frequently after class definition, so this works.

---

## 8. Array Part Interaction

The Phase 1 hybrid table layout (array part + hash part) is unchanged. Shapes apply only to the hash part with string keys.

### Mixed access patterns

```lua
local t = {10, 20, 30, name="thing"}
t[1]       -- TGETB → array part
t.name     -- TGETS → shape part
t[user.id] -- TGETV → must dispatch on key type
```

`TGETB` (constant small-integer key) and `TGETV` (general key) handle the array part. `TGETS` and `TSETS` (string-constant keys) handle the shape part. The dispatch is done at compile time via the bytecode opcode choice.

### `TGETV` and the slow path

When the key type isn't known statically, `TGETV` checks:

1. If integer and in `[1, array_cap]` → array part.
2. If string and shape-mode → shape part.
3. Otherwise → dictionary part (which may be empty in shape mode — fall through to slow path).

Per-call-site IC for `TGETV` is harder because the key type itself varies. Phase 4 §3 noted this: `TGETV` gets a partial benefit. If a `TGETV` site consistently sees one key type, the parser/compiler may rewrite to the more specific opcode (`TGETS`/`TGETB`) — but only when the key is constant. Variable-key `TGETV` is the slow path.

### Integer key with shape-tracked table

What if a user writes `t[1] = "a"` on a shape-mode table where `1` is *not* in the array range and *would not* be in any reasonable shape? Two options:

- **Demote to dictionary.** A non-integer-array, non-string key forces dictionary mode. Conservative but simple.
- **Allow integer keys in shape part.** Requires shapes to track non-string keys. More memory, more complexity. Marginal benefit.

We pick demote-to-dictionary. The rule: any non-string-key write triggers dictionary-mode demotion. Empirically, code that mixes integer-table-as-record patterns is rare and shouldn't drag down the common case.

---

## 9. Dictionary Mode

The fallback for tables that don't behave like records.

### When a table goes to dictionary mode

| Trigger                                              | Reasoning                                         |
|------------------------------------------------------|---------------------------------------------------|
| Field deletion (`t.x = nil` where x exists)          | Shape transitions are forward-only               |
| Non-string key write                                 | Shapes only handle string keys                    |
| > 16 distinct shapes seen on this one table          | Used as a map, not a record                       |
| > 64 fields                                          | Shape per field is too much memory                |
| Manual demote (test-only knob)                       | Debugging                                         |

### Demotion mechanism

```zig
fn demoteToDict(vm: *VM, t: *Table) !void {
    const s = t.shape orelse return;  // already dict-mode

    // 1. Allocate hash part
    const initial_size = std.math.ceilPowerOfTwo(u32, s.fields.len * 2) catch unreachable;
    var new_hash = try HashPart.initWithSize(vm.gc.backing, initial_size);

    // 2. Move each field from slots into hash
    for (s.fields, 0..) |field, i| {
        try new_hash.put(Value.fromString(field.key), t.slots[i], vm.gc);
    }

    // 3. Free the slot array
    vm.gc.backing.free(t.slots[0..t.slots_cap]);
    t.slots = undefined;
    t.slots_cap = 0;

    // 4. Switch mode
    t.hash = new_hash;
    t.shape = null;

    // 5. Decrement shape ref count
    s.ref_count -= 1;
}
```

### Cost

Demotion is O(N) in the field count plus a hash allocation. Happens at most once per table. Acceptable.

### Dictionary mode is performant

Dictionary-mode tables are exactly Phase 1's hybrid tables (array + hash). They're not slow in absolute terms — they're slower than shape-mode but faster than what most scripting languages provide. The key property: **everything still works**. A worst-case Lua program runs at Phase 1 speed, not at "broken" speed.

---

## 10. Heuristics and Thresholds

The numbers below are *initial guesses*. Phase 4's benchmark suite (§2) drives empirical tuning.

| Heuristic                                  | Initial value | Notes                                         |
|--------------------------------------------|---------------|-----------------------------------------------|
| Max shapes per table before demote          | 16            | V8 uses 16 for hidden classes; reasonable     |
| Max fields per table before demote          | 64            | Rare; protects against pathological code      |
| Inline shape children (struct vs hashmap)   | 1             | `ChildMap.one` covers ~95% of shapes          |
| Shape children switch to hashmap at         | 4             | Above 4, allocate `*HashMap`                  |
| `field_index` linear scan threshold         | 4             | Below 4 fields, linear scan beats hash        |
| Initial table slot capacity                 | 4             | First few fields fit without realloc          |
| IC polymorphic capacity                     | 4             | Phase 4 §3 default                             |
| Re-shape-track attempt? (after demote)      | never         | Once dict, always dict                        |

All values are exposed via `comptime` constants so tuning is trivial.

---

## 11. Memory Management

### Shape lifetime

Shapes live in a dedicated arena (`vm.shape_arena`). They are **never freed**. Reasoning:

- The transition trie has bounded size for any given program. A program with 100 distinct table layouts has ~100 shapes; the memory is negligible.
- Reference-counting shapes is straightforward (we even have `ref_count`), but the bookkeeping cost on every transition is non-zero.
- V8 doesn't GC hidden classes either.

If a long-running daemon hits unusual patterns (e.g., re-cdef'd FFI types creating fresh shapes on each cycle), we may revisit. A periodic shape-arena compaction is a reasonable Phase 6 feature if it ever becomes a problem.

### `ref_count` is informational

Maintained for diagnostics (`debug.shape_stats()`) but not used for collection.

### Shape garbage on shutdown

The shape arena is freed wholesale at VM shutdown. No per-shape destructors needed.

### Slot array lifetime

Slot arrays are owned by tables, allocated/freed in sync with the table's lifetime. Standard GC machinery (Phase 1.5) handles them via the table's per-type teardown function.

---

## 12. Edge Cases

### Field deletion

Lua semantics: `t.x = nil` removes the entry.

In shape mode, this would require *back-edge* transitions in the trie ({x, y} → {y}), which breaks the trie property. Rather than handle this carefully, we **demote to dictionary** on any deletion. Two reasons:

1. Code that deletes fields is rarely used as a record.
2. Maintaining "shape with hole at offset 1" complicates every IC.

```lua
local t = {x=1, y=2}   -- shape mode
t.x = nil              -- demotes to dict
```

### Setting a field to nil that was never set

`t.x = nil` where `x` is not in the shape. Lua semantics: no-op. We check shape membership first; if missing, return without transitioning.

### Reassigning a field to a different value

`t.x = "string"` when `x` previously held a number: same shape, same offset, just a slot store. The type hint may degrade (number → any), but the shape is unchanged.

### Setting a field to nil that *is* in the shape

`t.x = nil` where `x` is in the shape: this *is* a deletion (per Lua semantics) and triggers dictionary-mode demotion. Counter-intuitive but consistent.

### Table built with integer keys then strings

```lua
local t = {}; t[1] = "a"; t.name = "thing"
```

The integer write goes to the array part; the string write triggers shape mode. Final state: array_len=1, shape={name}, both populated. Works.

### Table built with strings then integers

```lua
local t = {name="thing"}; t[1] = "a"
```

String write in shape mode; integer write goes to array part. Same final state.

### Mass operations (`table.insert`, `table.sort`)

These operate on the array part. Shape mode is irrelevant; they don't touch the hash part. Performance is identical to Phase 1.

### Tables with no string keys

```lua
local list = {10, 20, 30, 40}
```

No transitions to shape mode (no string keys ever set). `t.shape` stays at the empty root shape, which is an alias for "no fields tracked." Memory overhead vs. Phase 1: one pointer (the shape pointer) per table. Negligible.

### `next()` and `pairs()`

Iteration must visit all keys, including those in both array part and hash part. In shape mode, the hash part is replaced by the slot array indexed by shape fields. Iteration walks: array part 1..n, then `shape.fields[0..]` reading from `slots[]`.

This means iteration order on shape-tracked tables is *insertion-order* — a stronger guarantee than Lua provides (Lua iteration order on hash part is unspecified). We're free to provide a stronger guarantee but should document that user code shouldn't *rely* on this for portability with reference Lua.

### `setmetatable(t, nil)`

Removes the metatable. Shape transition: `S_with_mt → S_without_mt`. The shapes are siblings in the trie. Cached.

---

## 13. Testing Strategy

### Unit tests

- Shape allocation / transition (50+).
- Cache lookup correctness (40+).
- Demotion mechanics (20+).
- Metatable shape splitting (30+).
- All edge cases from §12 (50+).

### Differential against Phase 3

Same input, run with shape system on and off (`comptime` flag). Output must match exactly. Any divergence is a correctness bug in the shape system.

### Shape-fuzz

Generated test corpus of 10k random programs that:
- Allocate tables.
- Add fields.
- Read fields (verifying value matches what was set).
- Delete fields (triggering demotion).
- Compare against a reference (the Phase 1 hybrid table running the same program).

Outputs must match.

### Convergence tests

Verify that two tables built the same way share a shape:

```zig
test "tables built identically share shape" {
    const t1 = mkTable(.{ .x = 1, .y = 2 });
    const t2 = mkTable(.{ .x = 3, .y = 4 });
    try expectEqual(t1.shape, t2.shape);
}
```

### Memory tests

- 10⁶ tables created with the same shape. Memory should be O(1) in shape count, O(N) in table count.
- 10⁶ tables created with distinct shapes (each adds a unique key). Memory should be O(N) in shapes (with bounded shape size).
- Table that demotes to dictionary frees its shape's slot array. No leak.

### IC interaction stress

Phase 4 §13 covers IC stress. Add variants that specifically exercise:
- Mono → Poly → Mega transitions on shape changes.
- IC invalidation on `setmetatable`.
- Method-call ICs across shape changes on the prototype.

### Benchmark suite

Phase 4's bench suite includes shape-relevant benchmarks (deltablue-style OO code, JSON parsing, table-heavy logic). These should show 3–10x speedups over Phase 1's "always hash" implementation.

---

## 14. Performance Characteristics

### Memory overhead per table

| Kind                    | Overhead vs Phase 1 |
|-------------------------|---------------------|
| Empty table             | + 8 bytes (shape pointer = root) |
| Shape-mode, N fields    | Same total (slots replace hash, no per-entry overhead) |
| Dictionary-mode         | Same as Phase 1 |
| Each unique shape       | ~100 bytes (one Shape struct + small field index) |

The shape-mode case is *more memory-efficient* than Phase 1's pure hash for small tables: no Node structs, no chaining pointers, just a flat slot array.

### Memory overhead per shape

A `Shape` is ~100 bytes. The transition trie for a typical Lua program (say, the Neovim config corpus) has ~500–2000 distinct shapes — 50–200 KB total. Tiny.

### Speed (relative to Phase 1, on shape-mode-friendly code)

| Operation               | Phase 1    | Phase 4 (with shapes) | Speedup |
|-------------------------|------------|----------------------|---------|
| Field read, hot site    | hash + chain walk (~30 cycles) | shape compare + indexed load (~5 cycles) | ~6x |
| Field write, hot site   | hash + chain walk + alloc | shape transition (cached) + indexed store | ~5x |
| Method dispatch, hot site | hash + chain + metatable hash | shape compare + chain hint hit | ~10x |
| New table, fresh shape  | (no allocator change) | + shape allocation (~50 cycles) | minor regression |
| Table demote to dict    | (none) | one-time O(N) | irrelevant |

The fresh-shape case is a slight regression — we pay shape allocation for the first instance of a layout. Amortized over many instances, it's negligible. On programs that allocate one-off ad-hoc tables and never reuse the layout, shape tracking might be a wash; the dictionary-mode threshold (16 shapes) cuts off pathological cases.

---

## 15. Exit Criteria (for the shape slice of Phase 4)

- [ ] `Shape` data structure implemented; transitions form a true trie (verified by structural tests)
- [ ] Shape and dictionary mode coexist correctly; demotion never loses data
- [ ] Differential test passes: shape-on and shape-off produce identical output across the corpus
- [ ] Convergence: tables built by identical paths share `*const Shape` identity
- [ ] Field-read fast path is ~5 instructions on x86-64 in `-OReleaseFast`
- [ ] All §12 edge cases handled correctly with explicit tests
- [ ] Method-call IC chain hints work for the common "class with prototype" pattern; benchmarked
- [ ] Memory overhead: shape count grows sublinearly with table count for typical programs (validated on the corpus)
- [ ] No leaks; demotion frees the slot array; shape arena freed at VM shutdown
- [ ] `zig fmt` clean, `zig build test` green

---

## 16. Deliverables

| Path                              | Contents                                              |
|-----------------------------------|-------------------------------------------------------|
| `src/shape/shape.zig`             | `Shape` struct, transition logic                      |
| `src/shape/field_index.zig`       | Open-addressing key→offset index                      |
| `src/shape/child_map.zig`         | Inline-or-hash transition map                         |
| `src/shape/transition.zig`        | Top-level transition function, caching                |
| `src/shape/demote.zig`            | Dictionary-mode demotion                              |
| `src/shape/diagnostics.zig`       | `debug.shape_stats()`, dump tools                     |
| `src/table.zig` (modified)        | Table struct grows `shape`, `slots` fields            |
| `src/handlers.zig` (modified)     | `TGETS`, `TSETS`, `TNEW` use shape fast paths         |
| `src/ic.zig` (modified)           | IC cells consult shape ID; chain hints for methods    |
| `tests/shape/`                    | Shape system unit tests (200+)                        |
| `tests/shape/edge_cases/`         | All §12 cases                                         |
| `tests/shape/fuzz/`               | Shape-fuzz harness                                    |
| `tests/shape/convergence/`        | Convergence tests                                     |
| `bench/shape/`                    | OO-pattern benchmarks (deltablue, hot-method-dispatch) |
| `docs/shape-tuning.md`            | Heuristic values, when to revisit, how to measure     |

---

## 17. Estimated Effort

5–6 weeks focused. Part of Phase 4's overall 5–7 month estimate.

| Component                              | Estimate    |
|----------------------------------------|-------------|
| `Shape` data structure + arena         | 4 days      |
| `field_index`, `child_map`             | 3 days      |
| Transition function + caching          | 1 week      |
| Table struct migration                 | 3 days      |
| Handler updates (TGETS, TSETS, TNEW)   | 1 week      |
| IC integration                         | 1 week      |
| Demotion logic                         | 4 days      |
| Metatable splitting                    | 4 days      |
| Edge case implementation               | 1 week      |
| Diagnostics tools                      | 2 days      |
| Tests (unit, fuzz, convergence)        | 1.5 weeks   |
| Benchmarking + tuning                  | 1 week      |

---

## 18. Open Questions

1. **Inline slot count.** V8 reserves a few slots inside the object header for the first N fields ("in-object slots"). Saves an indirection on hot reads. Worth doing? In V8 it's ~10% improvement on object-heavy code. For Lua, less clear because the GC header is already 16 bytes; adding 4 inline slots brings the table object to 64 bytes (one cache line), which may help. Defer; revisit with measurements.

2. **Type-hint usage in interpreter.** The `TypeHint` field on `FieldInfo` is set during transitions but Phase 4's interpreter doesn't currently use it for specialization beyond what the IC already provides. Phase 5's JIT will use it heavily as a guard hint. Decide whether the interpreter should also exploit it (e.g., `ADD` with both operands "known integer" can skip the double check). Marginal interpreter win; defer.

3. **Metatable shape sharing.** Two distinct metatables `mt1` and `mt2` with identical structure produce different Shape entries. Could we *also* hash-cons metatable identity? Probably not worth it — two metatables with identical content are rare in real code.

4. **`__index` chain depth limit.** Method-call ICs cache a chain hint. Deeply nested `__index` chains (5+) hurt cache hit rate and increase invalidation cost. Document a soft limit; warn if exceeded.

5. **Generation counter granularity.** Phase 4 §3 uses a single global counter for metatable invalidation. Per-shape counters would be more precise but cost cache space. Default global; revisit if measurements show cache-thrashing on metatable-heavy programs.

6. **Migration path: existing tables on shape-mode introduction.** When Phase 4 ships, all existing tables are in dictionary mode (Phase 1 layout). Do we migrate them lazily as they're touched, or eagerly at startup? Lazy is simpler and probably correct (touched-once tables migrate, untouched stay).

7. **`__pairs` and `__ipairs` interaction.** Lua 5.2+ allows metamethods that override iteration. Shape-tracked tables iterate via shape order; what if `__pairs` is set? Defer to the metamethod; shape ordering is irrelevant in that case. Document.

8. **Concurrent shape mutation (future).** If multi-mutator support ever lands, shape transitions become a synchronization point. Consider lock-free trie design or per-shape spinlocks. Far-future concern.

9. **Compiler hints for shape stability.** A `local p = {x=1, y=2}` compile-time-known table constructor could allocate at the final shape directly via the `TNEW_LITERAL` superinstruction (Phase 4 §5). Verify this superinstruction lands and emits the right transitions in one shot.

10. **Shape ID exhaustion.** 32-bit IDs allow 4B distinct shapes. Wrap-around invalidates all ICs (not catastrophic, just slow until they re-record). For long-running programs that create unique shapes constantly, set a soft warning at 100M shape allocations — likely indicates a bug or anti-pattern.

11. **Snapshot debugging.** `debug.shape_stats()` should expose: total shape count, total tables in dictionary mode vs shape mode, distribution of fields-per-shape, transitions-per-shape distribution. Useful for "why is my code slow" investigations.

12. **Shape table for global environment.** `_ENV` is a Lua table. Reads of globals (`GGET`) are extremely hot. Shape-tracking `_ENV` is the same as any other table — should "just work" — but verify with benchmarks that the global-read path actually benefits.
