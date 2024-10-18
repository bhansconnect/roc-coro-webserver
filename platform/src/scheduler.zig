const std = @import("std");
const coro = @import("coro.zig");
const queue = @import("queue.zig");

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
    global.?.queue = queue.FlatQueue(*Coroutine).init(allocator);
    global.?.poller = try Poller.init(allocator);

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
    queue: queue.FlatQueue(*Coroutine),
    executors: []Executor,
    poller: Poller,

    pub fn len(self: *Self) usize {
        return self.queue.len();
    }

    pub fn push(self: *Self, c: *Coroutine) !void {
        try self.queue.push(c);
    }

    pub fn push_many(self: *Self, cs: []*Coroutine) !void {
        try self.queue.push_many(cs);
    }

    pub fn pop(self: *Self) !*Coroutine {
        return self.queue.pop();
    }

    pub fn pop_many(self: *Self, cs: []*Coroutine) !void {
        try self.queue.pop_many(cs);
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
                    } else |_| {}
                }
                // By default just loop the local queue.
                if (self.pop()) |c| {
                    next_coroutine = c;
                    break;
                } else |_| {}

                // Nothing local to do, try to grab a batch of waiting global work.
                // The double check on length avoids locking if the length is zero.
                if (sched.len() > 0) {
                    sched.lock.lock();
                    if (sched.len() > 0) {
                        const wanted = @min(@max(sched.len() / sched.executors.len, 1), self.available());
                        sched.pop_many(self.copy_buf[0..wanted]) catch unreachable;
                        sched.lock.unlock();

                        next_coroutine = self.copy_buf[0];
                        self.push_many(self.copy_buf[1..wanted]) catch unreachable;
                        break;
                    }
                    sched.lock.unlock();
                }

                // If out of work, try polling with no delay.
                if (poller.run_lock.tryLock()) {
                    defer poller.run_lock.unlock();
                    poller.add_lock.lock();
                    defer poller.add_lock.unlock();
                    try poller.loop.run(.no_wait);
                    var to_queue = poller.readyCoroutines.items;
                    if (to_queue.len > 0) {
                        next_coroutine = to_queue[0];
                        to_queue = to_queue[1..];
                        const local_count = @min(to_queue.len, self.available());
                        try self.push_many(to_queue[0..local_count]);
                        to_queue = to_queue[local_count..];
                        if (to_queue.len > 0) {
                            sched.lock.lock();
                            defer sched.lock.unlock();
                            try sched.push_many(to_queue);
                        }
                        poller.readyCoroutines.clearRetainingCapacity();
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
                            try sched.push_many(self.copy_buf[(thread_queue_size / 2)..]);
                            try sched.push(next_coroutine.?);
                            sched.lock.unlock();
                            break;
                        };
                    }
                },
                .awaiting_io => {
                    // TODO: the full locking, unlocking, and completion submitting.
                    // Ensure the tasks are actually submitted.
                    // Want to get the io running as fast as possible.
                    defer poller.add_lock.unlock();
                    // try poller.loop.submit();
                },
                .done => {
                    next_coroutine.?.deinit();
                },
            }
        }
    }

    pub fn len(self: *Self) usize {
        const offset = if (self.head < self.tail) self.data.len else 0;
        return (self.head + offset) - self.tail;
    }

    fn available(self: *Self) usize {
        return self.data.len - self.len();
    }

    fn push(self: *Self, elem: *Coroutine) !void {
        std.debug.assert(self.index == executor_index);
        var h = @atomicLoad(usize, &self.head, .acquire);
        while (true) {
            const t = self.tail;
            if (queue_len(h, t, self.data.len) == self.data.len) {
                return error.QueueFull;
            }
            self.data[self.head] = elem;
            if (@cmpxchgWeak(usize, &self.head, h, inc_wrap(h, self.data.len), .release, .acquire)) |next| {
                h = next;
                continue;
            }
            return;
        }
    }

    fn push_many(self: *Self, elems: []*Coroutine) !void {
        std.debug.assert(self.index == executor_index);
        var h = @atomicLoad(usize, &self.head, .acquire);
        while (true) {
            const t = self.tail;
            if (queue_len(h, t, self.data.len) + elems.len > self.data.len) {
                return error.QueueFull;
            }

            if (h + elems.len <= self.data.len) {
                // Can copy all in one go.
                std.mem.copyForwards(*Coroutine, self.data[h..(h + elems.len)], elems);
            } else {
                // Have to copy in two parts.
                const size = self.data.len - h;
                std.mem.copyForwards(*Coroutine, self.data[h..], elems[0..size]);
                const rem_size = elems.len - size;
                std.mem.copyForwards(*Coroutine, self.data[0..rem_size], elems[size..]);
            }

            if (@cmpxchgWeak(usize, &self.head, h, inc_n_wrap(h, elems.len, self.data.len), .release, .acquire)) |next| {
                h = next;
                continue;
            }
            return;
        }
    }

    fn pop(self: *Self) !*Coroutine {
        var t = @atomicLoad(usize, &self.tail, .acquire);
        while (true) {
            const h = self.head;
            if (h == t) {
                return error.QueueEmpty;
            }
            const elem = self.data[t];
            if (@cmpxchgWeak(usize, &self.tail, t, inc_wrap(t, self.data.len), .release, .acquire)) |next| {
                t = next;
                continue;
            }
            return elem;
        }
    }

    fn pop_many(self: *Self, out: []*Coroutine) !void {
        var t = @atomicLoad(usize, &self.tail, .acquire);
        while (true) {
            const h = self.head;
            if (queue_len(h, t, self.data.len) < out.len) {
                return error.NotEnoughElements;
            }
            if (t + out.len <= self.data.len) {
                // Can copy all in one go.
                std.mem.copyForwards(*Coroutine, out, self.data[t..(t + out.len)]);
            } else {
                // Have to copy in two parts.
                const size = self.data.len - t;
                std.mem.copyForwards(*Coroutine, out[0..size], self.data[t..]);
                const rem_size = out.len - size;
                std.mem.copyForwards(*Coroutine, out[size..], self.data[0..rem_size]);
            }
            if (@cmpxchgWeak(usize, &self.tail, t, inc_n_wrap(t, out.len, self.data.len), .release, .acquire)) |next| {
                t = next;
                continue;
            }
            return;
        }
    }
};

fn queue_len(h: usize, t: usize, len: usize) usize {
    const offset = if (h < t) len else 0;
    return (h + offset) - t;
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
