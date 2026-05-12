const std = @import("std");
const ast = @import("ast.zig");

pub const ResolvedAst = struct {
    root: *ast.Block,
};

/// Resolve names and build resolved tree; Phase 0 stub passes through.
pub fn resolve(allocator: std.mem.Allocator, tree: *ast.Block) std.mem.Allocator.Error!ResolvedAst {
    _ = allocator;
    return .{ .root = tree };
}
