# Phase 2 — Coroutines, Stdlib, and Embedding API

**Project:** Lua/LuaJIT-shaped scripting language in Zig
**Phase goal:** Make the language genuinely usable. Add coroutines (the eighth value type), expand the standard library to cover real Lua programs (`string.format`, patterns, `io`, `os`, `debug`), and ship the embedding API surface — both a Zig-native ergonomic API and a C-ABI shim for non-Zig hosts.

**Predecessors:** Phase 1 (bytecode VM) and Phase 1.5 (GC). The single-thread VM, NaN-boxed values, opcode set, and GC abstractions all carry over. The major addition is multi-thread state (per-coroutine stacks) and the embedding boundary.

---

## 1. Goals & Non-Goals

### Goals

- Implement stackful asymmetric coroutines as a first-class value type, leveraging the fact that we're a pure interpreter (no C-stack switching required).
- Ship `coroutine.*` library with full Lua 5.1+ semantics for `create` / `resume` / `yield` / `wrap` / `status`.
- Expand stdlib to cover the functions actually exercised by real-world Lua code: `string.format`, Lua patterns (`find`, `match`, `gmatch`, `gsub`), full `table.*`, full `math.*`, `io.*` basics, `os.*` basics, minimal `debug.*`.
- Design and ship two embedding APIs: a Zig-native typed API (preferred for Zig hosts) and a C-ABI shim (Lua-API-shaped, for non-Zig hosts).
- Source-level debugging info: file:line in error messages, traceback support, `debug.traceback`.
- Wire up `__gc` finalizers (deferred from Phase 1) — feasible under stop-the-world; Phase 4 will adapt them to incremental GC.
- Expand the test corpus to 300+ Lua tests, plus embedding-API tests in both Zig and C.

### Non-Goals

- FFI for *Lua code* to call C libraries — that's Phase 3 (the LuaJIT-style `ffi.*` library, distinct from the embedding C API).
- Yielding across C boundaries (Lua 5.1 disallows; Lua 5.2+ allows via continuations). Phase 2 matches Lua 5.1 — yielding from inside a host call is an error. Continuations deferred.
- Weak tables. Phase 4.
- Incremental / generational GC. Phase 4.
- `__close` / to-be-closed variables (Lua 5.4 feature). Skip; we're targeting LuaJIT-shape, which is 5.1+.
- Bitwise operations on numbers (Lua 5.3+ `bit32` / native operators). Skip — LuaJIT-shape uses `bit.*` from BitOp library; provide as a separate optional module.
- UTF-8 library (`utf8.*` from 5.3+). Skip.
- Optimization work — Phase 4.

---

## 2. The `thread` Type

The eighth value type. A `thread` is a coroutine: a suspended computation with its own stack, call stack, open-upvalue list, and error-handler stack.

```zig
pub const Thread = struct {
    gc:           GcHeader,

    // Per-thread VM state
    stack:        []Value,
    stack_top:    [*]Value,
    call_stack:   std.ArrayList(CallInfo),
    open_upvals:  std.ArrayList(*UpvalueCell),
    error_frames: std.ArrayList(ErrorFrame),

    // Resume/yield state
    status:       Status,
    resumer:      ?*Thread,         // who resumed us; null for main thread
    saved_ip:     ?[*]const Instruction,
    saved_base:   ?[*]Value,

    // Result transfer
    transfer:     std.ArrayList(Value),  // args on resume / values on yield

    gclist:       ?*GcHeader,
};

pub const Status = enum {
    suspended,   // newly created or yielded
    running,     // currently executing (only one Thread has this at a time)
    normal,      // resumed another coroutine and is waiting
    dead,        // finished or errored
};
```

### Why this is easy for us (and hard for native Lua)

In a C interpreter like reference Lua, a coroutine yielding has to unwind the C stack to get back to the dispatch loop. Lua handles this with `setjmp`/`longjmp`. In LuaJIT, hand-written assembly does the context switch. Either way, the C stack is the obstacle.

We have **no C-stack interleaving with the VM**. The dispatch loop's state — IP, register base, current proto, current call info — all lives in the `VM` and `Thread` structs. To suspend a coroutine, we:

1. Save IP and register base into the suspending thread.
2. Mark its status `.suspended`.
3. Switch `vm.current_thread` to the resumer.
4. Restore that thread's IP and base.
5. Return to the dispatch loop, which keeps running.

