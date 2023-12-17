const std = @import("std");
const limine = @import("../limine.zig");

pub export var mmap_req = limine.MemoryMapRequest{};

const log = std.log.scoped(.pmm);

var bitmap: []u8 = undefined;

pub fn init() void {
    log.debug("Initializing", .{});
    defer log.debug("Initialization done", .{});

    if (mmap_req.response) |mmap_res| {
        var biggest_section: ?limine.MemoryMapEntry = null;
        for (mmap_res.entries()) |entry| {
            if (entry.kind == .usable) {
                log.debug("Memory section: {x:0>16} --- {x:0>16}", .{ entry.base, entry.base + entry.length });
                if (biggest_section == null or entry.length > biggest_section.?.length) {
                    biggest_section = entry.*;
                }
            }
        }

        if (biggest_section) |section| {
            log.debug("Selected section: base={x} len={d}", .{ section.base, section.length });
            const page_count = @divFloor(section.length, 4096);

            bitmap = @as([*]u8, @ptrFromInt(section.base))[0..@divFloor(page_count, 8)];
            log.debug("Bitmap: ptr={*} len={d}", .{ bitmap.ptr, bitmap.len });

            @memset(bitmap, 0xFF);

            const bitmap_pages = std.math.divCeil(usize, bitmap.len, 4096) catch unreachable;
            log.debug("The bitmap itself takes up {d} pages", .{bitmap_pages});
            for (0..bitmap_pages) |i| {
                setUsed(i);
            }

            log.debug("{d} pages available", .{countFree()});
        } else @panic("No usable memory");
    } else @panic("Memory map not available");
}

pub fn countFree() usize {
    var count: usize = 0;

    for (0..bitmap.len * 8) |i| {
        if (isFree(i)) count += 1;
    }

    return count;
}

inline fn isFree(idx: usize) bool {
    return (bitmap[@divFloor(idx, 8)] & (@as(u8, 1) << @truncate(idx % 8))) > 0;
}

inline fn isUsed(idx: usize) bool {
    return !isFree(idx);
}

inline fn setFree(idx: usize) void {
    bitmap[@divFloor(idx, 8)] |= (@as(u8, 1) << @truncate(idx % 8));
}

inline fn setUsed(idx: usize) void {
    bitmap[@divFloor(idx, 8)] &= ~(@as(u8, 1) << @truncate(idx % 8));
}

inline fn addrFromIdx(idx: usize) [*]u8 {
    return @ptrCast(bitmap.ptr + 4096 * idx);
}

inline fn idxFromAddr(addr: [*]u8) usize {
    return @divExact(@intFromPtr(addr) - @intFromPtr(bitmap.ptr), 4096);
}

fn alloc(_: *anyopaque, len: usize, ptr_align: u8, _: usize) ?[*]u8 {
    log.debug("Allocating {d} bytes", .{len});
    const page_count = std.math.divCeil(usize, len, 4096) catch unreachable;

    if (ptr_align > 12) return null; // TODO: Implement alignment

    var count: usize = 0;
    var found_idx: usize = undefined;
    for (0..bitmap.len * 8) |i| {
        if (isFree(i)) {
            if (count == 0) found_idx = i;
            count += 1;

            if (count >= page_count) {
                for (found_idx..found_idx + count) |j| {
                    setUsed(j);
                }
                return addrFromIdx(found_idx);
            }
        } else {
            count = 0;
        }
    }

    return null;
}

fn free(_: *anyopaque, buf: []u8, _: u8, _: usize) void {
    log.debug("Freeing {d} bytes", .{buf.len});
    const idx = idxFromAddr(buf.ptr);
    const count = std.math.divCeil(usize, buf.len, 4096) catch unreachable;

    for (idx..idx + count) |i| {
        setFree(i);
    }
}

pub const allocator: std.mem.Allocator = .{
    .ptr = undefined,
    .vtable = &.{
        .alloc = &alloc,
        .resize = &std.mem.Allocator.noResize, // TODO: Support resizing
        .free = &free,
    },
};
