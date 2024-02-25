const std = @import("std");

const log = std.log.scoped(.vfs);

var gpa = std.heap.GeneralPurposeAllocator(.{}){};
const allocator = gpa.allocator();

var mountpoints: std.StringHashMap(*Node) = undefined;

var file_systems: std.ArrayList(FileSystem) = undefined;

pub const FileSystem = struct {
    name: [16]u8,
    vtable: VTable,

    pub const VTable = struct {
        accepts: *const AcceptsFn,
        openDevice: *const OpenDeviceFn,

        pub const OpenDeviceError = error{ CorruptedFileSystem, UnsupportedVersion } || std.mem.Allocator.Error;

        pub const AcceptsFn = fn (*Node) bool;
        pub const OpenDeviceFn = fn (std.mem.Allocator, *Node) OpenDeviceError!*Node;
    };

    pub inline fn getName(self: FileSystem) []const u8 {
        return std.mem.span(@as([*:0]const u8, @ptrCast(&self.name)));
    }

    pub inline fn setName(self: *FileSystem, name: []const u8) void {
        std.debug.assert(name.len < @typeInfo(@TypeOf(self.name)).Array.len);

        for (name, 0..) |char, i| {
            self.name[i] = char;
        }
        self.name[name.len] = 0;
    }

    pub inline fn accepts(self: FileSystem, device: *Node) bool {
        return self.vtable.accepts(device);
    }

    pub inline fn openDevice(self: FileSystem, alloc: std.mem.Allocator, device: *Node) !*Node {
        return self.vtable.openDevice(alloc, device);
    }
};

/// A VFS node. Can be a file, directory, etc.
pub const Node = struct {
    /// The name of the node
    name: [128]u8,
    /// Used for internal identification by the FS
    inode: u64,
    /// The length of the node.
    length: u64,
    /// The type of the node
    type: Type,
    /// The node's `Operations`
    operations: Operations,
    /// Used by the FS implementation
    ctx: *anyopaque,
    /// Used by the FS implementation
    impl: u64,

    /// Operations that can be performed on a node
    pub const Operations = struct {
        open: ?*const Open,
        close: ?*const Close,
        read: ?*const Read,
        write: ?*const Write,
        childCount: ?*const ChildCount,
        readDir: ?*const ReadDir,

        pub const Open = fn (node: *Node) void;
        pub const Close = fn (node: *Node) void;
        pub const Read = fn (node: *Node, offset: u64, buffer: []u8) u64;
        pub const Write = fn (node: *Node, offset: u64, buffer: []const u8) u64;
        pub const ChildCount = fn (node: *Node) u64;
        pub const ReadDir = fn (node: *Node, offset: u64, buffer: []*Node) void;
    };

    /// The type of a node
    pub const Type = enum {
        file,
        directory,
    };

    pub inline fn open(self: *Node) void {
        if (self.operations.open) |openFn| {
            openFn(self);
        }
    }

    pub inline fn close(self: *Node) void {
        if (self.operations.close) |closeFn| {
            closeFn(self);
        }
    }

    pub inline fn read(self: *Node, offset: u64, buffer: []u8) u64 {
        return if (self.operations.read) |readFn| switch (self.type) {
            .file => readFn(self, offset, buffer),
            .directory => 0,
        } else 0;
    }

    pub inline fn write(self: *Node, offset: u64, buffer: []const u8) u64 {
        return if (self.operations.write) |writeFn| switch (self.type) {
            .file => writeFn(self, offset, buffer),
            .directory => 0,
        } else 0;
    }

    pub inline fn childCount(self: *Node) u64 {
        return if (self.operations.childCount) |childCountFn| switch (self.type) {
            .directory => childCountFn(self),
            .file => 0,
        } else 0;
    }

    pub inline fn readDir(self: *Node, offset: u64, buffer: []*Node) void {
        if (self.operations.readDir) |readDirFn| {
            switch (self.type) {
                .directory => readDirFn(self, offset, buffer),
                .file => {},
            }
        }
    }

    /// Get the name of the node
    pub inline fn getName(self: *Node) []const u8 {
        return std.mem.span(@as([*:0]const u8, @ptrCast(&self.name)));
    }

    /// Is the name `name`?
    pub inline fn nameIs(self: *Node, name: []const u8) bool {
        for (self.name, 0..) |char, i| {
            if (char == 0) return name.len == i;
            if (i == name.len) return false;

            if (char != name[i]) return false;
        }

        unreachable;
    }

    /// Set the name of the node. Stores the name in the struct itself, so
    /// there's no need to keep `options.name` lying around in memory, it will
    /// be copied.
    pub inline fn setName(self: *Node, name: []const u8) void {
        std.debug.assert(name.len < @typeInfo(@TypeOf(self.name)).Array.len);

        for (name, 0..) |char, i| {
            self.name[i] = char;
        }
        self.name[name.len] = 0;
    }

    pub const CreateOptions = struct {
        name: []const u8,
        inode: u64,
        length: u64,
        type: Type,
        openFn: ?*const Operations.Open = null,
        closeFn: ?*const Operations.Close = null,
        readFn: ?*const Operations.Read = null,
        writeFn: ?*const Operations.Write = null,
        childCountFn: ?*const Operations.ChildCount = null,
        readDirFn: ?*const Operations.ReadDir = null,
        ctx: *anyopaque = undefined,
        impl: u64 = undefined,
    };

    /// Create a VFS node. Stores the name in the struct itself, so there's no
    /// need to keep `options.name` lying around in memory, it will be copied.
    pub inline fn create(options: CreateOptions) Node {
        var node = Node{
            .name = undefined,
            .inode = options.inode,
            .length = options.length,
            .type = options.type,
            .operations = .{
                .open = options.openFn,
                .close = options.closeFn,
                .read = options.readFn,
                .write = options.writeFn,
                .childCount = options.childCountFn,
                .readDir = options.readDirFn,
            },
            .ctx = options.ctx,
            .impl = options.impl,
        };

        node.setName(options.name);

        return node;
    }
};

