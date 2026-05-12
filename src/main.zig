const std = @import("std");
const nexa = @import("nexa");

pub fn main() !void {
    var gpa_state = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa_state.deinit();
    const gpa = gpa_state.allocator();

    const args = try std.process.argsAlloc(gpa);
    defer std.process.argsFree(gpa, args);

    if (args.len < 2) {
        const stderr = std.fs.File.stderr().deprecatedWriter();
        try stderr.writeAll("usage: nexa <script.lua>\n");
        std.process.exit(2);
    }

    const path = args[1];
    const source = try std.fs.cwd().readFileAlloc(gpa, path, 16 * 1024 * 1024);
    defer gpa.free(source);

    var out = std.array_list.Managed(u8).init(gpa);
    defer out.deinit();

    nexa.runChunk(gpa, source, &out) catch |err| {
        const stderr = std.fs.File.stderr().deprecatedWriter();
        try stderr.print("{s}\n", .{@errorName(err)});
        std.process.exit(1);
    };

    const stdout = std.fs.File.stdout().deprecatedWriter();
    try stdout.writeAll(out.items);
}
