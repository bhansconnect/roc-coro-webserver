const std = @import("std");
const coro = @import("coro.zig");
const queue = @import("queue.zig");

const Allocator = std.mem.Allocator;

pub var scheduler: Scheduler = undefined;

// All scheduling state.
pub const Scheduler = struct {
    const Self = @This();
    lock: std.Thread.Mutex,
    // Theoretically this could be a lock free queue.
    queue: queue.FlatQueue(*coro.Coroutine),

    pub fn init(allocator: Allocator) Self {
        return .{
            .lock = .{},
            .queue = queue.FlatQueue(*coro.Coroutine).init(allocator),
        };
    }

    pub fn len(self: *Self) usize {
        return self.queue.len();
    }

    pub fn push(self: *Self, c: *coro.Coroutine) !void {
        try self.queue.push(c);
    }

    pub fn push_many(self: *Self, cs: []*coro.Coroutine) !void {
        try self.queue.push_many(cs);
    }

    pub fn pop(self: *Self) !*coro.Coroutine {
        return self.queue.pop();
    }

    pub fn pop_many(self: *Self, cs: []*coro.Coroutine) !void {
        try self.queue.pop_many(cs);
    }
};

// A thread that executes coroutines.
pub const Processor = struct {};
