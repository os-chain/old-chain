const std = @import("std");
const vfs = @import("fs/vfs.zig");
const devfs = @import("fs/devfs.zig");

const font = @embedFile("font");

comptime {
    std.debug.assert(font.len == 0x1000);
}

const log = std.log.scoped(.tty);

var node: vfs.Node = undefined;

var fb: *vfs.Node = undefined;
var kb: *vfs.Node = undefined;

var cursor: struct { x: usize, y: usize } = .{ .x = 0, .y = 0 };

const State = enum {
    normal,
    escape,
    csi,
};

var state: State = .normal;

var sgr: usize = 0;

const Color = enum {
    black,
    red,
    green,
    yellow,
    blue,
    magenta,
    cyan,
    white,
    bright_black,
    bright_red,
    bright_green,
    bright_yellow,
    bright_blue,
    bright_magenta,
    bright_cyan,
    bright_white,

    const Rgb = struct {
        r: u8,
        g: u8,
        b: u8,
    };

    fn getRgb(self: Color) Rgb {
        return switch (self) {
            .black => .{ .r = 0, .g = 0, .b = 0 },
            .red => .{ .r = 170, .g = 0, .b = 0 },
            .green => .{ .r = 0, .g = 170, .b = 0 },
            .yellow => .{ .r = 170, .g = 85, .b = 0 },
            .blue => .{ .r = 0, .g = 0, .b = 170 },
            .magenta => .{ .r = 170, .g = 0, .b = 170 },
            .cyan => .{ .r = 0, .g = 170, .b = 170 },
            .white => .{ .r = 170, .g = 170, .b = 170 },
            .bright_black => .{ .r = 85, .g = 85, .b = 85 },
            .bright_red => .{ .r = 255, .g = 85, .b = 85 },
            .bright_green => .{ .r = 85, .g = 255, .b = 85 },
            .bright_yellow => .{ .r = 255, .g = 255, .b = 85 },
            .bright_blue => .{ .r = 85, .g = 85, .b = 255 },
            .bright_magenta => .{ .r = 255, .g = 85, .b = 255 },
            .bright_cyan => .{ .r = 85, .g = 255, .b = 255 },
            .bright_white => .{ .r = 255, .g = 255, .b = 255 },
        };
    }
};

const Attributes = struct {
    underline: bool = false,
    invert: bool = false,
    strike: bool = false,
    overline: bool = false,
    fg: Color = .white,
    bg: Color = .black,
};

var attr: Attributes = .{};

fn newLine() void {
    cursor.x = 0;
    cursor.y += 1;
}

fn advanceCursor() void {
    cursor.x += 1;

    if (cursor.x >= 1280 / 8) newLine();
}

fn backspace() void {
    if (cursor.x != 0) cursor.x -= 1;
    clearChar(cursor.x, cursor.y);
}

fn tab() void {
    while (cursor.x % 8 != 0) advanceCursor();
}

fn printChar(char: u8) void {
    switch (state) {
        .normal => switch (char) {
            '\x07' => {}, // Bell
            '\x08' => backspace(),
            '\x09' => tab(),
            '\x1b' => state = .escape,
            '\r' => {},
            '\n' => newLine(),
            else => {
                setChar(cursor.x, cursor.y, char);
                advanceCursor();
            },
        },
        .escape => switch (char) {
            '[' => {
                sgr = 0;
                state = .csi;
            },
            else => state = .normal,
        },
        .csi => switch (char) {
            '0'...'9' => {
                sgr *= 10;
                sgr += char - '0';
            },
            'm' => {
                switch (sgr) {
                    0 => attr = .{},
                    1 => {}, // Bold
                    2 => {}, // Faint
                    3 => {}, // Italic
                    4 => attr.underline = true,
                    5, 6 => {}, // Blink
                    7 => attr.invert = true,
                    9 => attr.strike = true,
                    24 => attr.underline = false,
                    27 => attr.invert = false,
                    29 => attr.strike = false,
                    inline 30...37, 40...47, 90...97, 100...107 => |n| {
                        (switch (n) {
                            30...37, 90...97 => &attr.fg,
                            40...47, 100...107 => &attr.bg,
                            else => unreachable,
                        }).* = switch (n) {
                            30...37 => @enumFromInt(n - 30),
                            40...47 => @enumFromInt(n - 40),
                            90...97 => @enumFromInt(n - 90 + 8),
                            100...107 => @enumFromInt(n - 100 + 8),
                            else => unreachable,
                        };
                    },
                    39 => attr.fg = @as(*const Color, @ptrCast(std.meta.fieldInfo(Attributes, .fg).default_value.?)).*,
                    49 => attr.bg = @as(*const Color, @ptrCast(std.meta.fieldInfo(Attributes, .bg).default_value.?)).*,
                    53 => attr.overline = true,
                    55 => attr.overline = false,
                    else => {},
                }
                state = .normal;
            },
            else => state = .normal,
        },
    }
}

fn clearChar(x: usize, y: usize) void {
    for (0..16) |row_i| {
        for (0..8) |col_i| {
            setPixel(x * 8 + col_i, y * 16 + row_i, attr.bg);
        }
    }
}

fn setChar(x: usize, y: usize, char: u8) void {
    const glyph = font[@as(usize, char) * 16 .. @as(usize, char + 1) * 16];

    for (glyph, 0..) |row, row_i| {
        for (0..8) |col_i| {
            var present = row >> @truncate(8 - col_i) & 0x1 != 0;

            if (attr.underline and row_i == 14) present = true;
            if (attr.strike and row_i == 8) present = true;
            if (attr.overline and row_i == 1) present = true;

            var fg = attr.fg;
            var bg = attr.bg;

            if (attr.invert) {
                const old_fg = fg;
                const old_bg = bg;
                fg = old_bg;
                bg = old_fg;
            }

            const color = if (present) fg else bg;
            setPixel(x * 8 + col_i, y * 16 + row_i, color);
        }
    }
}

fn setPixel(x: usize, y: usize, col: Color) void {
    std.debug.assert(x < 1280);
    std.debug.assert(y < 800);

    const offset = x * 4 + y * 1280 * 4;

    const rgb = col.getRgb();
    const buf: [4]u8 = .{ rgb.b, rgb.g, rgb.r, 0x00 };

    std.debug.assert(fb.write(offset, &buf) == 4);
}

pub fn init() !void {
    log.debug("Initializing...", .{});
    defer log.debug("Initialization done", .{});

    fb = try vfs.openPath("/dev/fb0");
    kb = try vfs.openPath("/dev/kb");

    if (fb.length != 1280 * 800 * 4) log.err("Framebuffer is not 1280x800 bpp=32", .{});

    node = vfs.Node.create(.{
        .name = "tty",
        .type = .file,
        .inode = 0,
        .length = 0,
        .writeFn = write,
        .readFn = read,
    });

    try devfs.addDevice(&node);
}

pub fn deinit() void {
    devfs.removeDevice("tty") catch log.warn("Could not unmount /dev/tty", .{});
}

fn write(_node: *vfs.Node, _: u64, buf: []const u8) usize {
    std.debug.assert(&node == _node);

    for (buf) |char| {
        printChar(char);
    }

    return buf.len;
}

fn read(_node: *vfs.Node, _: u64, buf: []u8) usize {
    std.debug.assert(&node == _node);

    return kb.read(0, buf);
}