No `setjmp`, no `ucontext`, no inline assembly. This is one of the genuine wins of being interpreted.

The **constraint** is that yielding from inside a Zig host function is an error: the host's Zig stack frame would have to be preserved across the suspension, and we don't have a mechanism for that. This matches Lua 5.1 semantics. Phase 2 explicitly disallows it; the dispatch boundary is the only legal yield point.

### `coroutine.create(f)`

```zig
fn coroCreate(vm: *VM, f: Value) !*Thread {
    const fn_ptr = f.asFunction() orelse return error.NotAFunction;

    const t = try vm.gc.create(Thread);
    t.* = .{
        .gc = .{ ... },
        .stack = try vm.gc.backing.alloc(Value, INITIAL_STACK_SIZE),
        .stack_top = undefined,
        .call_stack = std.ArrayList(CallInfo).init(vm.gc.backing),
        .open_upvals = std.ArrayList(*UpvalueCell).init(vm.gc.backing),
        .error_frames = std.ArrayList(ErrorFrame).init(vm.gc.backing),
        .status = .suspended,
        .resumer = null,
        .saved_ip = null,
        .saved_base = null,
        .transfer = std.ArrayList(Value).init(vm.gc.backing),
        .gclist = null,
    };
    t.stack_top = t.stack.ptr;

    // Push the entry function onto the new thread's stack — it'll be called on first resume
    t.stack[0] = f;
    t.stack_top = t.stack.ptr + 1;

    return t;
}
```

### `coroutine.resume(co, ...)`

```zig
fn coroResume(vm: *VM, target: *Thread, args: []const Value) ![]const Value {
    if (target.status != .suspended) return error.BadStatus;

    const current = vm.current_thread;
    target.resumer = current;
    target.status = .running;
    current.status = .normal;

    // Transfer args
    target.transfer.clearRetainingCapacity();
    try target.transfer.appendSlice(args);

    // Save current thread's IP/base
    current.saved_ip = vm.ip;
    current.saved_base = vm.base;

    // Switch
    vm.current_thread = target;
    if (target.saved_ip) |ip| {
        // Resuming a previously-yielded thread
        vm.ip = ip;
        vm.base = target.saved_base.?;
    } else {
        // First resume — set up an initial call frame
        try setupInitialCall(vm, target, args);
    }

    // Return to dispatch loop. The resume "returns" when the target either:
    //   - yields (yield logic switches back to current and returns yielded values)
    //   - returns from its top-level function (status -> dead, results returned)
    //   - errors (status -> dead, error propagates)
    return drive(vm);
}
```

### `coroutine.yield(...)`

A **yield-trap opcode** isn't necessary; yield is a host call from inside the coroutine.

```zig
fn coroYield(vm: *VM, values: []const Value) ![]const Value {
    const current = vm.current_thread;
    if (current.resumer == null) return error.YieldFromMainThread;

    const resumer = current.resumer.?;

    // Save current state
    current.saved_ip = vm.ip;
    current.saved_base = vm.base;
    current.status = .suspended;

    // Transfer yielded values to resumer
    resumer.transfer.clearRetainingCapacity();
    try resumer.transfer.appendSlice(values);

    // Switch
    vm.current_thread = resumer;
    vm.ip = resumer.saved_ip.?;
    vm.base = resumer.saved_base.?;
    resumer.status = .running;

    // When this thread is resumed again, control returns here, and `current.transfer` holds the new args
    suspendUntilResumed(vm, current);
    return current.transfer.items;
}
```

The "return when resumed" mechanic is implemented by having `coroYield` actually return out of the `coroutine.yield` host function back to the original `coroutine.resume` host frame — the coroutine's dispatch resumes naturally on the next `resume`. The dispatch loop is structured so that the active thread is always `vm.current_thread` and switching it changes who's running.

### Status transitions

```
        create
          ↓
      suspended ──resume──▶ running ──yield──▶ suspended
          │                    │  │                ↑
          │                    │  └────resume──────┘  (resuming another coroutine)
          │                    │           ↓
          │                    │       (running)
          │                    │           ↓
          │                  return     normal
          │                    ↓           
          └────────dead◀───────┴──error────┐
                                           │
                                       (any state)
```

### GC integration

