# Phase 3.5 — C Declaration Parser Spec

**Project:** Lua/LuaJIT-shaped scripting language in Zig
**Spec scope:** The C declaration parser that powers `ffi.cdef[[ ... ]]` at runtime. Implementation-ready depth: lexer, declaration-specifier parsing, declarator parsing, compound types, bitfields, constant expressions, layout calculation, error recovery.
**Relationship to Phase 3:** Companion document. Phase 3 §5 covers what the dynamic FFI does at the API level and roughly how the parser fits in; this doc covers it at the level needed to *implement* the parser without surprises.

---

## 1. Goals & Non-Goals

### Goals

- Parse the subset of C declarations exercised by real-world FFI use: typedefs, struct/union/enum declarations, function prototypes, primitive and compound types, qualifiers, pointers, arrays, function pointers, bitfields.
- Compatible with **LuaJIT's `ffi.cdef`**: code written for LuaJIT FFI parses without modification.
- Produce `*const CType` values (Phase 3 §3) that are bit-compatible with the host platform's C ABI: `sizeof`, `alignof`, `offsetof` match what a native C compiler would compute.
- Hash-cons types so structurally-identical types share storage and compare by pointer.
- Robust error messages: source position, expected-vs-found, recovery to the next declaration.
- ~2k lines of Zig, single-pass, no preprocessor, no runtime dependencies beyond `std`.

### Non-Goals

