//! Poller is responsible for dealing with all async IO (and maybe blocking io via background threads?).
//! Anytime a coroutine wants to do async io, it should submit the task to the poller.
//! After submitting, it should park itself and context switch away.
//!
//! We may want to allow coroutines a single step to skip waiting if all data happens to be ready.

const std = @import("std");
const xev = @import("xev");
const coro = @import("coro.zig");

const Allocator = std.mem.Allocator;

pub var poller: Poller = undefined;

pub const Poller = struct {
    const Self = @This();

    loop: xev.Loop,
    lock: std.Thread.Mutex,
    readyCoroutines: std.ArrayList(*coro.Coroutine),

    pub fn init(allocator: Allocator) !Self {
        return .{
            .loop = try xev.Loop.init(.{}),
            .lock = .{},
            .readyCoroutines = std.ArrayList(*coro.Coroutine).init(allocator),
        };
    }

    pub fn deinit(self: *Self) void {
        self.loop.deinit();
    }
};
