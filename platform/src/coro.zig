//! Coro is our coroutine implementation.
//! Coro is responsible for dealing with context switching.
//! Context switching to begin with is just cooperative.
//! Later, will add support for fully preemtive context switching.
//!
//! The stack plan is let mmap deal with everything.
//! Hopefully that is performant and just works.
//! It does add more cost to creating a coroutine, but coroutine stacks can be pooled and reused.
//! We also will use guarded pages to detect stack overflows.

const std = @import("std");
const builtin = @import("builtin");
const log = std.log.scoped(.platform);

const xev = @import("xev");
const scheduler = @import("scheduler.zig");

const Allocator = std.mem.Allocator;

const Instrinsics = switch (builtin.cpu.arch) {
    .aarch64 => struct {
        const switch_context_impl = @embedFile("asm/aarch64.s");
        const context_size = 21;

        fn setup_context(c: *Coroutine, sp: [*]u8) void {
            const frame_pointer_index = 18;
            const return_pointer_index = 19;
            const stack_pointer_index = 20;
            c.context[stack_pointer_index] = @intFromPtr(sp);
            c.context[frame_pointer_index] = @intFromPtr(sp);
            c.context[return_pointer_index] = @intFromPtr(&coroutine_wrapper);
        }
    },
    .x86_64 => switch (builtin.os.tag) {
        .windows => @compileError("Windows not supported yet (needs coroutine switch asm)"),
        else => struct {
            const switch_context_impl = @embedFile("asm/x86_64.s");
            const context_size = 7;

            fn setup_context(c: *Coroutine, stack_base: [*]u8) void {
                // Makes space to store the return address on the stack.
                var sp = stack_base;
                sp -= @sizeOf(usize);
                sp = @ptrFromInt(@intFromPtr(sp) & ~@as(usize, (STACK_ALIGN - 1)));

                const return_address_ptr = @as(*usize, @alignCast(@ptrCast(sp)));
                return_address_ptr.* = @intFromPtr(&coroutine_wrapper);

                const frame_pointer_index = 5;
                const stack_pointer_index = 6;
                c.context[stack_pointer_index] = @intFromPtr(sp);
                c.context[frame_pointer_index] = @intFromPtr(sp);
            }
        },
    },
    else => @compileError("Unsupported cpu architecture"),
};

extern fn switch_context_impl(current: [*]u64, target: [*]u64) void;
comptime {
    asm (Instrinsics.switch_context_impl);
}

pub fn switch_context(target: ?*Coroutine) void {
    if (current_coroutine) |current| {
        current_coroutine = target.?;
        switch_context_impl(&current.context, &target.?.context);
    } else {
        // We are in main currently.
        current_coroutine = target.?;
        switch_context_impl(&main_coroutine.context, &target.?.context);
    }
}

pub fn await_completion(c: *xev.Completion) void {
    // TODO: There are definitely bugs to fix since this needs to be disabled.
    // That said, they seem to be mac/kqueue specific?
    // std.debug.assert(current_coroutine.?.state == .active);
    scheduler.global.?.poller.submission_queue.push(c);
    current_coroutine.?.state = .awaiting_io;
    switch_context(&main_coroutine);
}

const STACK_SIZE = 1024 * 1024; // 1MB stack.
const STACK_ALIGN = 16;

pub threadlocal var main_coroutine: Coroutine = .{
    .context = std.mem.zeroes([Instrinsics.context_size]usize),
    .func = undefined,
    .arg = undefined,
    .mmap = undefined,
    .state = .active,
};
pub threadlocal var current_coroutine: ?*Coroutine = null;

pub const State = enum {
    active,
    awaiting_io,
    done,
};
pub const Coroutine = struct {
    const Self = @This();

    context: [Instrinsics.context_size]usize,
    func: *const fn (*void) void,
    arg: *void,
    mmap: []u8,
    state: State,
    // This enables the coroutines to be used in an intrusive queue.
    next: ?*Self = null,

    pub fn init(comptime Arg: type, comptime func: fn (Arg) void, arg: Arg) !*Coroutine {
        // Mmap the stack.
        const mmap = try std.posix.mmap(
            null,
            STACK_SIZE,
            std.posix.PROT.READ | std.posix.PROT.WRITE,
            .{ .TYPE = .PRIVATE, .ANONYMOUS = true },
            -1,
            0,
        );
        errdefer std.posix.munmap(mmap);

        // Setup 2 guard pages.
        const guard_page_size = 2 * std.mem.page_size;
        try std.posix.mprotect(mmap[0..guard_page_size], std.posix.PROT.NONE);

        // Put coroutine in the mmap and set it up.
        var sp = @as([*]u8, @alignCast(mmap.ptr + STACK_SIZE));
        sp -= @sizeOf(Coroutine);
        sp = @ptrFromInt(@intFromPtr(sp) & ~@as(usize, (@alignOf(Coroutine) - 1)));

        var c = @as(*Coroutine, @alignCast(@ptrCast(sp)));
        c.mmap = mmap;
        c.reinit(Arg, func, arg);

        return c;
    }

    pub fn reinit(self: *Self, comptime Arg: type, comptime func: fn (Arg) void, arg: Arg) void {
        // Ensure this coroutine is at the correct location.
        var sp = @as([*]u8, @alignCast(self.mmap.ptr + STACK_SIZE));
        sp -= @sizeOf(Coroutine);
        sp = @ptrFromInt(@intFromPtr(sp) & ~@as(usize, (@alignOf(Coroutine) - 1)));
        std.debug.assert(@intFromPtr(self) == @intFromPtr(sp));

        // Put the arg on the stack.
        sp -= @sizeOf(Arg);
        sp = @ptrFromInt(@intFromPtr(sp) & ~@as(usize, (@alignOf(Arg) - 1)));
        const arg_ptr = @as(*Arg, @alignCast(@ptrCast(sp)));
        arg_ptr.* = arg;

        // Align the stack for actual use.
        sp = @ptrFromInt(@intFromPtr(sp) & ~@as(usize, (STACK_ALIGN - 1)));

        self.func = struct {
            fn func_wrapper(ptr: *void) void {
                func(@as(*Arg, @alignCast(@ptrCast(ptr))).*);
            }
        }.func_wrapper;
        self.arg = @ptrCast(arg_ptr);
        Instrinsics.setup_context(self, sp);
        self.state = .active;
    }

    pub fn deinit(self: *Self) void {
        std.posix.munmap(@alignCast(self.mmap));
    }
};

fn coroutine_wrapper() void {
    var c = current_coroutine.?;
    c.func(c.arg);
    // Exit has to be a separate function.
    // If I use `&main_coroutine` here, zig will load the address too soon.
    // As such, we will try to return to the main_coroutine on the wrong thread.
    exit();
}

noinline fn exit() void {
    current_coroutine.?.state = .done;
    switch_context(&main_coroutine);
}
