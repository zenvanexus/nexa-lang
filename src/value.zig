const String = @import("types/string.zig").String;
const Table = @import("types/table.zig").Table;

/// Phase 0 tagged union; later phases replace representation (NaN-boxing, etc.).
pub const Value = union(enum) {
    nil,
    boolean: bool,
    number: f64,
    string: *String,
    table: *Table,
};
