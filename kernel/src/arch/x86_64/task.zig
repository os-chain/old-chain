const std = @import("std");
const vfs = @import("../../fs/vfs.zig");
const paging = @import("paging.zig");
const cpu = @import("cpu.zig");

const log = std.log.scoped(.task);

var tasks: std.ArrayList(?Task) = undefined;

var current_pid: Pid = 0;

pub const Pid = u64;

pub const Task = struct {
    regs: cpu.ContextFrame = undefined,
    lvl4_page: *paging.PageTable,
    arena: std.heap.ArenaAllocator,
};

pub fn init(allocator: std.mem.Allocator) !void {
    log.debug("Initializing...", .{});
    defer log.debug("Initialization done", .{});

    tasks = std.ArrayList(?Task).init(allocator);
}

pub fn addTask(task: Task) !Pid {
    for (tasks.items, 0..) |maybe_task, i| {
        if (maybe_task == null) {
            tasks.items[i] = task;
            return i;
        }
    }

    try tasks.append(task);
    return tasks.items.len - 1;
}

pub fn deleteTask(pid: Pid) void {
    std.debug.assert(pid < tasks.items.len);
    std.debug.assert(tasks.items[pid] != null);

    tasks.items[pid].?.paging_arena.deinit();

    tasks.items[pid] = null;
}

pub fn runRoot(alloc: std.mem.Allocator, path: []const u8) !noreturn {
    log.debug("Running {s} as the root process", .{path});

    var task = Task{
        .arena = std.heap.ArenaAllocator.init(alloc),
        .lvl4_page = undefined,
    };

    const allocator = task.arena.allocator();

    task.lvl4_page = &((try allocator.allocWithOptions(paging.PageTable, 1, 0x1000, null))[0]);
    task.lvl4_page.* = std.mem.zeroes(paging.PageTable);
    paging.mapKernel(task.lvl4_page);

    const node = try vfs.openPath(path);
    defer node.close();

    const code_page_count = std.math.divCeil(usize, node.length, 0x1000) catch unreachable;
    const stack_page_count = 8;

    const code_frames = try allocator.allocWithOptions(u8, code_page_count * 0x1000, 0x1000, null);
    const stack_frames = try allocator.allocWithOptions(u8, stack_page_count * 0x1000, 0x1000, null);

    std.debug.assert(node.read(0, code_frames) == node.length);

    for (0..code_page_count) |i| {
        try paging.mapPage(
            allocator,
            task.lvl4_page,
            0x200000 + 0x1000 * i,
            paging.physFromVirt(task.lvl4_page, @intFromPtr(code_frames.ptr)).? + 0x1000 * i,
            .{
                .writable = false,
                .executable = true,
                .user = true,
                .global = false,
            },
        );
    }
    for (0..stack_page_count) |i| {
        try paging.mapPage(
            allocator,
            task.lvl4_page,
            0x10200000 + 0x1000 * i,
            paging.physFromVirt(task.lvl4_page, @intFromPtr(stack_frames.ptr)).? + 0x1000 * i,
            .{
                .writable = true,
                .executable = false,
                .user = true,
                .global = false,
            },
        );
    }

    const stack_top = 0x10200000 + 0x1000 * stack_page_count;

    std.debug.assert(tasks.items.len == 0);
    const pid = try addTask(task);
    std.debug.assert(pid == 0);

    const cr3 = paging.physFromVirt(paging.getActiveLvl4Table(), @intFromPtr(task.lvl4_page)).?;
    std.debug.assert(cr3 % 0x1000 == 0);
    std.debug.assert(paging.isValid(task.lvl4_page, 4));

    cpu.Cr3.write(cr3);

    {
        asm volatile (
            \\mov %[addr], %%rcx
            \\mov %[stack], %%rsp
            \\mov %[flags], %%r11
            \\sysretq
            :
            : [addr] "r" (0x200000),
              [flags] "r" (0x202),
              [stack] "r" (stack_top),
        );
        unreachable;
    }
}

fn nextTask() void {
    current_pid += 1;

    while (tasks[current_pid] == null) {
        current_pid += 1;
    }

    while (current_pid >= tasks.len) {
        current_pid -= tasks.len;
    }
}
