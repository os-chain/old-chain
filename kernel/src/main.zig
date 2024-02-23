const std = @import("std");
const builtin = @import("builtin");
const hal = @import("hal.zig");

pub const os = @import("os.zig");

const log = std.log.scoped(.core);

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
        hal.debugcon(char);
    }
}

pub const std_options = .{
    .logFn = logFn,
};

pub fn panic(msg: []const u8, _: ?*std.builtin.StackTrace, _: ?usize) noreturn {
    @setCold(true);

    log.err("{s}", .{msg});

    hal.halt();
}

pub usingnamespace switch (builtin.cpu.arch) {
    .x86_64 => @import("arch/x86_64/start.zig"),
    else => |other| @compileError("Unimplemented for " ++ @tagName(other)),
};
