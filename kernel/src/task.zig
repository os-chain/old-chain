const std = @import("std");
const builtin = @import("builtin");
const vfs = @import("fs/vfs.zig");
const hal = @import("hal.zig");
const smp = @import("smp.zig");

const log = std.log.scoped(.task);

var allocator: std.mem.Allocator = undefined;

var tasks: std.ArrayList(?Task) = undefined;

const stack_page_count = 0x10;

const reschedule_ticks = 0x10000;

var queue: std.fifo.LinearFifo(Pid, .Dynamic) = undefined;
var current: ?Pid = null;

pub const Pid = u64;

pub const Fd = u64;

pub const Task = struct {
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

    // TODO: Use a stream
    const file_data = try arena.alloc(u8, node.length);
    std.debug.assert(node.read(0, file_data) == file_data.len);

    try loadTask(&task, file_data);

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
    log.debug("Starting scheduler...", .{});
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
    log.debug("Rescheduling from PID={?d}", .{getCurrentPid()});

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

    log.debug("Returning from reschedule to PID={?d}", .{getCurrentPid()});
}

fn nextTask() void {
    const maybe_next_pid = queue.readItem();

    const next_pid = maybe_next_pid orelse return;

    current = next_pid;
}

fn deleteTask(pid: Pid) void {
    tasks.items[pid].?.arena.deinit();

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

    for (tasks.items[pid].?.files.items) |fd| {
        if (fd) |file| file.close();
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
            0x100200000 + 0x1000 * i,
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

        const child_stack_page: *[0x1000]u8 = @ptrFromInt(hal.virtFromPhys(hal.physFromVirt(child.page_table, 0x100200000 + 0x1000 * i).?));
        const parent_stack_page: *[0x1000]u8 = @ptrFromInt(hal.virtFromPhys(hal.physFromVirt(getCurrentTask().?.page_table, 0x100200000 + 0x1000 * i).?));
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

pub fn execve(context: *hal.ContextFrame, argv: []const []const u8) !void {
    const task = &(tasks.items[getCurrentPid().?].?);

    const arena = task.arena.allocator();

    const node = vfs.openPath(argv[0]) catch return error.CannotOpenFile;
    defer node.close();

    // TODO: Use a stream
    const file_data = arena.alloc(u8, node.length) catch |err| switch (err) {
        error.OutOfMemory => @panic("OOM"),
    };
    std.debug.assert(node.read(0, file_data) == file_data.len);

    loadTask(task, file_data) catch |err| switch (err) {
        error.OutOfMemory => @panic("OOM"),
        error.BadElf => return,
    };

    context.* = task.context;
}

fn runRootTask(task: Task) noreturn {
    const page_table_addr = hal.physFromVirt(hal.getActivePageTable(), @intFromPtr(task.page_table)).?;
    std.debug.assert(page_table_addr % 0x1000 == 0);
    std.debug.assert(hal.pageIsValid(task.page_table));

    hal.setPageTableAddr(page_table_addr);

    {
        switch (builtin.cpu.arch) {
            .x86_64 => asm volatile (
                \\sysretq
                :
                : [addr] "{rcx}" (task.context.rcx),
                  [flags] "{r11}" (0x202),
                  [stack_rsp] "{rsp}" (task.context.rsp),
                : "memory"
            ),
            else => |other| @compileError(@tagName(other) ++ " not supported"),
        }
        unreachable;
    }
}

fn loadTask(task: *Task, exe: []const u8) !void {
    const arena = task.arena.allocator();

    var fbs = std.io.fixedBufferStream(exe);
    const reader = fbs.reader();

    const ehdr = reader.readStruct(std.elf.Elf64_Ehdr) catch return error.BadElf;

    if (!std.mem.eql(u8, ehdr.e_ident[0..4], std.elf.MAGIC)) return error.BadElf;
    if (ehdr.e_ident[std.elf.EI_CLASS] != std.elf.ELFCLASS64) return error.BadElf;
    if (ehdr.e_ident[std.elf.EI_DATA] != std.elf.ELFDATA2LSB) return error.BadElf;
    if (ehdr.e_ident[std.elf.EI_VERSION] != 1) return error.BadElf;
    if (ehdr.e_type != .EXEC) return error.BadElf;
    if (ehdr.e_machine != builtin.cpu.arch.toElfMachine()) return error.BadElf;
    if (ehdr.e_version != 1) return error.BadElf;

    log.debug("entry=0x{x}", .{ehdr.e_entry});

    fbs.pos = ehdr.e_phoff;
    for (0..ehdr.e_phnum) |_| {
        const phdr = reader.readStruct(std.elf.Elf64_Phdr) catch return error.BadElf;
        switch (phdr.p_type) {
            std.elf.PT_NULL => {},
            std.elf.PT_LOAD => {
                if (phdr.p_filesz != phdr.p_memsz) return error.BadElf;
                const page_count = std.math.divCeil(usize, phdr.p_filesz, 0x1000) catch unreachable;
                const frames = try arena.allocWithOptions(u8, page_count * 0x1000, 0x1000, null);
                const data = exe[phdr.p_offset .. phdr.p_offset + phdr.p_filesz];
                @memcpy(frames[0..phdr.p_filesz], data);

                for (0..page_count) |page_i| {
                    try hal.mapPage(
                        arena,
                        task.page_table,
                        phdr.p_vaddr + 0x1000 * page_i,
                        hal.physFromVirt(task.page_table, @intFromPtr(frames.ptr)).? + 0x1000 * page_i,
                        .{
                            .writable = (phdr.p_flags & std.elf.PF_W) != 0,
                            .executable = (phdr.p_flags & std.elf.PF_X) != 0,
                            .user = true,
                            .global = false,
                        },
                    );
                }
            },
            else => return error.BadElf,
        }
    }

    const stack_frames = try arena.allocWithOptions(u8, stack_page_count * 0x1000, 0x1000, null);

    for (0..stack_page_count) |page_i| {
        try hal.mapPage(
            arena,
            task.page_table,
            0x100200000 + 0x1000 * page_i,
            hal.physFromVirt(task.page_table, @intFromPtr(stack_frames.ptr)).? + 0x1000 * page_i,
            .{
                .writable = true,
                .executable = false,
                .user = true,
                .global = false,
            },
        );
    }

    const stack_top = 0x100200000 + 0x1000 * stack_page_count;

    task.context.rcx = ehdr.e_entry;
    task.context.rsp = stack_top;
}
