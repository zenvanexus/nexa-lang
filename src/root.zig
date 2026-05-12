//! Root module for the VM and compiler. Re-exports the Phase 0 surface.

pub const Value = @import("value.zig").Value;
pub const lex = @import("parser/lex.zig");
pub const ast = @import("parser/ast.zig");
pub const parse = @import("parser/parse.zig");
pub const resolve = @import("parser/resolve.zig");
pub const vm_mod = @import("vm/vm.zig");
pub const vm_error = @import("vm/error.zig");
pub const String = @import("types/string.zig").String;
pub const Table = @import("types/table.zig").Table;

test {
    _ = @import("value.zig");
    _ = @import("parser/lex.zig");
    _ = @import("parser/ast.zig");
    _ = @import("parser/parse.zig");
    _ = @import("parser/resolve.zig");
    _ = @import("vm/vm.zig");
    _ = @import("vm/error.zig");
    _ = @import("types/string.zig");
    _ = @import("types/table.zig");
}

test "value nil is active tag" {
    const v: Value = .nil;
    try @import("std").testing.expect(@import("std").meta.activeTag(v) == .nil);
}