/// The root node of the whole VFS.
var root: *Node = undefined;

pub fn init() !void {
    log.debug("Initializing...", .{});
    defer log.debug("Initialization done", .{});

    mountpoints = std.StringHashMap(*Node).init(allocator);
    file_systems = std.ArrayList(FileSystem).init(allocator);

    root = try allocator.create(Node);
    root.* = Node.create(.{
        .name = "",
        .inode = 0,
        .length = 0,
        .type = .directory,
    });
}

pub const MountNodeError = error{ AlreadyMounted, NotAbsolute, NotNormalized } || std.mem.Allocator.Error;

pub fn mountNode(node: *Node, path: []const u8) MountNodeError!void {
    if (!std.fs.path.isAbsolutePosix(path)) return error.NotAbsolute;
    if (path[path.len - 1] == '/' and path.len != 1) return error.NotNormalized;

    log.debug("Mounting at {s}", .{path});

    if (mountpoints.get(path) != null) return error.AlreadyMounted;

    const path_dupe = try allocator.dupe(u8, path);
    try mountpoints.put(path_dupe, node);
}

pub const UnmountNodeError = error{ NotMounted, NotAbsolute, NotNormalized };

pub fn unmountNode(path: []const u8) UnmountNodeError!void {
    if (!std.fs.path.isAbsolutePosix(path)) return error.NotAbsolute;
    if (path[path.len - 1] == '/' and path.len != 1) return error.NotNormalized;

    if (mountpoints.getKey(path)) |key| {
        std.debug.assert(mountpoints.remove(path));
        allocator.free(key);
    } else return error.NotMounted;
}

pub const MountDeviceError = error{UnknownFileSystem} || OpenPathError || FileSystem.VTable.OpenDeviceError || MountNodeError || std.mem.Allocator.Error;

pub fn mountDevice(dev_path: []const u8, dest_path: []const u8) MountDeviceError!void {
    log.debug("Mounting {s} to {s}", .{ dev_path, dest_path });
    const dev = try openPath(dev_path);
    var detected_fs: ?FileSystem = null;
    for (file_systems.items) |fs| {
        if (fs.accepts(dev)) detected_fs = fs;
    }
    if (detected_fs) |fs| {
        log.debug("{s} was detected to be {s}", .{ dev_path, fs.getName() });
        const node = try fs.openDevice(allocator, dev);
        try mountNode(node, dest_path);
    } else return error.UnknownFileSystem;
}

pub const RegisterFileSystemOptions = struct {
    name: []const u8,
    acceptsFn: *const FileSystem.VTable.AcceptsFn,
    openDeviceFn: *const FileSystem.VTable.OpenDeviceFn,
};

pub fn registerFileSystem(options: RegisterFileSystemOptions) !void {
    var fs: FileSystem = .{
        .name = undefined,
        .vtable = .{
            .accepts = options.acceptsFn,
            .openDevice = options.openDeviceFn,
        },
    };
    fs.setName(options.name);
    try file_systems.append(fs);
}

pub const OpenPathError = error{ NotAbsolute, NotDirectory, NotFound } || std.mem.Allocator.Error;

/// Given a path, open the node and return a pointer to it
pub fn openPath(path: []const u8) OpenPathError!*Node {
    if (!std.fs.path.isAbsolutePosix(path)) return error.NotAbsolute;

    var iter = try std.fs.path.componentIterator(path);

    var node = root;

    if (mountpoints.get("/")) |mountpoint| {
        node = mountpoint;
    }

    while (iter.next()) |component| {
        switch (node.type) {
            .file => return error.NotDirectory,
            .directory => {
                const child_count = node.childCount();
                const buffer = try allocator.alloc(*Node, child_count);
                node.readDir(0, buffer);
                defer allocator.free(buffer);
                if (!match: {
                    if (mountpoints.get(component.path)) |mountpoint| {
                        node = mountpoint;
                        break :match true;
                    }
                    for (buffer) |child| {
                        if (child.nameIs(component.name)) {
                            node = child;
                            break :match true;
                        }
                    }
                    break :match false;
                }) return error.NotFound;
            },
        }
    }

    node.open();

    return node;
}
