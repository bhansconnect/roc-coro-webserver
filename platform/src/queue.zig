const std = @import("std");
const Allocator = std.mem.Allocator;

pub fn FlatQueue(comptime T: type) type {
    return struct {
        const Self = @This();

        data: []T,
        head: usize,
        tail: usize,
        allocator: Allocator,

        pub fn init(allocator: Allocator) Self {
            return .{
                .data = &[0]T{},
                .head = 0,
                .tail = 0,
                .allocator = allocator,
            };
        }

        pub fn deinit(self: *Self) void {
            self.data.deinit();
        }

        pub fn len(self: *Self) usize {
            const offset = if (self.tail < self.head) self.data.len else 0;
            return (self.tail + offset) - self.head;
        }

        pub fn push(self: *Self, elem: T) !void {
            if (self.len() == self.data.len) {
                const old_len = self.data.len;
                const new_capacity = calculate_capacity(T, old_len, old_len + 1);
                self.data = try self.allocator.realloc(self.data, new_capacity * @sizeOf(T));
                self.head += old_len;
            }
            self.data[self.head] = elem;
            self.head = inc_wrap(self.head, self.data.len);
        }

        pub fn push_many(self: *Self, elems: []const T) !void {
            if (self.len() + elems.len > self.data.len) {
                const old_len = self.data.len;
                const new_capacity = calculate_capacity(T, old_len, old_len + elems.len);
                self.data = try self.allocator.realloc(self.data, new_capacity * @sizeOf(T));
                self.head += old_len;
            }
            if (self.head + elems.len < self.data.len) {
                // Can copy all in one go.
                std.mem.copyForwards(T, self.data[self.head..(self.head + elems.len)], elems);
            } else {
                // Have to copy in two parts.
                const size = self.data.len - self.head;
                std.mem.copyForwards(T, self.data[self.head..], elems[0..size]);
                const rem_size = elems.len - size;
                std.mem.copyForwards(T, self.data[0..rem_size], elems[size..]);
            }
            self.head = inc_n_wrap(self.head, elems.len, self.data.len);
        }

        pub fn pop(self: *Self) !T {
            if (self.len() == 0) {
                return error.QueueEmpty;
            }
            const elem = self.data[self.tail];
            self.tail = inc_wrap(self.tail, self.data.len);
            return elem;
        }

        pub fn pop_many(self: *Self, out: []T) !void {
            if (self.len() < out.len) {
                return error.NotEnoughElements;
            }
            if (self.tail + out.len < self.data.len) {
                // Can copy all in one go.
                std.mem.copyForwards(T, out, self.data[self.tail..(self.tail + out.len)]);
            } else {
                // Have to copy in two parts.
                const size = self.data.len - self.tail;
                std.mem.copyForwards(T, out[0..size], self.data[self.head..]);
                const rem_size = out.len - size;
                std.mem.copyForwards(T, out[size..], self.data[0..rem_size]);
            }
            self.tail = inc_n_wrap(self.tail, out.len, self.data.len);
        }
    };
}

pub fn FixedFlatQueue(comptime T: type) type {
    return struct {
        const Self = @This();

        data: []T,
        head: usize,
        tail: usize,

        pub fn init(buffer: []T) Self {
            return .{
                .data = buffer,
                .head = 0,
                .tail = 0,
            };
        }

        pub fn deinit(self: *Self) void {
            self.data.deinit();
        }

        pub fn len(self: *Self) usize {
            const offset = if (self.tail < self.head) self.data.len else 0;
            return (self.tail + offset) - self.head;
        }

        pub fn available(self: *Self) usize {
            return self.data.len - self.len();
        }

        pub fn push(self: *Self, elem: T) !void {
            if (self.len() == self.data.len) {
                return error.QueueFull;
            }
            self.data[self.head] = elem;
            self.head = inc_wrap(self.head, self.data.len);
        }

        pub fn push_many(self: *Self, elems: []T) !void {
            if (self.len() + elems.len > self.data.len) {
                return error.QueueFull;
            }
            if (self.head + elems.len < self.data.len) {
                // Can copy all in one go.
                std.mem.copyForwards(T, self.data[self.head..(self.head + elems.len)], elems);
            } else {
                // Have to copy in two parts.
                const size = self.data.len - self.head;
                std.mem.copyForwards(T, self.data[self.head..], elems[0..size]);
                const rem_size = elems.len - size;
                std.mem.copyForwards(T, self.data[0..rem_size], elems[size..]);
            }
            self.head = inc_n_wrap(self.head, elems.len, self.data.len);
        }

        pub fn pop(self: *Self) !T {
            if (self.len() == 0) {
                return error.QueueEmpty;
            }
            const elem = self.data[self.tail];
            self.tail = inc_wrap(self.tail, self.data.len);
            return elem;
        }

        pub fn pop_many(self: *Self, out: []T) !void {
            if (self.len() < out.len) {
                return error.NotEnoughElements;
            }
            if (self.tail + out.len < self.data.len) {
                // Can copy all in one go.
                std.mem.copyForwards(T, out, self.data[self.tail..(self.tail + out.len)]);
            } else {
                // Have to copy in two parts.
                const size = self.data.len - self.tail;
                std.mem.copyForwards(T, out[0..size], self.data[self.head..]);
                const rem_size = out.len - size;
                std.mem.copyForwards(T, out[size..], self.data[0..rem_size]);
            }
            self.tail = inc_n_wrap(self.tail, out.len, self.data.len);
        }
    };
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

fn calculate_capacity(comptime T: type, old_capacity: usize, requested_length: usize) usize {
    const element_width = @sizeOf(T);

    var new_capacity: usize = 0;
    if (element_width == 0) {
        return requested_length;
    } else if (old_capacity == 0) {
        new_capacity = 64 / element_width;
    } else if (old_capacity < 4096 / element_width) {
        new_capacity = old_capacity * 2;
    } else if (old_capacity > 4096 * 32 / element_width) {
        new_capacity = old_capacity * 2;
    } else {
        new_capacity = (old_capacity * 3 + 1) / 2;
    }

    return @max(new_capacity, requested_length);
}
