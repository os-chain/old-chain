const std = @import("std");

var gpa = std.heap.GeneralPurposeAllocator(.{}){};
const allocator = gpa.allocator();

fn createInnerFile(writer: std.io.AnyWriter, name: []const u8, file: std.fs.File) !void {
    try writer.writeByte(0x01);
    std.debug.assert(name.len < 256);
    try writer.writeByte(@truncate(name.len));
    _ = try writer.write(name);
    const size = (try file.metadata()).size();
    try writer.writeInt(u64, size, .little);
    const reader = file.reader().any();
    for (0..size) |_| {
        try writer.writeByte(try reader.readByte());
    }
}

fn createInnerDir(writer: std.io.AnyWriter, name: []const u8, dir: std.fs.Dir) !void {
    try writer.writeByte(0x02);
    std.debug.assert(name.len < 256);
    try writer.writeByte(@truncate(name.len));
    _ = try writer.write(name);
    var iter = dir.iterate();
    var child_count: usize = 0;
    while (try iter.next()) |_| {
        child_count += 1;
    }
    iter.reset();
    std.debug.assert(child_count < 256);
    try writer.writeByte(@truncate(child_count));
    while (try iter.next()) |child| {
        switch (child.kind) {
            .file => {
                var child_file = try dir.openFile(child.name, .{});
                try createInnerFile(writer, child.name, child_file);
                child_file.close();
            },
            .directory => {
                var child_dir = try dir.openDir(child.name, .{ .iterate = true });
                try createInnerDir(writer, child.name, child_dir);
                child_dir.close();
            },
            else => return error.InvalidFile,
        }
    }
}

pub fn create(writer: std.io.AnyWriter, dir: std.fs.Dir) !void {
    _ = try writer.write("~CROFS~");
    try writer.writeByte(0x00);
    try createInnerDir(writer, "", dir);
}

pub fn main() !void {
    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    if (args.len == 1) {
        std.debug.print(
            \\Usage: crofs-utils <command> [args]
            \\Commands:
            \\  create <dest_file> <source_dir>     Create a CROFS file from a directory
            \\
        , .{});
    } else {
        if (std.mem.eql(u8, args[1], "create")) {
            if (args.len != 4) {
                std.debug.print("Usage: crofs-utils create <dest_file> <source_dir>\n", .{});
            } else {
                var file = try if (std.fs.path.isAbsolute(args[2]))
                    std.fs.createFileAbsolute(args[2], .{})
                else
                    std.fs.cwd().createFile(args[2], .{});
                defer file.close();

                var dir = try if (std.fs.path.isAbsolute(args[3]))
                    std.fs.openDirAbsolute(args[3], .{ .iterate = true })
                else
                    std.fs.cwd().openDir(args[3], .{ .iterate = true });
                defer dir.close();

                try create(file.writer().any(), dir);
            }
        } else {
            std.debug.print("Invalid command \"{s}\"\n", .{args[1]});
        }
    }
}
