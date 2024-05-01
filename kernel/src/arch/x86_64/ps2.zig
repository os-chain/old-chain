const std = @import("std");
const int = @import("int.zig");
const cpu = @import("cpu.zig");
const ioapic = @import("ioapic.zig");
const lapic = @import("lapic.zig");
const vfs = @import("../../fs/vfs.zig");
const devfs = @import("../../fs/devfs.zig");

const log = std.log.scoped(.ps2);

var init_done = false;

const map: [128]?u8 = .{ null, null, '1', '2', '3', '4', '5', '6', '7', '8', '9', '0', '-', '=', '\x08', '\t', 'q', 'w', 'e', 'r', 't', 'y', 'u', 'i', 'o', 'p', '[', ']', '\n', null, 'a', 's', 'd', 'f', 'g', 'h', 'j', 'k', 'l', ';', '\'', '`', null, '\\', 'z', 'x', 'c', 'v', 'b', 'n', 'm', ',', '.', '/', null, '*', null, ' ' } ++ .{null} ** 70;

var char_buffer: std.fifo.LinearFifo(u8, .Dynamic) = undefined;

var kb_node: vfs.Node = undefined;

fn handler(_: *cpu.ContextFrame) void {
    if (!init_done) {
        _ = cpu.inb(0x60);
        return;
    }

    const code = cpu.inb(0x60);

    if (code < 128) {
        if (map[code]) |char| {
            char_buffer.writeItem(char) catch |err| switch (err) {
                error.OutOfMemory => @panic("OOM"),
            };
        }
    }
}

const Cmd = enum(u8) {
    read_config = 0x20,
    write_config = 0x60,
    disable_second_port = 0xA7,
    enable_second_port = 0xA8,
    disable_first_port = 0xAD,
    enable_first_port = 0xAE,
};

fn sendCommand(cmd: Cmd) void {
    write(0x64, @intFromEnum(cmd));
}

fn canRead() bool {
    return (cpu.inb(0x64) & 1) != 0;
}

fn canWrite() bool {
    return (cpu.inb(0x64) & 2) == 0;
}

fn read() u8 {
    while (!canRead()) {}

    return cpu.inb(0x60);
}

fn write(comptime port: u16, value: u8) void {
    std.debug.assert(port == 0x60 or port == 0x64);

    while (!canWrite()) {}

    cpu.outb(port, value);
}

fn disable() void {
    sendCommand(.disable_first_port);
    sendCommand(.disable_second_port);
}

fn enable() void {
    sendCommand(.enable_first_port);
    sendCommand(.enable_second_port);
}

fn reset() void {
    cpu.outb(0x64, 0xFF);
    cpu.outb(0x60, 0xFF);
}

fn configure() void {
    log.debug("Configuring...", .{});
    defer log.debug("Configuration done", .{});

    sendCommand(.read_config);
    var config = read();

    log.debug("Old config: {b:0>8}", .{config});

    config |= 1;

    log.debug("New config: {b:0>8}", .{config});

    sendCommand(.write_config);
    write(0x60, config);
}

fn readFile(_node: *vfs.Node, _: u64, buf: []u8) usize {
    std.debug.assert(_node == &kb_node);

    return char_buffer.read(buf);
}

pub fn init(allocator: std.mem.Allocator) !void {
    log.debug("Initializing...", .{});
    defer log.debug("Initialization done", .{});

    char_buffer = std.fifo.LinearFifo(u8, .Dynamic).init(allocator);
    try char_buffer.ensureTotalCapacity(0x1000);

    kb_node = vfs.Node.create(.{ .name = "kb", .type = .file, .inode = 0, .length = 0, .readFn = readFile });
    try devfs.addDevice(&kb_node);

    disable();

    int.registerIrq(1, handler);
    var red_tbl_entry = ioapic.readRedTbl(1);
    red_tbl_entry.mask = false;
    red_tbl_entry.destination = @truncate(lapic.getBootstrapLapicId());
    red_tbl_entry.vec = 32 + 1;
    ioapic.writeRedTbl(1, red_tbl_entry);

    _ = cpu.inb(0x60);

    configure();

    enable();
    reset();

    _ = cpu.inb(0x60);
    init_done = true;
}

pub fn deinit() void {
    char_buffer.deinit();
}
