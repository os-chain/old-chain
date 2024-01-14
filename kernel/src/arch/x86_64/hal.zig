const cpu = @import("cpu.zig");

pub fn halt() noreturn {
    cpu.halt();
}

pub fn debugcon(byte: u8) void {
    cpu.outb(0xE9, byte);
}
