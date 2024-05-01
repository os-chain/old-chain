const std = @import("std");
const builtin = @import("builtin");
const root = @import("root");
const options = @import("options");
const cpu = @import("cpu.zig");
const gdt = @import("gdt.zig");
const int = @import("int.zig");
const paging = @import("paging.zig");
const tss = @import("tss.zig");
const lapic = @import("lapic.zig");
const ioapic = @import("ioapic.zig");
const syscall = @import("syscall.zig");
const ps2 = @import("ps2.zig");
const smp = @import("../../smp.zig");

fn _start() callconv(.C) noreturn {
    cpu.cli();

    for (0..4) |_| cpu.outb(0xE9, '\n');

    root.start();

    cpu.halt();
}

pub fn initCpuBarebones() void {
    gdt.init();
    int.init();
    paging.init();
}

pub fn initCpu(allocator: std.mem.Allocator) !void {
    try tss.init(allocator);
    try lapic.init(allocator);
    ioapic.init();
    syscall.init();
}

pub fn initDevices(allocator: std.mem.Allocator) !void {
    try ps2.init(allocator);
}

pub fn deinit() void {
    ps2.deinit();
    lapic.deinit();
    tss.deinit();
}
