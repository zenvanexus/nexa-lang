# Phase 3 — FFI: Lua Code Calling C

**Project:** Lua/LuaJIT-shaped scripting language in Zig
**Phase goal:** Ship the FFI library that lets Lua code declare C types, allocate C values, call C functions, and exchange data with native code — without writing any Zig glue per binding. Two paths: a **compile-time static FFI** that leverages Zig's `@cImport` to bind C headers at build time (the unique-to-this-project fast path), and a **runtime dynamic FFI** that parses C declarations from Lua strings at runtime (LuaJIT-compatible fallback).

**Predecessors:** Phase 2's `Userdata` and embedding API. The C-ABI shim from Phase 2 is for *hosts calling Lua*; this phase is the inverse — *Lua calling C*. They share infrastructure (sandboxing, type-marshaling patterns, `comptime` wrapper generation) but are separate libraries.

---

## 1. Goals & Non-Goals

### Goals

- **`cdata`** as a 9th value type, with NaN-boxing tag `0xFFF7`. Represents C values (primitives, pointers, structs, arrays).
- **Static FFI** (the project's distinguishing feature): C headers imported at Zig compile time via `@cImport`, exposed to Lua via `ffi.zig.C`. Calls go through `comptime`-generated wrappers — no libffi, no marshaling overhead beyond Lua-value↔C-value conversion.
- **Dynamic FFI** (LuaJIT-compatible): `ffi.cdef[[ ... ]]` parses C declarations at runtime; `ffi.C.symbol` resolves through `dlopen`/`GetProcAddress`; calls dispatched through libffi (or dyncall).
- **`ffi.metatype`**: Lua metatables attached to C types, so `point:translate(1, 2)` works on a struct.
- **Callbacks**: Lua functions usable where C function pointers are expected, via libffi closures or hand-rolled trampolines.
- **Type introspection**: `sizeof`, `offsetof`, `alignof`, `typeof`, `istype`.
- **Memory management**: GC-owned cdata with optional `__gc`-style finalizers (`ffi.gc`); manual ownership for cdata wrapping external memory.
- **Sandboxing hooks**: hosts can disable FFI entirely, or restrict it to a pre-registered allow-list of libraries / symbols.
- **Performance target for static FFI**: within 2x of native Zig calling C, on microbenchmarks. (Dynamic FFI is allowed to be slower.)

### Non-Goals

- C++ bindings. C only. C++ requires name-mangling support and ABI tracking that's out of scope.
- C preprocessor implementation beyond what `@cImport` (and libclang for the dynamic path) already provide. We don't ship our own preprocessor.
- Inline assembly support. If users need it, they write Zig.
- Full standardese conformance. Pragmatic subset: ISO C99 + common compiler extensions (`__attribute__`, MSVC declspec) where they affect ABI.
- JIT-specialized FFI calls. Phase 5 may revisit; for now, comptime specialization is what we have.
- Yielding from inside an FFI call. Same constraint as Phase 2 — host-to-Lua reentry across yield boundaries is unsupported.

---

## 2. The `cdata` Value Type

Adds tag `0xFFF7` to the NaN-boxing scheme:

| Tag (high 16) | Type        |
|---------------|-------------|
| `0xFFF7`      | **cdata**   |

```zig
pub const CData = struct {
    gc:         GcHeader,
    ctype:      *const CType,
    flags:      packed struct {
        gc_owns:        bool,    // true: GC frees on collection
        has_finalizer:  bool,    // true: finalizer field is valid
        is_indirect:    bool,    // true: `payload` is a pointer to value, not the value
        _padding:       u5,
    },
    finalizer:  ?*Function,      // ffi.gc-attached
    // For primitives (≤ 8 bytes) and small fixed-size types, payload follows inline.
    // For larger types or pointer-to-external-memory, payload is a pointer.
    payload:    [*]u8,           // points either inline (just past the struct) or out
};
```

### Layout discipline

- **Primitive cdata (≤ 8 bytes)** — inline trailing payload. No indirection.
- **Struct/union cdata** — inline trailing payload, sized and aligned per the `CType`.
- **Pointer cdata** — `payload` is the pointer value itself (8 bytes inline).
- **Array cdata (sized)** — inline trailing payload.
- **Reference-only cdata** — `is_indirect = true`, `payload` points to externally-managed memory; GC never frees.

### Identity vs equality

- `==` between two cdata: pointer equality of the underlying address. Two distinct `ffi.new("int")` allocations are not equal even if they hold the same value.
- `__eq` metamethod via `ffi.metatype` overrides this if defined.

---

## 3. The `CType` System

The internal representation of C types. Parallel to Zig's `std.builtin.Type` but for C semantics.

```zig
pub const CType = struct {
    kind:   Kind,
    size:   u32,           // bytes; UINT32_MAX for incomplete types
    align:  u8,            // alignment, power of two
    flags:  packed struct {
        is_const:    bool,
        is_volatile: bool,
        is_complete: bool,
        _pad:        u5,
    },
    info:   Info,

    pub const Kind = enum(u8) {
        void_t,
        integer,
        float,
        pointer,
        array,
        struct_,
        union_,
        function,
        enum_,
        typedef,            // alias to another CType
    };

    pub const Info = union(Kind) {
        void_t: void,
        integer: struct { signed: bool, bits: u8 },             // 8, 16, 32, 64
        float:   struct { bits: u8 },                            // 32, 64 (80 platform-dependent)
        pointer: struct { pointee: *const CType },
        array:   struct { element: *const CType, len: ?u64 },    // null = unsized
        struct_: struct { fields: []const Field, packed_: bool, anon: bool },
        union_:  struct { fields: []const Field },
        function: struct {
            return_type: *const CType,
            params:      []const *const CType,
            variadic:    bool,
            calling_conv: CallConv,
        },
        enum_:   struct { backing: *const CType, values: []const EnumValue },
        typedef: struct { aliased: *const CType, name: []const u8 },
    };

    pub const Field = struct {
        name:    []const u8,
        ctype:   *const CType,
        offset:  u32,
        bit_offset: u8,    // for bitfields; 0xFF if not a bitfield
        bit_width:  u8,
    };

    pub const CallConv = enum(u4) { c, stdcall, fastcall, thiscall };
    pub const EnumValue = struct { name: []const u8, value: i64 };
};
```

### Where CTypes come from

Three sources, all producing the same `*const CType` representation downstream:

1. **Compile-time `@cImport`** — Zig parses C headers, we walk the resulting Zig type info and emit `CType` table entries at Zig compile time. These are `comptime`-known and live in read-only data.
2. **Runtime `ffi.cdef[[ ... ]]`** — our own C declaration parser produces fresh `CType`s allocated under the GC. Cached in a hash table to dedupe.
3. **Built-in primitives** — `int`, `long`, `size_t`, etc., pre-registered at VM init, sized per the host platform.

---

## 4. Static FFI — the Compile-Time Fast Path

This is the angle that makes Zig genuinely the right language for this project. LuaJIT's FFI is great because Mike Pall hand-built a C parser, ABI tables, and code generator. We get most of that for free from `@cImport` running at *Zig* compile time.

### How a host imports C headers

The host writes Zig glue once (per VM build):

```zig
const c = @cImport({
    @cInclude("stdio.h");
    @cInclude("stdlib.h");
    @cInclude("string.h");
});

const ffi_imports = lua.ffi.staticImports(.{
    .printf  = c.printf,
    .malloc  = c.malloc,
    .free    = c.free,
    .strlen  = c.strlen,
    .FILE    = c.FILE,
});

try lua.ffi.registerStatic("c", ffi_imports);
```

Now Lua code can do:

```lua
local c = require("ffi").zig.c
local n = c.printf("hello %d\n", 42)
local p = c.malloc(1024)
c.free(p)
```

### What `staticImports` does

At Zig compile time, `staticImports` is a generic function that:

1. Walks the passed struct's fields.
2. For each field that's a `fn`, generates a per-signature wrapper that:
   - Reads N Lua values from the VM stack.
   - Converts each to the C parameter type (with type-checking).
   - Calls the C function natively.
   - Converts the return value back to a Lua value.
3. For each field that's a `type` (struct, enum, typedef), constructs a `CType` table entry pointing at the Zig type's introspected layout.
4. Returns a `StaticImportTable` consumable by the runtime.

Sketch:

```zig
pub fn staticImports(comptime decls: anytype) StaticImportTable {
    const Decls = @TypeOf(decls);
    const fields = @typeInfo(Decls).Struct.fields;

    comptime var entries: [fields.len]ImportEntry = undefined;
    inline for (fields, 0..) |field, i| {
        const value = @field(decls, field.name);
        const T = @TypeOf(value);
        switch (@typeInfo(T)) {
            .Fn => entries[i] = makeFnEntry(field.name, value),
            .Type => entries[i] = makeTypeEntry(field.name, value),
            else => @compileError("unsupported FFI import: " ++ field.name),
        }
    }
    return .{ .entries = &entries };
}

fn makeFnEntry(comptime name: []const u8, comptime f: anytype) ImportEntry {
    const F = @TypeOf(f);
    const info = @typeInfo(F).Fn;

    const wrapper = struct {
        fn call(vm: *VM, n_args: u32) !u32 {
            if (n_args != info.params.len and !info.is_var_args) return error.WrongArgCount;

            // Convert each Lua value to the C type.
            var tuple: std.meta.ArgsTuple(F) = undefined;
            inline for (info.params, 0..) |p, i| {
                tuple[i] = try luaToC(p.type.?, vm.regs[i]);
            }

            // Native call. Variadic gets a manual va_list assembly path.
            const result = if (info.is_var_args)
                @compileError("variadic — see §13")
            else
                @call(.auto, f, tuple);

            // Convert back.
            if (info.return_type.? == void) return 0;
            vm.regs[0] = try cToLua(info.return_type.?, result);
            return 1;
        }
    }.call;

    return .{ .name = name, .kind = .function, .ptr = @ptrCast(&wrapper), .ctype = comptime makeCTypeForFn(F) };
}
```

### What this buys us

For any C function whose signature is known at Zig compile time:

- **No libffi.** The wrapper calls the C function via Zig's normal `extern "C"` calling convention. Whatever the platform ABI is, the Zig compiler already handles it.
- **No marshaling table.** Each wrapper is specialized to the exact signature.
- **No runtime type parsing.** The `CType` is built at compile time and lives in `.rodata`.
- **Inlining-friendly.** Hot wrappers can be small and hot-cache-resident.

The remaining cost is **the Lua-value↔C-value conversion**, which is unavoidable in any FFI design. We pay nothing extra for the call itself.

### What it doesn't cover

- C functions discovered at runtime (loaded from a .so via `dlopen`) — those go through dynamic FFI.
- C declarations that come from data the host doesn't control at build time — same.
- Declarations that LuaJIT-compatible code defines via `ffi.cdef` strings.

For those cases, we have:

---

## 5. Dynamic FFI — the Runtime Path

Matches LuaJIT's API. The user writes `ffi.cdef[[ ... ]]` at Lua runtime and gets `ffi.C.foo` afterward.

### `ffi.cdef`

Parses a string of C declarations. Supports:

- `typedef`
- struct, union, enum declarations (forward and complete)
- function prototypes
- `const`, `volatile` qualifiers
- pointer and array types
- bitfields in structs
- `__attribute__((...))` for `packed`, `aligned`, calling-convention attributes (we recognize a useful subset)
- Common compiler extensions: `_Bool`, `__int64`, `size_t`, `ptrdiff_t`, etc.

Implementation: hand-written C declaration parser, ~2k lines of Zig. References LuaJIT's `lj_cparse.c` for the algorithm; we don't need full C, just declarations.

This is the largest single piece of new code in Phase 3. Worth it because it's the LuaJIT-compatibility surface — Lua code written for LuaJIT FFI works without changes.

### `ffi.load(name)`

Loads a shared library. Returns a namespace object whose `__index` resolves symbols via `dlsym` / `GetProcAddress`.

```lua
local lib = ffi.load("z")          -- libz.so / z.dll / libz.dylib
local sz = lib.compressBound(1024)  -- if compressBound was previously cdef'd
```

The lookup path:

1. `ffi.load("z")` → `dlopen("libz.so")` (Linux), `dlopen("libz.dylib")` (macOS), `LoadLibrary("z.dll")` (Windows). Returns a namespace cdata.
2. `lib.compressBound` → `dlsym(handle, "compressBound")` returns a function pointer. We look up `compressBound` in the cdef'd type table to get its signature. Pair them into a callable cdata.
3. Calling the cdata invokes via libffi using the signature.

### libffi integration

For runtime-typed calls, we use libffi as a vendored dependency. libffi handles:

- Building a `ffi_cif` (call interface) from the type signature.
- Marshaling arguments per the platform ABI (SysV, Windows x64, AArch64 AAPCS).
- Invoking the function pointer.
- Returning results.

We considered dyncall (lighter, no GPL concerns) but libffi is more battle-tested and has Windows variadic support. Worth the dependency. License is BSD-style.

```zig
fn callViaFfi(cd: *CData, args: []const Value) ![]Value {
    const fn_type = cd.ctype;  // kind == .function
    const cif = try buildOrCacheCif(fn_type);
    const fn_ptr = cd.payloadAsFnPtr();

    var arg_buf: [MAX_ARGS][8]u8 align(16) = undefined;
    var arg_ptrs: [MAX_ARGS]*anyopaque = undefined;
    inline for (fn_type.info.function.params, 0..) |p, i| {
        try luaToCRaw(p, args[i], &arg_buf[i]);
        arg_ptrs[i] = &arg_buf[i];
    }

    var rvalue: [16]u8 align(16) = undefined;
    ffi.ffi_call(cif, fn_ptr, &rvalue, &arg_ptrs);

    return cToLuaRaw(fn_type.info.function.return_type, &rvalue);
}
```

`buildOrCacheCif` memoizes — once a signature has produced a `ffi_cif`, subsequent calls reuse it.

---

## 6. Calling — Fast Path vs Slow Path

Decision tree at call site:

```
ffi cdata called as function
    ↓
Is the CType statically registered (came from comptime @cImport)?
    ├── Yes → direct dispatch to comptime wrapper. No libffi.
    └── No  → libffi dispatch via cached ffi_cif.
```

The fast path is detected by a flag on the `CType` (`is_static_wrapper: bool`) and a function pointer to the wrapper. If set, the call site dispatches the wrapper directly with the same signature `fn (vm: *VM, n_args: u32) !u32` used by host functions.

### Performance characteristics

| Path                                         | Per-call overhead                    |
|----------------------------------------------|--------------------------------------|
| Static FFI, primitive args/returns           | ~10 ns + native call                 |
| Static FFI, struct args (small, register)    | ~20 ns + native call                 |
| Static FFI, struct args (large, by ref)      | ~50 ns + native call                 |
| Dynamic FFI (libffi), primitive              | ~150 ns + native call                |
| Dynamic FFI (libffi), struct                 | ~300 ns + native call                |

Numbers are rough — measure on the actual platform. The point is that static FFI buys a real order of magnitude over dynamic FFI on small calls. For `printf("hello\n")`-style microbenchmarks, that's the difference between LuaJIT-class performance and "noticeably slower than C."

---

## 7. Memory Management

### GC-owned cdata (`ffi.new`)

```lua
local p = ffi.new("int[10]")     -- zeroed by default
local q = ffi.new("int[10]", {1,2,3,4,5,6,7,8,9,10})
```

- Allocated via `Gc.createWithTrailing(CData, payload_size)`.
- Owned by GC. Freed on collection if unreachable.
- Memory lives inline in the `CData` struct (no second indirection).

### External cdata (`ffi.cast`)

```lua
local p = ffi.cast("char *", some_pointer)
```

- Wraps a pointer the user already has.
- `is_indirect = true`, `gc_owns = false`. Never freed by GC.
- Lifetime is the user's responsibility.

### Finalized cdata (`ffi.gc`)

```lua
local fp = ffi.C.fopen("data.txt", "r")
ffi.gc(fp, ffi.C.fclose)
```

- Attaches a finalizer to a cdata.
- Stored in `CData.finalizer`.
- Runs in the same finalizer queue established for `__gc` in Phase 2.
- Order: cdata finalizers run after `__gc` Lua-table finalizers, before anything else.

### Stack-allocated cdata — deferred

LuaJIT's FFI has a notion of stack-bound cdata for short-lived intermediates (avoids GC pressure in tight loops). We defer this; the GC's allocation path is fast enough for Phase 3, and the optimization is messy to get right (lifetime analysis at the bytecode level).

---

## 8. `ffi.metatype` — Lua Methods on C Types

The single most ergonomic feature LuaJIT's FFI offers.

```lua
local Point = ffi.metatype("struct point", {
    __index = {
        translate = function(self, dx, dy)
            self.x = self.x + dx
            self.y = self.y + dy
        end,
        magnitude = function(self)
            return math.sqrt(self.x*self.x + self.y*self.y)
        end,
    },
    __add = function(a, b)
        return Point(a.x + b.x, a.y + b.y)
    end,
})

local p = Point(3, 4)
p:translate(1, 1)
print(p:magnitude())     -- 5.66
```

### Implementation

- A `CType` carries an optional `*Table` `metatable` field.
- `ffi.metatype(ct, mt)` sets it (and freezes — only one metatype per ctype).
- All metamethod dispatch (from `TGETV`, `ADD`, `EQ`, etc. opcodes) checks the cdata's `CType.metatable` after the regular fast paths fail.
- `Point(3, 4)` is constructor sugar — `ffi.metatype` returns a callable that proxies to `ffi.new` with the args.

Performance note: in LuaJIT, the JIT can specialize metatype method calls down to direct loads/stores on the underlying C struct fields. We don't have a JIT in Phase 3, so method calls go through the ordinary metamethod dispatch — slower than LuaJIT but still much faster than userdata-equivalent code in plain Lua.

---

## 9. The `ffi` Library API

Full surface, in one table:

| Symbol                        | Behavior                                                |
|-------------------------------|---------------------------------------------------------|
| `ffi.cdef(s)`                 | Parse C declarations from string                        |
| `ffi.C`                       | Default symbol namespace (current process)              |
| `ffi.load(name [, global])`   | Load shared library                                     |
| `ffi.new(ct, ...)`            | Allocate cdata                                          |
| `ffi.typeof(decl)`            | Returns ctype constructor                               |
| `ffi.cast(ct, x)`             | Type cast                                               |
| `ffi.metatype(ct, mt)`        | Attach metatable to ctype                               |
| `ffi.gc(cd, fn)`              | Attach finalizer; passing `nil` removes                 |
| `ffi.sizeof(ct [, len])`      | Size in bytes                                           |
| `ffi.alignof(ct)`             | Alignment in bytes                                      |
| `ffi.offsetof(ct, field)`     | Field offset in bytes                                   |
| `ffi.istype(ct, x)`           | Type predicate                                          |
| `ffi.string(ptr [, len])`     | C bytes → Lua string                                    |
| `ffi.copy(dst, src, len)`     | memcpy                                                  |
| `ffi.fill(dst, len [, c])`    | memset                                                  |
| `ffi.errno([newval])`         | errno read/write                                        |
| `ffi.os`                      | "Linux" / "Windows" / "OSX" / etc.                      |
| `ffi.arch`                    | "x64" / "arm64" / etc.                                  |
| `ffi.abi(param)`              | ABI predicate: "le", "be", "win", "32bit", "64bit"      |
| **`ffi.zig.C`**               | **Static-import namespace (our extension)**             |
| **`ffi.zig.types`**           | **Static type registry namespace**                      |

`ffi.zig.*` is our extension; LuaJIT-compatible code uses `ffi.cdef` + `ffi.C`.

---

## 10. Callbacks — Lua Functions as C Function Pointers

The hardest piece of FFI. A C library expects a function pointer; we want to pass it a Lua function.

### Approach

Use libffi closures. libffi can allocate executable trampolines that, when called as native C code, dispatch into a chosen handler.

```zig
fn makeCallback(vm: *VM, lua_fn: *Function, sig: *const CType) !*anyopaque {
    var cif: ffi.ffi_cif = undefined;
    try buildCif(&cif, sig);

    var closure_addr: *anyopaque = undefined;
    const closure: *ffi.ffi_closure = ffi.ffi_closure_alloc(@sizeOf(ffi.ffi_closure), &closure_addr);
    if (closure == null) return error.OutOfMemory;

    const ctx = try vm.gc.backing.create(CallbackCtx);
    ctx.* = .{ .vm = vm, .lua_fn = lua_fn, .sig = sig, .closure = closure };

    if (ffi.ffi_prep_closure_loc(closure, &cif, callbackTrampoline, ctx, closure_addr) != ffi.FFI_OK) {
        return error.FfiError;
    }

    return closure_addr;
}

fn callbackTrampoline(cif: *ffi.ffi_cif, ret: *anyopaque, args: [*]*anyopaque, user: *anyopaque) callconv(.C) void {
    const ctx: *CallbackCtx = @ptrCast(@alignCast(user));
    // Convert C args → Lua values
    // Call ctx.lua_fn
    // Convert Lua return → C return
}
```

### Lifetime management

Callbacks anchor themselves to the cdata that holds them. When the cdata is collected, the closure is freed. Users must keep the callback cdata alive for as long as the C library will call back; this is a known FFI footgun and matches LuaJIT's behavior.

### Without libffi

The static FFI fast path doesn't help here — callbacks fundamentally need executable memory generated at runtime. No way around libffi (or a hand-rolled trampoline allocator) for this feature.

---

## 11. Library Loading

### Sandboxing

The host can opt-in or opt-out of:

```zig
pub const FfiSandboxOptions = struct {
    enabled:           bool = true,
    allow_dlopen:      bool = false,
    allowed_libraries: []const []const u8 = &.{},  // names allow-list
    allow_callbacks:   bool = true,
    allow_runtime_cdef: bool = true,                 // false ⇒ static-only mode
    static_imports:    StaticImportTable = .empty,
};
```

A locked-down host (e.g. game scripting where security matters) sets `allow_dlopen = false`, `allow_runtime_cdef = false`, and only ships pre-vetted `static_imports`. In that mode the FFI is "compile-time-only" and the attack surface is minimal — Lua code can only call functions the host explicitly registered.

A development host with `allow_dlopen = true, allowed_libraries = &.{ "z", "ssl" }` permits `ffi.load` for those names but rejects others.

A fully-open host has the LuaJIT default. Same threat model: FFI is unrestricted privileged code execution from Lua.

### Symbol resolution

```zig
fn resolveSymbol(lib: *Library, name: []const u8) !*anyopaque {
    return switch (builtin.os.tag) {
        .linux, .freebsd, .openbsd, .netbsd, .macos => blk: {
            const ptr = std.c.dlsym(lib.handle, name.ptr) orelse return error.SymbolNotFound;
            break :blk ptr;
        },
        .windows => blk: {
            const ptr = std.os.windows.kernel32.GetProcAddress(lib.handle, name.ptr) orelse return error.SymbolNotFound;
            break :blk @ptrCast(ptr);
        },
        else => return error.UnsupportedPlatform,
    };
}
```

---

## 12. Type Introspection

Implementations are mechanical once `CType` is in place:

- `ffi.sizeof(ct)` → `ct.size`
- `ffi.alignof(ct)` → `ct.align`
- `ffi.offsetof(ct, field_name)` → linear scan of struct fields, return `field.offset`
- `ffi.istype(ct, x)` → check x is cdata and `x.ctype` matches `ct` (with typedef unwrapping)
- `ffi.typeof("char[?]")` → parses the type expression, returns a constructor cdata that allocates with the supplied length

`typeof` on a parameterized array (`"char[?]"`) returns a closure that takes the missing dimension as an argument when used as a constructor:

```lua
local CharArr = ffi.typeof("char[?]")
local buf = CharArr(64)   -- 64-byte char array
```

---

## 13. Variadic, Struct Returns, Edge Cases

### Variadic functions

`printf` and friends. Calling convention is platform-specific.

- **Static FFI**: Zig handles variadic args via `@call` and `@cVaArg`. We generate a wrapper that builds an `extern "C" var_args` call. Restriction: varargs must be primitive (int, double, pointer) — no struct varargs.
- **Dynamic FFI**: libffi supports variadic via `ffi_prep_cif_var`. We pass each variadic arg's type explicitly per call site.

### Struct return values

Struct returns are tricky on all calling conventions:

- Small structs (≤ 16 bytes) returned in registers (RAX/RDX on SysV).
- Large structs returned via hidden first argument (caller allocates space, callee writes there).

For static FFI, Zig's `extern "C"` already handles this correctly — we just call. For dynamic FFI, libffi handles it via the `ffi_cif`. No special FFI code needed; the abstraction layers below us solve this.

### Pointer arithmetic

`p + n` on pointer cdata advances by `n * sizeof(*p)` (C semantics). Implemented via the `__add` metamethod on pointer ctypes, registered automatically when a pointer ctype is created.

### NULL

`ffi.cast("void*", 0)` produces a NULL pointer cdata. Comparison: `p == nil` is **false** (different value types); use `p == ffi.NULL` or `p == ffi.cast("void*", 0)`. This matches LuaJIT.

### Bitfields

```c
struct { unsigned int a : 3; unsigned int b : 5; };
```

Layout per C bitfield rules. Read/write goes through bit-shift wrappers. Subset of bitfield use cases; we won't support all the GCC-specific corner cases.

---

## 14. Testing Strategy

Six tiers:

1. **Unit tests** for the C declaration parser (300+, edge cases, error messages).
2. **`CType` invariants**: size/align must match what Zig computes for `extern struct` versions; `offsetof` must match `@offsetOf`. Fuzzed with random struct layouts.
3. **Static FFI smoke tests**: import a curated set of headers (`string.h`, `stdlib.h`, `math.h`), verify common functions work end-to-end.
4. **Dynamic FFI tests**: a small bundled C library (built as part of the test harness) with known signatures; load via `ffi.load`, exercise.
5. **LuaJIT FFI compatibility**: port LuaJIT's FFI test suite. Target ≥ 90% pass rate; document divergences.
6. **Fuzz**: random C declarations through `ffi.cdef`; should never crash, always produce a parse error or a valid `CType`.
7. **Differential**: same code path through static and dynamic FFI (where both work) — outputs identical.

### Memory-safety stress

- Allocate many cdata, drop refs, GC. No use-after-free.
- Run callbacks under a callback-stress test that calls a Lua callback from C 10⁶ times. No leaks.
- libffi closure exhaustion: allocate closures until failure; verify graceful error.

---

## 15. Exit Criteria

- [ ] `cdata` value type integrated; NaN-boxing tag `0xFFF7`; round-trips through GC, equality, hashing
- [ ] Static FFI: compile-time `staticImports` works for primitives, pointers, structs, function pointers
- [ ] Static FFI: a small curated set of libc headers is importable and works end-to-end (`printf`, `malloc`/`free`, `strlen`, `strcmp`, `qsort` with Lua callback)
- [ ] Dynamic FFI: `ffi.cdef` parser handles all of LuaJIT's FFI test suite declarations
- [ ] Dynamic FFI: `ffi.load` + `ffi.C` symbol resolution on Linux, macOS, Windows
- [ ] libffi integration with cached `ffi_cif`s
- [ ] `ffi.metatype` works, including `__index`, `__newindex`, `__add`, `__eq`, `__tostring`, `__call`
- [ ] Callbacks (libffi closures) work for primitive-only signatures on x86-64 and AArch64
- [ ] LuaJIT FFI compatibility: ≥ 90% of LuaJIT FFI test suite passes; documented divergences for the rest
- [ ] Performance: static FFI within 2x of native Zig→C call on a microbenchmark
- [ ] Sandboxing: locked-down mode (no `dlopen`, no runtime `cdef`) is enforceable
- [ ] No leaks under `GeneralPurposeAllocator{ .safety = true }`; libffi closure pool drains cleanly on VM shutdown
- [ ] `zig fmt` clean, `zig build test` green

---

## 16. Deliverables

| Path                              | Contents                                              |
|-----------------------------------|-------------------------------------------------------|
| `src/ffi/cdata.zig`               | `CData` value type, NaN-boxing integration            |
| `src/ffi/ctype.zig`               | `CType` representation, predicates, equality          |
| `src/ffi/static.zig`              | `staticImports`, comptime wrapper generation          |
| `src/ffi/cparse.zig`              | C declaration parser (~2k lines)                      |
| `src/ffi/dispatch.zig`            | Call dispatch (static fast path / libffi slow path)   |
| `src/ffi/libffi_glue.zig`         | libffi binding, `ffi_cif` cache                       |
| `src/ffi/loader.zig`              | `ffi.load`, `dlopen`/`GetProcAddress`                 |
| `src/ffi/callback.zig`            | libffi closure allocation, trampolines                |
| `src/ffi/metatype.zig`            | `ffi.metatype` machinery                              |
| `src/ffi/lib_ffi.zig`             | The `ffi` Lua library, exposed as a stdlib module     |
| `src/ffi/api_zig.zig`             | Zig-side API for hosts to register static imports     |
| `vendor/libffi/`                  | Vendored libffi (or git submodule)                    |
| `tests/ffi/cparse/`               | C parser tests (300+)                                 |
| `tests/ffi/static/`               | Static FFI tests                                      |
| `tests/ffi/dynamic/`              | Dynamic FFI tests with bundled C lib                  |
| `tests/ffi/luajit_compat/`        | Ported LuaJIT FFI test suite                          |
| `tests/ffi/callbacks/`            | Callback stress tests                                 |
| `bench/ffi/`                      | Microbenchmarks: static vs dynamic vs LuaJIT vs native|
| `examples/ffi_libz.lua`           | Real-world example: zlib via FFI                      |
| `examples/ffi_static_libc.zig`    | Host code registering libc statically                 |
| `docs/phase-3-postmortem.md`      | Decisions, surprises, inputs to Phase 4               |

---

## 17. Estimated Effort

3.5–4.5 months focused.

| Component                              | Estimate    |
|----------------------------------------|-------------|
| `cdata` type + NaN-boxing integration  | 1 week      |
| `CType` representation + introspection | 1.5 weeks   |
| Static FFI: comptime wrapper generation| 3–4 weeks   |
| C declaration parser                   | 4–5 weeks   |
| libffi integration + dispatch          | 3 weeks     |
| Library loader (cross-platform)        | 1.5 weeks   |
| `ffi.metatype`                         | 1.5 weeks   |
| Callbacks                              | 2–3 weeks   |
| LuaJIT compatibility tests + fixes     | 3 weeks     |
| Sandboxing + locked-down mode          | 1 week      |
| Performance work to hit 2x target      | 1.5 weeks   |
| Documentation + examples               | 1 week      |
| Postmortem + cleanup                   | 1 week      |

---

## 18. Inputs to Phase 4

Phase 4 (optimization: inline caches, table shape tracking, superinstructions, incremental GC, weak tables) inherits:

- The static-FFI fast path is one of the hot dispatch sites that benefits from superinstruction fusion (`GGET ffi; TGETS C; TGETS printf; CALL` → fused FFI-call superinstruction)
- Cdata access patterns (`p.field` reads, `p.field = x` writes) are excellent candidates for inline caches — same struct field accessed in a loop is the canonical IC win
- The libffi `ffi_cif` cache is a precedent for general inline-cache architecture
- `ffi.metatype` method calls suffer from the same overhead as ordinary metamethod calls — Phase 4's IC work should help both uniformly
- `ffi.gc`-attached finalizers must adapt cleanly to incremental GC's atomic phase

---

## 19. Open Questions

1. **libffi vs dyncall vs hand-rolled.** libffi is the safe choice but adds a vendored dependency. dyncall is lighter and more permissive (zlib license vs libffi's BSD). Hand-rolled is fastest for small platforms but doesn't scale. Default to libffi; document the trade-off.

2. **C parser scope.** A full C parser is huge. LuaJIT's `lj_cparse.c` is ~2k lines and handles only declarations, not statements. We follow that scope — declarations only. Verify this is enough for the LuaJIT FFI test suite and for typical real-world headers (zlib, libcurl, sqlite3 declarations).

3. **`@cImport` in user code vs in our build.** Static FFI imports happen in *host* Zig code (the embedder writes the `staticImports` call). This means each host has a different set of static imports — there's no one-size-fits-all bundle. Document this clearly; consider shipping a default `staticImports` covering libc that hosts can opt into.

4. **Callback stack size.** libffi closures running on the C stack call back into the VM. The VM dispatch loop expects a particular stack discipline; verify that libffi-driven reentry doesn't blow the C stack on deeply nested callbacks.

5. **Bitfield endianness.** Bitfield layout depends on the compiler and platform. We match the host platform's behavior (whatever Zig's `extern struct` does). Document divergences from LuaJIT.

6. **Pointer arithmetic vs array semantics.** In C, `int p[10]; p+1` and `int *p; p+1` behave the same way; `&p[0]+1` differs. Lua doesn't have `[]`-vs-`*` distinction in expressions. Decide a consistent rule and document.

7. **`ffi.NULL` identity.** A single sentinel cdata for NULL pointers, deduplicated. Allocated once at VM init, treated as immutable. Verify GC doesn't try to collect it.

8. **Static-import naming collisions.** If a host registers `printf` statically *and* the user does `ffi.cdef "int printf(const char*, ...);"`, what wins? Default: static imports take precedence; runtime cdef errors with a "type already defined" message.

9. **Performance regression risk in the VM hot path.** The cdata value type adds a tag check to every metamethod-relevant opcode. Benchmark Phase 1 / Phase 2 corpora before and after; expect ≤ 5% regression on non-FFI workloads.

10. **Memory for the C parser cache.** Many cdef'd types live for the program's lifetime. They're GC-managed but rarely collected. Worth tracking total cdef'd bytes and warning if it grows unbounded — long-running daemons that re-cdef the same types could leak them otherwise.
