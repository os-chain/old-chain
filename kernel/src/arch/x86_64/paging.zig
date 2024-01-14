const std = @import("std");
const vmm = @import("../../mm/vmm.zig");
const pmm = @import("../../mm/pmm.zig");

const log = std.log.scoped(.paging);

/// An abstraction of the page mapping
pub const PageMap = struct {
    root: u64 = undefined,

    /// Load the map
    pub fn load(self: PageMap) void {
        loadSpace(self.root);
    }

    /// Save the currently loaded map
    pub fn save(self: *PageMap) void {
        self.root = saveSpace();
    }

    /// Map a physical page to a virtual page
    pub fn mapPage(self: *PageMap, flags: vmm.MapFlags, virt: u64, phys: u64, huge: bool) !void {
        var root: [*]u64 = @ptrFromInt(vmm.toHigherHalf(self.root));

        const indices = [4]u64{
            getIndex(virt, 39), getIndex(virt, 30),
            getIndex(virt, 21), getIndex(virt, 12),
        };

        root = (try getNextLevel(root, indices[0], true)).?;
        root = (try getNextLevel(root, indices[1], true)).?;

        if (huge) {
            root[indices[2]] = createPte(flags, phys, true);
        } else {
            root = (try getNextLevel(root, indices[2], true)).?;
            root[indices[3]] = createPte(flags, phys, false);
        }
    }
};

fn getNextLevel(level: [*]u64, index: usize, create: bool) !?[*]u64 {
    // If entry not present
    if ((level[index] & 1) == 0) {
        if (!create) return null;

        const table_ptr = @intFromPtr((try pmm.allocator.alloc(u8, 4096)).ptr);
        level[index] = table_ptr;
        level[index] |= 0b111;
    }

    return @ptrFromInt(vmm.toHigherHalf(level[index] & ~@as(u64, 0x1FF)));
}

fn createPte(flags: vmm.MapFlags, phys_ptr: u64, huge: bool) u64 {
    var result: u64 = 1; // Present

    const pat_bit = if (huge) @as(u64, 1) << 12 else @as(u64, 1) << 7;

    if (flags.write) result |= @as(u64, 1) << 1;
    if (!flags.execute) result |= @as(u64, 1) << 63;
    if (flags.user) result |= @as(u64, 1) << 2;
    if (huge) result |= @as(u64, 1) << 7;

    switch (flags.cache_type) {
        .uncached => {
            result |= @as(u64, 1) << 4;
            result |= @as(u64, 1) << 3;
            result &= ~pat_bit;
        },
        .write_combining => {
            result |= pat_bit;
            result |= @as(u64, 1) << 4;
            result |= @as(u64, 1) << 3;
        },
        .write_protect => {
            result |= pat_bit;
            result |= @as(u64, 1) << 4;
            result &= ~(@as(u64, 1) << 3);
        },
        .write_back => {},
    }

    result |= phys_ptr;
    return result;
}

inline fn getIndex(virt: u64, comptime shift: u6) u64 {
    return ((virt & (0x1FF << shift)) >> shift);
}

inline fn loadSpace(root: u64) void {
    asm volatile ("mov %[root], %%cr3"
        :
        : [root] "r" (root),
        : "memory"
    );
}

inline fn saveSpace() void {
    asm volatile ("mov %%cr3, %[root]"
        : [root] "=r" (-> u64),
        :
        : "memory"
    );
}
