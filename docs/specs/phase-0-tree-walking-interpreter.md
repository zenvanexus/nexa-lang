# Phase 0 — Tree-walking interpreter

**Project:** Nexa (Lua- / LuaJIT-shaped scripting language in Zig)  
**Spec scope:** What the Phase 0 front-end and interpreter guarantee today: supported syntax, runtime model, builtins, and known gaps relative to Lua 5.1.

**Implementation:** `src/parser/` (lexer + recursive-descent parser + AST), `src/vm/interpreter.zig` (tree walk), `src/value.zig`, `src/types/`. Entry: `nexa.runChunk` in `src/root.zig`, CLI `nexa <file.lua>` in `src/main.zig`.

---

## 1. Goals

- Execute a **Lua-shaped subset** directly from source: tokenize → parse → walk AST (no bytecode yet).
- Provide **`print`** for observable program output (snapshots and CLI).
- Keep the AST and `Value` model small enough to **replace in Phase 1** (bytecode + different value representation) without rewriting the entire repo layout.

## 2. Non-goals (Phase 0)

- Bytecode, JIT, incremental GC, coroutines, full standard library, `require`, metamethods, `goto`, generic `for … in`, varargs `...`, proper `local function` desugaring, full numeric coercion rules, and full Lua lexical edge cases (e.g. long strings `[[...]]`).
- Drop-in compatibility with every Lua program on the internet.

---

## 3. Pipeline

1. **`lex.tokenize`** — `[]const u8` → `[]Token` (arena-allocated slice; string literal payloads live in the same arena).
2. **`parse.parse`** — tokens → `*ast.Block` (chunk body); all AST nodes allocated in the parse arena.
3. **`Interpreter.runChunk`** — `seedBuiltins` then execute the chunk inside one outer local scope (matches “chunk as implicit scope” enough for globals vs locals).

Two allocators at run boundary:

- **Arena** (per `runChunk`): AST + token string payloads + short-lived eval buffers.
- **Backing** (typically `std.testing.allocator` or the CLI GPA): `StringHashMap` nodes for globals/locals, `FunctionObj`, heap `String` values created at runtime.

---

## 4. Supported syntax (current)

**Literals:** `nil`, `true`, `false`, numbers (decimal + optional fraction + optional exponent), double-quoted strings with escapes `\n \t \r \\ \"`.

**Expressions:** identifiers, grouping `(...)`, calls `f(a,b)`, indexing `t[k]` and `t.k` (field desugars to string key), unary `-` `not` `#`, binary `+ - * / % ^ ..`, comparisons `== ~= < <= > >=`, short-circuit `and` `or` (parser emits `ast.BinOp` for `and`/`or`; interpreter short-circuits), **table constructors** `{ … }` (list fields get consecutive integer keys `1..n`; `[k] = v` and `name = v` keyed fields; optional `,` / `;` between fields).

**Statements:** `;`, expression statements, `local` (with `=` and expression lists; missing inits default to `nil`), assignment (multi-target / multi-value surface syntax; semantics match simple Lua for the supported cases), `if then [elseif then]* [else] end`, **numeric** `for v = e1, e2 [, e3] do … end` (step defaults to `1`; bounds and step must evaluate to numbers), `while do end`, `repeat until`, `do end`, `break`, `return` (only inside a function body), `function name(args) ... end` (registers a **global** function; use `local f = function() ... end` for locals).

**Anonymous functions:** `function(args) ... end` as an **expression** is parsed and creates a `FunctionObj` at runtime.

**Comments:** `--` to end of line.

---

## 5. Runtime model

- **Globals:** `Interpreter.globals` (`StringHashMapUnmanaged(Value)`).
- **Locals:** stack of scopes; each scope is a map name → `Value`. Lookup walks innermost → outermost then globals.
- **Assignment:** walks scopes for an existing binding; otherwise creates/updates a **global** (Lua-like for this subset).
- **Functions:** `Value.function` points at `FunctionObj` `{ name, params, body }`. Call pushes a fresh scope, binds parameters, runs `body`, first returned value becomes the call result (multiple returns are not surfaced to callers yet).
- **Builtins:** `Value.builtin` — only `.print` is wired. Writes tab-separated arguments and a newline to the run’s output buffer (`std.array_list.Managed(u8)`).

**Tables:** `Table` backs `t[k]` / `t.k` and **table constructors** `{ … }` (see expressions above). No metamethods or `__index` chain.

---

## 6. Types (`Value`)

| Tag        | Meaning |
|-----------|---------|
| `nil`     | Lua `nil`. |
| `boolean` | `true` / `false`. |
| `number`  | `f64` (Lua semantics approximated; no integer subtype). |
| `string`  | Pointer to `String { bytes }` on the backing allocator. |
| `table`   | Pointer to `Table` (array + string map). |
| `function`| Pointer to `FunctionObj`. |
| `builtin` | Host builtin dispatch (e.g. `print`). |

**Truthiness:** `nil` and `false` are false; `0` is **true** (Lua rules); empty string is false.

---

## 7. CLI

```text
nexa path/to/script.lua
```

On error, prints `@errorName` to stderr and exits with code `1`. Missing script argument exits `2`.

---

## 8. Tests

- Unit: `src/parser/lex.zig` (smoke), `src/root.zig` (`print(1+1)`).
- Integration: `tests/snapshots/runner.zig` runs the real pipeline on `tests/snapshots/**/*.lua` (see `001_add`).

---

## 9. Known gaps / next steps toward Phase 1

- **Generic** `for namelist in explist`, metamethods, `_ENV`, exact Lua scoping for `function` statements in all contexts.
- **Heap teardown:** `Table` values from `{ … }` (and string keys stored in those tables) are not recursively freed when the interpreter exits; avoid GPA leak checks on scripts that retain tables until a GC or explicit teardown exists.
- **Return values:** multi-return from calls; tail calls.
- **Error locations:** no `source_info` module yet; parse/runtime errors use Zig `error` names only.
- **Bytecode:** Phase 1 introduces `op.zig`, `bytecode.zig`, `compile.zig`, and a real VM loop; this interpreter remains useful for differential testing until the bytecode VM matches behavior.

For repository layout and future files, see **`docs/project-layout.md`**. For `.lua` vs `.zig` boundaries, see **`docs/reference/source-files.md`**.
