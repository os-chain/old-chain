const std = @import("std");
const abi = @import("abi");
const builtin = @import("builtin");
const root = @import("root");

pub fn _start() callconv(.C) void {
    root.main();
    exit(0);
}

pub const stdout = 0;
pub const stdin = 1;

fn getSyscallNum(comptime syscall: abi.Syscall) usize {
    return @intFromEnum(syscall);
}

pub fn print(buf: []const u8) void {
    std.debug.assert(write(stdout, buf) == buf.len);
}

pub fn write(fd: usize, buf: []const u8) usize {
    return arch.syscall3(getSyscallNum(.write), fd, @intFromPtr(buf.ptr), buf.len);
}

pub fn read(fd: usize, buf: []u8) usize {
    return arch.syscall3(getSyscallNum(.read), fd, @intFromPtr(buf.ptr), buf.len);
}

pub fn exit(ret: u8) noreturn {
    while (true) {}

    _ = arch.syscall1(getSyscallNum(.exit), ret);
    unreachable;
}

pub fn fork() usize {
    return arch.syscall0(getSyscallNum(.fork));
}

pub const ExecveError = error{
    CannotOpenFile,
};

pub fn execve(argv: []const []const u8) ExecveError {
    switch (@as(abi.Syscall.execve.GetErrorEnum().?, @enumFromInt(arch.syscall2(getSyscallNum(.execve), argv.len, @intFromPtr(argv.ptr))))) {
        .cannot_open_file => return error.CannotOpenFile,
    }
}

const arch = switch (builtin.cpu.arch) {
    .x86_64 => struct {
        fn syscall0(comptime n: usize) usize {
            return asm volatile ("syscall"
                : [ret] "={rax}" (-> usize),
                : [n] "{rax}" (n),
                : "memory", "rcx", "r11"
            );
        }

        fn syscall1(comptime n: usize, a1: usize) usize {
            return asm volatile ("syscall"
                : [ret] "={rax}" (-> usize),
                : [n] "{rax}" (n),
                  [a1] "{rdi}" (a1),
                : "rax", "memory", "rcx", "r11"
            );
        }

        fn syscall2(comptime n: usize, a1: usize, a2: usize) usize {
            return asm volatile ("syscall"
                : [s] "={rax}" (-> usize),
                : [n] "{rax}" (n),
                  [a1] "{rdi}" (a1),
                  [a2] "{rsi}" (a2),
                : "memory", "rcx", "r11"
            );
        }

        fn syscall3(comptime n: usize, a1: usize, a2: usize, a3: usize) usize {
            return asm volatile ("syscall"
                : [s] "={rax}" (-> usize),
                : [n] "{rax}" (n),
                  [a1] "{rdi}" (a1),
                  [a2] "{rsi}" (a2),
                  [a3] "{rdx}" (a3),
                : "memory", "rcx", "r11"
            );
        }
    },
    .aarch64 => struct {
        fn syscall0(comptime n: usize) usize {
            _ = n;
            while (true) {}
        }

        fn syscall1(comptime n: usize, a1: usize) usize {
            _ = n;
            _ = a1;
            while (true) {}
        }

        fn syscall2(comptime n: usize, a1: usize, a2: usize) usize {
            _ = n;
            _ = a1;
            _ = a2;
            while (true) {}
        }

        fn syscall3(comptime n: usize, a1: usize, a2: usize, a3: usize) usize {
            _ = n;
            _ = a1;
            _ = a2;
            _ = a3;
            while (true) {}
        }
    },
    else => |other| @compileError(@tagName(other) ++ " not implemented"),
};
