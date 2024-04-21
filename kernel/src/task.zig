const std = @import("std");
const builtin = @import("builtin");
const vfs = @import("fs/vfs.zig");
const hal = @import("hal.zig");
const smp = @import("smp.zig");

const log = std.log.scoped(.task);

var allocator: std.mem.Allocator = undefined;

var tasks: std.ArrayList(?Task) = undefined;

const stack_page_count = 8;

pub const Pid = u64;

pub const Fd = u64;

pub const Task = struct {
    regs: hal.ContextFrame = undefined,
    page_table: *hal.PageTable,
    arena: std.heap.ArenaAllocator,
    files: std.ArrayListUnmanaged(?*vfs.Node) = .{},
};

pub fn init(alloc: std.mem.Allocator) !void {
    log.debug("Initializing...", .{});
    defer log.debug("Initialization done", .{});

    allocator = alloc;

    tasks = std.ArrayList(?Task).init(allocator);
}

pub fn deinit() void {
    tasks.deinit();
}

pub fn getCurrentTask() Task {
    return tasks.items[getCurrentPid()].?;
}

pub fn getCurrentPid() Pid {
    return 0; // TODO: Actual scheduler
}

fn addTask(task: Task) !Pid {
    try tasks.append(task);
    return tasks.items.len - 1;
}

pub fn addRoot(path: []const u8) !void {
    log.debug("Setting {s} as the root process", .{path});

    var task = Task{
        .arena = std.heap.ArenaAllocator.init(allocator),
        .page_table = undefined,
    };

    const arena = task.arena.allocator();

    task.page_table = &((try arena.allocWithOptions(hal.PageTable, 1, 0x1000, null))[0]);
    task.page_table.* = std.mem.zeroes(hal.PageTable);
    hal.mapKernel(task.page_table);

    const node = try vfs.openPath(path);
    defer node.close();

    const code_page_count = std.math.divCeil(usize, node.length, 0x1000) catch unreachable;

    const code_frames = try arena.allocWithOptions(u8, code_page_count * 0x1000, 0x1000, null);
    const stack_frames = try arena.allocWithOptions(u8, stack_page_count * 0x1000, 0x1000, null);

    std.debug.assert(node.read(0, code_frames) == node.length);

    for (0..code_page_count) |i| {
        try hal.mapPage(
            arena,
            task.page_table,
            0x200000 + 0x1000 * i,
            hal.physFromVirt(task.page_table, @intFromPtr(code_frames.ptr)).? + 0x1000 * i,
            .{
                .writable = false,
                .executable = true,
                .user = true,
                .global = false,
            },
        );
    }
    for (0..stack_page_count) |i| {
        try hal.mapPage(
            arena,
            task.page_table,
            0x10200000 + 0x1000 * i,
            hal.physFromVirt(task.page_table, @intFromPtr(stack_frames.ptr)).? + 0x1000 * i,
            .{
                .writable = true,
                .executable = false,
                .user = true,
                .global = false,
            },
        );
    }

    std.debug.assert(task.files.items.len == 0);
    try task.files.append(arena, try vfs.openPath("/dev/tty"));
    std.debug.assert(task.files.items.len == 1);
    try task.files.append(arena, try vfs.openPath("/dev/tty"));
    std.debug.assert(task.files.items.len == 2);

    std.debug.assert(tasks.items.len == 0);
    const pid = try addTask(task);
    log.debug("Root task PID is {d}", .{pid});
}

pub fn start() noreturn {
    // TODO: Actual scheduler
    if (tasks.items.len > smp.cpuid()) {
        runTask(tasks.items[smp.cpuid()] orelse while (true) {});
    } else {
        while (true) {}
    }
}

fn runTask(task: Task) noreturn {
    const page_table_addr = hal.physFromVirt(hal.getActivePageTable(), @intFromPtr(task.page_table)).?;
    std.debug.assert(page_table_addr % 0x1000 == 0);
    std.debug.assert(hal.pageIsValid(task.page_table));

    const stack_top = 0x10200000 + 0x1000 * stack_page_count;

    hal.setPageTableAddr(page_table_addr);

    {
        switch (builtin.cpu.arch) {
            .x86_64 => asm volatile (
                \\sysretq
                :
                : [addr] "{rcx}" (0x200000),
                  [flags] "{r11}" (0x202),
                  [stack] "{rsp}" (stack_top),
                : "memory"
            ),
            else => |other| @compileError(@tagName(other) ++ " not supported"),
        }
        unreachable;
    }
}
