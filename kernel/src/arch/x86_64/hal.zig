pub const cpu = @import("cpu.zig");
const paging = @import("paging.zig");
const lapic = @import("lapic.zig");
const int = @import("int.zig");

pub fn halt() noreturn {
    cpu.halt();
}

pub fn debugcon(byte: u8) void {
    cpu.outb(0xE9, byte);
}

pub const physFromVirt = paging.physFromVirt;
pub const virtFromPhys = paging.virtFromPhys;

pub fn interruptsEnabled() bool {
    const flags = cpu.getLowEflags();
    return (flags & 0x200) != 0;
}

pub fn enableInterrupts() void {
    cpu.sti();
}

pub fn disableInterrupts() void {
    cpu.cli();
}

pub const ContextFrame = cpu.ContextFrame;
pub const PageTable = paging.PageTable;

pub const mapPage = paging.mapPage;
pub const unmapPage = paging.unmapPage;
pub const mapKernel = paging.mapKernel;
pub const getActivePageTable = paging.getActiveLvl4Table;
pub const setPageTableAddr = cpu.Cr3.write;
pub const dupePageTable = paging.dupePageTable;

pub fn pageIsValid(page: *PageTable) bool {
    return paging.isValid(page, 4);
}

pub const CoreInfo = cpu.CoreInfo;

pub fn oneshot(vec: u8, ticks: usize) void {
    lapic.getLapic().oneshot(vec, @truncate(ticks));
}

pub const intFromIrq = int.intFromIrq;

pub const registerIrq = int.registerIrq;

pub fn endIrq() void {
    lapic.getLapic().writeRegister(.eoi, 0);
}
