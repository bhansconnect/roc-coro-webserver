const std = @import("std");
const xev = @import("xev");
const coro = @import("coro.zig");
const scheduler = @import("scheduler.zig");
const poller = @import("poller.zig");

const libc = @cImport({
    @cInclude("stdlib.h");
});

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
// var gpa: std.heap.GeneralPurposeAllocator(.{ .safety = false, .thread_safe = true }) = .{};
// var allocator: Allocator = gpa.allocator();
var allocator: Allocator = std.heap.c_allocator;

pub fn main() !void {
    try scheduler.init_global(allocator, .{ .num_executors = try std.Thread.getCpuCount() / 2 });

    // Setup the socket.
    var address = try std.net.Address.parseIp4("0.0.0.0", 8000);
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
    // TODO: this isn't really quite what we want.
    // If data is ready, we want to skip this.
    // Once this fires, we want to do our first read without any extra queueing.
    socket.read(null, &idle_socket.completion, .{ .slice = idle_buffer[0..0] }, IdleSocket, idle_socket, struct {
        fn callback(
            idle_socket_inner: ?*IdleSocket,
            _: *xev.Loop,
            _: *xev.Completion,
            _: xev.TCP,
            _: xev.ReadBuffer,
            result: xev.ReadError!usize,
        ) xev.CallbackAction {
            const len = result catch |err| brk: {
                if (err == error.WouldBlock) {
                    return .rearm;
                }
                if (err == error.EOF) {
                    // libxev returns EOF incorrectly with kqueue.
                    // This is just cause we gave a zero byte read.
                    break :brk 0;
                }
                // TODO: on error, properly close the socket.
                if (err != error.ConnectionReset and err != error.ConnectionResetByPeer) {
                    log.err("unhandled error {}", .{err});
                }
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

const StrU8Map = std.StaticStringMap(u8);
const StrU8 = struct { []const u8, u8 };
const method_to_enum = StrU8Map.initComptime([_]StrU8{
    .{ "CONNECT", 0 },
    .{ "DELETE", 1 },
    .{ "GET", 2 },
    .{ "HEAD", 3 },
    .{ "OPTIONS", 4 },
    .{ "PATCH", 5 },
    .{ "POST", 6 },
    .{ "PUT", 7 },
    .{ "TRACE", 8 },
});

fn handle_request(socket: xev.TCP) void {
    log.debug("Launched coroutine on thread: {}", .{scheduler.executor_index});

    // TODO: everything here needs timeouts.

    // Rough simple parsing plan (ignoring timeout for now):
    // This will be a strict parser.
    // 0. It is fine to clear out extra empty lines before the starte line.
    // 1. scan for "\r\n" and log them (limit max new lines in header to x)
    //    - Optional, after first new line, validate core of request method, uri, and http version.
    //    - Statically scan for method and limit to valid types (convert to enum).
    //    - Zig static string map can be used for the method to enum conversion.
    //    - Note, it is valid to just check for "\n" as long as we also check that their are no lone "\r" characters
    // 2. On double newline, consider the header fully loaded and process it.
    // 3. Split it line into key and value pairs for passing to roc.
    // 4. While scan, check for host (it's required) and content length  (eventually support content encoding "chunked" required).
    //    - No content length is valid. Means no body
    // 5. Also scan for the keep alive state and mimetype.
    // 6. For now, ignore any sort of compression and context encoding.
    // 7. In general be strict and fail fast if possible.
    //
    // After header is parsed, load in a loop until the body is parsed.
    // If everything fits in 16kb, just load in the buffer.
    // Otherwise, allocate a new buffer and load the full body in that (this buffer should be from a lifo perferably).
    //
    // Extra defense notes:
    // 0. When in doubt 400 and close.
    // 1. Everything needs a timeout and cancelation. This protects from things like sloworis.
    // 2. We should generally fail fast, respond with an error, and close connections.
    // 3. We need to be careful to block broken unicode and trick headers.
    // 4. If a request headers are too big (16KB limit), simply fail it (also maybe limit body size).
    // 5. must give roc bytes or scan to ensure valid utf-8

    // TODO: actually use some functions and clean up this repetitive mess.

    var buffer_len: usize = 0;
    var buffer: [16 * 1024]u8 align(@alignOf(u64)) = undefined;

    // Kick off the first read.
    // We have an empty buffer and the os is ready.
    // Theoretically this could be a direct read without the poller.
    buffer_len += socket_read(socket, buffer[buffer_len..]) catch |err| {
        if (err != error.ConnectionReset and err != error.ConnectionResetByPeer and err != error.EOF) {
            log.warn("Failed to read from tcp connection: {}", .{err});
        }
        // TODO: send error if needed before closing the socket?
        socket_close(socket);
        return;
    };

    // TODO: decide what the max number of header lines should be.
    const MAX_HEADER_LINES = 128;
    var header_lines: [MAX_HEADER_LINES]u16 = undefined;
    var header_lines_len: usize = 0;

    var scanned: usize = 0;
    skip_blanks: while (true) {
        // This should be pretty dang rare.
        // HTTP spec recommends skipping at least 1 of these.
        // We will skip all of them.
        while (scanned + 1 < buffer_len) : (scanned += 2) {
            const rn_match = buffer[scanned] == '\r' and buffer[scanned + 1] == '\n';
            if (!rn_match) {
                break :skip_blanks;
            }
        }

        if (buffer_len == buffer.len) {
            // Hit limit for max header size.
            // TODO: send error before closing the socket
            log.err("close: max size too large", .{});
            socket_close(socket);
            return;
        }
        // Still in new lines. Read more data.
        buffer_len += socket_read(socket, buffer[buffer_len..]) catch |err| {
            if (err != error.ConnectionReset and err != error.ConnectionResetByPeer and err != error.EOF) {
                log.warn("Failed to read from tcp connection: {}", .{err});
            }
            // TODO: send error if needed before closing the socket?
            socket_close(socket);
            return;
        };
    }
    header_lines[0] = @intCast(scanned);
    header_lines_len = 1;

    load_header: while (true) {
        // use swar (cause real simd is more complex and hardware specific) to scan for newlines.
        // At the same time, scan for `\r`. Lone `\r` must return an error.
        // TODO: should swar use u128 or u256? is u64 enough?
        const r_needle: u64 = 0x0D0D_0D0D_0D0D_0D0D;
        const n_needle: u64 = 0x0A0A_0A0A_0A0A_0A0A;
        // This only moves by 7 cause we are scanning pairs of 2 bytes. So last byte can't be check in pair with byte after.
        while (scanned + 7 < buffer_len) {
            var bytes: u64 = undefined;
            // TODO: is there a more efficient way to load this int?
            @memcpy(std.mem.asBytes(&bytes), buffer[scanned .. scanned + 8]);

            var r_match = ~(r_needle ^ bytes);
            r_match &= r_match >> 1;
            r_match &= r_match >> 2;
            r_match &= r_match >> 4;
            r_match &= 0x0101_0101_0101_0101;
            // r_match is shifted to line up with n_match
            const r_match_shift = r_match << 8;

            var n_match = ~(n_needle ^ bytes);
            n_match &= n_match >> 1;
            n_match &= n_match >> 2;
            n_match &= n_match >> 4;
            n_match &= 0x0101_0101_0101_0101;

            const bare_r_or_n = r_match_shift ^ n_match;
            if (bare_r_or_n != 0) {
                // Invalid: bare `\r` not allowed.
                // At least for now, we are also a strict parser. So bare `\n` is invalid as well.
                // TODO: send error before closing the socket
                log.err("close: bare \\r or \\n", .{});
                socket_close(socket);
                return;
            }
            const rn_match = r_match_shift & n_match;
            if (rn_match == 0) {
                // No match at all, increment by 8 if no `\r`, otherwise by 7 for trailing `\r`.
                scanned += @intFromBool(r_match == 0);
                scanned += 7;
                continue;
            }

            // We have a `\r\n`. Log the newline and only increment just past it.
            const n_offset = scanned + @ctz(n_match) / 8;
            const line_start = n_offset + 1;
            scanned = line_start;
            if (header_lines_len >= header_lines.len) {
                // Hit max number of new lines for a header.
                // TODO: send error before closing the socket
                log.err("close: too many lines", .{});
                socket_close(socket);
                return;
            }
            header_lines[header_lines_len] = @intCast(line_start);
            header_lines_len += 1;

            if (header_lines[header_lines_len -| 2] == (header_lines[header_lines_len - 1] - 2)) {
                // Two newlines in a row.
                // Full header loaded.
                break :load_header;
            }
        }

        // Scan final tail 1 byte at a time.
        while (scanned + 1 < buffer_len) {
            if (buffer[scanned] == '\r') {
                if (buffer[scanned + 1] != '\n') {
                    // Invalid: bare `\r` not allowed.
                    // At least for now, we are also a strict parser. So bare `\n` is invalid as well.
                    // TODO: send error before closing the socket
                    log.err("close: bare \\r", .{});
                    socket_close(socket);
                    return;
                }

                // We have a `\r\n`. Log the newline and only increment just past it.
                const line_start = scanned + 2;
                scanned = line_start;
                if (header_lines_len >= header_lines.len) {
                    // Hit max number of new lines for a header.
                    // TODO: send error before closing the socket
                    log.err("close: too many lines", .{});
                    socket_close(socket);
                    return;
                }
                header_lines[header_lines_len] = @intCast(line_start);
                header_lines_len += 1;

                if (header_lines[header_lines_len -| 2] == (header_lines[header_lines_len - 1] - 2)) {
                    // Two newlines in a row.
                    // Full header loaded.
                    break :load_header;
                }
                continue;
            } else if (buffer[scanned] == '\n') {
                // At least for now, we are also a strict parser. So bare `\n` is invalid as well.
                // TODO: send error before closing the socket
                log.err("close: bare \\n", .{});
                socket_close(socket);
                return;
            }
            scanned += 1;
        }

        if (buffer_len == buffer.len) {
            // Hit limit for max header size.
            // TODO: send error before closing the socket
            log.err("close: max size too large", .{});
            socket_close(socket);
            return;
        }

        // No end to the header yet. Read more data.
        buffer_len += socket_read(socket, buffer[buffer_len..]) catch |err| {
            if (err != error.ConnectionReset and err != error.ConnectionResetByPeer and err != error.EOF) {
                log.warn("Failed to read from tcp connection: {}", .{err});
            }
            // TODO: send error if needed before closing the socket?
            socket_close(socket);
            return;
        };
    }
    log.debug("request headers:\n{s}", .{buffer[0..scanned]});
    log.debug("header lines: {any}", .{header_lines[0..header_lines_len]});

    // Parse the request line.
    // This could probably use swar or simd, but I just want it to be simple.
    // Don't need it to be long like the above right now.
    // `-2` used below is used to avoid the trailing `\r\n`.
    const request_line = buffer[header_lines[0] .. header_lines[1] - 2];
    var it = std.mem.splitScalar(u8, request_line, ' ');
    const method = it.first();
    const uri = it.next();
    const version = it.next();
    if (uri == null or version == null or it.next() != null) {
        // First line is incorrect either missing a required elements or has extra elements.
        // TODO: send 400
        log.err("close: bad request line: {s}", .{request_line});
        socket_close(socket);
        return;
    }
    var method_enum: u8 = 0;
    if (method_to_enum.get(method)) |e| {
        method_enum = e;
    } else {
        // TODO: send 400
        log.err("close: bad method: {s}", .{method});
        socket_close(socket);
        return;
    }
    const subversion = version.?[version.?.len - 1];
    const good_subversion = subversion == '0' or subversion == '1';
    if (!std.mem.eql(u8, version.?[0 .. version.?.len - 1], "HTTP/1.") or !good_subversion) {
        // TODO: send 400
        log.err("close: bad http version: {s}", .{method});
        socket_close(socket);
        return;
    }

    // TODO: handle uri validation.

    // These will be RocList or RocStr in the future.
    const Header = struct {
        key: []const u8,
        value: []const u8,
    };
    // `-1` for request line. `-2` for trailing empty lines.
    const headers_len = header_lines_len - 3;
    var headers: [MAX_HEADER_LINES]Header = undefined;
    for (0..headers_len) |i| {
        // `-2` used below is used to avoid the trailing `\r\n`.
        const line = buffer[header_lines[i + 1]..(header_lines[i + 2] - 2)];

        // TODO: actually validate the characters here. for example null is not valid here.
        // Also, if we want them to be roc strings, they need to be utf-8.
        it = std.mem.splitScalar(u8, line, ':');
        const key = it.first();
        const value = std.mem.trim(u8, it.rest(), &[_]u8{ ' ', '\t' });

        headers[i] = .{ .key = key, .value = value };
    }

    for (headers[0..headers_len]) |h| {
        log.debug("header -> {s}:{s}", .{ h.key, h.value });
    }

    // TODO: ensure we have a Host header and reconstruct url.
    // TODO: check keep alive status.
    // TODO: check for countent length and load the full body.

    // TODO: Call into roc and setup a basic web request in roc to get the response.
    const out = roc__respondBoxed_1_exposed(RocStr{ .ptr = null, .len = 0, .cap = 0 });
    defer roc_str_decref(&out);
    const bytes = roc_str_bytes(&out);

    const response = std.fmt.allocPrint(allocator, "HTTP/1.1 200 OK\r\nContent-Type: text/plain; charset=utf-8\r\nContent-Length: {}\r\n\r\n{s}", .{ bytes.len, bytes }) catch |err| {
        // TODO: send 400
        log.err("failed to write response buffer: {?}", .{err});
        socket_close(socket);
        return;
    };
    defer allocator.free(response);

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

    // TODO: reminder this is http 1.1, we could have read multiple requests at once in the buffer.
    // If there is another request started in the buffer, we should loop back to keep reading.

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

fn sleep(millis: u64) xev.Timer.RunError!void {
    const SleepState = struct {
        coroutine: *Coroutine,
        result: xev.Timer.RunError!void,
    };
    var sleep_state = SleepState{
        .coroutine = coro.current_coroutine.?,
        .result = undefined,
    };
    var completion: xev.Completion = undefined;
    // This should be safe with some of my modifications.
    // At least on kqueue and epoll only looks to access a cached time...
    // Might need a lock though to actually be correct.
    var timer = try xev.Timer.init();
    defer timer.deinit();
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

// All the roc... at least for now...
const RocStr = extern struct {
    ptr: ?*u8,
    len: u64,
    cap: i64,
};

fn roc_str_bytes(str: *const RocStr) []const u8 {
    if (str.cap < 0) {
        // Is a small str.
        const bytes: [*]const u8 = @ptrCast(str);
        const len = bytes[@sizeOf(RocStr) - 1] & 0x7F;
        return bytes[0..len];
    } else {
        const bytes: [*]const u8 = @ptrCast(str.ptr.?);
        const len = str.len & 0x7FFF_FFFF_FFFF_FFFF;
        return bytes[0..len];
    }
}

const REFCOUNT_MAX: isize = 0;
pub const REFCOUNT_ONE: isize = std.math.minInt(isize);

fn roc_str_decref(str: *const RocStr) void {
    if (str.cap < 0) {
        // Is a small str.
        return;
    }

    const rc: *isize = @ptrFromInt(@intFromPtr(str.ptr.?) - 8);
    if (rc.* == REFCOUNT_MAX) {
        // Constant refcount.
        return;
    }
    if (rc.* == REFCOUNT_ONE) {
        roc_dealloc(rc, 0);
        return;
    }

    rc.* -= 1;
}

extern fn roc__respondBoxed_1_exposed(RocStr) callconv(.C) RocStr;

export fn roc_fx_sleepMillis(ms: u64) void {
    sleep(ms) catch @panic("failed to sleep");
}

export fn roc_alloc(requested_size: usize, _: u32) callconv(.C) ?*anyopaque {
    return libc.malloc(requested_size);
}

export fn roc_realloc(old_ptr: [*]u8, new_size: usize, _: usize, _: u32) callconv(.C) ?*anyopaque {
    return libc.realloc(old_ptr, new_size);
}

export fn roc_dealloc(ptr: *anyopaque, _: u32) callconv(.C) void {
    return libc.free(ptr);
}

export fn roc_panic(msg: *RocStr, _: u32) callconv(.C) void {
    _ = msg;
    @panic("ROC PANICKED");
}

export fn roc_dbg(loc: *RocStr, msg: *RocStr, src: *RocStr) callconv(.C) void {
    _ = src;
    _ = msg;
    _ = loc;
    @panic("TODO");
    // var loc0 = str.strConcatC(loc.*, RocStr.fromSlice(&[1]u8{0}));
    // defer loc0.decref();
    // var msg0 = str.strConcatC(msg.*, RocStr.fromSlice(&[1]u8{0}));
    // defer msg0.decref();
    // var src0 = str.strConcatC(src.*, RocStr.fromSlice(&[1]u8{0}));
    // defer src0.decref();

    // w4.tracef("[%s] %s = %s\n", loc0.asU8ptr(), src0.asU8ptr(), msg0.asU8ptr());
}
