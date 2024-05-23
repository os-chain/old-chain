const std = @import("std");
const cpu = @import("cpu.zig");

pub fn halt() noreturn {
    cpu.halt();
}

pub fn debugcon(byte: u8) void {
    @as(*volatile u8, @ptrFromInt(0x09000000)).* = byte;
}

pub const CoreInfo = cpu.CoreInfo;

pub fn enableInterrupts() void {
    cpu.daifclr();
}

pub fn disableInterrupts() void {
    cpu.daifset();
}

pub fn interruptsEnabled() void {
    const daif = asm volatile (
        \\mrs %[result], daif
        : [result] "=r" (-> u64),
    );

    return !(daif & @as(u64, 1 << 7)) or !(daif & @as(u64, 1 << 6));
}
