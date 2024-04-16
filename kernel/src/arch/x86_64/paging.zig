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
    accessed: bool = false,
    dirty: bool = false,
    huge: bool,
    global: bool,
    rsv_a: u3 = 0,
    aligned_paddr: u40,
    rsv_b: u11 = 0,
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

var base_lvl4_table: *PageTable = undefined;

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
        if (entry.rsv_a != 0 or entry.rsv_b != 0) {
            log.warn("L{d} entry has reserved bits set", .{lvl});
        }

        if (entry.present) {
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

pub const MapPageOptions = struct {
    writable: bool,
    executable: bool,
    user: bool,
    global: bool,
};

pub fn mapPage(allocator: std.mem.Allocator, lvl4: *PageTable, vaddr: usize, paddr: usize, options: MapPageOptions) !void {
    log.debug("Mapping V:{x} -> P:{x}", .{ vaddr, paddr });

    std.debug.assert(vaddr % 0x1000 == 0);
    std.debug.assert(paddr % 0x1000 == 0);

    const indices = indicesFromAddr(vaddr);

    std.debug.assert(indices.offset == 0);

    log.debug("V:{x} indices: L4:{d} L3:{d} L2:{d} L1:{d}", .{ vaddr, indices.lvl4, indices.lvl3, indices.lvl2, indices.lvl1 });

    var current = lvl4;
    inline for ([_]usize{ indices.lvl4, indices.lvl3, indices.lvl2 }, 0..) |index, i| {
        const entry = current[index];

        if (entry.present) {
            if (entry.huge) @panic("Huge pages not implemented");

            current = entry.getTable();
        } else {
            log.debug("L{d}:{d} will need to be allocated", .{ 4 - i, index });

            const table = &((try allocator.allocWithOptions(PageTable, 1, 0x1000, null))[0]);
            table.* = std.mem.zeroes(PageTable);
            std.debug.assert(isValid(table, 1));

            current[index] = .{
                .present = true,
                .writable = true,
                .user = true,
                .write_through = true,
                .no_cache = true,
                .huge = false,
                .global = false,
                .no_exe = false,
                .aligned_paddr = @truncate(physFromVirt(getActiveLvl4Table(), @intFromPtr(table.ptr)).? >> 12),
            };

            current = current[index].getTable();
        }
    }

    const was_present = current[indices.lvl1].present;

    current[indices.lvl1] = .{
        .present = true,
        .writable = options.writable,
        .user = options.user,
        .write_through = true,
        .no_cache = true,
        .huge = false,
        .global = options.global,
        .no_exe = !options.executable,
        .aligned_paddr = @truncate(paddr >> 12),
    };

    if (was_present) {
        log.debug("Mapping was present, invalidating the TLB...", .{});
        cpu.invlpg(vaddr);
    } else {
        log.debug("Mapping was not present, no need to invalidate the TLB", .{});
    }
}

pub const PageTableModifications = struct {
    writable: ?bool = null,
    executable: ?bool = null,
    user: ?bool = null,
    global: ?bool = null,
    write_through: ?bool = null,
    no_cache: ?bool = null,
};

pub fn modifyRecursive(table: *PageTable, level: usize, modifications: PageTableModifications) void {
    for (0..table.len) |i| {
        if (table[i].present) {
            if (modifications.writable) |writable| {
                table[i].writable = writable;
            }
            if (modifications.executable) |executable| {
                table[i].no_exe = !executable;
            }
            if (modifications.user) |user| {
                table[i].user = user;
            }
            if (modifications.global) |global| {
                table[i].global = global;
            }
            if (modifications.write_through) |write_through| {
                table[i].write_through = write_through;
            }
            if (modifications.no_cache) |no_cache| {
                table[i].no_cache = no_cache;
            }

            if (level > 1) {
                modifyRecursive(table[i].getTable(), level - 1, modifications);
            }
        }
    }
}

pub const UnmapPageError = error{NotMapped};

pub fn unmapPage(vaddr: usize) UnmapPageError!void {
    _ = vaddr;
    @panic("Not implemented");
}

/// Map the kernel to a lvl4 page table
pub fn mapKernel(lvl4: *PageTable) void {
    for (256..512) |i| {
        const base_entry = base_lvl4_table[i];
        if (base_entry.present) {
            lvl4[i] = base_entry;
        }
    }
}

pub fn isValid(table: *PageTable, level: usize) bool {
    for (table) |entry| {
        if (entry.rsv_a != 0 or entry.rsv_b != 0) {
            return false;
        }

        if (entry.huge) return true; // TODO: Check huge pages
        if (level > 1 and entry.present) {
            if (!isValid(entry.getTable(), level - 1)) {
                return false;
            }
        }
    }

    return true;
}

pub fn init() void {
    log.debug("Initializing...", .{});
    defer log.debug("Initialization done", .{});

    if (hhdm_request.response) |hhdm_response| {
        hhdm_offset = hhdm_response.offset;
        log.debug("HHDM offset=0x{x}", .{hhdm_offset});
    } else @panic("No HHDM bootloader response available");

    base_lvl4_table = getActiveLvl4Table();
}