Each thread's stack, call stack, open upvalues, and error-frame error values are roots. The root walk now iterates threads instead of using `vm.stack` directly:

```zig
fn markRoots(gc: *Gc, vm: *VM) void {
    // Globals, registry, error value as before
    markObject(gc, &vm.globals.gc);
    if (vm.error_value.asGcPtr()) |p| markObject(gc, p);

    // Walk all live threads
    for (vm.all_threads.items) |t| {
        markThread(gc, t);
    }
}

fn markThread(gc: *Gc, t: *Thread) void {
    // Stack
    var i: usize = 0;
    while (i < @intFromPtr(t.stack_top) - @intFromPtr(t.stack.ptr) / @sizeOf(Value)) : (i += 1) {
        markValue(gc, t.stack[i]);
    }
    // Call stack: each CallInfo carries a Function pointer
    for (t.call_stack.items) |ci| markObject(gc, &ci.func.gc);
    // Open upvalues
    for (t.open_upvals.items) |c| markObject(gc, &c.gc);
    // Error frames
    for (t.error_frames.items) |ef| markValue(gc, ef.error_value);
}
```

`vm.all_threads` is a list of all live threads (added on creation, removed on death). It's a strong root list; threads die only via GC of unreachable threads, which is handled by ordinary marking.

---

## 3. The `coroutine` Library

| Function                  | Behavior                                                |
|---------------------------|---------------------------------------------------------|
| `coroutine.create(f)`     | Create suspended coroutine with `f` as entry            |
| `coroutine.resume(co, ...)` | Resume coroutine; returns `(true, results...)` or `(false, error)` |
| `coroutine.yield(...)`    | Suspend; values become the resume's results             |
| `coroutine.status(co)`    | Returns `"suspended"` / `"running"` / `"normal"` / `"dead"` |
| `coroutine.wrap(f)`       | Returns a function that resumes; raises errors directly |
| `coroutine.running()`     | Returns the current coroutine and a boolean (`true` if main thread) |
| `coroutine.isyieldable()` | True if `yield` would succeed from the current point    |

`wrap` is a convenience: `coroutine.wrap(f)` returns a closure that captures a freshly-created thread and resumes it on each call. Errors from within the coroutine are raised directly instead of returned as `(false, err)`.

---

## 4. Stdlib Expansion: Strings

### `string.format`

A Lua-flavored printf. Specifiers:

- `%d`, `%i`: integer (we coerce f64 → i64 with bounds check)
- `%u`: unsigned integer
- `%f`, `%e`, `%g`, `%G`: floating-point, with Lua's defaults
- `%s`: string (calls `__tostring` if metatable provides it)
- `%q`: string in safely-quoted form (escape sequences as needed)
- `%x`, `%X`, `%o`: hex/octal
- `%c`: single character from numeric code
- `%%`: literal `%`

Width, precision, and flags (`-`, `+`, ` `, `#`, `0`) supported per C printf.

Implementation: parse the format string, dispatch each specifier, build output via `std.ArrayList(u8)`. ~250 lines.

### Lua Patterns

Lua patterns are **not regex**. A small, well-defined string-matching language:

| Construct      | Meaning                                                 |
|----------------|---------------------------------------------------------|
| `.`            | any character                                           |
| `%a` / `%A`    | letter / non-letter                                     |
| `%d` / `%D`    | digit / non-digit                                       |
| `%l` / `%L`    | lowercase / non-lowercase                               |
| `%p` / `%P`    | punctuation / non-punctuation                           |
| `%s` / `%S`    | whitespace / non-whitespace                             |
| `%u` / `%U`    | uppercase / non-uppercase                               |
| `%w` / `%W`    | alphanumeric / non-alphanumeric                         |
| `%c` / `%C`    | control / non-control                                   |
| `%x` / `%X`    | hex / non-hex                                           |
| `%<punct>`     | escape literal punctuation                              |
| `[set]`        | character class, `[^set]` complement, `[a-z]` ranges    |
| `*`            | 0+ greedy                                               |
| `+`            | 1+ greedy                                               |
| `-`            | 0+ lazy                                                 |
| `?`            | optional                                                |
| `^` (anchor)   | match start (only at pattern start)                     |
| `$` (anchor)   | match end (only at pattern end)                         |
| `()`           | capture                                                 |
| `()` (empty)   | position capture                                        |
| `%n` (1–9)     | back-reference to nth capture                           |
| `%b()`         | balanced match: matches `(...)` with nesting            |
| `%f[set]`      | frontier: zero-width match at a class boundary          |

