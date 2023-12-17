const pmm = @import("mm/pmm.zig");

pub const heap = struct {
    pub const page_allocator = pmm.allocator;
};

pub const system = struct {};
