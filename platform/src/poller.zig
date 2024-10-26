//! Poller is responsible for dealing with all async IO (and maybe blocking io via background threads?).
//! Anytime a coroutine wants to do async io, it should submit the task to the poller.
//! After submitting, it should park itself and context switch away.
//!
//! We may want to allow coroutines a single step to skip waiting if all data happens to be ready.

const std = @import("std");
const xev = @import("xev");
const coro = @import("coro.zig");

const Allocator = std.mem.Allocator;

pub const idle_buffer_size = 64;

pub const IdleSocket = struct {
    completion: xev.Completion,
    socket: xev.TCP,
    // The goal of this buffer is to potentially read the first line.
    // It uses minimal resources, but can quick fail some http requests that are clearly invalid.
    // TODO: tune size.
    idle_buffer: [idle_buffer_size]u8,
    next: ?*IdleSocket,
};

pub const Poller = struct {
    const Self = @This();
    const SubmissionQueue = xev.queue_mpsc.Intrusive(xev.Completion);
    const ReadyQueue = xev.queue.Intrusive(coro.Coroutine);

    const CoroutinePool = xev.queue_mpsc.Intrusive(coro.Coroutine);
    const IdleSocketPool = xev.queue.Intrusive(IdleSocket);

    loop: xev.Loop,
    run_lock: std.Thread.Mutex,
    submission_queue: SubmissionQueue,
    ready_coroutines: ReadyQueue,

    // TODO: this should be a lifo.
    // Also, really old coroutines(30s? 10min?) should be freed every once and a while.
    coroutine_pool: CoroutinePool,

    // TODO: this should also be a lifo and cleanup all completions.
    // This also could probably be a list or something else basic.
    // It would just need to be sized to hold the max number of idle connections.
    // Cause there will be one queue read for each idle socket.
    // This will only ever be submitted a task in the poller.
    // As such, it will also be protected by the run_lock.
    idle_socket_pool: IdleSocketPool,

    // Due to the mpsc queues, poller must init in place.
    pub fn init(self: *Self) !void {
        self.loop = try xev.Loop.init(.{});
        self.run_lock = .{};
        self.ready_coroutines = .{};
        self.idle_socket_pool = .{};
        self.submission_queue.init();
        self.coroutine_pool.init();
    }

    pub fn deinit(self: *Self) void {
        self.loop.deinit();
    }
};