Implementation: classic recursive matcher matching `lstrlib.c`. ~500 lines including captures and back-references.

Functions:

| Function                        | Behavior                                            |
|---------------------------------|-----------------------------------------------------|
| `string.find(s, pat, init, plain)` | Returns start, end, captures (or nil)            |
| `string.match(s, pat, init)`    | Returns captures (or first-N if no `()`)            |
| `string.gmatch(s, pat)`         | Iterator over all matches                           |
| `string.gsub(s, pat, repl, n)`  | Substitution; `repl` may be string, table, or function |

### Other `string.*` functions

`string.byte`, `string.char`, `string.dump` (deferred — needs bytecode dump from Phase 1), `string.len`, `string.lower`, `string.rep`, `string.reverse`, `string.sub`, `string.upper`. All straightforward.

---

## 5. Stdlib Expansion: Tables, Math, OS, IO, Debug

### `table.*`

| Function                       | Behavior                                            |
|--------------------------------|-----------------------------------------------------|
| `table.insert(t, [pos,] v)`    | Insert; shift if pos given                          |
| `table.remove(t, [pos])`       | Remove and return; default last                     |
| `table.concat(t, sep, i, j)`   | Concatenate range                                   |
| `table.sort(t, comp)`          | In-place sort; default `<`                          |
| `table.unpack(t, i, j)`        | Multi-return values from t                          |
| `table.pack(...)`              | Pack varargs into table with `n` field              |

`table.sort` uses introsort (quicksort with depth limit + heapsort fallback). Lua's reference uses pure quicksort; introsort is a small upgrade for worst-case behavior.

### `math.*`

| Function                       | Notes                                               |
|--------------------------------|-----------------------------------------------------|
| `math.abs`, `math.ceil`, `math.floor` | Trivial                                      |
| `math.exp`, `math.log`, `math.pow`, `math.sqrt` | Direct std math                       |
| `math.sin`, `math.cos`, `math.tan`, `math.asin`, `math.acos`, `math.atan` | Direct std math |
| `math.deg`, `math.rad`         | Conversion                                          |
| `math.max`, `math.min`         | Variadic                                            |
| `math.modf`, `math.fmod`       | Decomposition                                       |
| `math.random`, `math.randomseed` | xoshiro256** PRNG (NOT the C `rand()`; Lua 5.4 uses xoshiro) |
| `math.huge`, `math.pi`         | Constants                                           |
| `math.maxinteger`, `math.mininteger` | If we add integer subtype later             |

### `os.*`

| Function                       | Behavior                                            |
|--------------------------------|-----------------------------------------------------|
| `os.time([t])`                 | Unix timestamp; optional table → encode             |
| `os.date(fmt, [t])`            | Format date; supports `*t` and `!*t`                |
| `os.clock()`                   | CPU time in seconds                                 |
| `os.difftime(t2, t1)`          | Difference in seconds                               |
| `os.getenv(name)`              | Environment variable                                |
| `os.tmpname()`                 | Temporary filename                                  |
| `os.remove(path)`              | Delete file                                         |
| `os.rename(old, new)`          | Rename                                              |
| `os.exit([code, [close]])`     | Exit; runs finalizers if `close`                    |

Sandboxing hooks: the embedding API can disable any subset (e.g. `os.execute`, `os.remove`, `io.open`). See §8.

### `io.*`

| Function                       | Behavior                                            |
|--------------------------------|-----------------------------------------------------|
| `io.open(path, mode)`          | Returns file handle (userdata) or `nil, err`        |
| `io.close([file])`             | Close file or default output                        |
| `io.read(...)`                 | Read from default input                             |
| `io.write(...)`                | Write to default output                             |
| `io.lines([path, ...])`        | Iterator over lines                                 |
| `io.input([file])`, `io.output([file])` | Get/set defaults                           |
| `file:read`, `file:write`, `file:seek`, `file:lines`, `file:close` | Methods |

File handles are full userdata with a `__gc` finalizer that closes the underlying file descriptor — exercises the finalizer machinery wired up in this phase.

### `debug.*` (minimal)

