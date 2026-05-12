const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const nexa_mod = b.addModule("nexa", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
    });

    const exe = b.addExecutable(.{
        .name = "nexa",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "nexa", .module = nexa_mod }},
        }),
    });
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    const run_step = b.step("run", "Run the lua host");
    run_step.dependOn(&run_cmd.step);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const nexa_tests = b.addTest(.{ .root_module = nexa_mod });
    const run_nexa_tests = b.addRunArtifact(nexa_tests);

    const snapshot_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/snapshots/runner.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "nexa", .module = nexa_mod }},
        }),
    });
    const run_snapshot_tests = b.addRunArtifact(snapshot_tests);

    const exe_tests = b.addTest(.{ .root_module = exe.root_module });
    const run_exe_tests = b.addRunArtifact(exe_tests);

    const test_step = b.step("test", "Run unit and snapshot tests");
    test_step.dependOn(&run_nexa_tests.step);
    test_step.dependOn(&run_snapshot_tests.step);
    test_step.dependOn(&run_exe_tests.step);

    const fmt_step = b.addFmt(.{
        .paths = &.{ "src", "tests", "build.zig" },
        .check = false,
    });
    const fmt_check = b.addFmt(.{
        .paths = &.{ "src", "tests", "build.zig" },
        .check = true,
    });
    b.step("fmt", "Format Zig sources").dependOn(&fmt_step.step);
    b.step("fmt-check", "Check Zig formatting").dependOn(&fmt_check.step);
}
