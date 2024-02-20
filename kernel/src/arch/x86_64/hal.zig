const cpu = @import("cpu.zig");
const paging = @import("paging.zig");

pub fn halt() noreturn {
    cpu.halt();
}

pub fn debugcon(byte: u8) void {
    cpu.outb(0xE9, byte);
}

pub const physFromVirt = paging.physFromVirt;
pub const virtFromPhys = paging.virtFromPhys;
