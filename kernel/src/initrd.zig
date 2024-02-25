const std = @import("std");
const limine = @import("limine");
const vfs = @import("fs/vfs.zig");
const devfs = @import("fs/devfs.zig");

pub export var mod_req = limine.ModuleRequest{};

const log = std.log.scoped(.initrd);

var gpa = std.heap.GeneralPurposeAllocator(.{}){};
const allocator = gpa.allocator();

var mod: *limine.File = undefined;

pub fn init() !void {
    log.debug("Initializing...", .{});
    defer log.debug("Initialization done", .{});

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

        const node = try allocator.create(vfs.Node);
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

fn read(_: *vfs.Node, offset: u64, buffer: []u8) u64 {
    const data = mod.data();
    const bytes_to_read = @min(data.len - offset, buffer.len);

    const res = data[offset .. offset + bytes_to_read];
    @memcpy(buffer[0..bytes_to_read], res);
    return res.len;
}
