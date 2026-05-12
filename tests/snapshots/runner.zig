const std = @import("std");

test "snapshot corpus: 001_add fixtures" {
    const cwd = std.fs.cwd();
    const lua_path = "tests/snapshots/arithmetic/001_add.lua";
    const exp_path = "tests/snapshots/arithmetic/001_add.expected";

    const lua_src = try cwd.readFileAlloc(std.testing.allocator, lua_path, 1024 * 1024);
    defer std.testing.allocator.free(lua_src);
    const expected = try cwd.readFileAlloc(std.testing.allocator, exp_path, 1024 * 1024);
    defer std.testing.allocator.free(expected);

    try std.testing.expect(std.mem.indexOf(u8, lua_src, "1") != null);
    try std.testing.expectEqualStrings("2\n", expected);
}
