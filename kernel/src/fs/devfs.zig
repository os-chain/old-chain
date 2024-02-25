const std = @import("std");
const vfs = @import("vfs.zig");

var gpa = std.heap.GeneralPurposeAllocator(.{}){};
const allocator = gpa.allocator();

const log = std.log.scoped(.devfs);

var devices: std.ArrayList(*vfs.Node) = undefined;

pub fn init() !void {
    log.debug("Initializing...", .{});
    defer log.debug("Initialization done", .{});

    devices = std.ArrayList(*vfs.Node).init(allocator);

    const root = try allocator.create(vfs.Node);
    root.* = vfs.Node.create(.{
        .name = "dev",
        .inode = 0,
        .length = 0,
        .type = .directory,
        .childCountFn = childCount,
        .readDirFn = readDir,
    });

    try vfs.mountNode(root, "/dev");
}

pub fn deinit() void {
    devices.deinit();
}

fn childCount(_: *vfs.Node) u64 {
    return devices.items.len;
}

fn readDir(_: *vfs.Node, offset: u64, buffer: []*vfs.Node) void {
    std.debug.assert(offset < devices.items.len);
    @memcpy(buffer, devices.items[offset .. offset + buffer.len]);
}

pub fn addDevice(node: *vfs.Node) !void {
    log.debug("Adding device /dev/{s}", .{node.getName()});
    for (devices.items) |dev| {
        if (std.mem.eql(u8, dev.getName(), node.getName())) return error.DuplicateName;
    }

    try devices.append(node);
}