- Full ISO C parser. We parse declarations, not statements, expressions outside constant contexts, or function bodies.
- C++. No namespaces, no classes, no templates, no references, no `auto`, no member functions.
- C preprocessor. Caller must run `cpp` (or equivalent) externally if their headers contain `#include`, `#if`, complex `#define`. We accept a flat declaration stream.
- K&R-style function declarations: `int f(a, b) int a; int b; { ... }`. Only ANSI prototypes.
- Variable-length arrays (`int x[n]` where `n` isn't a constant). Reject with error.
- C11 atomics (`_Atomic`), generics (`_Generic`), thread-locals (`_Thread_local`).
- Recovery sophisticated enough to give multiple errors per declaration. One error → skip to next `;` or `}`.
- Cross-translation-unit linking, name mangling, weak symbols, sections — all handled by the FFI runtime (Phase 3 §11), not the parser.

---

## 2. Scope of Supported C

A precise statement of what the parser accepts.

### Tokens

- **Keywords (32):** `auto break case char const continue default do double else enum extern float for goto if inline int long register restrict return short signed sizeof static struct switch typedef union unsigned void volatile while _Bool`
  - Many of these are syntactically reserved but semantically rejected (`auto`, `register`, `goto`, `case`, `default`, `do`, `for`, `if`, `else`, `return`, `switch`, `while`, `break`, `continue`, `inline`, `restrict`) — we accept them in declarations contexts where they could appear, ignore them otherwise.
- **Identifiers:** `[A-Za-z_][A-Za-z0-9_]*`
- **Numeric literals:** decimal, octal (`0...`), hex (`0x...`), with optional `U`/`L`/`LL`/`UL`/`ULL`/`F` suffixes
- **Character literals:** `'a'`, `'\n'`, `'\xFF'`, `'\123'` — evaluate to integer
- **String literals:** `"..."` — accepted in `__attribute__` arguments, otherwise rejected in declarations
- **Punctuators:** `{ } ( ) [ ] ; , : * & . -> ... ? = + - ~ ! / % < > == != <= >= && || << >> ^ |`
  - `=` only legal in enum value initializers and array-size constant expressions
  - `?:`, `&&`, `||` legal in constant expressions

### Compiler extensions

- **`__attribute__((...))`:** GCC syntax. Recognized attributes:
  - `packed` — disables structure padding
  - `aligned(N)` — sets alignment
  - `cdecl`, `stdcall`, `fastcall`, `thiscall` — calling conventions (mainly Windows)
  - `unused`, `deprecated`, `noreturn`, `pure`, `const` — accepted, ignored (semantic-only)
  - `mode(...)`, `vector_size(...)` — rejected with error
- **`__declspec(...)`:** MSVC syntax.
  - `align(N)` — sets alignment
  - `dllimport`, `dllexport` — accepted, ignored
- **`__cdecl`, `__stdcall`, `__fastcall`, `__thiscall`:** calling-convention keywords. Treated as attributes.
- **`__int8`, `__int16`, `__int32`, `__int64`:** MSVC fixed-width types.
- **`__extension__`:** GCC marker. Accepted, ignored (skip past it).
- **`__inline__`, `__inline`:** Variants of `inline`. Accepted as `inline`.
- **`__restrict__`, `__restrict`:** Variants of `restrict`. Accepted as `restrict`.

### Declarations supported

```c
// Typedefs
typedef int int32;
typedef struct foo Foo;
typedef int (*FnPtr)(int, char *);

// Variable / function declarations
int x;
extern int y;
static const char *str;
int printf(const char *fmt, ...);

// Struct, union, enum
struct point { int x; int y; };
struct __attribute__((packed)) packed_t { char a; int b; };
union u { int i; float f; };
enum color { RED, GREEN, BLUE = 5, MAGENTA };

// Function pointers
void (*signal_handler)(int);

// Arrays
int arr[10];
char buf[256];
int matrix[3][4];

// Bitfields
struct flags {
    unsigned int a : 1;
    unsigned int b : 3;
    unsigned int   : 0;   // alignment break
    unsigned int c : 4;
};

// Forward declarations
struct opaque;
typedef struct opaque opaque_t;
```

---

## 3. Architecture

```
input bytes (Lua string from ffi.cdef)
    ↓  Lexer
[Token]
    ↓  DeclSpecParser  → DeclSpec (base type + qualifiers + storage class)
    ↓  DeclaratorParser → Declarator (name + chain of modifiers)
    ↓  apply()          → *const CType + identifier
    ↓  bind into Namespace (typedef, tag, or value)
```

Single-pass, no AST intermediate. The parser builds `CType` values directly as it reads.

The two parsers (DeclSpec and Declarator) operate on the same token stream, sequentially. A declaration is `<spec> <declarator> ( ',' <declarator> )* ';'`. Multiple declarators share a DeclSpec — `int x, *y, z[10];` declares three names with the same base type.

---

## 4. Lexer

Hand-rolled, single forward scan with one-byte lookahead. Produces `Token` values:

```zig
pub const Token = struct {
    kind: Kind,
    src:  []const u8,    // slice into input
    line: u32,
    col:  u32,
    // Numeric literals: decoded value lives here
    num: union { unsigned: u64, signed: i64, float: f64 },
    num_kind: NumKind,   // for numeric literals only
};

pub const Kind = enum {
    // Categories
    ident,
    keyword,            // matched against keyword table
    num_lit,
    char_lit,
    str_lit,
    punct,              // followed by which punctuator in `Punct`
    eof,
    // Punctuators are subdivided
};
```

### Keyword recognition

A `comptime` perfect-hash table:

```zig
const keywords = comptime blk: {
    var t: [256]?Keyword = .{null} ** 256;
    t[hash("int")]      = .int_;
    t[hash("char")]     = .char_;
    t[hash("struct")]   = .struct_;
    // ... 32 keywords
    break :blk t;
};

inline fn hash(s: []const u8) u8 {
    var h: u32 = 0;
    for (s) |c| h = h *% 31 +% c;
    return @truncate(h);
}
```

If two keywords collide on the perfect hash, the comptime initializer fails and you nudge the hash function. Same trick the Phase 4 superinstruction generator will use.

### Numeric literals

ANSI C numeric literals with suffixes:

| Pattern              | Type             |
|----------------------|------------------|
| `123`                | `int` (or larger if doesn't fit) |
| `123U`               | `unsigned int`   |
| `123L`               | `long`           |
| `123UL`, `123LU`     | `unsigned long`  |
| `123LL`              | `long long`      |
| `123ULL`             | `unsigned long long` |
| `0x...`              | hex; type follows the same suffix rules |
| `0...`               | octal            |
| `123.0`, `1e10`      | `double`         |
| `1.0F`, `1.0f`       | `float`          |
| `1.0L`               | `long double`    |
| `0x1.8p3`            | hex float        |

Decoded into `Token.num` at lex time so the parser doesn't redo the work.

### String and character literals

Standard C escapes: `\a \b \f \n \r \t \v \\ \" \' \xHH \ddd \0`. String literals stored verbatim (the slice in source); the parser interprets escapes only when needed (e.g., inside `__attribute__` arguments).

### Trigraphs

Not supported. Rejected silently — modern code doesn't use them, and they'd complicate the lexer with the buffer rewriting they require.

---

## 5. CType Representation

Recap from Phase 3 §3, with the implementation-relevant details:

```zig
pub const CType = struct {
    kind:  Kind,
    size:  u32,
    align: u8,
    flags: Flags,
    info:  Info,

    pub const Kind = enum(u8) {
        void_t, integer, float, pointer, array,
        struct_, union_, function, enum_, typedef,
    };
    // ... see Phase 3 §3
};
```

### Hash-consing

Every `CType` is interned. Two structurally-identical types share one `*const CType` pointer; equality is `==` on the pointer.

```zig
pub const TypeCache = struct {
    arena:  std.heap.ArenaAllocator,
    map:    std.HashMap(CTypeKey, *const CType, KeyContext, 80),

    pub fn intern(self: *TypeCache, candidate: CType) *const CType {
        const key = CTypeKey.from(candidate);
        if (self.map.get(key)) |existing| return existing;
        const slot = self.arena.allocator().create(CType) catch unreachable;
        slot.* = candidate;
        self.map.put(key, slot) catch unreachable;
        return slot;
    }
};
```

The `CTypeKey` hashes structural content (kind + size + align + info), not identity. Field arrays in structs and parameter arrays in functions are hashed deeply.

**Cycle handling.** A struct can be self-referential via a pointer (`struct list { struct list *next; };`). During parsing of the struct body, the struct's own `*const CType` is registered as forward-declared (size = `UINT32_MAX`, complete = false) so the inner `struct list *` resolves. Once the body is parsed, we call `intern` on the now-complete type; if a structurally-identical complete struct already exists, dedupe.

---

## 6. DeclSpec — Declaration Specifier Parsing

A declaration specifier is the prefix of a declaration that establishes the *base* type and qualifiers, before any declarator-introduced modifications.

### What a DeclSpec contains

```zig
pub const DeclSpec = struct {
    base_type:    *const CType,
    storage:      enum { none, typedef_, extern_, static_, auto_, register_ } = .none,
    is_const:     bool = false,
    is_volatile:  bool = false,
    is_restrict:  bool = false,
    is_inline:    bool = false,
    align_attr:   ?u8 = null,
    packed_attr:  bool = false,
    calling_conv: ?CallConv = null,
};
```

### The grammar

```
declaration_specifier := (storage_class | type_qualifier | type_specifier | function_specifier | attribute)+
type_specifier := primitive_combo | struct_or_union_spec | enum_spec | typedef_name
```

The complication: `type_specifier` can be a *combination* of primitive keywords. `unsigned long long int` is one type. `signed char` is another. The combinations follow rules:

- Exactly one of: `void`, `char`, `int`, `float`, `double`, `_Bool`, or a typedef name, or a struct/union/enum spec.
- Optionally: `signed` or `unsigned` (mutually exclusive).
- Optionally: `short` or `long` or `long long` (with restrictions: `short` only with `int`, `long` with `int` or `double`, etc.).

### Implementation: bitset of seen specifiers

```zig
const PrimitiveBits = packed struct {
    void_:     bool = false,
    char_:     bool = false,
    int_:      bool = false,
    float_:    bool = false,
    double_:   bool = false,
    bool_:     bool = false,
    signed_:   bool = false,
    unsigned_: bool = false,
    short_:    bool = false,
    long_:     u2  = 0,    // 0, 1, or 2 (long long)
};
```

Walk the prefix tokens, set bits. After the prefix, look up the resulting bitset in a table:

```zig
fn resolvePrimitive(bits: PrimitiveBits) ?*const CType {
    return switch (@as(u32, @bitCast(bits))) {
        @bitCast(PrimitiveBits{ .int_ = true })                       => &c_int_type,
        @bitCast(PrimitiveBits{ .signed_ = true, .int_ = true })      => &c_int_type,
        @bitCast(PrimitiveBits{ .unsigned_ = true, .int_ = true })    => &c_uint_type,
        @bitCast(PrimitiveBits{ .long_ = 1, .int_ = true })           => &c_long_type,
        @bitCast(PrimitiveBits{ .unsigned_ = true, .long_ = 1, .int_ = true }) => &c_ulong_type,
        @bitCast(PrimitiveBits{ .long_ = 2, .int_ = true })           => &c_longlong_type,
        // ... etc, ~30 cases
        else => null,
    };
}
```

If `resolvePrimitive` returns `null` and the bitset is non-zero, the declaration is ill-formed (e.g., `signed float`). Error.

If the bitset is zero, the type came from a `struct`/`union`/`enum` spec or a typedef name — handled separately.

### "Implicit int" rejection

K&R C allowed `f() { ... }` to mean `int f()`. Modern code shouldn't rely on this, and supporting it adds parser complexity. We require explicit type specifiers and error out on `int`-less declarations.

### Order independence

`unsigned long int x;` and `long unsigned int x;` mean the same thing. The bitset approach handles this naturally — we don't care about token order within the specifier.

---

## 7. Declarator Parsing — the Hard Part

A *declarator* is an identifier optionally surrounded by `*`, `[]`, and `()` operators that modify the type produced by the DeclSpec.

### Examples

```c
int x;              // declarator: `x`
int *p;             // declarator: `*p` — pointer to int
int arr[10];        // declarator: `arr[10]` — array of 10 int
int (*fp)(int);     // declarator: `(*fp)(int)` — pointer to function returning int
int *fp(int);       // declarator: `*fp(int)` — function returning pointer to int
int *(*funcs[5])(); // declarator: `*(*funcs[5])()` — array of 5 pointers to function returning pointer to int
```

The same set of operators (`*`, `[]`, `()`) reads as different types depending on grouping.

### The "spiral rule" / "right-left rule"

Reading a declarator: start at the identifier, alternate going right and left, reading operators in this priority:

1. `[]` and `()` are postfix, bind tighter than prefix `*`.
2. Parentheses group.

Examples:
- `int *fp(int)`: start at `fp`; right finds `(int)` (function); left finds `*` (pointer); left finds `int` (return type). So `fp` is "function (taking int) returning pointer to int."
- `int (*fp)(int)`: start at `fp`; left finds `*` (pointer); we hit `)`, switch direction; right finds `(int)` (function); left finds `int` (return). So `fp` is "pointer to function (taking int) returning int."

### Implementation: chain of modifiers

We don't implement the spiral rule literally — instead we parse the declarator into a *chain of type modifiers* and apply them in reverse to produce the final type.

```zig
const DeclMod = union(enum) {
    pointer:  Qualifiers,                          // `*` with optional qualifiers
    array:    struct { len: ?u64, qualifiers: Qualifiers },
    function: struct { params: []const Param, variadic: bool, calling_conv: ?CallConv },
};

const Declarator = struct {
    name:      ?[]const u8,    // null for abstract declarators (e.g., in casts or function parameters)
    mods:      []const DeclMod, // applied in reverse to base type
};
```

### Parsing algorithm (recursive descent)

```
parseDeclarator(needs_name: bool) -> Declarator:
    pointers := parsePointers()      // collect leading `*` operators
    inner := parseDirectDeclarator(needs_name)
    return { name: inner.name, mods: inner.mods + pointers }   // pointers applied LAST = outermost

parseDirectDeclarator(needs_name) -> Declarator:
    base := if peek == '(':
        consume('(')
        d := parseDeclarator(needs_name)   // recursive
        expect(')')
        d
    elif peek == identifier and needs_name:
        Declarator { name: consume(), mods: [] }
    elif !needs_name:
        Declarator { name: null, mods: [] }
    else:
        error("expected identifier")

    while true:
        if peek == '[':
            consume('[')
            len := if peek != ']' then parseConstExpr() else null
            qualifiers := parseQualifiers()
            expect(']')
            base.mods.append(DeclMod.array { len, qualifiers })
        elif peek == '(':
            consume('(')
            params := parseParameterList()
            expect(')')
            base.mods.append(DeclMod.function { params, ... })
        else:
            break

    return base
```

The "applied in reverse" detail is critical. If the declarator is `*foo[10]`, the mod chain (from the parser) is `[array(10), pointer]`, and applied in reverse it produces "pointer (innermost) → array of 10 (outermost)." So `foo` is "array of 10 pointers to T."

Wait — that's the wrong reading. Let me re-walk:

Tokens: `* foo [ 10 ]`.

`parseDeclarator`:
- `parsePointers()` consumes `*`, returns `[pointer]`.
- `parseDirectDeclarator`:
  - peek is `foo` (identifier). Consume it; base = `{name: "foo", mods: []}`.
  - Loop: peek is `[`. Parse `[10]`. Append `array(10)` to mods. base = `{name: "foo", mods: [array(10)]}`.
  - Loop: peek is `;`. Exit.
- Return `{name: "foo", mods: [array(10), pointer]}`.

To apply: starting with base type `T`, apply `array(10)` first → `array of 10 T`, then `pointer` → `pointer to (array of 10 T)`.

So `int *foo[10]` is "array of 10 pointers to int." Correct.

The mod-list order is "innermost first, outermost last." Apply in *forward* order to wrap successively.

### Apply step

```zig
fn applyMods(base: *const CType, mods: []const DeclMod, cache: *TypeCache) *const CType {
    var t = base;
    for (mods) |m| {
        t = switch (m) {
            .pointer => |q| internPointer(cache, t, q),
            .array => |a| internArray(cache, t, a.len),
            .function => |f| internFunction(cache, t, f.params, f.variadic, f.calling_conv),
        };
    }
    return t;
}
```

Each `intern*` consults the type cache, returning an existing `*const CType` if structurally-identical or allocating + interning a new one.

### Abstract declarators

Used in function parameters (`int f(int)` — the `int` parameter has no name) and in casts (`(int *)x`). Parser flag `needs_name: bool`; when false, the identifier slot may be empty.

### Function parameter list

```c
int f(void);          // no parameters, explicit
int g();              // no parameters, implicit (LuaJIT-style: treat as no params, not unspecified)
int h(int, char *);   // anonymous parameters
int i(int x, char *y); // named parameters
int j(int, ...);      // variadic
```

`(void)` is the C idiom for "explicitly no parameters." Required in strict C; we accept the empty form too.

`(int, ...)` is variadic. The `...` token only legal as the last "parameter."

Parameter types are themselves declarations (DeclSpec + abstract declarator). Parameter names are recorded but not used by the type system — they're for documentation only.

---

## 8. Compound Types

### Struct and union

```c
struct foo { int x; int y; };       // tag `foo`, complete
struct bar;                          // tag `bar`, incomplete (forward decl)
struct { int x; };                   // anonymous, fields directly inlined into enclosing scope (C11)
struct foo { ... } x, y;             // declares struct AND two variables of that type
```

### Tag namespaces

C has separate namespaces for tags (struct/union/enum names) and ordinary identifiers. So `struct point` and `int point` can coexist:

```c
struct point { int x, y; };
int point = 5;
```

We model this with two namespaces: `tags` and `idents`.

### Forward declarations and completion

```c
struct foo;                    // declared incomplete
typedef struct foo Foo;        // typedef to incomplete
struct foo { int x; };         // now complete; all references retroactively see the complete type
```

The `*const CType` for an incomplete struct has `size = UINT32_MAX, complete = false`. When the same tag is later defined with a body, we mutate the existing `CType` to fill in fields and set `complete = true`. **This is the one place in the parser we mutate a `CType` after interning.** Pointer identity is preserved so existing references remain valid.

If the tag is *never* completed before it's used in a context that needs the size (`sizeof(struct foo)`, `struct foo` as a struct field by value), we error at the using site.

### Anonymous structs/unions inside structs

C11 allows:

```c
struct outer {
    int a;
    struct { int x; int y; };   // anonymous struct, fields x and y promoted
    int b;
};

// `outer.x` is now valid.
```

Implementation: when we see an anonymous compound inside a struct body, parse it as if its fields were declared at the outer level, with field offsets adjusted by the anonymous struct's start offset. Slightly subtle but well-defined.

### Bitfields

```c
struct flags {
    unsigned int a : 1;
    unsigned int b : 3;
    unsigned int   : 0;          // unnamed zero-width — alignment break
    unsigned int c : 4;
};
```

Each bitfield carries a *bit width* (the integer after `:`). Layout follows platform rules:

- Bitfields pack into a "storage unit" sized as the underlying type (e.g., 4 bytes for `unsigned int`).
- Adjacent bitfields share a storage unit if they fit; otherwise start a new one.
- An unnamed bitfield with width 0 forces alignment to a fresh storage unit.
- Endianness affects which end of the unit the first bitfield occupies (little-endian: low bits first; big-endian: high bits first).

We track per-field `bit_offset` (within its storage unit) and `bit_width`. The struct's overall size is computed including bitfield-occupied storage units.

Bitfields are notoriously platform-dependent. We match the Zig compiler's view of the host platform (which matches Clang/GCC for that platform). Document this in `docs/ffi-bitfield-layout.md`.

### Enums

```c
enum color { RED, GREEN, BLUE = 5, MAGENTA };
// RED = 0, GREEN = 1, BLUE = 5, MAGENTA = 6
```

Values are constant expressions evaluated at parse time (§9). Enumerators bind into the *ordinary identifier* namespace as integer constants. They're available globally after parsing.

The enum's underlying type is platform-dependent: typically `int`, but the compiler may pick a smaller type if all values fit and `-fshort-enums` is in effect. We use `int` always for simplicity and to match the platform default.

---

## 9. Constant Expression Evaluation

Required in three contexts:
- Array sizes: `int x[10 + 5]`
- Enum values: `enum { A = 1 << 4 }`
- Bitfield widths: `unsigned x : sizeof(int) * 4`

### Subset supported

Pratt-parsed expression grammar evaluating to a `i64` or `u64` (we don't track signed/unsigned precisely outside of literal types):

| Operator                       | Precedence (low→high) |
|--------------------------------|----------------------|
| `?:`                           | 1 (right assoc)      |
| `\|\|`                          | 2                    |
| `&&`                           | 3                    |
| `\|`                            | 4                    |
| `^`                            | 5                    |
| `&`                            | 6                    |
| `==`, `!=`                     | 7                    |
| `<`, `>`, `<=`, `>=`           | 8                    |
| `<<`, `>>`                     | 9                    |
| `+`, `-` (binary)              | 10                   |
| `*`, `/`, `%`                  | 11                   |
| unary `-`, `+`, `!`, `~`       | 12                   |
| `sizeof T`, `sizeof (expr)`    | 12                   |
| `_Alignof T`                   | 12                   |
| literals, identifiers, parens  | 13                   |

Identifiers must resolve to enum constants previously declared in scope. `sizeof` requires its argument's `CType` to be complete.

No floating-point in constant expressions (illegal in C array sizes anyway).

### Implementation

```zig
fn parseConstExpr(p: *Parser) !i64 {
    return parseTernary(p);
}

fn parseTernary(p: *Parser) !i64 {
    const cond = try parseLogicalOr(p);
    if (p.match("?")) {
        const then_val = try parseTernary(p);
        try p.expect(":");
        const else_val = try parseTernary(p);
        return if (cond != 0) then_val else else_val;
    }
    return cond;
}

// ... etc
```

Pure recursive descent + Pratt. About 150 lines.

### Overflow

C constant-expression overflow is undefined behavior. We choose to wrap (two's complement) and emit a warning when `-Wconst-overflow` is on. Practically, FFI declarations rarely have overflow in const exprs.

---

## 10. Compiler Extensions: `__attribute__` and `__declspec`

### Position

`__attribute__((...))` can appear:
- After a struct/union/enum keyword: `struct __attribute__((packed)) foo { ... }`
- After the closing brace of a struct/union/enum: `struct foo { ... } __attribute__((packed))`
- After a declaration-specifier list: `int __attribute__((aligned(16))) x`
- At the end of a declaration (before the `;`)
- Inside a function-pointer declaration

The lenient placement rules are a real complication. Parser strategy: at any place where `__attribute__` *could* legally appear, accept it. Track which attributes apply to which entity by the position they were seen.

`__declspec(...)` (MSVC) is similar with simpler placement (always before the type).

### Attribute parsing

```
attribute := '__attribute__' '(' '(' attr_list ')' ')'
attr_list := attr (',' attr)*
attr := identifier ('(' arg_list ')')?
```

Each attribute is a name + optional argument list. We recognize a fixed set; unknown attributes are accepted with a warning ("ignoring unknown attribute 'foo'") — matching GCC's behavior.

### Calling convention attributes

```c
void __attribute__((stdcall)) f(int);
void __stdcall f(int);                  // equivalent
void f(int) __attribute__((stdcall));   // also equivalent
```

All three forms set `CallConv = .stdcall` on the function type. On non-Windows platforms, calling-convention attributes are accepted but ignored — they're a no-op on SysV.

### `aligned(N)`

`__attribute__((aligned(8)))` sets the alignment to N (must be power of two). Applies to:
- A variable declaration: increases alignment of the variable.
- A type declaration: increases alignment of all instances.
- A struct/union: increases alignment of the whole struct.

### `packed`

Disables automatic field padding. The struct's size is the sum of field sizes (modulo bitfield rules).

```c
struct __attribute__((packed)) S { char a; int b; };
// sizeof(S) == 5 (vs. 8 with default padding)
// alignof(S) == 1
```

`packed` and `aligned` can combine: `__attribute__((packed, aligned(2)))` packs but ensures 2-byte alignment.

---

## 11. Layout Calculation

After a struct/union body is parsed, the parser computes the layout: per-field offset, struct size, struct alignment.

### Algorithm

```
compute_layout(fields, packed_attr, align_attr):
    offset = 0
    max_align = 1
    for each field f in fields:
        f_align = if packed_attr then 1 else f.type.align
        offset = round_up(offset, f_align)
        f.offset = offset
        if f is bitfield:
            allocate bits; complex (see §8 bitfields)
        else:
            offset += f.type.size
        max_align = max(max_align, f.type.align)
    if align_attr:
        max_align = max(max_align, align_attr)
    struct_size = round_up(offset, max_align)
    struct_align = max_align
```

### Bitfield layout (more carefully)

```
storage_unit_offset = 0
storage_unit_bits_used = 0
for each field f:
    if f is bitfield with width W:
        if W == 0:
            # alignment break: round up to next storage unit
            storage_unit_bits_used = storage_unit_size_bits(f.type)
            continue
        if storage_unit_bits_used + W > storage_unit_size_bits(f.type):
            # doesn't fit; start new storage unit
            offset = storage_unit_offset + storage_unit_size_bytes(f.type)
            offset = round_up(offset, f.type.align)
            storage_unit_offset = offset
            storage_unit_bits_used = 0
        f.offset = storage_unit_offset
        f.bit_offset = storage_unit_bits_used
        f.bit_width = W
        storage_unit_bits_used += W
    else:
        # close the current bitfield storage unit
        offset = storage_unit_offset + (round_up(storage_unit_bits_used, 8) / 8)
        ...
```

The interactions are subtle. Best validated by *fuzz-testing against the platform's C compiler*: generate random struct layouts, compile a C file with the same layout, compare `sizeof`, `alignof`, `offsetof` to what we computed.

### Cross-compilation note

Layout depends on the *target* platform, not the host running the parser. Phase 3 §3 noted this: at VM init, we register the target's primitive sizes and alignments. The parser uses those throughout; nothing in the parser is host-specific.

---

## 12. Namespace and Symbol Resolution

```zig
pub const Namespace = struct {
    parent: ?*Namespace,         // for nested scopes (currently always null at top level)
    tags:    std.StringHashMap(*const CType),  // struct/union/enum names
    idents:  std.StringHashMap(IdentBinding),  // typedefs, enum constants, function/variable decls

    pub const IdentBinding = union(enum) {
        typedef:       *const CType,
        enum_const:    i64,
        decl:          struct { ctype: *const CType, linkage: enum { external, internal } },
    };
};
```

Lookup priority within `parseDeclSpec`:

1. If the token is a keyword → primitive type.
2. If the token is an identifier → check `idents`. If it's bound to a `typedef`, use that. If it's an `enum_const` or `decl`, error (those aren't types).

This is the famous "lexer hack" — to know whether `foo` is a type or a variable, the parser must consult the namespace. The lexer is namespace-agnostic; the parser does the disambiguation.

### Adding bindings

Each declaration adds a binding:
- `typedef T name;` → `idents[name] = .typedef T`
- `T name;` → `idents[name] = .decl { ctype: T, linkage: ... }`
- `enum X { A, B }` → `idents[A] = .enum_const 0`, `idents[B] = .enum_const 1`, `tags[X] = enum_type`

Redeclaration rules:

- Two compatible declarations of the same identifier → OK (`extern int x;` followed by `int x;`).
- Two incompatible declarations → error (`int x;` then `char x;`).
- Typedef redeclaration with same type → OK.

---

## 13. Error Handling and Recovery

### Error reporting

Every error carries source position (line + column from the lexer). Format matches Zig's compiler errors:

```
ffi.cdef:5:13: error: expected ';' after declaration
    int foo()  bar();
            ^
```

### Recovery

Parser is best-effort, single-error-per-declaration. On error:

1. Format the error.
2. **Skip to the next declaration boundary.** Advance the token stream until we hit `;` (top-level) or `}` (within a struct body), then resume.
3. Continue parsing from there.

This produces helpful "all errors at once" output without the implementation complexity of phrase-level recovery.

### Panic vs. recovery

We never panic. A malformed `cdef` returns an error to the Lua caller; partial state from before the error is discarded (the namespace is rolled back to its pre-cdef state via a transaction-style snapshot).

---

## 14. Testing

### Unit tests by phase

- Lexer: 100+ tests covering keywords, identifiers, numeric literals (including all suffix combinations), string literals, character literals, all punctuators, comments, newlines.
- DeclSpec: 50+ tests covering all primitive type combinations, including invalid combos (`signed float`).
- Declarator: 80+ tests covering simple, array, pointer, function, function-pointer, deeply-nested forms (the famous `int *(*funcs[5])()`).
- Compound types: 50+ tests covering structs, unions, enums, anonymous, packed, aligned, forward declarations.
- Bitfields: 30+ tests covering layout, zero-width unnamed, mixed bitfield/non-bitfield in same struct.
- Constant expressions: 40+ tests for each operator and operator combinations.
- Attributes: 40+ tests covering each recognized attribute and unknown-attribute-warning behavior.

### Integration tests: layout fuzzer

Generate 10,000 random struct definitions. For each:
1. Emit a `.c` file with the same struct.
2. Compile with the host C compiler.
3. Use `clang -Xclang -fdump-record-layouts` (or similar) to extract field offsets.
4. Compare to our parser's output.

Any divergence is a parser bug. Run on x86-64 Linux, x86-64 macOS, ARM64 macOS as a CI matrix.

### LuaJIT compatibility

Port LuaJIT's FFI cdef test cases. Target ≥ 95% pass rate; document divergences (likely around obscure attributes or undocumented MSVC extensions).

### Real-world headers

Curate a set of `cpp`-preprocessed headers from real projects (zlib, sqlite3, libpng, openssl). Run `ffi.cdef` on each; verify all declarations parse without error.

### Fuzz the parser

Random strings (both pure-random and grammar-aware) fed into the parser. Should never crash, should always produce a parse error or a valid parse. Catches buffer-overruns, infinite loops, and assertion failures.

---

## 15. Exit Criteria (for the C parser slice of Phase 3)

- [ ] Lexer produces correct tokens for all of `tests/lexer/`
- [ ] DeclSpec parses every primitive combination correctly; rejects ill-formed combos with helpful errors
- [ ] Declarator parsing handles `int *(*funcs[5])(char *, ...)` and similarly tangled forms
- [ ] Hash-consing: structurally-identical types interned to single pointer; verified by structural-equality fuzz test
- [ ] Forward-then-complete struct cycles work without dangling pointers
- [ ] Layout fuzzer: 10,000 random structs match host-compiler layout on x86-64 Linux, x86-64 macOS, ARM64 macOS
- [ ] Bitfield layout matches host compiler; zero-width unnamed bitfields force alignment as expected
- [ ] Recognized `__attribute__` and `__declspec` attributes produce the documented effects
- [ ] LuaJIT FFI cdef test suite: ≥ 95% passing; divergences documented
- [ ] Real-world headers (zlib, sqlite3 declarations): parse without error
- [ ] Errors carry source position; recovery skips to next `;` or `}` and continues
- [ ] No leaks under `GeneralPurposeAllocator{ .safety = true }`
- [ ] Fuzz: 1M random inputs, no crashes, no infinite loops
- [ ] `zig fmt` clean, `zig build test` green

---

## 16. Deliverables

| Path                              | Contents                                           |
|-----------------------------------|----------------------------------------------------|
| `src/ffi/cparse/lex.zig`          | Lexer                                              |
| `src/ffi/cparse/decl_spec.zig`    | DeclSpec parser, primitive resolution table        |
| `src/ffi/cparse/declarator.zig`   | Declarator parser, modifier chain, apply step      |
| `src/ffi/cparse/compound.zig`     | Struct, union, enum bodies                         |
| `src/ffi/cparse/bitfield.zig`     | Bitfield layout                                    |
| `src/ffi/cparse/const_expr.zig`   | Constant expression evaluator                      |
| `src/ffi/cparse/attribute.zig`    | `__attribute__` and `__declspec` handling          |
| `src/ffi/cparse/layout.zig`       | Struct/union layout calculation                    |
| `src/ffi/cparse/namespace.zig`    | Tag and identifier namespaces                      |
| `src/ffi/cparse/error.zig`        | Error formatting and recovery                      |
| `src/ffi/cparse/parser.zig`       | Top-level entry point: `parse(src)` → namespace    |
| `tests/cparse/lexer/`             | Lexer tests                                        |
| `tests/cparse/declarators/`       | Declarator tangle tests                            |
| `tests/cparse/layout_fuzz/`       | Random-struct layout fuzzer + harness              |
| `tests/cparse/luajit_compat/`     | Ported LuaJIT cdef tests                           |
| `tests/cparse/real_headers/`      | Pre-processed real-world headers                   |
| `tests/cparse/fuzz/`              | Random-input fuzz harness                          |
| `docs/ffi-bitfield-layout.md`     | Platform-specific bitfield rules + reference       |

---

## 17. Estimated Effort

5–6 weeks focused. Part of Phase 3's overall 3.5–4.5 month estimate.

| Component                              | Estimate    |
|----------------------------------------|-------------|
| Lexer                                  | 4 days      |
| DeclSpec                               | 4 days      |
| Declarator                             | 1 week      |
| Compound types (struct, union, enum)   | 1 week      |
| Bitfields                              | 4 days      |
| Constant expressions                   | 3 days      |
| Attributes                             | 3 days      |
| Layout calculation                     | 4 days      |
| Namespace + redeclaration rules        | 3 days      |
| Hash-consing + cycle handling          | 3 days      |
| Error reporting + recovery             | 3 days      |
| Layout fuzzer + harness                | 1 week      |
| LuaJIT compat tests + fixes            | 1 week      |
| Real-header validation                 | 3 days      |

---

## 18. Open Questions

1. **GCC vs Clang vs MSVC bitfield rules.** They differ on edge cases (whether unnamed zero-width breaks alignment, packing across storage units, signed vs unsigned default). We match the *host platform's default compiler*. Document divergences. Fuzz against actual host compiler.

2. **Long double size.** 80-bit on x86-64 Linux, 128-bit on AArch64, doesn't exist on Windows MSVC. Use platform-specific value; document.

3. **`__int128`.** GCC extension, useful but rare. Probably skip in Phase 3.5; revisit if a real header uses it.

4. **`enum` underlying type stability.** We always use `int`. If a header relies on `enum` being smaller (`enum : char { ... }` C++23, or `-fshort-enums`), our layout will be wrong. Document; refuse C++ enum-with-base.

5. **`#pragma pack(...)`.** Not supported. If a real header uses `#pragma pack(push, 1)` to set packing, the user must replace with `__attribute__((packed))` per-struct.

6. **Anonymous fields in non-C11 contexts.** GCC supports anonymous structs/unions even pre-C11. We accept them unconditionally.

7. **Function pointers without explicit `(*...)`.** `void f(int);` declares `f` as a function. `void (*fp)(int);` declares `fp` as a function pointer. Some real-world FFI code uses `typedef void (*signal_handler_t)(int)` then `signal_handler_t handler;` — note that `handler` here is a *function pointer*, not a function. Critical that the parser handles typedef-of-function-pointer correctly.

8. **Type-qualified pointers.** `const char *p` (pointer to const char) vs `char *const p` (const pointer to char) vs `const char *const p` (const pointer to const char). Three distinct types, distinguished by where `const` falls in the declarator. Test extensively.

9. **`restrict` semantics.** ANSI C99 keyword; affects optimization but not layout or ABI. We accept and ignore; record on the type for completeness but never use.

10. **Parser performance.** A 100KB header (after `cpp`) should parse in < 50ms. Profile and optimize if needed; the layout fuzzer is a useful microbenchmark.

11. **Memory pressure from interning.** Long-running programs that re-cdef the same types should not leak. Hash-consing dedupes structurally; verify the type cache itself doesn't grow unbounded (e.g., via fragmented anonymous-struct types that all hash distinctly).

12. **Source location through interning.** When two declarations produce the same `*const CType`, which source location "wins" for error reporting? First-seen, by convention. Subsequent declarations that resolve to the same type don't update the location.
