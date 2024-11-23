const std = @import("std");

// Although this function looks imperative, note that its job is to
// declaratively construct a build graph that will be executed by an external
// runner.
pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    var roc_src = b.option([]const u8, "app", "the roc application to build");

    const build_roc = b.addExecutable(.{
        .name = "build_roc",
        .root_source_file = b.path("build_roc.zig"),
        .target = target,
        .optimize = .Debug,
    });
    const run_build_roc = b.addRunArtifact(build_roc);
    // By setting this to true, we ensure zig always rebuilds the roc app since it can't tell if any transitive dependencies have changed.
    run_build_roc.stdio = .inherit;
    run_build_roc.has_side_effects = true;

    const default_path = "examples/hello.roc";
    if (roc_src == null) {
        roc_src = default_path;
    }
    run_build_roc.addFileArg(b.path(roc_src.?));

    switch (optimize) {
        .ReleaseFast, .ReleaseSafe => {
            run_build_roc.addArg("--optimize");
        },
        .ReleaseSmall => {
            run_build_roc.addArg("--opt-size");
        },
        else => {},
    }

    const exe = b.addExecutable(.{
        // Make the executable name the roc app name minus `.roc`.
        .name = std.fs.path.stem(roc_src.?),
        .root_source_file = b.path("platform/host/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    exe.linkLibC();

    const libxev = b.dependency("libxev", .{});
    exe.root_module.addImport("xev", libxev.module("xev"));

    exe.step.dependOn(&run_build_roc.step);
    exe.addObjectFile(b.path(".zig-cache/app.o"));

    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }
    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);
}
