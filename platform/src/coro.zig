const builtin = @import("builtin");

extern fn switch_context_impl(current: [*]u64, target: [*]u64) void;
comptime {
    asm (@embedFile("asm/aarch64.s"));
}

const context_size =
    switch (builtin.cpu.arch) {
    .aarch64 => 21,
    else => @compileError("Unsupported cpu architecture"),
};

pub fn switch_context(current: *[context_size]u64, target: *[context_size]u64) void {
    switch_context_impl(current, target);
}
