const std = @import("std");
const Value = @import("../value.zig").Value;

/// Minimal Lua-like table: positive integer keys use a 1-based array; string keys use a map.
pub const Table = struct {
    array: std.ArrayListUnmanaged(Value) = .{},
    map: std.StringHashMapUnmanaged(Value) = .{},

    pub fn init() Table {
        return .{};
    }

    pub fn deinit(self: *Table, allocator: std.mem.Allocator) void {
        self.array.deinit(allocator);
        self.map.deinit(allocator);
    }

    fn isArrayIndex(k: f64) ?usize {
        if (k != k) return null; // nan
        const t = @trunc(k);
        if (t != k or t < 1) return null;
        if (t > @as(f64, @floatFromInt(std.math.maxInt(usize)))) return null;
        return @intFromFloat(t);
    }

    pub fn get(self: *const Table, key: Value) Value {
        switch (key) {
            .nil, .boolean, .function, .builtin => return .nil,
            .number => |n| {
                if (isArrayIndex(n)) |i| {
                    if (i == 0 or i > self.array.items.len) return .nil;
                    return self.array.items[i - 1];
                }
                return .nil;
            },
            .string => |s| return self.map.get(s.bytes) orelse .nil,
            .table => return .nil,
        }
    }

    pub fn set(self: *Table, key: Value, val: Value, allocator: std.mem.Allocator) std.mem.Allocator.Error!void {
        switch (key) {
            .number => |n| {
                if (isArrayIndex(n)) |i| {
                    if (i == 0) return;
                    const need = i;
                    if (need > self.array.items.len) {
                        const old = self.array.items.len;
                        try self.array.resize(allocator, need);
                        for (old..need) |j| self.array.items[j] = .nil;
                    }
                    self.array.items[i - 1] = val;
                    return;
                }
            },
            .string => |s| {
                try self.map.put(allocator, s.bytes, val);
                return;
            },
            else => {},
        }
    }
};
