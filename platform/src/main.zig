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
    .log_level = .err,
};

pub fn main() !void {
    var gpa: std.heap.GeneralPurposeAllocator(.{}) = .{};
    defer _ = gpa.deinit();

    var scheduler = try coro.Scheduler.init(gpa.allocator(), .{});
    defer scheduler.deinit();
    var tpool: coro.ThreadPool = try coro.ThreadPool.init(gpa.allocator(), .{ .max_threads = 4 });
    defer tpool.deinit();

    _ = try scheduler.spawn(server, .{ &scheduler, &tpool }, .{});
    try scheduler.run(.wait);
}

fn server(scheduler: *coro.Scheduler, tpool: *coro.ThreadPool) !void {
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

    while (true) {
        var client_sock: std.posix.socket_t = undefined;
        try coro.io.single(aio.Accept{ .socket = socket, .out_socket = &client_sock });

        _ = try tpool.spawnForCompletition(scheduler, handler, .{client_sock}, .{});
    }
}

fn handler(client_sock: std.posix.socket_t) !void {
    log.info("Starting new handler\n", .{});
    defer log.info("Closing handler\n", .{});

    // I should do a proper check for keepalive here?
    // And http headers in general I guess.
    var buf: [1024]u8 = undefined;
    var len: usize = 0;
    while (true) {
        try coro.io.single(aio.Recv{ .socket = client_sock, .buffer = &buf, .out_read = &len });
        // Would check the header for keep alive here and inter a loop if so.
        // Otherwise, this is where we would handle http or just hand bytes off to roc.
        // Not sure best way to handle a request size limit.
        log.debug("request:\n{s}\n\n", .{buf[0..len]});

        const response =
            "HTTP/1.1 200 OK\r\nContent-Type: text/plain; charset=utf-8\r\nContent-Length: 13\r\n\r\nHello, World!";
        try coro.io.single(aio.Send{ .socket = client_sock, .buffer = response });
    }
    // try coro.io.single(aio.CloseSocket{ .socket = client_sock });
}
