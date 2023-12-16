const std = @import("std");
const limine = @import("../limine.zig");

pub export var mmap_req = limine.MemoryMapRequest{};

const FreePage = packed struct(u32768) {
    next: ?*FreePage,
    rsv: u32704 = undefined,
};

var free_page: ?*FreePage = null;

const log = std.log.scoped(.pmm);

pub fn free(ptr: *[4096]u8) void {
    const last = free_page;
    free_page = @alignCast(@ptrCast(ptr));
    free_page.?.next = last;
}

pub fn alloc() error{OutOfMemory}!*[4096]u8 {
    if (free_page) |actual_free_page| {
        const allocated_page = actual_free_page;

        free_page = actual_free_page.next;

        return @ptrCast(allocated_page);
    } else return error.OutOfMemory;
}

pub fn countFree() usize {
    var count: usize = 0;
    var page = free_page;

    while (page) |_| {
        count += 1;
        page = page.?.next;
    }

    return count;
}

pub fn init() void {
    log.debug("Initializing", .{});
    defer log.debug("Initialization done", .{});

    log.debug("Mapping memory...", .{});
    if (mmap_req.response) |mmap_res| {
        for (mmap_res.entries()) |entry| {
            switch (entry.kind) {
                .usable => {
                    std.debug.assert(entry.base % 4096 == 0);
                    std.debug.assert(entry.length % 4096 == 0);

                    const base = @divExact(entry.base, 4096);
                    const length = @divExact(entry.length, 4096);

                    for (base..base + length) |offset| {
                        free(@ptrFromInt(offset * 4096));
                    }
                },
                else => {},
            }
        }
    } else @panic("No memory map available");
    log.debug("Memory mapped", .{});

    log.debug("Pages available: {d}", .{countFree()});
}
