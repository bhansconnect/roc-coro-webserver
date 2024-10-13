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

    var threads = try gpa.allocator().alloc(std.Thread, 4);
    for (0..4) |i| {
        threads[i] = try std.Thread.spawn(.{}, server_thread, .{ i, gpa.allocator(), socket });
    }
    for (0..4) |i| {
        threads[i].join();
    }
}

// This really should be some sort of fancier work stealing scheduler/thread pool.
// Instead, it is one scheduler per thread.
// Also schedulers attempt to accept any incoming connections.
fn server_thread(thread_id: usize, allocator: std.mem.Allocator, socket: std.posix.socket_t) !void {
    var scheduler = try coro.Scheduler.init(allocator, .{});
    defer scheduler.deinit();

    _ = try scheduler.spawn(accept_requests, .{ thread_id, &scheduler, socket }, .{});

    try scheduler.run(.wait);
}

fn accept_requests(thread_id: usize, scheduler: *coro.Scheduler, socket: std.posix.socket_t) !void {
    while (true) {
        var client_sock: std.posix.socket_t = undefined;
        try coro.io.single(aio.Accept{ .socket = socket, .out_socket = &client_sock });

        _ = try scheduler.spawn(handler, .{ thread_id, client_sock }, .{});
    }
}

fn handler(thread_id: usize, client_sock: std.posix.socket_t) !void {
    log.info("Starting new handler on {}\n", .{thread_id});
    defer log.info("Closing handler on {}\n", .{thread_id});

    // I should do a proper check for keepalive here?
    // And http headers in general I guess.
    var buf: [1024]u8 = undefined;
    var len: usize = 0;
    while (true) {
        try coro.io.single(aio.Recv{ .socket = client_sock, .buffer = &buf, .out_read = &len });
        log.debug("request:\n{s}\n\n", .{buf[0..len]});

        // This is the costly part, sleep for a bit (pretend this is some server web request)
        // Sleep 20ms
        try coro.io.single(aio.Timeout{ .ns = 20 * 1_000 * 1_000 });

        const response =
            "HTTP/1.1 200 OK\r\nContent-Type: text/plain; charset=utf-8\r\nContent-Length: 13\r\n\r\nHello, World!";
        try coro.io.single(aio.Send{ .socket = client_sock, .buffer = response });
    }
}
