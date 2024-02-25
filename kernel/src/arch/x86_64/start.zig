const std = @import("std");
const builtin = @import("builtin");
const options = @import("options");
const cpu = @import("cpu.zig");
const gdt = @import("gdt.zig");
const int = @import("int.zig");
const paging = @import("paging.zig");
const pmm = @import("../../mm/pmm.zig");
const acpi = @import("../../acpi.zig");
const vfs = @import("../../fs/vfs.zig");
const devfs = @import("../../fs/devfs.zig");
const initrd = @import("../../initrd.zig");
const crofs = @import("../../fs/crofs.zig");

const log = std.log.scoped(.core);

comptime {
    if (!builtin.is_test) {
        @export(_start, .{ .name = "_start" });
    }
}

fn _start() callconv(.C) noreturn {
    cpu.cli();

    for (0..4) |_| cpu.outb(0xE9, '\n');

    init() catch |e| switch (e) {
        inline else => |err| @panic("Error: " ++ @errorName(err)),
    };
    cpu.halt();
}

fn init() !void {
    log.info("Booting chain (v{})", .{options.version});

    gdt.init();
    int.init();
    paging.init();
    pmm.init();
    try acpi.init();
    try vfs.init();
    try devfs.init();
    try initrd.init();
    try crofs.init();

    try vfs.mountDevice("/dev/initrd", "/");

    {
        var gpa = std.heap.GeneralPurposeAllocator(.{}){};
        const allocator = gpa.allocator();
        const motd = try vfs.openPath("/etc/motd");
        defer motd.close();
        var buffer = try allocator.alloc(u8, motd.length);
        const read_bytes = motd.read(0, buffer);
        log.debug("MOTD: \"{s}\"", .{buffer[0..read_bytes]});
    }

    log.debug("Initalization used {} pages", .{pmm.countUsed()});

    log.info("Hello from chain", .{});
}

test {
    _ = std.testing.refAllDeclsRecursive(int);
    _ = std.testing.refAllDeclsRecursive(paging);
}
