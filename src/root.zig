//! Root module for the VM and compiler. Re-exports the Phase 0 surface.

const std = @import("std");
const lex = @import("parser/lex.zig");
const parse = @import("parser/parse.zig");
const vm_error = @import("vm/error.zig");

pub const Value = @import("value.zig").Value;
pub const Builtin = @import("value.zig").Builtin;
pub const lex_mod = lex;
pub const ast = @import("parser/ast.zig");
pub const parse_mod = parse;
pub const resolve = @import("parser/resolve.zig");
pub const vm_mod = @import("vm/vm.zig");
pub const vm_error_mod = vm_error;
pub const String = @import("types/string.zig").String;
pub const Table = @import("types/table.zig").Table;
pub const Interpreter = @import("vm/interpreter.zig").Interpreter;

pub const RunError = parse.ParseError || vm_error.VmError;

/// Lex + parse + run `source` (Lua-shaped Nexa subset). Printed output accumulates in `out`.
pub fn runChunk(gpa: std.mem.Allocator, source: []const u8, out: *std.array_list.Managed(u8)) RunError!void {
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const toks = try lex.tokenize(a, source);
    const tree = try parse.parse(a, toks, source);
    var intr = Interpreter.init(gpa, a, out);
    defer intr.deinit();
    try intr.seedBuiltins();
    try intr.runChunk(tree);
}

test {
    _ = @import("value.zig");
    _ = @import("parser/lex.zig");
    _ = @import("parser/ast.zig");
    _ = @import("parser/parse.zig");
    _ = @import("parser/resolve.zig");
    _ = @import("vm/vm.zig");
    _ = @import("vm/interpreter.zig");
    _ = @import("vm/error.zig");
    _ = @import("types/string.zig");
    _ = @import("types/table.zig");
    _ = @import("types/function.zig");
}

test "value nil is active tag" {
    const v: Value = .nil;
    try std.testing.expect(@import("std").meta.activeTag(v) == .nil);
}

test "eval print add" {
    const src = "print(1 + 1)";
    var out = std.array_list.Managed(u8).init(std.testing.allocator);
    defer out.deinit();
    try runChunk(std.testing.allocator, src, &out);
    try std.testing.expectEqualStrings("2\n", out.items);
}

test "elseif and numeric for" {
    const src =
        \\local x = 0
        \\if false then x = 1 elseif true then x = 2 else x = 3 end
        \\local s = 0
        \\for i = 1, 3 do s = s + i end
        \\print(x, s)
    ;
    var out = std.array_list.Managed(u8).init(std.testing.allocator);
    defer out.deinit();
    try runChunk(std.testing.allocator, src, &out);
    try std.testing.expectEqualStrings("2\t6\n", out.items);
}
