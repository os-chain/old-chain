const std = @import("std");
const builtin = @import("builtin");
const vfs = @import("fs/vfs.zig");
const hal = @import("hal.zig");
const smp = @import("smp.zig");

const log = std.log.scoped(.task);

var allocator: std.mem.Allocator = undefined;

var tasks: std.ArrayList(?Task) = undefined;

const stack_page_count = 8;

const reschedule_ticks = 0x10000;

var queue: std.fifo.LinearFifo(Pid, .Dynamic) = undefined;
var current: ?Pid = null;

pub const Pid = u64;

pub const Fd = u64;

pub const Task = struct {
    regs: hal.ContextFrame = undefined,
    page_table: *hal.PageTable,
    arena: std.heap.ArenaAllocator,
    files: std.ArrayListUnmanaged(?*vfs.Node) = .{},
    context: hal.ContextFrame,
    parent: ?Pid,
    children: std.ArrayListUnmanaged(Pid) = .{},
};

pub fn init(alloc: std.mem.Allocator) !void {
    log.debug("Initializing...", .{});
    defer log.debug("Initialization done", .{});

    allocator = alloc;

    tasks = std.ArrayList(?Task).init(allocator);
    queue = std.fifo.LinearFifo(Pid, .Dynamic).init(allocator);
}

pub fn deinit() void {
    tasks.deinit();
    queue.deinit();
}

pub fn getCurrentTask() ?Task {
    return tasks.items[getCurrentPid() orelse return null].?;
}

pub fn getCurrentPid() ?Pid {
    return current;
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
        .context = undefined,
        .parent = null,
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
    try task.files.append(arena, vfs.openPath("/dev/tty") catch null);
    std.debug.assert(task.files.items.len == 1);
    try task.files.append(arena, vfs.openPath("/dev/tty") catch null);
    std.debug.assert(task.files.items.len == 2);

    std.debug.assert(tasks.items.len == 0);
    const pid = try addTask(task);
    log.debug("Root task PID is {d}", .{pid});
    current = pid;
}

pub fn start() noreturn {
    hal.registerIrq(0, struct {
        fn f(frame: *hal.ContextFrame) void {
            reschedule(frame) catch |err| switch (err) {
                error.OutOfMemory => @panic("OOM"),
            };
            hal.oneshot(hal.intFromIrq(0), reschedule_ticks);
        }
    }.f);
    hal.oneshot(hal.intFromIrq(0), reschedule_ticks);

    if (getCurrentTask()) |task| {
        runRootTask(task);
    } else @panic("Scheduler started with no root task");
}

fn reschedule(context: *hal.ContextFrame) !void {
    if (current == null and queue.readableLength() == 0) {
        hal.oneshot(hal.intFromIrq(0), reschedule_ticks);
        while (true) {}
    } else {
        if (current != null) tasks.items[current.?].?.context = context.*;

        if (queue.readableLength() > 0 and current != null) {
            try queue.writeItem(current.?);
            current = null;
        }

        nextTask();

        context.* = getCurrentTask().?.context;
        hal.setPageTableAddr(hal.physFromVirt(hal.getActivePageTable(), @intFromPtr(getCurrentTask().?.page_table)).?);
    }
}

fn nextTask() void {
    const maybe_next_pid = queue.readItem();

    const next_pid = maybe_next_pid orelse return;

    current = next_pid;
}

fn deleteTask(pid: Pid) void {
    tasks.items[pid] = null;

    if (current == pid) current = null;
    for (queue.readableSlice(0), 0..) |queued_task, i| {
        if (queued_task == pid) {
            for (0..i) |_| {
                queue.writeItem(queue.readItem().?) catch unreachable;
            }

            _ = queue.readItem().?;
        }
    }
}

fn killTask(pid: Pid) void {
    for (tasks.items[pid].?.children.items) |child| {
        killTask(child);
    }

    deleteTask(pid);
}

pub fn exit(context: *hal.ContextFrame) void {
    const pid = getCurrentPid().?;

    killTask(pid);

    reschedule(context) catch |err| switch (err) {
        error.OutOfMemory => @panic("OOM"),
    };
}

pub fn fork(context: *hal.ContextFrame) Pid {
    var child = Task{
        .arena = std.heap.ArenaAllocator.init(allocator),
        .page_table = undefined,
        .context = context.*,
        .parent = undefined,
    };

    child.context.rax = 0;

    const child_arena = child.arena.allocator();

    child.page_table = hal.dupePageTable(child_arena, getCurrentTask().?.page_table) catch |err| switch (err) {
        error.OutOfMemory => @panic("OOM"),
    };

    const stack_frames = child_arena.allocWithOptions(u8, stack_page_count * 0x1000, 0x1000, null) catch |err| switch (err) {
        error.OutOfMemory => @panic("OOM"),
    };

    for (0..stack_page_count) |i| {
        hal.mapPage(
            child_arena,
            child.page_table,
            0x10200000 + 0x1000 * i,
            hal.physFromVirt(child.page_table, @intFromPtr(stack_frames.ptr)).? + 0x1000 * i,
            .{
                .writable = true,
                .executable = false,
                .user = true,
                .global = false,
            },
        ) catch |err| switch (err) {
            error.OutOfMemory => @panic("OOM"),
        };

        const child_stack_page: *[0x1000]u8 = @ptrFromInt(hal.virtFromPhys(hal.physFromVirt(child.page_table, 0x10200000 + 0x1000 * i).?));
        const parent_stack_page: *[0x1000]u8 = @ptrFromInt(hal.virtFromPhys(hal.physFromVirt(getCurrentTask().?.page_table, 0x10200000 + 0x1000 * i).?));
        log.debug("Copying stack page from 0x{x} to 0x{x} because of a fork", .{ @intFromPtr(parent_stack_page.ptr), @intFromPtr(child_stack_page) });
        @memcpy(child_stack_page, parent_stack_page);
    }

    std.debug.assert(child.files.items.len == 0);
    child.files.append(child_arena, vfs.openPath("/dev/tty") catch null) catch |err| switch (err) {
        error.OutOfMemory => @panic("OOM"),
    };
    std.debug.assert(child.files.items.len == 1);
    child.files.append(child_arena, vfs.openPath("/dev/tty") catch null) catch |err| switch (err) {
        error.OutOfMemory => @panic("OOM"),
    };
    std.debug.assert(child.files.items.len == 2);

    const pid = addTask(child) catch |err| switch (err) {
        error.OutOfMemory => @panic("OOM"),
    };

    tasks.items[getCurrentPid().?].?.children.append(tasks.items[getCurrentPid().?].?.arena.allocator(), pid) catch |err| switch (err) {
        error.OutOfMemory => @panic("OOM"),
    };
    child.parent = getCurrentPid().?;

    queue.writeItem(pid) catch |err| switch (err) {
        error.OutOfMemory => @panic("OOM"),
    };

    return pid;
}

fn runRootTask(task: Task) noreturn {
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
                  [stack_rsp] "{rsp}" (stack_top),
                  [stack_rbp] "{rbp}" (stack_top),
                : "memory"
            ),
            else => |other| @compileError(@tagName(other) ++ " not supported"),
        }
        unreachable;
    }
}
