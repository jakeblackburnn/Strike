const std = @import("std");

// This build script does one thing: compile the `strike` CLI. It deliberately
// does *no* content rendering — that's `strike render`'s job at runtime, so
// the build never depends on any content existing.

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const exe = b.addExecutable(.{
        .name = "strike",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    b.installArtifact(exe);

    // `zig build run` -> render sample/kitchen-sink.md to stdout. Args after
    // `--` replace that default entirely.
    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    } else {
        run_cmd.addArgs(&.{ "render", "sample/kitchen-sink.md" });
    }

    const run_step = b.step("run", "Build and run strike (default: render sample/kitchen-sink.md)");
    run_step.dependOn(&run_cmd.step);

    // `zig build test` -> run the unit tests in every src/*.zig file. (Imported
    // files' tests only run when their file is a test root, so each gets its
    // own test artifact.) A glob rather than a hardcoded list so a new source
    // file is picked up automatically instead of silently going untested.
    const test_step = b.step("test", "Run unit tests");
    var src_dir = b.build_root.handle.openDir(b.graph.io, "src", .{ .iterate = true }) catch
        @panic("could not open src/");
    defer src_dir.close(b.graph.io);
    var src_it = src_dir.iterate();
    while (src_it.next(b.graph.io) catch @panic("could not iterate src/")) |entry| {
        if (entry.kind != .file or !std.mem.endsWith(u8, entry.name, ".zig")) continue;
        const tests = b.addTest(.{
            .root_module = b.createModule(.{
                .root_source_file = b.path(b.fmt("src/{s}", .{entry.name})),
                .target = target,
                .optimize = optimize,
            }),
        });
        test_step.dependOn(&b.addRunArtifact(tests).step);
    }
}
