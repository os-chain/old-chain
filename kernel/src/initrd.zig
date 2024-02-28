const std = @import("std");
const limine = @import("limine");
const vfs = @import("fs/vfs.zig");
const devfs = @import("fs/devfs.zig");

pub export var mod_req = limine.ModuleRequest{};

var allocator: std.mem.Allocator = undefined;
var node: *vfs.Node = undefined;

const log = std.log.scoped(.initrd);

var mod: *limine.File = undefined;

pub fn init(alloc: std.mem.Allocator) !void {
    log.debug("Initializing...", .{});
    defer log.debug("Initialization done", .{});

    allocator = alloc;

    if (mod_req.response) |mod_res| {
        mod = blk: {
            for (mod_res.modules()) |module| {
                const name = std.mem.span(module.cmdline);
                if (std.mem.eql(u8, name, "initrd")) {
                    break :blk module;
                }
            }

            return error.NoInitrd;
        };

        node = try allocator.create(vfs.Node);
        node.* = vfs.Node.create(.{
            .name = "initrd",
            .inode = 0,
            .length = mod.size,
            .type = .file,
            .readFn = read,
        });
        try devfs.addDevice(node);
    } else return error.NoInitrd;
}

pub fn deinit() void {
    allocator.destroy(node);
}

fn read(_: *vfs.Node, offset: u64, buffer: []u8) u64 {
    const data = mod.data();
    const bytes_to_read = @min(data.len - offset, buffer.len);

    const res = data[offset .. offset + bytes_to_read];
    @memcpy(buffer[0..bytes_to_read], res);
    return res.len;
}
