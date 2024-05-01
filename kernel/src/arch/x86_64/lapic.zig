const std = @import("std");
const options = @import("options");
const smp = @import("../../smp.zig");
const cpu = @import("cpu.zig");
const paging = @import("paging.zig");

const log = std.log.scoped(.lapic);

var allocator: std.mem.Allocator = undefined;

pub const Lapic = struct {
    base: usize = 0xffff8000fee00000,

    pub const Register = enum(u32) {
        eoi = 0xB0,
        timer_lvt = 0x320,
        timer_init = 0x380,
    };

    pub fn writeRegister(self: Lapic, register: Register, value: u32) void {
        @as(*volatile u32, @ptrFromInt(self.base + @intFromEnum(register))).* = value;
    }

    pub fn readRegister(self: Lapic, register: Register) u32 {
        return @as(*volatile u32, @ptrFromInt(self.base + @intFromEnum(register))).*;
    }

    pub fn oneshot(self: Lapic, vec: u8, ticks: u32) void {
        self.writeRegister(.timer_init, 0);
        self.writeRegister(.timer_lvt, @as(usize, 1) << 16);

        self.writeRegister(.timer_lvt, vec);
        self.writeRegister(.timer_init, ticks);
    }
};

var lapics: []Lapic = &(.{} ** options.max_cpus);

var bootstrap_lapic_id: u32 = 0;

pub fn getBootstrapLapicId() u32 {
    return bootstrap_lapic_id;
}

pub fn init(_allocator: std.mem.Allocator) !void {
    log.debug("Initializing...", .{});
    defer log.debug("Initialization done", .{});

    if (smp.cpuid() == 0) {
        allocator = _allocator;
        lapics = try allocator.alloc(Lapic, smp.count());
    }

    if (smp.smp_req.response) |smp_res| {
        bootstrap_lapic_id = smp_res.bsp_lapic_id;

        const lapic_id = smp_res.cpus()[smp.cpuid()].lapic_id;
        if (lapic_id != smp.cpuid()) @panic("LAPIC ID doesn't match CPU ID");
        lapics[smp.cpuid()] = .{
            .base = paging.virtFromPhys(cpu.Msr.read(.APIC_BASE) & 0xFFFFF000),
        };
        log.debug("LAPIC {d}: base=0x{x}", .{ smp.cpuid(), lapics[smp.cpuid()].base });

        log.debug("Enabling...", .{});
        cpu.Msr.write(.APIC_BASE, cpu.Msr.read(.APIC_BASE) | (@as(u64, 1) << 11));
        log.debug("Enabled", .{});

        lapics[smp.cpuid()].writeRegister(.timer_init, 0);
    } else @panic("No SMP response from bootloader");
}

pub fn deinit() void {
    allocator.free(lapics);
}

pub fn getLapic() Lapic {
    return lapics[smp.cpuid()];
}
