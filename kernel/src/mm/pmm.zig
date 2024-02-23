const std = @import("std");
const limine = @import("limine");
const hal = @import("../hal.zig");

pub export var mmap_req = limine.MemoryMapRequest{};

const log = std.log.scoped(.pmm);

var bitmap: []u8 = undefined;

/// Mark a page as used, by index
pub inline fn setUsed(i: usize) void {
    bitmap[@divFloor(i, 8)] &= ~(@as(u8, 1) << @truncate(i % 8));
}

/// Mark a page as free (not used), by index
pub inline fn setFree(i: usize) void {
    bitmap[@divFloor(i, 8)] |= (@as(u8, 1) << @truncate(i % 8));
}

/// Is the `i`th page free (not used)?
pub inline fn isFree(i: usize) bool {
    return (bitmap[@divFloor(i, 8)] & (@as(u8, 1) << @truncate(i % 8))) > 0;
}

/// Is the `i`th page used?
pub inline fn isUsed(i: usize) bool {
    return !isFree(i);
}

inline fn vaddrFromIdx(i: usize) usize {
    return @intFromPtr(bitmap.ptr) + 4096 * i;
}

inline fn idxFromVaddr(vaddr: usize) usize {
    return @divExact(vaddr - @intFromPtr(bitmap.ptr), 4096);
}

pub fn init() void {
    log.debug("Initializing...", .{});
    defer log.debug("Initialization done", .{});

    if (mmap_req.response) |mmap_res| {
        var best_region: ?[]u8 = null;

        for (mmap_res.entries(), 0..) |entry, i| {
            log.debug("Memory map entry {}: {s} 0x{x} -- 0x{x}", .{ i, @tagName(entry.kind), entry.base, entry.base + entry.length });

            if (entry.kind == .usable) {
                if (best_region == null or best_region.?.len < entry.length) {
                    best_region = @as([*]u8, @ptrFromInt(entry.base))[0..entry.length];
                }
            }
        }

        if (best_region) |phys_region| {
            const virt_region = @as([*]u8, @ptrFromInt(hal.virtFromPhys(@intFromPtr(phys_region.ptr))))[0..phys_region.len];

            log.debug("Using region P:{x} -- P:{x} which is V:{x} -- V:{x}", .{
                @intFromPtr(phys_region.ptr),
                @intFromPtr(phys_region.ptr) + phys_region.len,
                @intFromPtr(virt_region.ptr),
                @intFromPtr(virt_region.ptr) + virt_region.len,
            });

            const page_count = @divFloor(phys_region.len, 4096);

            bitmap = virt_region[0..@divFloor(page_count, 8)];
            log.debug("Bitmap at V:{x} -- V:{x}", .{ @intFromPtr(bitmap.ptr), @intFromPtr(bitmap.ptr) + bitmap.len });

            @memset(bitmap, 0xFF);

            const bitmap_pages = std.math.divCeil(usize, bitmap.len, 4096) catch unreachable;
            log.debug("Bitmap uses {} pages", .{bitmap_pages});

            for (0..bitmap_pages) |i| {
                setUsed(i);
            }
        } else @panic("No usable memory");
    } else @panic("No memory map info available");
}

fn alloc(_: *anyopaque, n: usize, _: u8, _: usize) ?[*]u8 {
    std.debug.assert(n > 0);

    const page_count = std.math.divCeil(usize, n, 4096) catch unreachable;

    var count: usize = 0;
    var found_i: usize = undefined;
    for (0..bitmap.len * 8) |i| {
        if (isFree(i)) {
            if (count == 0) found_i = i;
            count += 1;

            if (count >= page_count) {
                for (found_i..found_i + count) |j| {
                    setUsed(j);
                }
                return @ptrFromInt(vaddrFromIdx(found_i));
            }
        } else {
            count = 0;
        }
    }

    return null;
}

fn free(_: *anyopaque, buf: []u8, _: u8, _: usize) void {
    const i = idxFromVaddr(@intFromPtr(buf.ptr));
    const count = std.math.divCeil(usize, buf.len, 4096) catch unreachable;
    for (i..i + count) |j| {
        setFree(j);
    }
}

pub const allocator = std.mem.Allocator{
    .ptr = undefined,
    .vtable = &.{
        .alloc = alloc,
        .resize = std.mem.Allocator.noResize,
        .free = free,
    },
};
