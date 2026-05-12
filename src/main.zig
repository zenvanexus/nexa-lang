const std = @import("std");
const nexa = @import("nexa");

pub fn main() !void {
    const stdout = std.fs.File.stdout().deprecatedWriter();
    try stdout.print("nexa — Phase 0 bootstrap (interpreter not wired yet)\n", .{});
    try stdout.print("active tag smoke: {s}\n", .{@tagName(@as(nexa.Value, .nil))});
}
