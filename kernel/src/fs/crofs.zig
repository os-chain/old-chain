const std = @import("std");
const vfs = @import("vfs.zig");

const supported_versions = [_]u8{0x00};

const log = std.log.scoped(.crofs);

pub const Ctx = struct {
    device: *vfs.Node,
    node_list: *std.ArrayList(*vfs.Node),
};

fn childCount(node: *vfs.Node) u64 {
    const ctx: *Ctx = @ptrCast(@alignCast(node.ctx));
    const device = ctx.device;
    const offset = node.impl;

    var buffer: [1]u8 = undefined;
    std.debug.assert(device.read(offset, &buffer) == 1);
    std.debug.assert(buffer[0] == 0x02);
    std.debug.assert(device.read(offset + 1, &buffer) == 1);
    const name_len = buffer[0];
    std.debug.assert(device.read(offset + 2 + name_len, &buffer) == 1);
    return buffer[0];
}

fn readDir(node: *vfs.Node, read_offset: u64, read_buffer: []*vfs.Node) void {
    const ctx: *Ctx = @ptrCast(@alignCast(node.ctx));
    const device = ctx.device;
    const device_offset = node.impl;

    const ReaderCtx = struct {
        offset: u64,
        device: *vfs.Node,
    };
    var reader_ctx: ReaderCtx = .{
        .offset = device_offset,
        .device = device,
    };
    const reader = std.io.AnyReader{
        .context = @as(*const anyopaque, @alignCast(@ptrCast(&&reader_ctx))),
        .readFn = struct {
            fn f(reader_ctx_opaque: *const anyopaque, buf: []u8) anyerror!usize {
                const reader_ctx_ptr = @as(*const *ReaderCtx, @ptrCast(@alignCast(reader_ctx_opaque))).*;
                const bytes_read = reader_ctx_ptr.device.read(reader_ctx_ptr.offset, buf);
                reader_ctx_ptr.offset += bytes_read;
                return bytes_read;
            }
        }.f,
    };
    std.debug.assert((reader.readByte() catch unreachable) == 0x02);
    const name_len = reader.readByte() catch unreachable;
    reader.skipBytes(name_len, .{}) catch unreachable;
    const child_count = reader.readByte() catch unreachable;
    const children_to_read = @min(child_count - read_offset, read_buffer.len);

    var child_inode = node.inode + 1 + (skipN(reader, read_offset) catch unreachable);
    for (0..children_to_read) |i| {
        read_buffer[i] = ctx.node_list.items[child_inode];
        child_inode += skip(reader) catch unreachable;
    }
}

fn read(node: *vfs.Node, read_offset: u64, read_buffer: []u8) u64 {
    const ctx: *Ctx = @ptrCast(@alignCast(node.ctx));
    const device = ctx.device;
    const device_offset = node.impl;

    var buffer_1: [1]u8 = undefined;
    std.debug.assert(device.read(device_offset, &buffer_1) == 1);
    std.debug.assert(buffer_1[0] == 0x01);
    std.debug.assert(device.read(device_offset + 1, &buffer_1) == 1);
    const name_len = buffer_1[0];
    var buffer_8: [8]u8 = undefined;
    std.debug.assert(device.read(device_offset + 2 + name_len, &buffer_8) == 8);
    std.debug.assert(std.mem.readInt(u64, &buffer_8, .little) == node.length);

    const read_len = @min(node.length - read_offset, read_buffer.len);
    std.debug.assert(device.read(device_offset + 10 + name_len + read_offset, read_buffer[0..read_len]) == read_len);
    return read_len;
}

fn skipN(reader: std.io.AnyReader, n: usize) !usize {
    var count: usize = 0;
    for (0..n) |_| count += try skip(reader);
    return count;
}

fn skip(reader: std.io.AnyReader) @TypeOf(reader).Error!usize {
    const file_type = try reader.readByte();
    const name_len = reader.readByte() catch return error.CorruptedFileSystem;
    reader.skipBytes(name_len, .{}) catch return error.CorruptedFileSystem;
    switch (file_type) {
        0x01 => {
            const length = reader.readInt(u64, .little) catch return error.CorruptedFileSystem;
            reader.skipBytes(length, .{}) catch return error.CorruptedFileSystem;
            return 1;
        },
        0x02 => {
            const child_count = reader.readByte() catch return error.CorruptedFileSystem;
            return try skipN(reader, child_count) + 1;
        },
        else => return error.CorruptedFileSystem,
    }
}

