//! Poller is responsible for dealing with all async IO (and maybe blocking io via background threads?).
//! Anytime a coroutine wants to do async io, it should submit the task to the poller.
//! After submitting, it should park itself and context switch away.
//!
//! We may want to allow coroutines a single step to skip waiting if all data happens to be ready.

const std = @import("std");
const xev = @import("xev");
const coro = @import("coro.zig");

const Allocator = std.mem.Allocator;

pub const Poller = struct {
    const Self = @This();
    const SubmissionQueue = xev.queue_mpsc.Intrusive(xev.Completion);
    const ReadyQueue = xev.queue.Intrusive(coro.Coroutine);

    loop: xev.Loop,
    run_lock: std.Thread.Mutex,
    submission_queue: SubmissionQueue,
    ready_coroutines: ReadyQueue,

    // Due to the submission queue, poller must init in place.
    pub fn init(self: *Self) !void {
        self.loop = try xev.Loop.init(.{});
        self.run_lock = .{};
        self.ready_coroutines = .{};
        self.submission_queue.init();
    }

    pub fn deinit(self: *Self) void {
        self.loop.deinit();
    }
};
