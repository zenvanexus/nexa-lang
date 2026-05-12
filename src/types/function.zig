const ast = @import("../parser/ast.zig");

/// User-defined function (Phase 0: no upvalues).
pub const FunctionObj = struct {
    name: ?[]const u8,
    params: []const []const u8,
    body: *ast.Block,
};