fn accepts(device: *vfs.Node) bool {
    var buffer: [8]u8 = undefined;
    const bytes_read = device.read(0, &buffer);
    if (bytes_read != 8) return false;
    if (!std.mem.eql(u8, buffer[0..7], "~CROFS~")) return false;

    const version = buffer[7];
    for (supported_versions) |supported| {
        if (version == supported) return true;
    }
    return false;
}

fn parseFile(allocator: std.mem.Allocator, list: *std.ArrayList(*vfs.Node), reader: std.io.AnyReader, next_inode: *u64, ctx: *Ctx, offset: usize) !usize {
    const name_len = reader.readByte() catch return error.CorruptedFileSystem;
    if (name_len == 0) return error.CorruptedFileSystem;
    const name = try allocator.alloc(u8, name_len);
    defer allocator.free(name);
    reader.readNoEof(name) catch return error.CorruptedFileSystem;
    const inode = next_inode.*;
    next_inode.* += 1;

    const length = reader.readInt(u64, .little) catch return error.CorruptedFileSystem;
    reader.skipBytes(length, .{}) catch return error.CorruptedFileSystem;

    const node = try allocator.create(vfs.Node);
    node.* = vfs.Node.create(.{
        .name = name,
        .inode = inode,
        .type = .file,
        .length = length,
        .ctx = ctx,
        .impl = offset,
        .readFn = read,
    });
    try list.append(node);
    std.debug.assert(list.items.len == inode + 1);

    return offset + 9 + name_len + length;
}

fn parseDir(allocator: std.mem.Allocator, list: *std.ArrayList(*vfs.Node), reader: std.io.AnyReader, next_inode: *u64, is_root: bool, ctx: *Ctx, start_offset: usize) !usize {
    var offset = start_offset;
    const name_len = reader.readByte() catch return error.CorruptedFileSystem;
    if ((is_root and name_len != 0) or (!is_root and name_len == 0)) return error.CorruptedFileSystem;
    const name = if (is_root) "" else (try allocator.alloc(u8, name_len));
    defer if (!is_root) allocator.free(name);
    if (!is_root) reader.readNoEof(@constCast(name)) catch return error.CorruptedFileSystem;
    const inode = next_inode.*;
    next_inode.* += 1;

    const child_count = reader.readByte() catch return error.CorruptedFileSystem;

    const node = try allocator.create(vfs.Node);
    node.* = vfs.Node.create(.{
        .name = name,
        .inode = inode,
        .type = .directory,
        .length = 0,
        .ctx = ctx,
        .impl = offset,
        .childCountFn = childCount,
        .readDirFn = readDir,
    });
    try list.append(node);
    std.debug.assert(list.items.len == inode + 1);

    offset += 2 + name_len;

    for (0..child_count) |_| {
        const file_type = reader.readByte() catch return error.CorruptedFileSystem;
        offset += 1;
        switch (file_type) {
            0x01 => offset = try parseFile(allocator, list, reader, next_inode, ctx, offset),
            0x02 => offset = try parseDir(allocator, list, reader, next_inode, false, ctx, offset),
            else => return error.CorruptedFileSystem,
        }
    }

    return offset;
}

fn openDevice(allocator: std.mem.Allocator, device: *vfs.Node) !*vfs.Node {
    std.debug.assert(accepts(device));

    const buffer = try allocator.alloc(u8, device.length);
    defer allocator.free(buffer);
    std.debug.assert(device.read(0, buffer) == device.length);
    var fbs = std.io.fixedBufferStream(buffer);
    const reader = fbs.reader().any();
    reader.skipBytes(7, .{ .buf_size = 7 }) catch return error.CorruptedFileSystem;
    const version = reader.readByte() catch return error.CorruptedFileSystem;
    log.debug("Detected CROFS version is {x}", .{version});
    if (version != 0x00) return error.UnsupportedVersion;

    var next_inode: u64 = 0;
    if ((reader.readByte() catch return error.CorruptedFileSystem) != 0x02) return error.CorruptedFileSystem;
    const ctx = try allocator.create(Ctx);
    const node_list = try allocator.create(std.ArrayList(*vfs.Node));
    node_list.* = std.ArrayList(*vfs.Node).init(allocator);
    ctx.* = .{
        .device = device,
        .node_list = node_list,
    };
    _ = try parseDir(allocator, node_list, reader, &next_inode, true, ctx, 8);
    _ = (reader.readByte() catch { // We should be at EOF
        return node_list.items[0];
    });
    return error.CorruptedFileSystem;
}

pub fn init() !void {
    log.debug("Initializing...", .{});
    defer log.debug("Initialization done", .{});

    log.debug("Registering file system", .{});
    try vfs.registerFileSystem(.{
        .name = "crofs",
        .acceptsFn = accepts,
        .openDeviceFn = openDevice,
    });
}