| Function                       | Behavior                                            |
|--------------------------------|-----------------------------------------------------|
| `debug.traceback([msg, [level]])` | Stack trace as string                            |
| `debug.getinfo(level, what)`   | Frame info: source, line, name, etc.                |
| `debug.sethook`, `debug.gethook` | Deferred — Phase 4 (interacts with dispatch)      |
| `debug.getlocal`, `debug.setlocal` | Frame variable access                            |
| `debug.getupvalue`, `debug.setupvalue` | Closure upvalue access                       |

---

## 6. Finalizers (`__gc`)

Wired up in Phase 2 under the simpler stop-the-world GC. Phase 4 will adapt to incremental.

### Mechanism

1. `setmetatable(t, {__gc = fn})` sets the `has_finalizer` flag on `t`.
2. During the mark phase, finalizable objects that are **unreachable** are added to a `to_be_finalized` queue (rather than being marked dead immediately).
3. Each is *resurrected*: marked live so the rest of marking sees it as reachable.
4. After sweep, the GC runs each queued object's `__gc` metamethod in a separate phase. The metamethod is mutator code — it can allocate, call functions, even resurrect via side effects.
5. On the next collection cycle, the object is reconsidered. If still unreachable, it's freed without re-running the finalizer.

### Resurrection invariant

When we resurrect an object during marking:

- Mark it gray, push onto the gray queue.
- Anything it references is now reachable for *this* cycle.
- Set a flag (`has_run_finalizer`) so the next cycle won't re-queue it.

### Ordering

Finalizers run in **reverse order of finalization registration** (LIFO). This matches Lua's behavior and is the order users expect.

### Errors in finalizers

Errors raised by `__gc` are caught by the GC and reported via a registered handler (`debug.gcinfo` or similar) but do not propagate. Otherwise a misbehaved finalizer could destabilize the entire program.

---

## 7. Source-Level Debug Info

Phase 1's `Proto` already has `line_info: []const u32`. Phase 2 wires it through everything that needs it.

### Error message format

Lua convention: `"<source>:<line>: <message>"`. The `<source>` is the `Proto.source` field; `<line>` is `Proto.line_info[ip - code]`.

```zig
fn raiseError(vm: *VM, msg: []const u8) error{LuaError} {
    const ci = vm.current_thread.call_stack.items[vm.current_thread.call_stack.items.len - 1];
    const ip_idx = (@intFromPtr(vm.ip) - @intFromPtr(ci.proto.code.ptr)) / @sizeOf(Instruction);
    const line = ci.proto.line_info[ip_idx];

    const formatted = try std.fmt.allocPrint(vm.gc.backing, "{s}:{d}: {s}", .{
        ci.proto.source.bytes[0..ci.proto.source.len],
        line,
        msg,
    });
    vm.error_value = Value.fromString(try internShort(vm, formatted));
    return error.LuaError;
}
```

### Traceback

`debug.traceback` walks the current thread's call stack:

```
stack traceback:
    [C]: in function 'error'
    foo.lua:12: in function 'inner'
    foo.lua:18: in function 'middle'
    foo.lua:25: in main chunk
    [C]: in ?
```

For each `CallInfo`, format `<source>:<line>: in function '<name>'`. C functions show as `[C]: in function '<name>'`. Names come from inspecting the calling frame's bytecode: if the call site was `GGET name; CALL`, the name is `name`. Otherwise `?`.

---

## 8. Embedding API — Two Layers

Distinct from the FFI library that Phase 3 will add for *Lua code* to call C, the **embedding API** is what hosts use to invoke Lua, register functions, and exchange values. We ship two layers:

### Layer A: Zig-native API

Type-safe, ergonomic, uses Zig errors and slices. The preferred API for Zig hosts.

