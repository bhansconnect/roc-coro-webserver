const std = @import("std");

pub fn main() !void {
    // Setup allocator
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();
    defer _ = gpa.deinit();

    // Grab args
    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    // Setup buffered stdout and stderr
    const stdout = std.io.getStdOut().writer();
    const stderr = std.io.getStdErr().writer();

    // Early exit on not enough args
    if (args.len < 2) {
        try stderr.print("not enough args for build_roc.\n", .{});
        std.process.exit(1);
    }

    // First arg is executable name (can be ignored)
    // Second is the file for roc to check and build.
    // Third is the optional optimization flag.
    const app_name = args[1];
    const optimize_flag = if (args.len >= 3) args[2] else "";

    // Run `roc check`
    const roc_check_args = [_][]const u8{ "roc", "check", app_name };
    var roc_check = std.process.Child.init(
        &roc_check_args,
        allocator,
    );
    roc_check.stdout_behavior = .Pipe;
    roc_check.stderr_behavior = .Pipe;
    try roc_check.spawn();
    var roc_check_stdout = std.ArrayList(u8).init(allocator);
    var roc_check_stderr = std.ArrayList(u8).init(allocator);
    defer roc_check_stdout.deinit();
    defer roc_check_stderr.deinit();
    try roc_check.collectOutput(&roc_check_stdout, &roc_check_stderr, 4096);
    const roc_check_term = try roc_check.wait();

    const roc_check_success = roc_check_term.Exited == 0;
    const roc_check_warning = roc_check_term.Exited == 2;
    // On the error case, print the output of `roc check` and return and err.
    if (!roc_check_success and !roc_check_warning) {
        try stdout.print("{s}", .{roc_check_stdout.items});
        try stderr.print("{s}", .{roc_check_stderr.items});
        std.process.exit(1);
    }

    // `roc check` succeeded or only had warnings.
    // Proceed to `roc build`
    var roc_build_args = try std.ArrayList([]const u8).initCapacity(allocator, 10);
    defer roc_build_args.deinit();
    try roc_build_args.appendSlice(&[_][]const u8{ "roc", "build", "--no-link", "--output", ".zig-cache/app.o" });
    if (optimize_flag.len != 0) {
        try roc_build_args.append(optimize_flag);
    }
    try roc_build_args.append(app_name);
    var roc_build = std.process.Child.init(
        roc_build_args.items,
        allocator,
    );
    roc_build.stdout_behavior = .Pipe;
    roc_build.stderr_behavior = .Pipe;
    try roc_build.spawn();
    var roc_build_stdout = std.ArrayList(u8).init(allocator);
    var roc_build_stderr = std.ArrayList(u8).init(allocator);
    defer roc_build_stdout.deinit();
    defer roc_build_stderr.deinit();
    try roc_build.collectOutput(&roc_build_stdout, &roc_build_stderr, 4096);
    const roc_build_term = try roc_build.wait();

    // For roc build, we always output all of stdout and stderr, but only fail on errors.
    try stdout.print("{s}", .{roc_build_stdout.items});
    try stderr.print("{s}", .{roc_build_stderr.items});

    const roc_build_success = roc_build_term.Exited == 0;
    const roc_build_warning = roc_build_term.Exited == 2;
    if (!roc_build_success and !roc_build_warning) {
        std.process.exit(1);
    }
}
