const std = @import("std");
const builtin = @import("builtin");
const limine = @import("../limine.zig");
const pmm = @import("pmm.zig");

const paging = switch (builtin.cpu.arch) {
    .x86_64 => @import("../arch/x86_64/paging.zig"),
    else => |other| @compileError(@tagName(other) ++ "not implemented"),
};

pub const CacheMode = enum(u4) {
    uncached,
    write_combining,
    write_protect,
    write_back,
};

pub const MapFlags = packed struct {
    read: bool,
    write: bool,
    execute: bool,
    user: bool,
    cache_type: CacheMode = .write_back,
    rsv_a: u24 = undefined,
};

pub export var kaddr_req = limine.KernelAddressRequest{};

const log = std.log.scoped(.vmm);

var kernel_pagemap: paging.PageMap = .{};

pub fn init() void {
    log.debug("Initializing", .{});
    defer log.debug("Initialization done", .{});

    if (kaddr_req.response) |kaddr_res| {
        kernel_pagemap.root = @intFromPtr((pmm.allocator.alloc(u8, 4096) catch @panic("Ran out of memory while initializing the VMM")).ptr);

        log.debug("Mapping initial pages...", .{});

        for (0..0x400) |i| {
            kernel_pagemap.mapPage(
                .{
                    .read = true,
                    .write = true,
                    .execute = true,
                    .user = false,
                },
                kaddr_res.virtual_base + i * 4096,
                kaddr_res.physical_base + i * 4096,
                false,
            ) catch @panic("Ran out of memory while initializing the VMM");
        }

        for (0..0x800) |i| {
            kernel_pagemap.mapPage(
                .{
                    .read = true,
                    .write = true,
                    .execute = false,
                    .user = false,
                },
                toHigherHalf(i * 0x200000),
                i * 0x200000,
                true,
            ) catch @panic("Ran out of memory while initializing the VMM");
        }

        if (pmm.mmap_req.response) |mmap_res| {
            for (mmap_res.entries()) |entry| {
                if (entry.base + entry.length < 0x800 * 0x200000) {
                    continue; // Already mapped
                }

                const base = std.mem.alignBackward(usize, entry.base, 0x200000);

                for (0..@divExact(std.mem.alignForward(usize, entry.length, 0x200000), 0x200000)) |i| {
                    kernel_pagemap.mapPage(
                        .{
                            .read = true,
                            .write = true,
                            .execute = false,
                            .user = false,
                        },
                        toHigherHalf(base + i * 0x200000),
                        base + i * 0x200000,
                        true,
                    ) catch @panic("Ran out of memory while initializing the VMM");
                }
            }
        } else @panic("Could not get memory mapping from the bootloader");

        log.debug("Initial pages mapped", .{});

        log.debug("Loading page map...", .{});
        kernel_pagemap.load();
        log.debug("Page map loaded", .{});
    } else @panic("Could not get kernel address information from the bootloader");
}

pub inline fn toHigherHalf(ptr: usize) usize {
    return ptr + 0xFFFF800000000000;
}

pub inline fn fromHigherHalf(ptr: usize) usize {
    return ptr - 0xFFFF800000000000;
}
