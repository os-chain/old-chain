const std = @import("std");
const options = @import("options");
const root = @import("root");

pub fn _start() callconv(.C) void {
    root.main();
    exit(0);
}

fn getSyscallNum(comptime name: []const u8) usize {
    for (options.syscalls, 0..) |syscall, i| {
        if (std.mem.eql(u8, syscall, name)) return i;
    }
    unreachable;
}

pub fn print(buf: []const u8) void {
    std.debug.assert(write(0, buf) == buf.len);
}

pub fn write(fd: usize, buf: []const u8) usize {
    return syscall3(getSyscallNum("write"), fd, @intFromPtr(buf.ptr), buf.len);
}

pub fn exit(ret: u8) noreturn {
    _ = syscall1(getSyscallNum("exit"), ret);
    unreachable;
}

pub fn fork() usize {
    return syscall0(getSyscallNum("fork"));
}

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
