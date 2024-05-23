const std = @import("std");
const abi = @import("abi");
const cpu = @import("cpu.zig");
const gdt = @import("gdt.zig");
const tss = @import("tss.zig");
const smp = @import("../../smp.zig");
const task = @import("../../task.zig");
const root_syscall = @import("../../syscall.zig");

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

    smp.getCoreInfo().kernel_stack = @intFromPtr(tss.kernel_stack.ptr);
}

fn syscallEntry() callconv(.Naked) void {
    asm volatile (
        \\cli
        \\swapgs
        \\movq %%rsp, %%gs:8
        \\movq %%gs:0, %%rsp
        \\
        \\pushq %[udata]
        \\pushq %%gs:8
        \\pushq %r11
        \\pushq %[ucode]
        \\pushq %%rcx
        \\pushq $0
        \\pushq $0
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
        \\xor %%rbp, %%rbp
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
        \\add $16, %%rsp
        \\
        \\movq %%gs:8, %%rsp
        \\swapgs
        \\sti
        \\sysretq
        :
        : [kdata] "i" (gdt.selectors.kdata_64),
          [udata] "i" (gdt.selectors.udata_64),
          [ucode] "i" (gdt.selectors.ucode_64),
    );
}

export fn syscallHandler(frame: *cpu.ContextFrame) void {
    log.debug(
        "Syscall {x} (rdi=0x{x}, rsi=0x{x}, rdx=0x{x}, r10=0x{x}, r8=0x{x}, r9=0x{x})",
        .{ frame.rax, frame.rdi, frame.rsi, frame.rdx, frame.r10, frame.r8, frame.r9 },
    );

    switch (frame.rax) {
        inline 0...std.meta.fields(abi.Syscall).len - 1 => |n| {
            const syscall: abi.Syscall = @enumFromInt(n);
            const func = root_syscall.getFunction(syscall);
            const argc = @typeInfo(@TypeOf(func)).Fn.params.len - 1;

            const ret = switch (argc) {
                0 => func(frame),
                1 => func(frame, frame.rdi),
                2 => func(frame, frame.rdi, frame.rsi),
                3 => func(frame, frame.rdi, frame.rsi, frame.rdx),
                4 => func(frame, frame.rdi, frame.rsi, frame.rdx, frame.r10),
                5 => func(frame, frame.rdi, frame.rsi, frame.rdx, frame.r10, frame.r8),
                6 => func(frame, frame.rdi, frame.rsi, frame.rdx, frame.r10, frame.r8, frame.r9),
                else => unreachable,
            };

            switch (@TypeOf(ret)) {
                u64, u8 => frame.rax = ret,
                void => frame.rax = 0,
                inline else => |other| {
                    if (other == syscall.GetErrorEnum()) {
                        frame.rax = @intFromEnum(ret);
                    } else @compileError(std.fmt.comptimePrint("Syscall {d} has a return type of {}", .{ n, other }));
                },
            }
        },
        else => log.debug("Unknown syscall {d}", .{frame.rax}),
    }

    log.debug("Returning from syscall with rax=0x{x}", .{frame.rax});
}
