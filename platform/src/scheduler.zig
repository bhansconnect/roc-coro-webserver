const std = @import("std");
const xev = @import("xev");
const coro = @import("coro.zig");

const Allocator = std.mem.Allocator;
const Coroutine = coro.Coroutine;
const Poller = @import("poller.zig").Poller;

const log = std.log.scoped(.scheduler);

pub var global: ?*Scheduler = null;

pub fn init_global(allocator: Allocator, config: Scheduler.Config) !void {
    if (global != null) {
        @panic("Only support one global scheduler currently");
    }
    global = try allocator.create(Scheduler);
    global.?.lock = .{};
    global.?.queue = .{};
    global.?.length = 0;
    try global.?.poller.init();

    const num_executors = if (config.num_executors == 0) try std.Thread.getCpuCount() else config.num_executors;
    global.?.executors = try allocator.alloc(Executor, num_executors);
    for (global.?.executors, 0..) |*exec, i| {
        exec.* = try Executor.init(allocator, i, config.executor_config);
        exec.thread = try std.Thread.spawn(.{}, Executor.start, .{exec});
    }
}

// All scheduling state.
pub const Scheduler = struct {
    const Self = @This();

    pub const Config = struct {
        // zero means 1 per cpu core.
        num_executors: usize = 0,
        executor_config: Executor.Config = .{},
    };

    lock: std.Thread.Mutex,
    // Theoretically this could be a lock free queue.
    queue: xev.queue.Intrusive(Coroutine),
    length: usize,
    executors: []Executor,
    poller: Poller,

    pub fn is_empty(self: *Self) bool {
        return self.length == 0;
    }

    pub fn len(self: *Self) usize {
        return self.length;
    }

    pub fn push(self: *Self, c: *Coroutine) void {
        self.length += 1;
        self.queue.push(c);
    }

    pub fn push_many(self: *Self, cs: []*Coroutine) void {
        // For push many, there are smart ways to reduce the global scheduler lock.
        // The main one is the link all of the entries before locking the scheduler.
        // We should do that.
        // Then sumbit is updating just two pointers.
        for (cs) |c| {
            self.push(c);
        }
    }

    pub fn pop(self: *Self) ?*Coroutine {
        if (self.queue.pop()) |c| {
            self.length -= 1;
            return c;
        }
        return null;
    }
};

pub threadlocal var executor_index: usize = undefined;

