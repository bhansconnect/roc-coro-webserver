const std = @import("std");
const xev = @import("xev");
const coro = @import("coro.zig");
const queue = @import("queue.zig");

const Allocator = std.mem.Allocator;
const Coroutine = coro.Coroutine;

const log = std.log.scoped(.platform);
pub const std_options: std.Options = .{
    .log_level = .info,
};

var gpa: std.heap.GeneralPurposeAllocator(.{}) = .{};
var allocator: Allocator = gpa.allocator();

const Poller = @import("poller.zig").Poller;
var poller = &@import("poller.zig").poller;
const Scheduler = @import("scheduler.zig").Scheduler;
var scheduler = &@import("scheduler.zig").scheduler;

const THREAD_COUNT = 4;

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

            poller.readyCoroutines.append(c) catch |err| {
                log.err("Failed to queue coroutine: {}", .{err});
                c.deinit();
                return .rearm;
            };
            return .rearm;
        }
    }).callback);

    var threads: [THREAD_COUNT]std.Thread = undefined;
    for (0..4) |i| {
        threads[i] = try std.Thread.spawn(.{}, run_coroutines, .{i});
    }
    for (threads) |t| {
        t.join();
    }
}

threadlocal var thread_id: usize = undefined;

fn run_coroutines(i: usize) !void {
    thread_id = i;
    log.info("Launching executor thread: {}", .{thread_id});

    const queue_size = 256;
    var copy_buf: [queue_size]*Coroutine = undefined;
    var local_queue_buf: [queue_size]*Coroutine = undefined;
    var local_queue = queue.FixedFlatQueue(*Coroutine).init(&local_queue_buf);

    var tick: u8 = 0;
    while (true) {
        var next_coroutine: ?*Coroutine = null;
        while (next_coroutine == null) : (tick +%= 1) {
            // It has been a while, try to take one from the global scheduler.
            // This ensures nothing is left for too long in the global queue.
            if (tick % 61 == 0) {
                scheduler.lock.lock();
                const result = scheduler.pop();
                scheduler.lock.unlock();
                if (result) |c| {
                    next_coroutine = c;
                    break;
                } else |_| {}
            }
            // By default just loop the local queue.
            if (local_queue.pop()) |c| {
                next_coroutine = c;
                break;
            } else |_| {}
            // If out of work, try polling.
            if (poller.run_lock.tryLock()) {
                defer poller.run_lock.unlock();
                poller.add_lock.lock();
                defer poller.add_lock.unlock();
                try poller.loop.run(.no_wait);
                var to_queue = poller.readyCoroutines.items;
                if (to_queue.len > 0) {
                    next_coroutine = to_queue[0];
                    to_queue = to_queue[1..];
                    const local_count = @min(to_queue.len, local_queue.available());
                    try local_queue.push_many(to_queue[0..local_count]);
                    to_queue = to_queue[local_count..];
                    if (to_queue.len > 0) {
                        scheduler.lock.lock();
                        defer scheduler.lock.unlock();
                        try scheduler.push_many(to_queue);
                    }
                    poller.readyCoroutines.clearRetainingCapacity();
                    break;
                }
            }

            // Last resort, grab a bunch from the global queue.
            scheduler.lock.lock();
            const len = scheduler.len();
            if (len > 0) {
                const wanted = @min(@max(len / THREAD_COUNT, 1), local_queue.available());
                scheduler.pop_many(copy_buf[0..wanted]) catch unreachable;
                scheduler.lock.unlock();

                next_coroutine = copy_buf[0];
                local_queue.push_many(copy_buf[1..wanted]) catch unreachable;
                break;
            }
            scheduler.lock.unlock();

            // Literally nothing to do. Take a rest.
            // 1ms is arbitrary.
            std.posix.nanosleep(0, 1000 * 1000);
        }
        coro.switch_context(next_coroutine.?);
        switch (next_coroutine.?.state) {
            .active => {
                local_queue.push(next_coroutine.?) catch {
                    // Local queue is full. Push half to global.
                    // First load all to buffer.
                    local_queue.pop_many(&copy_buf) catch unreachable;

                    // Keep the first half that should execute sooner.
                    local_queue.push_many(copy_buf[0..(queue_size / 2)]) catch unreachable;

                    // Submit the rest to the global scheduler.
                    scheduler.lock.lock();
                    try scheduler.push_many(copy_buf[(queue_size / 2)..]);
                    try scheduler.push(next_coroutine.?);
                    scheduler.lock.unlock();
                };
            },
            .awaiting_io => {
                // TODO: the full locking, unlocking, and completion submitting.
                // Ensure the tasks are actually submitted.
                // Want to get the io running as fast as possible.
                defer poller.add_lock.unlock();
                try poller.loop.submit();
            },
            .done => {
                next_coroutine.?.deinit();
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
                // if (err != error.ConnectionReset and err != error.ConnectionResetByPeer and err != error.EOF) {
                log.warn("Failed to read from tcp connection: {}", .{err});
                // }
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
                // if (err != error.ConnectionReset and err != error.ConnectionResetByPeer and err != error.EOF) {
                log.warn("Failed to write to tcp connection: {}", .{err});
                // }
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
    // TODO: we should not actually lock the pooler in a child coroutine.
    // We should generate a list of completions and share them with the main coroutine.
    // Then it should update the child coroutine to awaiting io and submit the completions.
    coro.current_coroutine.?.state = .awaiting_io;
    poller.add_lock.lock();
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
            poller.readyCoroutines.append(c) catch unreachable;
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
    poller.add_lock.lock();
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
            poller.readyCoroutines.append(c) catch unreachable;
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
    poller.add_lock.lock();
    socket.close(&poller.loop, &completion, coro.Coroutine, coro.current_coroutine, struct {
        fn callback(
            c: ?*coro.Coroutine,
            _: *xev.Loop,
            _: *xev.Completion,
            _: xev.TCP,
            _: xev.ShutdownError!void,
        ) xev.CallbackAction {
            c.?.state = .active;
            poller.readyCoroutines.append(c.?) catch unreachable;
            return .disarm;
        }
    }.callback);
    coro.switch_context(&coro.main_coroutine);
    log.debug("Loaded coroutine after close on thread: {}", .{thread_id});
}