```zig
pub const Lua = struct {
    vm: *VM,

    pub fn init(allocator: std.mem.Allocator, opts: InitOptions) !Lua;
    pub fn deinit(self: *Lua) void;

    // Loading
    pub fn loadString(self: *Lua, source: []const u8, name: []const u8) !*Function;
    pub fn loadFile(self: *Lua, path: []const u8) !*Function;
    pub fn loadBytecode(self: *Lua, bytes: []const u8) !*Function;

    // Calling
    pub fn call(self: *Lua, f: Value, args: anytype) ![]Value;
    pub fn pcall(self: *Lua, f: Value, args: anytype) PcallResult;

    // Globals
    pub fn getGlobal(self: *Lua, name: []const u8) Value;
    pub fn setGlobal(self: *Lua, name: []const u8, v: Value) !void;

    // Tables
    pub fn newTable(self: *Lua, array_hint: u32, hash_hint: u32) !*Table;
    pub fn tableGet(self: *Lua, t: *Table, key: anytype) Value;
    pub fn tableSet(self: *Lua, t: *Table, key: anytype, value: anytype) !void;

    // Function registration — type-safe, comptime-generated
    pub fn registerFn(self: *Lua, name: []const u8, comptime f: anytype) !void;

    // Sandboxing
    pub fn sandbox(self: *Lua, opts: SandboxOptions) void;
};

pub const InitOptions = struct {
    allocator: std.mem.Allocator,
    open_libs: LibSet = .all,                // which stdlib modules to load
    stack_size: usize = 1024 * 1024,
};

pub const SandboxOptions = struct {
    allow_io:      bool = true,
    allow_os_exec: bool = false,
    allow_loaders: bool = true,
    memory_limit:  ?usize = null,
    instruction_limit: ?u64 = null,
};
```

### `registerFn` — comptime function adaptation

The interesting part. A native Zig function can be registered without writing any glue:

```zig
fn add(a: f64, b: f64) f64 {
    return a + b;
}

try lua.registerFn("add", add);
```

Behind the scenes, `comptime` inspects `add`'s signature, generates a wrapper that reads arguments off the Lua stack with type-checking, calls `add`, and pushes the result. Errors (wrong arg count, wrong type) become Lua errors with helpful messages.

```zig
pub fn registerFn(self: *Lua, name: []const u8, comptime f: anytype) !void {
    const wrapper = comptime makeWrapper(f);
    const gf = try self.vm.gc.create(GHostFunction);
    gf.* = .{ .gc = ..., .fn_ptr = wrapper };
    try self.setGlobal(name, Value.fromFunction(gf));
}

fn makeWrapper(comptime f: anytype) HostFn {
    const Args = @typeInfo(@TypeOf(f)).Fn.params;
    return struct {
        fn wrapper(vm: *VM, n_args: u32) !u32 {
            if (n_args != Args.len) return error.WrongArgCount;
            var tuple: std.meta.ArgsTuple(@TypeOf(f)) = undefined;
            inline for (Args, 0..) |arg, i| {
                tuple[i] = try valueAsZigType(arg.type.?, vm.regs[i]);
            }
            const result = @call(.auto, f, tuple);
            vm.regs[0] = zigTypeToValue(result);
            return 1;
        }
    }.wrapper;
}
```

This is comparable in spirit to LuaJIT FFI's auto-binding but at the host-function level rather than for arbitrary C declarations. It's a Zig-specific ergonomic win that has no equivalent in the Lua C API.

### Layer B: C-ABI shim

Lua-API-shaped, byte-compatible enough that most embedding code ports easily, exposed as `extern "C"` functions with `lua_State*` (which is just `*VM` cast).

```zig
export fn lua_pushnumber(L: *VM, n: f64) callconv(.C) void {
    pushValue(L, Value.fromDouble(n));
}

export fn lua_tonumber(L: *VM, idx: c_int) callconv(.C) f64 {
    const v = stackAt(L, idx);
    return v.asDouble() orelse 0.0;
}

export fn lua_pcall(L: *VM, nargs: c_int, nresults: c_int, errfunc: c_int) callconv(.C) c_int {
    // ...
}

// ... ~200 functions for Lua 5.1 API surface
```

Naming: we expose `lua_*` functions for source-level compatibility with Lua C API code. Where our semantics diverge (e.g. integer/float distinction in 5.3+), we match Lua 5.1 / LuaJIT.

The C ABI surface is auto-generated where possible from the Zig API via a `comptime` table — write each function once in Zig, get a C-shim wrapper for free.

---

## 9. Error Handling Refinements

Phase 1 had basic `pcall` / `error`. Phase 2 adds:

- **`xpcall(f, handler, ...)`**: like `pcall`, but on error, calls `handler(err)` *while the stack still has the error frames* — handler can capture traceback before unwind.
- **`error(msg, level)`**: the `level` argument controls which frame's source/line gets prepended. Level 1 (default) is the caller; level 2 is the caller's caller, etc.
- **Object errors**: `error(t)` with a table or any non-string is permitted; the object is passed through unmodified to the catcher. `__tostring` is called only at the boundary where Lua needs a string representation.
- **Internal errors carry source location**: every runtime error (type errors, arithmetic on non-numbers, index nil, etc.) prepends `<source>:<line>:` automatically.

