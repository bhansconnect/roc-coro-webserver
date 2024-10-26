const std = @import("std");
const xev = @import("xev");
const coro = @import("coro.zig");
const scheduler = @import("scheduler.zig");

const Allocator = std.mem.Allocator;
const Coroutine = coro.Coroutine;
const Scheduler = scheduler.Scheduler;

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

            // TODO: reuse coroutines here.
            // Well, actually it would be best to just queue a zero sized read with a timeout here.
            // Only if that succeeds, grab a coroutine and run an individual request.
            // Once the request is done queue another zero sized read and puth the coroutine back in a pool for reuse.
            const c = Coroutine.init(xev.TCP, handle_tcp_requests, socket) catch |err| {
                log.err("Failed to create coroutine: {}", .{err});
                return .rearm;
            };

            scheduler.global.?.poller.ready_coroutines.push(c);
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

fn handle_tcp_requests(socket: xev.TCP) void {
    // TODO: don't use up a coroutine until a tcp connection is actively handling bytes.
    // Instead, through the tcp request in the io poll with a zero sized read (and idle timeout).
    // Once the read returns, claim a coroutine and lunch into handling exactly one request before pushing back to idle.
    // Make sure to have a lifo of coroutines and clean up old coroutines when the server is under low load.
    log.debug("Launched coroutine on thread: {}", .{scheduler.executor_index});

    var timer = try xev.Timer.init();
    defer timer.deinit();
    outer: while (true) {
        // We don't want to waste memory for every single idle connection.
        // As such, we first do a zero byte read (in the future, this would be dealt with before launching a coroutine).
        // Once that read succeeds, we know that the os has data waiting for us.
        // Technically, it would next be best to directly call the os read method instead of going back to libxev.
        // For simplicity, we directly use libxev for now even though data should be ready for us.
        var idle_buffer: [0]u8 = undefined;
        const len = socket_read(socket, &idle_buffer) catch |err| {
            if (err != error.ConnectionReset and err != error.ConnectionResetByPeer and err != error.EOF) {
                log.warn("Failed to read from tcp connection: {}", .{err});
            }
            break :outer;
        };
        std.debug.assert(len == 0);

        // We have data. This is now an active TCP conection.

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
                break :outer;
            };
        }
    }
    socket_close(socket);
}

// This function is noinline to ensure it's header buffer is only
// allocated
noinline fn handle_request() void {
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
    // 4. If a request is too big (16KB limit), simply fail it.
}

fn sleep(timer: *xev.Timer, millis: u64) xev.Timer.RunError!void {
    const SleepState = struct {
        coroutine: *Coroutine,
        result: xev.Timer.RunError!void,
    };
    var sleep_state = SleepState{
        .coroutine = coro.current_coroutine.?,
        .result = undefined,
    };
    var completion: xev.Completion = undefined;
    // This may require locking the poller based on how timers work...
    timer.run(&scheduler.global.?.poller.loop, &completion, millis, SleepState, &sleep_state, struct {
        fn callback(
            state: ?*SleepState,
            _: *xev.Loop,
            _: *xev.Completion,
            result: xev.Timer.RunError!void,
        ) xev.CallbackAction {
            const c = state.?.*.coroutine;
            c.state = .active;
            state.?.*.result = result;
            scheduler.global.?.poller.ready_coroutines.push(c);
            return .disarm;
        }
    }.callback);

    coro.await_completion(&completion);
    log.debug("Loaded coroutine after sleep on thread: {}", .{scheduler.executor_index});
    return sleep_state.result;
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
