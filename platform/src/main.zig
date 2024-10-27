const std = @import("std");
const xev = @import("xev");
const coro = @import("coro.zig");
const scheduler = @import("scheduler.zig");
const poller = @import("poller.zig");

const Allocator = std.mem.Allocator;
const Coroutine = coro.Coroutine;
const Scheduler = scheduler.Scheduler;
const IdleSocket = poller.IdleSocket;

const log = std.log.scoped(.platform);
pub const std_options: std.Options = .{
    .log_level = .info,
};

// There are still multiple large gain tasks that can be done to this platform for perf.
// Obviously, this platform is also mostly a shell. It needs at lot to be more robust.
// - No work stealing: This means too much work can be waiting in a single threads queue.
// - No reuse: Coroutines should be reused in LIFO order. On long timeouts should be freed.
// - Interacting with the global scheduler locks longer than necessary when pushing multiple items.
// - No time tracking: This will be useful for polling in the background and avoiding polling too much
// - No preemption: This will be important for cpu heavy tasks
// - Threads are not able to attempt work in a non-blocking form before passing off to the poller (if the data is there, it should just keep running).
// - The threads sleep for a pretty arbitrary amount of time and otherwise just spin.
// - Threads should run the poller with delay if they have truely nothing to do (reduces spinning by blocking only one thread).

// TODO: evaluate if GPA is slow and hurting perf.
// Might be better to use the c allocator or https://github.com/joadnacer/jdz_allocator/
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

            socket_set_idle(socket);
            return .rearm;
        }
    }).callback);

    // var queue_lengths = try allocator.alloc(usize, scheduler.global.?.executors.len + 1);
    // while (true) {
    //     std.posix.nanosleep(1, 0);
    //     queue_lengths[0] = scheduler.global.?.len();

    //     for (0..scheduler.global.?.executors.len) |i| {
    //         queue_lengths[i + 1] = scheduler.global.?.executors[i].len();
    //     }
    //     log.info("queue_lengths: {any}", .{queue_lengths});
    // }
    for (scheduler.global.?.executors) |e| {
        e.thread.?.join();
    }
}

fn socket_set_idle(socket: xev.TCP) void {
    // This function waits for the first bytes of an http request.
    // Once bytes are ready to be recieved, it launches a coroutine to actually handle the request.
    // This greatly reduces the memory cost of an idle socket.

    // TODO: add a timeout for max wait for headers bytes to come in.

    var idle_socket: *IdleSocket = undefined;
    if (scheduler.global.?.poller.idle_socket_pool.pop()) |s| {
        idle_socket = s;
    } else {
        idle_socket = allocator.create(IdleSocket) catch |err| {
            log.err("Failed to allocate idle socket: {}", .{err});
            // TODO: Should 500 and close socket.
            return;
        };
    }
    idle_socket.next = null;
    idle_socket.socket = socket;
    const idle_buffer = [_]u8{0};
    // Store the socket fd in the pointer to avoid any sort of extra allocation here.
    socket.read(null, &idle_socket.completion, .{ .slice = idle_buffer[0..0] }, IdleSocket, idle_socket, struct {
        fn callback(
            idle_socket_inner: ?*IdleSocket,
            _: *xev.Loop,
            _: *xev.Completion,
            _: xev.TCP,
            _: xev.ReadBuffer,
            result: xev.ReadError!usize,
        ) xev.CallbackAction {
            const len = result catch |err| {
                if (err == error.WouldBlock) {
                    return .rearm;
                }
                // TODO: on error, properly close the socket.
                log.err("unhandled error {}", .{err});
                return .disarm;
            };
            std.debug.assert(len == 0);

            if (scheduler.global.?.poller.coroutine_pool.pop()) |c| {
                c.reinit(xev.TCP, handle_request, idle_socket_inner.?.socket);
                scheduler.global.?.poller.ready_coroutines.push(c);
                scheduler.global.?.poller.idle_socket_pool.push(idle_socket_inner.?);
                return .disarm;
            }

            // Need to allocate a new coroutine.
            const c = Coroutine.init(xev.TCP, handle_request, idle_socket_inner.?.socket) catch |err| {
                log.err("Failed to create coroutine: {}", .{err});
                // TODO: Should 500 and close socket.
                return .disarm;
            };
            scheduler.global.?.poller.ready_coroutines.push(c);
            scheduler.global.?.poller.idle_socket_pool.push(idle_socket_inner.?);
            return .disarm;
        }
    }.callback);
    scheduler.global.?.poller.submission_queue.push(&idle_socket.completion);
}

fn handle_request(socket: xev.TCP) void {
    // The goal here is to parse an http request for roc.
    // This needs to be robust and secure in the long run.
    // Basic steps:
    // 1. Have a SWAR/SIMD scanner for for crln. Record the start of each line.
    //     1.5. Can we have something at the same time scan that everything is valid utf8 or fail fast?
    // 2. After the first new line, validate it is right http version and such. Fail fast if not.
    // 3. Just keep scanning until a double newline is hit (headers all recieved).
    // 4. Parse each header to ensure it is valid (maybe could be done with step 1?)
    // 5. Find content length header (or in the future content encoding, but skipping that for now).
    // 6. Allocate a buffer for the body if it doesn't fit directly in the header buffer (eventually reuse buffers).
    // 7. Copy first chunk of body over to new buffer.
    // 8. Recieve rest of body.
    // 9. Get everything in roc format and call roc.
    // Extra defense notes:
    // 1. Everything needs a timeout and cancelation. This protects from things like sloworis.
    // 2. We should generally fail fast, respond with an error, and close connections.
    // 3. We need to be careful to block broken unicode and trick headers.
    // 4. If a request headers are too big (16KB limit), simply fail it (also maybe limit body size).
    log.debug("Launched coroutine on thread: {}", .{scheduler.executor_index});

    // TODO: everything here needs timeouts.

    // This socket should be ready to go.
    // Lets give it a real buffer and load the headers/body.
    // TODO: make this a lot smarter. Actually handle parsing.
    // For now, just load the full request.
    // Also, do we need to worry about accidentally loading part of the next request?
    var scanned: usize = 0;
    var full_len: usize = 0;
    var buffer: [4096]u8 = undefined;
    // This double new line ends a header.
    const target = "\r\n\r\n";
    while (std.mem.indexOfPos(u8, buffer[0..full_len], scanned, target) == null) {
        scanned = full_len -| (target.len - 1);
        if (full_len >= buffer.len) {
            // TODO: send error if needed before closing the socket?
            socket_close(socket);
            return;
        }

        const len = socket_read(socket, buffer[full_len..]) catch |err| {
            if (err != error.ConnectionReset and err != error.ConnectionResetByPeer and err != error.EOF) {
                log.warn("Failed to read from tcp connection: {}", .{err});
            }
            // TODO: send error if needed before closing the socket?
            socket_close(socket);
            return;
        };
        full_len += len;
    }
    log.debug("Request:\n{s}\n\n", .{buffer[0..full_len]});

    // TODO: Call into roc and setup a basic web request in roc to get the response.

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
            // TODO: send error if needed before closing the socket?
            socket_close(socket);
            return;
        };
    }

    // TODO: Here we should close the socket if keep alive is off.

    // Return the socket to the idle pool.
    socket_set_idle(socket);
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
