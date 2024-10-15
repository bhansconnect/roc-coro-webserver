const std = @import("std");
const xev = @import("xev");
const log = std.log.scoped(.platform);
const Allocator = std.mem.Allocator;

pub const std_options: std.Options = .{
    .log_level = .info,
};

var gpa: std.heap.GeneralPurposeAllocator(.{}) = .{};
var allocator: Allocator = gpa.allocator();

pub fn main() !void {
    // TODO: make the loop global.
    // It will be run by any thread without work or the system monitor.
    var root_loop = try xev.Loop.init(.{});
    defer root_loop.deinit();

    // For now just run the socket accepting single threaded.
    var address = try std.net.Address.parseIp4("127.0.0.1", 8000);
    const server = try xev.TCP.init(address);

    // Bind and listen
    try server.bind(address);
    try server.listen(128);

    // Is this needed? I think it is getting the port.
    // But we specify a specific port...
    const fd = if (xev.backend == .iocp) @as(std.os.windows.ws2_32.SOCKET, @ptrCast(server.fd)) else server.fd;
    var sock_len = address.getOsSockLen();
    try std.posix.getsockname(fd, &address.any, &sock_len);
    log.info("Starting server at: http://{}", .{address});

    // Setup accepting connections
    var c_accept: xev.Completion = undefined;
    server.accept(&root_loop, &c_accept, void, null, (struct {
        fn callback(
            _: ?*void,
            loop: *xev.Loop,
            _: *xev.Completion,
            accept_result: xev.AcceptError!xev.TCP,
        ) xev.CallbackAction {
            const socket = accept_result catch |err| {
                log.err("Failed to accept connection: {}", .{err});
                return .rearm;
            };
            log.debug("Accepting new TCP connection", .{});
            // Theoretically here we would queue a coroutine.
            // Just push into the global queue.
            // Another thread would eventual take the connection and handle it.
            // Note, the first thing a callback will do is probably read...
            // So we may want to read here no matter what.

            // For now, staying single threaded.
            // Add a new completion to handle the request.
            // This should probably be pooled instead of just allocating a new instance.
            var handler = allocator.create(Handler) catch unreachable;
            socket.read(loop, &handler.completion, .{ .slice = &handler.buffer }, Handler, handler, Handler.read_callback);
            return .rearm;
        }
    }).callback);

    try root_loop.run(.until_done);
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
        // If shutdowns fails, should this retry?
        allocator.destroy(self.?);
        return .disarm;
    }
};
