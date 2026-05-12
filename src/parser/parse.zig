const std = @import("std");
const ast = @import("ast.zig");

/// Parse tokens into a block; Phase 0 stub returns empty program.
pub fn parse(allocator: std.mem.Allocator, tokens: []const @import("lex.zig").Token) std.mem.Allocator.Error!*ast.Block {
    _ = tokens;
    const block = try allocator.create(ast.Block);
    block.* = .{ .stmts = &.{} };
    return block;
}