// A thread that executes coroutines.
// The Executor has the queue built directly in.
// This enables it to control atomics and stay consistent.
const Executor = struct {
    const Self = @This();

    const Config = struct {
        queue_size: usize = 256,
    };

    thread: ?std.Thread = null,
    copy_buf: []*Coroutine,
    data: []*Coroutine,
    // In this queue, you push to tail and pop from head.
    head: usize,
    tail: usize,
    index: usize,

    fn init(allocator: Allocator, index: usize, config: Config) !Self {
        return .{
            .copy_buf = try allocator.alloc(*Coroutine, config.queue_size),
            .data = try allocator.alloc(*Coroutine, config.queue_size),
            .head = 0,
            .tail = 0,
            .index = index,
        };
    }

    fn start(self: *Self) !void {
        executor_index = self.index;
        log.info("Launching executor thread: {}", .{executor_index});
        const sched = global.?;
        const poller = &sched.poller;

        var tick: u8 = 0;
        while (true) {
            var next_coroutine: ?*Coroutine = null;
            while (next_coroutine == null) : (tick +%= 1) {
                // It has been a while, try to take one from the global scheduler.
                // This ensures nothing is left for too long in the global queue.
                if (tick % 61 == 0) {
                    sched.lock.lock();
                    const result = sched.pop();
                    sched.lock.unlock();
                    if (result) |c| {
                        next_coroutine = c;
                        break;
                    }
                }
                // By default just loop the local queue.
                if (self.pop()) |c| {
                    next_coroutine = c;
                    break;
                } else |_| {}

                // Nothing local to do, try to grab a batch of waiting global work.
                // The double check on length avoids locking if the length is zero.
                if (!sched.is_empty()) {
                    sched.lock.lock();
                    defer sched.lock.unlock();
                    if (!sched.is_empty()) {
                        var target = sched.len() / sched.executors.len + 1;
                        target = @min(sched.len(), target);
                        target = @min(self.cap() / 2, target);
                        next_coroutine = sched.pop() orelse unreachable;
                        for (1..target) |_| {
                            self.push(sched.pop() orelse unreachable) catch unreachable;
                        }
                        break;
                    }
                }

                // If out of work, try polling with no delay.
                if (poller.run_lock.tryLock()) {
                    defer poller.run_lock.unlock();
                    // TODO: we should add some time aspect to this.
                    // If things are not submitted often enough, a sysmon thread should run through this.
                    // Submit all of the awaiting work.
                    // TODO: Should there be a max number of submissions here?
                    // Theoretically this could be stuck forever as work is being queued in other threads.
                    while (poller.submission_queue.pop()) |c| {
                        poller.loop.add(c);
                    }
                    try poller.loop.run(.no_wait);
                    // First task is what we will work on next.
                    if (poller.ready_coroutines.pop()) |c| {
                        next_coroutine = c;
                    }
                    // Remaining tasks are put in queues.
                    while (!poller.ready_coroutines.empty()) {
                        var index: usize = 0;
                        while (poller.ready_coroutines.pop()) |c| {
                            self.copy_buf[index] = c;
                            index += 1;
                            if (index == self.copy_buf.len) {
                                break;
                            }
                        }
                        var to_queue = self.copy_buf[0..index];
                        const local_count = @min(to_queue.len, self.available());
                        try self.push_many(to_queue[0..local_count]);
                        to_queue = to_queue[local_count..];
                        if (to_queue.len > 0) {
                            sched.lock.lock();
                            defer sched.lock.unlock();
                            for (to_queue) |c| {
                                sched.push(c);
                            }
                        }
                    }
                    if (next_coroutine != null) {
                        break;
                    }
                }

                // TODO: Steal work from other executors.

                // Might be worth trying netpoller with a delay here.
                // That is what go does kinda...

                // Literally nothing to do. Take a rest.
                // 1ms is arbitrary.
                std.posix.nanosleep(0, 1000 * 1000);
            }
            coro.switch_context(next_coroutine.?);
            switch (next_coroutine.?.state) {
                .active => {
                    while (true) {
                        self.push(next_coroutine.?) catch {
                            // Local queue is full. Push half to global.
                            // First load all to buffer.
                            self.pop_many(self.copy_buf) catch {
                                // Failed to pop the items.
                                // Another thread must have stolen the work.
                                // Just push try again.
                                continue;
                            };

                            const thread_queue_size = self.data.len;
                            // Keep the first half that should execute sooner.
                            self.push_many(self.copy_buf[0..(thread_queue_size / 2)]) catch unreachable;

                            // Submit the rest to the global scheduler.
                            sched.lock.lock();
                            for (self.copy_buf[(thread_queue_size / 2)..]) |c| {
                                sched.push(c);
                            }
                            sched.push(next_coroutine.?);
                            sched.lock.unlock();
                        };
                        break;
                    }
                },
                .awaiting_io => {},
                .done => {
                    next_coroutine.?.deinit();
                },
            }
        }
    }

    pub fn cap(self: *Self) usize {
        return self.data.len - 1;
    }

    pub fn len(self: *Self) usize {
        return queue_len(self.head, self.tail, self.data.len);
    }

    fn available(self: *Self) usize {
        return self.cap() - self.len();
    }

    fn push(self: *Self, elem: *Coroutine) !void {
        std.debug.assert(self.index == executor_index);
        var t = @atomicLoad(usize, &self.tail, .acquire);
        while (true) {
            const h = self.head;
            if (queue_len(h, t, self.data.len) == self.cap()) {
                return error.QueueFull;
            }
            self.data[t] = elem;
            if (@cmpxchgWeak(usize, &self.tail, t, inc_wrap(t, self.data.len), .release, .acquire)) |next| {
                t = next;
                continue;
            }
            return;
        }
    }

    fn push_many(self: *Self, elems: []*Coroutine) !void {
        std.debug.assert(self.index == executor_index);
        if (elems.len == 0) return;

        var t = @atomicLoad(usize, &self.tail, .acquire);
        while (true) {
            const h = self.head;
            if (queue_len(h, t, self.data.len) + elems.len > self.cap()) {
                return error.QueueFull;
            }

            if (t + elems.len <= self.data.len) {
                // Can copy all in one go.
                std.mem.copyForwards(*Coroutine, self.data[t..(t + elems.len)], elems);
            } else {
                // Have to copy in two parts.
                const size = self.data.len - t;
                std.mem.copyForwards(*Coroutine, self.data[t..], elems[0..size]);
                const rem_size = elems.len - size;
                std.mem.copyForwards(*Coroutine, self.data[0..rem_size], elems[size..]);
            }

            if (@cmpxchgWeak(usize, &self.tail, t, inc_n_wrap(t, elems.len, self.data.len), .release, .acquire)) |next| {
                t = next;
                continue;
            }
            return;
        }
    }

    fn pop(self: *Self) !*Coroutine {
        var h = @atomicLoad(usize, &self.head, .acquire);
        while (true) {
            const t = self.tail;
            if (t == h) {
                return error.QueueEmpty;
            }
            const elem = self.data[h];
            if (@cmpxchgWeak(usize, &self.head, h, inc_wrap(h, self.data.len), .release, .acquire)) |next| {
                h = next;
                continue;
            }
            return elem;
        }
    }

    fn pop_many(self: *Self, out: []*Coroutine) !void {
        var h = @atomicLoad(usize, &self.head, .acquire);
        while (true) {
            const t = self.tail;
            if (queue_len(h, t, self.data.len) < out.len) {
                return error.NotEnoughElements;
            }
            if (h + out.len <= self.data.len) {
                // Can copy all in one go.
                std.mem.copyForwards(*Coroutine, out, self.data[h..(h + out.len)]);
            } else {
                // Have to copy in two parts.
                const size = self.data.len - h;
                std.mem.copyForwards(*Coroutine, out[0..size], self.data[h..]);
                const rem_size = out.len - size;
                std.mem.copyForwards(*Coroutine, out[size..], self.data[0..rem_size]);
            }
            if (@cmpxchgWeak(usize, &self.head, h, inc_n_wrap(h, out.len, self.data.len), .release, .acquire)) |next| {
                h = next;
                continue;
            }
            return;
        }
    }
};

fn queue_len(h: usize, t: usize, len: usize) usize {
    const offset = if (t < h) len else 0;
    return (t + offset) - h;
}

fn inc_n_wrap(index: usize, n: usize, len: usize) usize {
    std.debug.assert(n <= len);
    var i = index;
    i += n;
    const shift = if (i >= len) len else 0;
    const out = i - shift;
    std.debug.assert(out < len);
    return out;
}

fn inc_wrap(i: usize, len: usize) usize {
    return inc_n_wrap(i, 1, len);
}
