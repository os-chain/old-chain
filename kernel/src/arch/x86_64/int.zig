const std = @import("std");
const cpu = @import("cpu.zig");
const gdt = @import("gdt.zig");

const log = std.log.scoped(.int);

pub const Idt = [256]IdtEntry;

pub const IdtEntry = packed struct(u128) {
    offset_low: u16,
    segment: u16,
    ist: u3,
    rsv_a: u5 = 0,
    type: Type,
    rsv_b: u1 = 0,
    ring: u2,
    present: bool,
    offset_high: u48,
    rsv_c: u32 = undefined,

    pub const Type = enum(u4) {
        tss_available = 0b1001,
        tss_busy = 0b1011,
        call = 0b1100,
        interrupt = 0b1110,
        trap = 0b1111,
    };

    pub inline fn getOffset(self: IdtEntry) u64 {
        return (@as(u64, self.offset_high) << 16) | self.offset_low;
    }

    pub inline fn setOffset(self: *IdtEntry, offset: u64) void {
        self.offset_low = @truncate(offset);
        self.offset_high = @truncate(offset >> 16);
    }

    test "getOffset() and setOffset()" {
        var entry: IdtEntry = undefined;
        entry.setOffset(0);
        try std.testing.expectEqual(@as(u16, 0), entry.offset_low);
        try std.testing.expectEqual(@as(u48, 0), entry.offset_high);
        try std.testing.expectEqual(@as(u64, 0), entry.getOffset());

        entry.setOffset(0xFFFFFFFFFFFFFFFF);
        try std.testing.expectEqual(@as(u16, 0xFFFF), entry.offset_low);
        try std.testing.expectEqual(@as(u48, 0xFFFFFFFFFFFF), entry.offset_high);
        try std.testing.expectEqual(@as(u64, 0xFFFFFFFFFFFFFFFF), entry.getOffset());

        entry.setOffset(0xDEADBEEFDEADBEEF);
        try std.testing.expectEqual(@as(u16, 0xBEEF), entry.offset_low);
        try std.testing.expectEqual(@as(u48, 0xDEADBEEFDEAD), entry.offset_high);
        try std.testing.expectEqual(@as(u64, 0xDEADBEEFDEADBEEF), entry.getOffset());

        entry.setOffset(0xFEDCBA9876543210);
        try std.testing.expectEqual(@as(u16, 0x3210), entry.offset_low);
        try std.testing.expectEqual(@as(u48, 0xFEDCBA987654), entry.offset_high);
        try std.testing.expectEqual(@as(u64, 0xFEDCBA9876543210), entry.getOffset());
    }
};

pub const Idtd = packed struct(u80) {
    limit: u16,
    base: *const Idt,
};

pub const Exception = enum(u8) {
    DE = 0,
    DB = 1,
    BP = 3,
    OF = 4,
    BR = 5,
    UD = 6,
    NM = 7,
    DF = 8,
    TS = 10,
    NP = 11,
    SS = 12,
    GP = 13,
    PF = 14,
    MF = 16,
    AC = 17,
    MC = 18,
    XM = 19,
    VE = 20,
    CP = 21,

    pub inline fn getMnemonic(self: Exception) []const u8 {
        return switch (self) {
            inline else => |e| "#" ++ @tagName(e),
        };
    }

    pub inline fn getDescription(self: Exception) []const u8 {
        // From Intel 64 and IA-32 Architectures Software Developer's Manual
        return switch (self) {
            .DE => "Divide Error",
            .DB => "Debug Exception",
            .BP => "Breakpoint",
            .OF => "Overflow",
            .BR => "BOUND Range Exceeded",
            .UD => "Invalid Opcode",
            .NM => "No Math Coprocessor",
            .DF => "Double Fault",
            .TS => "Invalid TSS",
            .NP => "Segment Not Present",
            .SS => "Stack-Segment Fault",
            .GP => "General Protection",
            .PF => "Page Fault",
            .MF => "Math Fault",
            .AC => "Alignment Check",
            .MC => "Machine Check",
            .XM => "SIMD Floating-Point Exception",
            .VE => "Virtualization Exception",
            .CP => "Control Protection Exception",
        };
    }
};

var idtd: Idtd = .{
    .limit = @sizeOf(Idt) - 1,
    .base = undefined,
};

export var idt: Idt = [1]IdtEntry{.{
    .offset_low = 0,
    .offset_high = 0,
    .segment = 0,
    .ist = 0,
    .type = .trap,
    .ring = 0,
    .present = false,
}} ** 256;

pub fn init() void {
    log.debug("Initializing", .{});
    defer log.debug("Initialization done", .{});

    idtd.base = &idt;

    inline for (0..256) |i_raw| {
        const i: u8 = @truncate(i_raw);
        if (getVector(i)) |vector| {
            idt[i] = .{
                .segment = gdt.selectors.kcode_64,
                .ist = 0,
                .type = switch (i) {
                    0...31 => .trap,
                    32...255 => .interrupt,
                },
                .ring = 0,
                .present = true,

                .offset_low = undefined,
                .offset_high = undefined,
            };
            idt[i].setOffset(@intFromPtr(vector));
        } else {
            idt[i].present = false;
        }
    }

    log.debug("Loading IDTD...", .{});
    cpu.lidt(&idtd);
    log.debug("IDTD loaded", .{});

    log.debug("Enabling interrupts...", .{});
    cpu.sti();
    log.debug("Interrupts enabled", .{});
}

fn getVector(comptime i: u8) ?*const fn () callconv(.Interrupt) void {
    return switch (i) {
        inline 0, 1, 3...8, 10...14, 16...21 => |exception_i| blk: {
            const exception: Exception = @enumFromInt(exception_i);
            break :blk struct {
                fn vector() callconv(.Interrupt) void {
                    log.err(std.fmt.comptimePrint("Exception: {s}[{d}] ({s})", .{ exception.getMnemonic(), exception_i, exception.getDescription() }), .{});
                    cpu.halt();
                }
            }.vector;
        },
        2, 9, 15, 22...31 => null,
        inline else => |int_i| struct {
            fn vector() callconv(.Interrupt) void {
                log.debug(std.fmt.comptimePrint("Interrupt {d} dispatched", .{int_i}), .{});
            }
        }.vector,
    };
}
