const std = @import("std");
const options = @import("options");
const cpu = @import("cpu.zig");

pub const std_options = struct {
    pub fn logFn(comptime message_level: std.log.Level, comptime scope: @Type(.EnumLiteral), comptime format: []const u8, args: anytype) void {
        var log_allocator_buf: [2048]u8 = undefined;
        var log_fba = std.heap.FixedBufferAllocator.init(&log_allocator_buf);
        const log_allocator = log_fba.allocator();

        const msg = std.fmt.allocPrint(log_allocator, switch (message_level) {
            .info => "\x1b[34m",
            .warn => "\x1b[33m",
            .err => "\x1b[31m",
            .debug => "\x1b[90m",
        } ++ "[" ++ @tagName(message_level) ++ "]\x1b[0m (" ++ @tagName(scope) ++ ") " ++ format ++ "\n", args) catch "LOG_FN_OOM";

        for (msg) |char| {
            cpu.outb(0xE9, char);
        }
    }
};

const log = std.log.scoped(.core);

export fn _start() callconv(.C) noreturn {
    init();
    cpu.halt();
}

fn init() void {
    log.info("Booting chain (v{})", .{options.version});
}
