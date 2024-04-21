const std = @import("std");
const cpu = @import("cpu.zig");
const gdt = @import("gdt.zig");
const tss = @import("tss.zig");
const smp = @import("../../smp.zig");
const task = @import("../../task.zig");

const log = std.log.scoped(.syscall);

var core_info: cpu.CoreInfo = undefined;

const syscalls = &.{
    write,
};

pub fn write(_fd: u64, _buf_ptr: u64, _buf_len: u64) u64 {
    const fd: task.Fd = _fd;
    if (_buf_ptr == 0) return 0; // TODO: Signal this
    const buf_ptr: [*]const u8 = @ptrFromInt(_buf_ptr);
    const buf_len: usize = _buf_len;
    const buf = buf_ptr[0..buf_len];

    const t = task.getCurrentTask();

    if (fd >= t.files.items.len or t.files.items[fd] == null) return 0; // TODO: Signal this
    const stdout = t.files.items[fd].?;

    return stdout.write(0, buf);
}

pub fn init() void {
    log.debug("Initializing...", .{});
    defer log.debug("Initialization done", .{});

    comptime {
        std.debug.assert(gdt.selectors.kdata_64 == gdt.selectors.kcode_64 + 8);
        std.debug.assert(gdt.selectors.ucode_64 == gdt.selectors.udata_64 + 8);
    }

    cpu.Msr.write(.STAR, (gdt.selectors.ucode_64 << 32) | ((gdt.selectors.udata_64 - 8) << 48));
    cpu.Msr.write(.LSTAR, @intFromPtr(&syscallEntry));
    cpu.Msr.write(.EFER, cpu.Msr.read(.EFER) | 1);
    cpu.Msr.write(.SF_MASK, 0b1111110111111111010101);

    smp.getCoreInfo().kernel_stack = @intFromPtr(tss.kernel_stack.ptr);
}

fn syscallEntry() callconv(.Naked) void {
    asm volatile (
        \\swapgs
        \\movq %%rsp, %%gs:8
        \\movq %%gs:0, %%rsp
        \\
        \\push %%rax
        \\push %%rbx
        \\push %%rcx
        \\push %%rdx
        \\push %%rbp
        \\push %%rsi
        \\push %%rdi
        \\push %%r8
        \\push %%r9
        \\push %%r10
        \\push %%r11
        \\push %%r12
        \\push %%r13
        \\push %%r14
        \\push %%r15
        \\cld
        \\
        \\mov %%ds, %%rax
        \\push %%rax
        \\mov %%es, %%rax
        \\push %%rax
        \\
        \\mov %%rsp, %%rdi
        \\mov %[kdata], %%ax
        \\mov %%ax, %%es
        \\mov %%ax, %%ds
        \\swapgs
        \\call syscallHandler
        \\swapgs
        \\
        \\pop %%rax
        \\mov %%rax, %%es
        \\pop %%rax
        \\mov %%rax, %%ds
        \\
        \\pop %%r15
        \\pop %%r14
        \\pop %%r13
        \\pop %%r12
        \\pop %%r11
        \\pop %%r10
        \\pop %%r9
        \\pop %%r8
        \\pop %%rdi
        \\pop %%rsi
        \\pop %%rbp
        \\pop %%rdx
        \\pop %%rcx
        \\pop %%rbx
        \\pop %%rax
        \\
        \\movq %%gs:8, %%rsp
        \\swapgs
        \\sysretq
        :
        : [kdata] "i" (gdt.selectors.kdata_64),
    );
}

export fn syscallHandler(frame: *cpu.ContextFrame) void {
    log.debug(
        "Syscall {x} (rdi=0x{x}, rsi=0x{x}, rdx=0x{x}, r10=0x{x}, r8=0x{x}, r9=0x{x})",
        .{ frame.rax, frame.rdi, frame.rsi, frame.rdx, frame.r10, frame.r8, frame.r9 },
    );

    switch (frame.rax) {
        inline 0...syscalls.len - 1 => |n| {
            const func = syscalls[n];

            const argc = @typeInfo(@TypeOf(func)).Fn.params.len;

            frame.rax = switch (argc) {
                0 => func(),
                1 => func(frame.rdi),
                2 => func(frame.rdi, frame.rsi),
                3 => func(frame.rdi, frame.rsi, frame.rdx),
                4 => func(frame.rdi, frame.rsi, frame.rdx, frame.r10),
                5 => func(frame.rdi, frame.rsi, frame.rdx, frame.r10, frame.r8),
                6 => func(frame.rdi, frame.rsi, frame.rdx, frame.r10, frame.r8, frame.r9),
                else => unreachable,
            };
        },
        else => log.debug("Unknown syscall {d}", .{frame.rax}),
    }

    log.debug("Returning from syscall with rax=0x{x}", .{frame.rax});
}
