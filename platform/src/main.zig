const std = @import("std");
const xev = @import("xev");
const coro = @import("coro.zig");

const Allocator = std.mem.Allocator;
const Coroutine = coro.Coroutine;
const Poller = @import("poller.zig").Poller;
const Scheduler = @import("scheduler.zig").Scheduler;

const log = std.log.scoped(.platform);
pub const std_options: std.Options = .{
    .log_level = .debug,
};

var gpa: std.heap.GeneralPurposeAllocator(.{}) = .{};
var allocator: Allocator = gpa.allocator();

var poller: Poller = undefined;
var sched: Scheduler = undefined;

pub fn main() !void {
    poller = try Poller.init(allocator);
    sched = Scheduler.init(allocator);

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
    var c_accept: xev.Completion = undefined;
    server.accept(&poller.loop, &c_accept, void, null, (struct {
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

            const c = Coroutine.init(xev.TCP, struct {
                fn handler(_: xev.TCP) void {
                    log.debug("launched coroutine!!!", .{});
                }
            }.handler, socket) catch |err| {
                log.err("Failed to create coroutine: {}", .{err});
                return .rearm;
            };
            // To keep things simple for now, just dump directly to the global queue.
            sched.lock.lock();
            sched.queue.push(c) catch |err| {
                sched.lock.unlock();
                log.err("Failed to queue coroutine: {}", .{err});
                c.deinit();
                return .rearm;
            };
            sched.lock.unlock();

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

    _ = try std.Thread.spawn(.{}, run_coroutines, .{});
    try poller.loop.run(.until_done);
}

fn run_coroutines() !void {
    while (true) {
        sched.lock.lock();
        const c = sched.pop() catch {
            sched.lock.unlock();
            // Sleep for 100 microseconds to avoid bashing the scheduler lock.
            std.posix.nanosleep(0, 100 * 1000);
            continue;
        };
        sched.lock.unlock();

        coro.switch_context(c);
        switch (c.state) {
            .active => {
                sched.lock.lock();
                try sched.push(c);
                sched.lock.unlock();
            },
            .done => {
                c.deinit();
            },
        }
    }
}

const Handler = struct {
    const Self = @This();

    // These all could theoretically go straight on the stack of the new coroutine.
    completion: xev.Completion,
    buffer: [4096]u8,

    // With coroutines, the callbacks won't actually do anything with the data.
    // They will just register the coroutine state change and push the coroutine into the global queue.

    fn read_callback(
        self: ?*Self,
        loop: *xev.Loop,
        _: *xev.Completion,
        socket: xev.TCP,
        rb: xev.ReadBuffer,
        len_result: xev.ReadError!usize,
    ) xev.CallbackAction {
        var d: [21]u64 = undefined;
        coro.switch_context(&d, &d);
        const len = len_result catch |err| {
            // I'm not sure this is correct, but I think we need to retry on would block.
            // Feels like something that libxev should handle on its own.
            if (err == error.WouldBlock) {
                return .rearm;
            }
            if (err != error.ConnectionReset and err != error.ConnectionResetByPeer and err != error.EOF) {
                log.warn("Failed to read from tcp connection: {}", .{err});
            }
            self.?.close(loop, socket);
            return .disarm;
        };
        // TODO: handle partial reads.
        // I'm a bit suprised that reading 0 bytes doesn't count as would block.
        if (len == 0) {
            return .rearm;
        }
        log.debug("Request: \n{s}\n", .{rb.slice[0..len]});

        // TODO: This is where we should parse the header, make sure it is valid.
        // Check the full lengh and keep polling if more is to come.
        // Also should check keep alive.

        const response =
            "HTTP/1.1 200 OK\r\nContent-Type: text/plain; charset=utf-8\r\nContent-Length: 13\r\n\r\nHello, World!";
        const slice = std.fmt.bufPrint(&self.?.buffer, response, .{}) catch |err| {
            log.warn("Failed to write to io buffer: {}", .{err});
            self.?.close(loop, socket);
            return .disarm;
        };
        socket.write(loop, &self.?.completion, .{ .slice = slice }, Self, self, Self.write_callback);
        return .disarm;
    }

    fn write_callback(
        self: ?*Self,
        loop: *xev.Loop,
        _: *xev.Completion,
        socket: xev.TCP,
        wb: xev.WriteBuffer,
        len_result: xev.WriteError!usize,
    ) xev.CallbackAction {
        var d: [21]u64 = undefined;
        coro.switch_context(&d, &d);
        const len = len_result catch |err| {
            // I'm not sure this is correct, but I think we need to retry on would block.
            // Feels like something that libxev should handle on its own.
            if (err == error.WouldBlock) {
                return .rearm;
            }
            if (err != error.ConnectionReset and err != error.ConnectionResetByPeer and err != error.EOF) {
                log.warn("Failed to write to tcp connection: {}", .{err});
            }
            self.?.close(loop, socket);
            return .disarm;
        };
        // TODO: handle partial writes.
        // I'm a bit suprised that writing 0 bytes doesn't count as would block.
        if (len == 0) {
            return .rearm;
        }
        log.debug("Response: \n{s}\n", .{wb.slice[0..len]});

        // Send back to reading. Just assuming keep alive for now.
        socket.read(loop, &self.?.completion, .{ .slice = &self.?.buffer }, Self, self, Self.read_callback);
        return .disarm;
    }

    fn close(self: *Self, loop: *xev.Loop, socket: xev.TCP) void {
        socket.close(loop, &self.completion, Self, self, close_callback);
    }

    fn close_callback(
        self: ?*Self,
        _: *xev.Loop,
        _: *xev.Completion,
        _: xev.TCP,
        _: xev.ShutdownError!void,
    ) xev.CallbackAction {
        var d: [21]u64 = undefined;
        coro.switch_context(&d, &d);
        // If shutdowns fails, should this retry?
        allocator.destroy(self.?);
        return .disarm;
    }
};
