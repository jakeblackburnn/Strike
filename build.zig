const std = @import("std");
// The renderer is pure Zig + std, so the build can call it directly at
// configure time to turn the project's markdown into static HTML.
const project = @import("src/project.zig");
const site = @import("src/site.zig");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // The markdown server executable.
    const exe = b.addExecutable(.{
        .name = "strike",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    b.installArtifact(exe);

    // Render the whole `strikedown/` content folder — projects, subfolders, the
    // picker — to `zig-out/html/`, preserving the route hierarchy as directories.
    const wf = b.addWriteFiles();
    var content_dir = b.build_root.handle.openDir(b.graph.io, "strikedown", .{ .iterate = true }) catch
        @panic("could not open strikedown/");
    defer content_dir.close(b.graph.io);
    const loaded = project.load(b.graph.io, b.allocator, content_dir) catch @panic("could not scan strikedown/");
    const pages = site.renderAll(b.allocator, loaded) catch @panic("OOM");

    var rendered: std.ArrayList(Rendered) = .empty;
    for (pages) |p| {
        const out_rel = site.outPath(b.allocator, p, loaded.base) catch @panic("OOM");
        installHtml(b, wf, out_rel, p.html);
        rendered.append(b.allocator, .{ .src = p.src, .out = out_rel }) catch @panic("OOM");
    }

    // Print a banner reporting which markdown files were built.
    const banner = Banner.create(b, rendered.toOwnedSlice(b.allocator) catch @panic("OOM"));
    banner.step.dependOn(&exe.step);
    b.getInstallStep().dependOn(&banner.step);

    // `zig build run` -> build and start the server on `strikedown/`. Extra
    // args after `--` (e.g. `zig build run -- --port 9000`) are forwarded, so
    // `-- serve /other/dir` also works.
    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    run_cmd.addArgs(&.{ "serve", "strikedown" });
    if (b.args) |args| run_cmd.addArgs(args);

    const run_step = b.step("run", "Build and run strike");
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

/// Add `html` to the WriteFiles step at `rel` and install it under `html/<rel>`.
fn installHtml(b: *std.Build, wf: *std.Build.Step.WriteFile, rel: []const u8, html: []const u8) void {
    const install = b.addInstallFileWithDir(wf.add(rel, html), .prefix, b.fmt("html/{s}", .{rel}));
    b.getInstallStep().dependOn(&install.step);
}

const Rendered = struct { src: []const u8, out: []const u8 };

/// A tiny custom build step that reports which markdown files were rendered.
const Banner = struct {
    step: std.Build.Step,
    rendered: []const Rendered,

    fn create(b: *std.Build, rendered: []const Rendered) *Banner {
        const self = b.allocator.create(Banner) catch @panic("OOM");
        self.* = .{
            .step = std.Build.Step.init(.{
                .id = .custom,
                .name = "build banner",
                .owner = b,
                .makeFn = make,
            }),
            .rendered = rendered,
        };
        return self;
    }

    fn make(step: *std.Build.Step, options: std.Build.Step.MakeOptions) anyerror!void {
        _ = options;
        const self: *Banner = @fieldParentPtr("step", step);
        std.debug.print("\n  strike — rendered {d} file(s) from strikedown/ to zig-out/html/\n", .{self.rendered.len});
        for (self.rendered) |r| std.debug.print("    strikedown/{s}  ->  html/{s}\n", .{ r.src, r.out });
        std.debug.print("  run with: zig build run   (serves strikedown/ at http://127.0.0.1:8080)\n\n", .{});
    }
};
