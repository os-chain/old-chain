const std = @import("std");
const cpu = @import("cpu.zig");
const gdt = @import("gdt.zig");
const tss = @import("tss.zig");

const log = std.log.scoped(.syscall);

var core_info: cpu.CoreInfo = undefined;

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

    core_info = .{
        .kernel_stack = @intFromPtr(tss.kernel_stack.ptr),
        .user_stack = undefined,
    };

    cpu.Msr.write(.KERNEL_GS_BASE, @intFromPtr(&core_info));
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
        \\call syscallHandler
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
    log.debug("Syscall {d}", .{frame.rax});
}
