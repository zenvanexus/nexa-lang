const std = @import("std");
const Value = @import("../value.zig").Value;

pub const VM = struct {
    arena: std.heap.ArenaAllocator,

    pub fn init(backing: std.mem.Allocator) VM {
        return .{ .arena = std.heap.ArenaAllocator.init(backing) };
    }

    pub fn deinit(self: *VM) void {
        self.arena.deinit();
    }

    /// Phase 0 tree-walking entry; stub returns nil.
    pub fn evalTop(_: *VM, _: Value) @import("error.zig").VmError!Value {
        return .nil;
    }
};
