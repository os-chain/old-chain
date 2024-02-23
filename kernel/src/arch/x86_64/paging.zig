const std = @import("std");
const limine = @import("limine");
const cpu = @import("cpu.zig");

pub const PageTable = [512]PageTableEntry;

pub const PageTableEntry = packed struct(u64) {
    present: bool,
    writable: bool,
    user: bool,
    write_through: bool,
    no_cache: bool,
    accessed: bool = undefined,
    dirty: bool = undefined,
    huge: bool,
    global: bool,
    rsv_a: u3 = undefined,
    aligned_paddr: u40,
    rsv_b: u11 = undefined,
    no_exe: bool,

    /// Get the page table pointed by this entry. Should not be called on L1
    /// entries, which point to physical frames of memory, instead of a page
    /// table. Returns a virtual address space pointer using HHDM.
    pub inline fn getTable(self: PageTableEntry) *PageTable {
        return @ptrFromInt(virtFromPhys(self.aligned_paddr << 12));
    }
};

pub const Indices = struct {
    offset: u12,
    lvl1: u9,
    lvl2: u9,
    lvl3: u9,
    lvl4: u9,
};

pub export var hhdm_request = limine.HhdmRequest{};

const log = std.log.scoped(.paging);

var hhdm_offset: usize = undefined;

/// Get the indices of the page tables (and the offset) from a virtual address
pub inline fn indicesFromAddr(addr: usize) Indices {
    return .{
        .offset = @truncate(addr),
        .lvl1 = @truncate(addr >> 12),
        .lvl2 = @truncate(addr >> 21),
        .lvl3 = @truncate(addr >> 30),
        .lvl4 = @truncate(addr >> 39),
    };
}

test indicesFromAddr {
    try std.testing.expectEqual(Indices{
        .offset = 0,
        .lvl1 = 0,
        .lvl2 = 0,
        .lvl3 = 0,
        .lvl4 = 0,
    }, indicesFromAddr(0));

    try std.testing.expectEqual(Indices{
        .offset = 0xFFF,
        .lvl1 = 0x1FF,
        .lvl2 = 0x1FF,
        .lvl3 = 0x1FF,
        .lvl4 = 0x1FF,
    }, indicesFromAddr(0xFFFFFFFFFFFFFFFF));
}

/// Get the virtual address from a set of page table indices
pub inline fn addrFromIndices(indices: Indices) usize {
    var res: usize = 0;
    res += indices.offset;
    res += @as(usize, indices.lvl1) << 12;
    res += @as(usize, indices.lvl2) << 21;
    res += @as(usize, indices.lvl3) << 30;
    res += @as(usize, indices.lvl4) << 39;
    if ((res & (@as(usize, 1) << 47)) != 0) {
        for (48..64) |i| {
            res |= (@as(usize, 1) << @truncate(i));
        }
    }
    return res;
}

test addrFromIndices {
    try std.testing.expectEqual(0, addrFromIndices(.{
        .offset = 0,
        .lvl1 = 0,
        .lvl2 = 0,
        .lvl3 = 0,
        .lvl4 = 0,
    }));

    try std.testing.expectEqual(0xFFFFFFFFFFFFFFFF, addrFromIndices(.{
        .offset = 0xFFF,
        .lvl1 = 0x1FF,
        .lvl2 = 0x1FF,
        .lvl3 = 0x1FF,
        .lvl4 = 0x1FF,
    }));
}

/// Given a physical address, convert it to virtual address space
pub inline fn virtFromPhys(phys: usize) usize {
    return phys + hhdm_offset;
}

/// Given a virtual address, convert it to physical address space. Returns null
/// if not present.
pub inline fn physFromVirt(lvl4: *PageTable, virt: usize) ?usize {
    const indices = indicesFromAddr(virt);

    var current = lvl4;

    var lvl: usize = 4;

    inline for ([_]usize{ indices.lvl4, indices.lvl3, indices.lvl2 }) |index| {
        const entry = current[index];

        if (entry.huge) {
            switch (lvl) {
                inline 1, 4 => |i| @panic(std.fmt.comptimePrint("PS flag set on a level {} page", .{i})),
                2 => {
                    return (entry.aligned_paddr << 21) + (@as(usize, indices.lvl1) << 12) + indices.offset;
                },
                3 => @panic("1GiB level 3 pages not supported"),
                else => unreachable,
            }
        }
        if (entry.present) {
            current = entry.getTable();
            lvl -= 1;
        } else return null;
    }

    if (current[indices.lvl1].present) {
        return (current[indices.lvl1].aligned_paddr << 12) + indices.offset;
    } else return null;
}

pub inline fn getActiveLvl4Table() *PageTable {
    return @ptrFromInt(virtFromPhys(cpu.Cr3.read()));
}

pub fn init() void {
    log.debug("Initializing...", .{});
    defer log.debug("Initialization done", .{});

    if (hhdm_request.response) |hhdm_response| {
        hhdm_offset = hhdm_response.offset;
        log.debug("HHDM offset=0x{x}", .{hhdm_offset});
    } else @panic("No HHDM bootloader response available");

    const lvl4 = getActiveLvl4Table();
    for (lvl4, 0..) |lvl4_entry, i_4| {
        if (lvl4_entry.present) {
            log.debug("L4 {}", .{i_4});
            const lvl3 = lvl4_entry.getTable();
            for (lvl3, 0..) |lvl3_entry, i_3| {
                if (lvl3_entry.present) {
                    log.debug("  L3 {}", .{i_3});
                }
            }
        }
    }
}
