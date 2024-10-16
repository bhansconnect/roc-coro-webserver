const std = @import("std");
const xev = @import("xev");
const coro = @import("coro.zig");

const Allocator = std.mem.Allocator;
const Coroutine = coro.Coroutine;

const log = std.log.scoped(.platform);
pub const std_options: std.Options = .{
    .log_level = .debug,
};

var gpa: std.heap.GeneralPurposeAllocator(.{}) = .{};
var allocator: Allocator = gpa.allocator();

const Poller = @import("poller.zig").Poller;
var poller = &@import("poller.zig").poller;
const Scheduler = @import("scheduler.zig").Scheduler;
var scheduler = &@import("scheduler.zig").scheduler;

pub fn main() !void {
    poller.* = try Poller.init(allocator);
    scheduler.* = Scheduler.init(allocator);

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
    server.accept(&poller.loop, &completion, void, null, (struct {
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
            // To keep things simple for now, just dump directly to the global queue.
            scheduler.lock.lock();
            scheduler.queue.push(c) catch unreachable;
            scheduler.lock.unlock();

            // poller.readyCoroutines.append(c) catch |err| {
            //     log.err("Failed to queue coroutine: {}", .{err});
            //     c.deinit();
            //     return .rearm;
            // };
            // var handler = allocator.create(Handler) catch unreachable;
            // socket.read(&poller.loop, &handler.completion, .{ .slice = &handler.buffer }, Handler, handler, Handler.read_callback);
            return .rearm;
        }
    }).callback);

    for (0..4) |i| {
        _ = try std.Thread.spawn(.{}, run_coroutines, .{i});
    }

    // For now, just running the poller in its own thread for simplicity.
    while (true) {
        // Sleep for 100 microseconds to avoid bashing the poller lock.
        std.posix.nanosleep(0, 100 * 1000);
        poller.lock.lock();
        try poller.loop.run(.no_wait);
        poller.lock.unlock();
    }
}

threadlocal var thread_id: usize = undefined;

fn run_coroutines(i: usize) !void {
    thread_id = i;
    log.info("Launching executor thread: {}", .{thread_id});
    while (true) {
        scheduler.lock.lock();
        const c = scheduler.pop() catch {
            scheduler.lock.unlock();
            // Sleep for 100 microseconds to avoid bashing the scheduler lock.
            std.posix.nanosleep(0, 100 * 1000);
            continue;
        };
        scheduler.lock.unlock();

        coro.switch_context(c);
        switch (c.state) {
            .active => {
                scheduler.lock.lock();
                try scheduler.push(c);
                scheduler.lock.unlock();
            },
            .awaiting_io => {
                // TODO: the full locking, unlocking, and completion submitting.
                poller.lock.unlock();
            },
            .done => {
                c.deinit();
            },
        }
    }
}

fn handle_tcp_requests(socket: xev.TCP) void {
    log.debug("Launched coroutine on thread: {}", .{thread_id});

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
        log.debug("Request: \n{s}\n", .{buffer[0..read_len]});

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
    // socket_close(socket);
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
    // TODO: we should not actually lock the pooler in a child coroutine.
    // We should generate a list of completions and share them with the main coroutine.
    // Then it should update the child coroutine to awaiting io and submit the completions.
    coro.current_coroutine.?.state = .awaiting_io;
    poller.lock.lock();
    socket.read(&poller.loop, &completion, .{ .slice = buffer }, ReadState, &read_state, struct {
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
            scheduler.lock.lock();
            scheduler.queue.push(c) catch unreachable;
            scheduler.lock.unlock();
            return .disarm;
        }
    }.callback);
    coro.switch_context(&coro.main_coroutine);
    log.debug("Loaded coroutine after read on thread: {}", .{thread_id});
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
    // TODO: we should not actually lock the pooler in a child coroutine.
    // We should generate a list of completions and share them with the main coroutine.
    // Then it should update the child coroutine to awaiting io and submit the completions.
    coro.current_coroutine.?.state = .awaiting_io;
    poller.lock.lock();
    socket.write(&poller.loop, &completion, .{ .slice = buffer }, WriteState, &write_state, struct {
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
            scheduler.lock.lock();
            scheduler.queue.push(c) catch unreachable;
            scheduler.lock.unlock();
            return .disarm;
        }
    }.callback);
    coro.switch_context(&coro.main_coroutine);
    log.debug("Loaded coroutine after write on thread: {}", .{thread_id});
    return write_state.result;
}

fn socket_close(socket: xev.TCP) void {
    var completion: xev.Completion = undefined;
    // TODO: we should not actually lock the pooler in a child coroutine.
    // We should generate a list of completions and share them with the main coroutine.
    // Then it should update the child coroutine to awaiting io and submit the completions.
    coro.current_coroutine.?.state = .awaiting_io;
    poller.lock.lock();
    socket.close(&poller.loop, &completion, coro.Coroutine, coro.current_coroutine, struct {
        fn callback(
            c: ?*coro.Coroutine,
            _: *xev.Loop,
            _: *xev.Completion,
            _: xev.TCP,
            x: xev.ShutdownError!void,
        ) xev.CallbackAction {
            log.info("Closed socked??? {}", .{x});
            c.?.state = .active;
            scheduler.lock.lock();
            scheduler.queue.push(c.?) catch unreachable;
            scheduler.lock.unlock();
            return .disarm;
        }
    }.callback);
    coro.switch_context(&coro.main_coroutine);
    log.debug("Loaded coroutine after close on thread: {}", .{thread_id});
}
