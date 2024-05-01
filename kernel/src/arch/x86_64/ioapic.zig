const std = @import("std");
const acpi = @import("../../acpi.zig");

const log = std.log.scoped(.ioapic);

var base_addr: usize = 0xFEC00000;

const Register = enum {
    ioapicid,
    ioapicver,
    ioapicarb,

    fn getOffset(self: Register) u8 {
        return switch (self) {
            .ioapicid => 0x00,
            .ioapicver => 0x01,
            .ioapicarb => 0x02,
        };
    }

    fn Type(self: Register) type {
        return switch (self) {
            .ioapicid => u32,
            .ioapicver => u32,
            .ioapicarb => u32,
        };
    }
};

fn read(comptime reg: Register) reg.Type() {
    @as(*allowzero u8, @ptrFromInt(base_addr)).* = reg.getOffset();
    return @as(*allowzero reg.Type(), @ptrFromInt(base_addr + 0x10)).*;
}

fn write(comptime reg: Register, value: reg.Type()) void {
    @as(*allowzero u8, @ptrFromInt(base_addr)).* = reg.getOffset();
    @as(*allowzero reg.Type(), @ptrFromInt(base_addr + 0x10)).* = value;
}

pub const RedEntry = packed struct(u64) {
    vec: u8,
    delivery_mode: DeliveryMode,
    destination_mode: DestinationMode,
    delivery_status: u1,
    polarity: Polarity,
    remote_irr: u1,
    trigger_mode: TriggerMode,
    mask: bool,
    rsv_a: u39 = 0,
    destination: u8,

    pub const DeliveryMode = enum(u3) {
        fixed = 0b000,
        lowest = 0b001,
        smi = 0b010,
        nmi = 0b100,
        init = 0b101,
        ext_int = 0b111,
    };

    pub const DestinationMode = enum(u1) {
        physical = 0,
        logical = 1,
    };

    pub const Polarity = enum(u1) {
        active_high = 0,
        active_low = 1,
    };

    pub const TriggerMode = enum(u1) {
        edge = 0,
        level = 1,
    };
};

pub fn readRedTbl(n: usize) RedEntry {
    const offset: u8 = @truncate(0x10 + n * 2);

    @as(*allowzero u8, @ptrFromInt(base_addr)).* = offset;
    const low = @as(*allowzero u32, @ptrFromInt(base_addr + 0x10)).*;

    @as(*allowzero u8, @ptrFromInt(base_addr)).* = offset + 1;
    const high = @as(*allowzero u32, @ptrFromInt(base_addr + 0x10)).*;

    const int: u64 = (@as(u64, high) << 32) | low;

    return @bitCast(int);
}

pub fn writeRedTbl(n: usize, entry: RedEntry) void {
    const offset: u8 = @truncate(0x10 + n * 2);

    const int: u64 = @bitCast(entry);

    @as(*allowzero u8, @ptrFromInt(base_addr)).* = offset;
    @as(*allowzero u32, @ptrFromInt(base_addr + 0x10)).* = @truncate(int);

    @as(*allowzero u8, @ptrFromInt(base_addr)).* = offset + 1;
    @as(*allowzero u32, @ptrFromInt(base_addr + 0x10)).* = @truncate(int >> 32);
}

pub fn init() void {
    log.debug("Initializing...", .{});
    defer log.debug("Initialization done", .{});

    if (acpi.madt) |madt| {
        base_addr = madt.getIoApicAddr();
        log.debug("I/O APIC base address: {x}", .{base_addr});
    } else @panic("No I/O APIC available");
}
