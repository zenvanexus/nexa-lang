const std = @import("std");
const nexa = @import("nexa");

test "snapshot corpus: 001_add" {
    const cwd = std.fs.cwd();
    const lua_path = "tests/snapshots/arithmetic/001_add.lua";
    const exp_path = "tests/snapshots/arithmetic/001_add.expected";

    const lua_src = try cwd.readFileAlloc(std.testing.allocator, lua_path, 1024 * 1024);
    defer std.testing.allocator.free(lua_src);
    const expected = try cwd.readFileAlloc(std.testing.allocator, exp_path, 1024 * 1024);
    defer std.testing.allocator.free(expected);

    var out = std.array_list.Managed(u8).init(std.testing.allocator);
    defer out.deinit();
    try nexa.runChunk(std.testing.allocator, lua_src, &out);

    try std.testing.expectEqualStrings(expected, out.items);
}
