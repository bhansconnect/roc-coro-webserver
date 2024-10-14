const std = @import("std");
const aio = @import("aio");
const coro = @import("coro");
const log = std.log.scoped(.coro_aio);

pub const aio_options: aio.Options = .{
    .debug = false, // set to true to enable debug logs
};

pub const coro_options: coro.Options = .{
    .debug = false, // set to true to enable debug logs
};

pub const std_options: std.Options = .{
    .log_level = .info,
};

pub fn main() !void {
    var gpa: std.heap.GeneralPurposeAllocator(.{}) = .{};
    defer _ = gpa.deinit();

    var socket: std.posix.socket_t = undefined;
    try coro.io.single(aio.Socket{
        .domain = std.posix.AF.INET,
        .flags = std.posix.SOCK.STREAM | std.posix.SOCK.CLOEXEC,
        .protocol = std.posix.IPPROTO.TCP,
        .out_socket = &socket,
    });

    const address = std.net.Address.initIp4(.{ 0, 0, 0, 0 }, 8000);
    try std.posix.setsockopt(socket, std.posix.SOL.SOCKET, std.posix.SO.REUSEADDR, &std.mem.toBytes(@as(c_int, 1)));
    if (@hasDecl(std.posix.SO, "REUSEPORT")) {
        try std.posix.setsockopt(socket, std.posix.SOL.SOCKET, std.posix.SO.REUSEPORT, &std.mem.toBytes(@as(c_int, 1)));
    }
    try std.posix.bind(socket, &address.any, address.getOsSockLen());
    try std.posix.listen(socket, 128);

    // var threads = try gpa.allocator().alloc(std.Thread, 4);
    // for (0..threads.len) |i| {
    //     threads[i] = try std.Thread.spawn(.{}, server_thread, .{ gpa.allocator(), socket, i });
    // }
    // for (0..threads.len) |i| {
    //     threads[i].join();
    // }
    try server_thread(gpa.allocator(), socket, 0);
}

fn server_thread(allocator: std.mem.Allocator, socket: std.posix.socket_t, thread_id: usize) !void {
    log.info("Launching Server Thread {}\n", .{thread_id});
    var scheduler = try coro.Scheduler.init(allocator, .{});
    defer scheduler.deinit();

    var tasks = std.ArrayList(HandlerTask).init(allocator);
    var have_tasks: coro.ResetEvent = .{};
    _ = try scheduler.spawn(accept_requests, .{ &scheduler, socket, &tasks, &have_tasks, thread_id }, .{});
    _ = try scheduler.spawn(clean_up_tasks, .{ &tasks, &have_tasks }, .{});

    try scheduler.run(.wait);
}

fn accept_requests(scheduler: *coro.Scheduler, socket: std.posix.socket_t, tasks: *std.ArrayList(HandlerTask), have_tasks: *coro.ResetEvent, thread_id: usize) !void {
    while (true) {
        log.info("Loop accept\n", .{});
        var client_socket: std.posix.socket_t = undefined;
        try coro.io.single(aio.Accept{ .socket = socket, .out_socket = &client_socket });

        const task = try scheduler.spawn(handler, .{ client_socket, thread_id }, .{});
        try tasks.append(task);
        if (!have_tasks.is_set) {
            have_tasks.set();
        }
    }
}

// Is this actually needed? Is there a better way to do this?
// Can tasks clean up after themselves?
fn clean_up_tasks(tasks: *std.ArrayList(HandlerTask), have_tasks: *coro.ResetEvent) !void {
    try have_tasks.wait();
    while (true) {
        if (tasks.items.len == 0) {
            have_tasks.reset();
            try have_tasks.wait();
        }
        var i: usize = 0;
        while (i < tasks.items.len) {
            // Ensure we break for the scheduler to run.
            try coro.io.single(aio.Nop{ .ident = 0 });
            if (tasks.items[i].isComplete()) {
                log.debug("Cleaning up a task\n", .{});
                // This will deinit the function and clean up resources.
                const task = tasks.swapRemove(i);
                task.complete(.wait);
            } else {
                i += 1;
            }
        }
    }
}

const HandlerTask = coro.Task.Generic(void);
fn handler(socket: std.posix.socket_t, thread_id: usize) void {
    log.info("Starting new handler on {}\n", .{thread_id});
    defer log.info("Closing handler\n", .{});

    // I should do a proper check for keepalive here?
    // And http headers in general I guess.
    var buf: [1024]u8 = undefined;
    var len: usize = 0;
    while (true) {
        coro.io.single(aio.Recv{ .socket = socket, .buffer = &buf, .out_read = &len }) catch break;
        log.debug("request:\n{s}\n\n", .{buf[0..len]});

        // This is the fake costly part, sleep for a bit (pretend this is some server web request)
        // Sleep 20ms
        // coro.io.single(aio.Timeout{ .ns = 20 * 1_000 * 1_000 }) catch break;

        const response =
            "HTTP/1.1 200 OK\r\nContent-Type: text/plain; charset=utf-8\r\nContent-Length: 13\r\n\r\nHello, World!";
        coro.io.single(aio.Send{ .socket = socket, .buffer = response }) catch break;
    }

    coro.io.single(aio.CloseSocket{ .socket = socket }) catch return;
}
