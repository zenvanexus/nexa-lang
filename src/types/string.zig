const std = @import("std");

/// Byte string; contents live in the arena for Phase 0.
pub const String = struct {
    bytes: []const u8,

    pub fn dupe(allocator: std.mem.Allocator, bytes: []const u8) std.mem.Allocator.Error!String {
        const copy = try allocator.dupe(u8, bytes);
        return .{ .bytes = copy };
    }
};