### The error frame change

`ErrorFrame` gains an optional handler:

```zig
pub const ErrorFrame = struct {
    saved_top:    [*]Value,
    saved_call:   usize,
    error_value:  Value,
    handler:      ?*Function,    // for xpcall
};
```

When an error is raised, the runtime walks the error-frame stack. If the topmost frame has a handler, the handler is invoked *before* unwind (so it sees full call stack for traceback purposes). Then unwind proceeds.

---

## 10. Testing Strategy

Five tiers:

1. **Unit tests** per module (coroutine state machine, pattern matcher, format spec parser, etc.). 200+ tests.
2. **Snapshot tests** for new functionality. Pattern matching alone deserves ~50 snapshots covering edge cases (anchors, captures, balanced matches, greedy vs lazy).
3. **Lua test corpus** expanded to 300+ files. Now tests with coroutines, patterns, full stdlib are eligible.
4. **Embedding tests in Zig**: Zig host code drives a Lua VM through the Layer A API. ~30 scenarios covering function registration, table manipulation, error handling, sandboxing.
5. **Embedding tests in C**: a C harness drives the Layer B API. Verifies the C ABI surface is actually usable from C. ~20 scenarios.
6. **Coroutine torture test**: producer/consumer pipelines with thousands of resumes per second, GC stress on, no leaks, no crashes.

---

## 11. Exit Criteria

- [ ] `coroutine.*` library passes Lua's coroutine test suite
- [ ] `string.format` covers all Lua 5.1 specifiers
- [ ] Lua patterns pass the official `lstrlib` test cases (port from upstream)
- [ ] `table.*`, `math.*`, `os.*`, `io.*`, `debug.*` (minimal) implemented per §5
- [ ] `__gc` finalizers run correctly under stop-the-world GC; resurrection works
- [ ] Source-level error messages everywhere; `debug.traceback` produces useful output
- [ ] Layer A Zig API: `registerFn` works for any function with primitive parameters; sandboxing options take effect
- [ ] Layer B C ABI: a small C program can embed the VM, register a function, call a Lua script, and read back results
- [ ] Lua test corpus: 300+ files passing
- [ ] No regressions on Phase 1 corpus; differential tests still green
- [ ] No leaks under `GeneralPurposeAllocator{ .safety = true }` after running corpus including coroutines and finalizers
- [ ] `zig fmt` clean, `zig build test` green

---

## 12. Deliverables

| Path                             | Contents                                              |
|----------------------------------|-------------------------------------------------------|
| `src/thread.zig`                 | `Thread` type, resume/yield mechanics                 |
| `src/lib_coroutine.zig`          | `coroutine.*` library                                 |
| `src/lib_string.zig`             | `string.*` including `format`                         |
| `src/pattern.zig`                | Lua pattern matcher                                   |
| `src/lib_table.zig`              | `table.*`                                             |
| `src/lib_math.zig`               | `math.*`                                              |
| `src/lib_os.zig`                 | `os.*`                                                |
| `src/lib_io.zig`                 | `io.*` with file userdata + `__gc`                    |
| `src/lib_debug.zig`              | `debug.*` minimal                                     |
| `src/finalize.zig`               | `__gc` queue, resurrection, post-GC hook              |
| `src/api_zig.zig`                | Layer A: `Lua` struct, `registerFn`, etc.             |
| `src/api_c.zig`                  | Layer B: `lua_*` C ABI exports                        |
| `src/error_format.zig`           | Source-line prepending, traceback                     |
| `tests/coroutine/`               | Coroutine-specific tests                              |
| `tests/pattern/`                 | Pattern matcher tests                                 |
| `tests/embed_zig/`               | Zig embedding scenarios                               |
| `tests/embed_c/`                 | C embedding scenarios (with build system integration) |
| `tests/lua-tests/`               | Expanded Lua corpus                                   |
| `examples/embed_minimal.c`       | Minimal C embedding example                           |
| `examples/embed_zig.zig`         | Minimal Zig embedding example                         |
| `docs/phase-2-postmortem.md`     | Decisions, surprises, inputs to Phase 3               |

