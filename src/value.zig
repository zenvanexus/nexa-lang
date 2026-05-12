const String = @import("types/string.zig").String;
const Table = @import("types/table.zig").Table;
const FunctionObj = @import("types/function.zig").FunctionObj;

pub const Builtin = enum {
    print,
};

/// Phase 0 tagged union; later phases replace representation (NaN-boxing, etc.).
pub const Value = union(enum) {
    nil,
    boolean: bool,
    number: f64,
    /// Heap-allocated string (e.g. concatenation, host).
    string: *String,
    /// Source literal; `bytes` live in the parse arena for the duration of `runChunk`.
    string_lit: []const u8,
    table: *Table,
    function: *FunctionObj,
    builtin: Builtin,
};

/// Bytes for string-like values, if any.
pub fn stringBytes(v: Value) ?[]const u8 {
    return switch (v) {
        .string => |s| s.bytes,
        .string_lit => |b| b,
        else => null,
    };
}
