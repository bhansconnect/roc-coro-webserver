const std = @import("std");
const xev = @import("xev");
const coro = @import("coro.zig");
const queue = @import("queue.zig");
const scheduler = @import("scheduler.zig");

const Allocator = std.mem.Allocator;
const Coroutine = coro.Coroutine;
const Scheduler = scheduler.Scheduler;

const log = std.log.scoped(.platform);
pub const std_options: std.Options = .{
    .log_level = .info,
};

var gpa: std.heap.GeneralPurposeAllocator(.{}) = .{};
var allocator: Allocator = gpa.allocator();

pub fn main() !void {
    try scheduler.init_global(allocator, .{ .num_executors = try std.Thread.getCpuCount() / 2 });

    // Setup the socket.
    var address = try std.net.Address.parseIp4("127.0.0.1", 8000);
    const server = try xev.TCP.init(address);
    try server.bind(address);
    try server.listen(128);

    // Is this needed? I think it is getting the port.
    // But we specify a specific port...
    const fd = if (xev.backend == .iocp) @as(std.os.windows.ws2_32.SOCKET, @ptrCast(server.fd)) else server.fd;
    var socket_len = address.getOsSockLen();
    try std.posix.getsockname(fd, &address.any, &socket_len);
    log.info("Starting server at: http://{}", .{address});

    // Setup accepting connections.
    var completion: xev.Completion = undefined;
    server.accept(&scheduler.global.?.poller.loop, &completion, void, null, (struct {
        fn callback(
            _: ?*void,
            _: *xev.Loop,
            _: *xev.Completion,
            accept_result: xev.AcceptError!xev.TCP,
        ) xev.CallbackAction {
            const socket = accept_result catch |err| {
                log.err("Failed to accept connection: {}", .{err});
                return .rearm;
            };
            log.debug("Accepting new TCP connection", .{});

            const c = Coroutine.init(xev.TCP, handle_tcp_requests, socket) catch |err| {
                log.err("Failed to create coroutine: {}", .{err});
                return .rearm;
            };

            scheduler.global.?.poller.ready_coroutines.push(c);
            return .rearm;
        }
    }).callback);

    var queue_lengths = try allocator.alloc(usize, scheduler.global.?.executors.len + 1);
    while (true) {
        std.posix.nanosleep(1, 0);
        queue_lengths[0] = scheduler.global.?.len();

        for (0..scheduler.global.?.executors.len) |i| {
            queue_lengths[i + 1] = scheduler.global.?.executors[i].len();
        }
        log.info("queue_lengths: {any}", .{queue_lengths});
    }
}

fn handle_tcp_requests(socket: xev.TCP) void {
    log.debug("Launched coroutine on thread: {}", .{scheduler.executor_index});

    var buffer: [4096]u8 = undefined;

    // We technically should be checking keepalive, but for now, just loop.
    outer: while (true) {
        var read_len: usize = 0;
        // TODO: handle partial reads.
        // For now just re-read on any empty reads.
        while (read_len == 0) {
            const result = socket_read(socket, &buffer);
            read_len = result catch |err| {
                if (err != error.ConnectionReset and err != error.ConnectionResetByPeer and err != error.EOF) {
                    log.warn("Failed to read from tcp connection: {}", .{err});
                }
                break :outer;
            };
        }

        const response =
            "HTTP/1.1 200 OK\r\nContent-Type: text/plain; charset=utf-8\r\nContent-Length: 13\r\n\r\nHello, World!";

        var write_len: usize = 0;
        // TODO: handle partial reads.
        // For now just re-read on any empty reads.
        while (write_len == 0) {
            const result = socket_write(socket, response);
            write_len = result catch |err| {
                if (err != error.ConnectionReset and err != error.ConnectionResetByPeer and err != error.EOF) {
                    log.warn("Failed to write to tcp connection: {}", .{err});
                }
                break :outer;
            };
        }
    }
    socket_close(socket);
}

fn socket_read(socket: xev.TCP, buffer: []u8) xev.ReadError!usize {
    const ReadState = struct {
        coroutine: *Coroutine,
        result: xev.ReadError!usize,
    };
    var read_state = ReadState{
        .coroutine = coro.current_coroutine.?,
        .result = undefined,
    };

    var completion: xev.Completion = undefined;
    socket.read(null, &completion, .{ .slice = buffer }, ReadState, &read_state, struct {
        fn callback(
            state: ?*ReadState,
            _: *xev.Loop,
            _: *xev.Completion,
            _: xev.TCP,
            _: xev.ReadBuffer,
            result: xev.ReadError!usize,
        ) xev.CallbackAction {
            if (result == error.WouldBlock) {
                return .rearm;
            }
            const c = state.?.*.coroutine;
            c.state = .active;
            state.?.*.result = result;
            scheduler.global.?.poller.ready_coroutines.push(c);
            return .disarm;
        }
    }.callback);
    coro.await_completion(&completion);
    log.debug("Loaded coroutine after read on thread: {}", .{scheduler.executor_index});
    return read_state.result;
}

fn socket_write(socket: xev.TCP, buffer: []const u8) xev.WriteError!usize {
    const WriteState = struct {
        coroutine: *Coroutine,
        result: xev.WriteError!usize,
    };
    var write_state = WriteState{
        .coroutine = coro.current_coroutine.?,
        .result = undefined,
    };

    var completion: xev.Completion = undefined;
    socket.write(null, &completion, .{ .slice = buffer }, WriteState, &write_state, struct {
        fn callback(
            state: ?*WriteState,
            _: *xev.Loop,
            _: *xev.Completion,
            _: xev.TCP,
            _: xev.WriteBuffer,
            result: xev.WriteError!usize,
        ) xev.CallbackAction {
            if (result == error.WouldBlock) {
                return .rearm;
            }
            const c = state.?.*.coroutine;
            c.state = .active;
            state.?.*.result = result;
            scheduler.global.?.poller.ready_coroutines.push(c);
            return .disarm;
        }
    }.callback);
    coro.await_completion(&completion);
    log.debug("Loaded coroutine after write on thread: {}", .{scheduler.executor_index});
    return write_state.result;
}

fn socket_close(socket: xev.TCP) void {
    var completion: xev.Completion = undefined;
    socket.close(null, &completion, coro.Coroutine, coro.current_coroutine, struct {
        fn callback(
            c: ?*coro.Coroutine,
            _: *xev.Loop,
            _: *xev.Completion,
            _: xev.TCP,
            _: xev.ShutdownError!void,
        ) xev.CallbackAction {
            c.?.state = .active;
            scheduler.global.?.poller.ready_coroutines.push(c.?);
            return .disarm;
        }
    }.callback);
    coro.await_completion(&completion);
    log.debug("Loaded coroutine after close on thread: {}", .{scheduler.executor_index});
}
