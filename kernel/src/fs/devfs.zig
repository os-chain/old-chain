const std = @import("std");
const vfs = @import("vfs.zig");

const log = std.log.scoped(.devfs);

var allocator: std.mem.Allocator = undefined;

var root: *vfs.Node = undefined;
var devices: std.ArrayList(*vfs.Node) = undefined;

pub fn init(alloc: std.mem.Allocator) !void {
    log.debug("Initializing...", .{});
    defer log.debug("Initialization done", .{});

    allocator = alloc;

    devices = std.ArrayList(*vfs.Node).init(allocator);

    root = try allocator.create(vfs.Node);
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
    vfs.unmountNode("/dev") catch |err| log.warn("Couldn't unmount /dev ({s})", .{@errorName(err)});
    allocator.destroy(root);
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

pub fn getDevice(name: []const u8) ?*vfs.Node {
    for (devices.items) |dev| {
        if (std.mem.eql(u8, dev.getName(), name)) {
            return dev;
        }
    }

    return null;
}

pub fn removeDevice(name: []const u8) error{NotFound}!void {
    for (devices.items, 0..) |dev, i| {
        if (std.mem.eql(u8, dev.getName(), name)) {
            _ = devices.swapRemove(i);
            return;
        }
    }

    return error.NotFound;
}
