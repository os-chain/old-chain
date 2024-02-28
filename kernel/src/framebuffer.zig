const std = @import("std");
const limine = @import("limine");
const vfs = @import("fs/vfs.zig");
const devfs = @import("fs/devfs.zig");

const log = std.log.scoped(.framebuffer);

pub export var fb_req = limine.FramebufferRequest{};

var framebuffers: []*limine.Framebuffer = &.{};

var allocator: std.mem.Allocator = undefined;

const FramebufferMask = struct {
    red_offset: u8,
    red_size: u8,
    green_offset: u8,
    green_size: u8,
    blue_offset: u8,
    blue_size: u8,
    total_size: u16,

    pub const Color = enum {
        red,
        green,
        blue,
    };

    pub inline fn getBit(mask: FramebufferMask, i: usize) ?Color {
        if (mask.red_offset <= i and mask.red_offset + mask.red_size > i) return .red;
        if (mask.green_offset <= i and mask.green_offset + mask.green_size > i) return .green;
        if (mask.blue_offset <= i and mask.blue_offset + mask.blue_size > i) return .blue;
        return null;
    }

    pub fn format(mask: FramebufferMask, comptime _: []const u8, _: std.fmt.FormatOptions, writer: anytype) !void {
        for (0..mask.total_size) |i| {
            const bit = mask.getBit(i);
            try writer.writeByte(if (bit) |color| @tagName(color)[0] else '-');
        }
    }

    pub inline fn fromFramebuffer(fb: *limine.Framebuffer) FramebufferMask {
        return .{
            .red_offset = fb.red_mask_shift,
            .red_size = fb.red_mask_size,
            .green_offset = fb.green_mask_shift,
            .green_size = fb.green_mask_size,
            .blue_offset = fb.blue_mask_shift,
            .blue_size = fb.blue_mask_size,
            .total_size = fb.bpp,
        };
    }
};

fn write(node: *vfs.Node, offset: u64, buffer: []const u8) u64 {
    const fb = framebuffers[node.inode];

    const size = fb.pitch * fb.height;
    std.debug.assert(node.length == size);

    const bytes_to_write = @min(size - offset, buffer.len);

    const slice = fb.data()[offset .. offset + bytes_to_write];
    @memcpy(slice, buffer[0..bytes_to_write]);
    return bytes_to_write;
}

pub fn init(alloc: std.mem.Allocator) !void {
    log.debug("Initializing...", .{});
    defer log.debug("Initialization done", .{});

    allocator = alloc;

    if (fb_req.response) |fb_res| {
        framebuffers = fb_res.framebuffers();
        log.debug("Found {} framebuffer(s)", .{framebuffers.len});

        for (framebuffers, 0..) |fb, i| {
            log.debug(
                \\fb{}:
                \\  addr=V:{x}
                \\  size={d}x{d}
                \\  pitch={d}
                \\  bpp={d}
                \\  memory_model={s}
                \\  mask={}
                \\  edid_addr=V:{x}
                \\  edid_size={d}
                \\  mode_count={d}
            , .{
                i,
                @intFromPtr(fb.address),
                fb.width,
                fb.height,
                fb.pitch,
                fb.bpp,
                @tagName(fb.memory_model),
                FramebufferMask.fromFramebuffer(fb),
                @intFromPtr(fb.edid),
                fb.edid_size,
                fb.mode_count,
            });

            const name = try std.fmt.allocPrint(allocator, "fb{d}", .{i});
            defer allocator.free(name);
            const node = try allocator.create(vfs.Node);
            node.* = vfs.Node.create(.{
                .name = name,
                .inode = i,
                .length = fb.pitch * fb.height,
                .type = .file,
                .writeFn = write,
            });
            try devfs.addDevice(node);
        }
    } else log.warn("No framebuffers found (no response)", .{});
}

pub fn deinit() void {
    for (0..count()) |i| {
        log.debug("Deinitializing fb{d}", .{i});
        const maybe_name = std.fmt.allocPrint(allocator, "fb{d}", .{i}) catch null;
        if (maybe_name) |name| {
            defer allocator.free(name);
            if (devfs.getDevice(name)) |node| {
                devfs.removeDevice(name) catch unreachable;
                allocator.destroy(node);
            } else log.warn("Couldn't unmount device {s} (not found)", .{name});
        } else log.err("Couldn't allocate memory for deinitializing fb{d} (unable to generate expected name)", .{i});
    }
}

// Return the number of framebuffers
pub inline fn count() usize {
    return framebuffers.len;
}