---

## 13. Estimated Effort

3–4 months focused. Smaller than Phase 1 because the foundations are in place.

| Component                              | Estimate     |
|----------------------------------------|--------------|
| Thread type + resume/yield             | 2 weeks      |
| `coroutine.*` library                  | 1 week       |
| `string.format`                        | 1 week       |
| Lua pattern matcher                    | 2 weeks      |
| Other `string.*`, `table.*`, `math.*`  | 1 week       |
| `os.*`                                 | 1 week       |
| `io.*` with file userdata + `__gc`     | 2 weeks      |
| Finalizer wiring (`__gc`)              | 1.5 weeks    |
| `debug.*` minimal + traceback          | 1.5 weeks    |
| Error refinements (xpcall, levels)     | 1 week       |
| Layer A Zig API                        | 2–3 weeks    |
| Layer B C ABI shim                     | 2 weeks      |
| Sandboxing                             | 1 week       |
| Test corpus expansion                  | 2 weeks      |
| Postmortem + cleanup                   | 1 week       |

---

## 14. Inputs to Phase 3

Phase 3 (FFI for Lua code calling C libraries) inherits:

- The Layer B C ABI as a model — many of the same patterns (struct layout, calling conventions) appear in FFI
- `Userdata` with `__gc` finalizers — FFI cdata is a specialized userdata type with similar lifetime semantics
- The pattern of `comptime`-generated wrappers (used in `registerFn`) generalizes to FFI's auto-binding of C functions
- The sandboxing API (which subsystems can be disabled) extends to FFI: hosts may want to allow the language but disallow arbitrary library loading
- Coroutine yielding-from-C deferred status: if Phase 3's FFI calls take long enough that yielding from inside them matters, the continuation mechanism becomes more important

---

## 15. Open Questions

1. **Coroutine stack growth.** Threads start with `INITIAL_STACK_SIZE`. If the stack grows, we `realloc` — but any pointer into the stack (open upvalues, error-frame `saved_top`) becomes invalid. Solution: walk and patch on every grow. Verify this is correct under deeply nested calls within a coroutine.

2. **`yield` and `pcall` interaction.** A `pcall` inside a coroutine creates an error frame on that coroutine's frame stack. Yielding while inside a `pcall` is legal — the error frame stays valid across the yield. But: when the coroutine is later resumed, the error frame must still be live. Check that the per-thread error-frame stack is correctly preserved across switches.

3. **Pattern matcher allocation.** Captures allocate. For `gmatch`/`gsub` over large strings, this can be a lot of small allocations. Consider an arena allocator scoped to a single match operation that's reset between matches.

4. **`string.format` and locale.** Lua's reference implementation calls into C's locale-aware formatting for `%f`/`%g`. We should match Lua 5.1 behavior (locale-independent C-locale formatting) to avoid surprises in international environments.

5. **`io.lines` lifetime.** The iterator returned by `io.lines("file")` owns the file handle and should close it on iterator exhaustion *or* GC. Reference Lua uses `__gc` on the iterator state. Verify our finalizer machinery handles this case (closure with userdata upvalue).

6. **Layer A `registerFn` for varargs.** Functions that take a Lua-side variable arg list (like `print`) can't be auto-wrapped from a Zig signature. Provide a manual `registerRawFn` escape hatch that takes `fn (vm: *VM, args: []const Value) ![]const Value`.

7. **C ABI `lua_State*` opacity.** Some embedders inspect `lua_State` internals (e.g. some debuggers). We should treat it as opaque and document that — anyone reaching into it is on their own.

8. **Finalizer ordering and cycles.** If A and B have finalizers and A.field = B and B.field = A, neither is reachable but each references the other. Lua's behavior: both are finalized; the order is unspecified within the cycle. Match this and document it.

9. **`debug.sethook`.** Deferred to Phase 4 because it requires the dispatch loop to call into a hook callback at instruction/line/call/return granularity. The natural place to add it is alongside Phase 4's optimization work, since both touch hot dispatch paths.

10. **Memory limits.** `SandboxOptions.memory_limit` requires the GC to track total bytes and refuse allocations beyond the limit. This interacts with the trigger heuristic — when memory pressure is high, collect more aggressively before failing. Verify we don't deadlock-spin in collect-then-allocate-then-collect loops near the limit.
