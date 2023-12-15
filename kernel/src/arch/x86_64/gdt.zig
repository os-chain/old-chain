const std = @import("std");
const cpu = @import("cpu.zig");

pub const Entry = packed struct(u64) {
    limit_a: u16,
    base_a: u24,
    access: Access,
    limit_b: u4,
    flags: Flags,
    base_b: u8,

    pub const Access = packed struct(u8) {
        accessed: bool = false,
        read_write: bool,
        direction_conforming: bool,
        executable: bool,
        type: Type,
        dpl: u2,
        present: bool,

        pub const Type = enum(u1) {
            system = 0,
            normal = 1,
        };
    };

    pub const Flags = packed struct(u4) {
        rsv: u1 = undefined,
        long_code: bool,
        size: bool,
        granularity: bool,
    };
};

pub const Gdtd = packed struct(u80) {
    size: u16,
    offset: u64,
};

pub const kcode_16 = 0x08;
pub const kdata_16 = 0x10;
pub const kcode_32 = 0x18;
pub const kdata_32 = 0x20;
pub const kcode_64 = 0x28;
pub const kdata_64 = 0x30;
pub const udata_64 = 0x3B;
pub const ucode_64 = 0x43;

const log = std.log.scoped(.gdt);

const gdt = [_]Entry{
    @bitCast(@as(u64, 0)),
    @bitCast(@as(u64, 0x00009a000000ffff)),
    @bitCast(@as(u64, 0x000092000000ffff)),
    @bitCast(@as(u64, 0x00cf9a000000ffff)),
    @bitCast(@as(u64, 0x00cf92000000ffff)),
    @bitCast(@as(u64, 0x00209A0000000000)),
    @bitCast(@as(u64, 0x0000920000000000)),
    @bitCast(@as(u64, 0x0000F20000000000)),
    @bitCast(@as(u64, 0x0020FA0000000000)),
};

var gdtd: Gdtd = undefined;

pub fn init() void {
    log.debug("Initializing", .{});
    defer log.debug("Initialization done", .{});

    gdtd = .{
        .offset = @intFromPtr(&gdt),
        .size = @sizeOf(@TypeOf(gdt)) - 1,
    };

    log.debug("Loading GDT...", .{});
    cpu.lgdt(&gdtd);
    log.debug("GDT loaded", .{});
}
