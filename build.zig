const std = @import("std");

// Although this function looks imperative, note that its job is to
// declaratively construct a build graph that will be executed by an external
// runner.
pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const roc_src = b.option([]const u8, "app", "the roc application to build");
    _ = roc_src;

    // const build_roc = b.addExecutable(.{
    //     .name = "build_roc",
    //     .root_source_file = .{ .path = "build_roc.zig" },
    //     // Empty means native.
    //     .target = .{},
    //     .optimize = .Debug,
    // });
    // const run_build_roc = b.addRunArtifact(build_roc);
    // // By setting this to true, we ensure zig always rebuilds the roc app since it can't tell if any transitive dependencies have changed.
    // run_build_roc.stdio = .inherit;
    // run_build_roc.has_side_effects = true;

    // if (roc_src) |val| {
    //     run_build_roc.addFileArg(.{ .path = val });
    // } else {
    //     const default_path = "examples/hello.roc";
    //     run_build_roc.addFileArg(.{ .path = default_path });
    // }

    // switch (optimize) {
    //     .ReleaseFast, .ReleaseSafe => {
    //         run_build_roc.addArg("--optimize");
    //     },
    //     .ReleaseSmall => {
    //         run_build_roc.addArg("--opt-size");
    //     },
    //     else => {},
    // }

    const exe = b.addExecutable(.{
        .name = "platform",
        .root_source_file = b.path("platform/host/main.zig"),
        .target = target,
        .optimize = optimize,
    });

    const libxev = b.dependency("libxev", .{});
    exe.root_module.addImport("xev", libxev.module("xev"));

    // exe.step.dependOn(&run_build_roc.step);
    // exe.addObjectFile(.{ .path = "zig-cache/app.o" });

    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }
    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);
}
