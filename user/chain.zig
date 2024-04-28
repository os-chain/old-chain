const std = @import("std");
const root = @import("root");

pub fn _start() callconv(.C) void {
    root.main();
    exit(0);
}

pub fn print(buf: []const u8) void {
    std.debug.assert(asm volatile ("syscall"
        : [s] "={rax}" (-> usize),
        : [n] "{rax}" (0),
          [fd] "{rdi}" (0),
          [buf_ptr] "{rsi}" (buf.ptr),
          [buf_len] "{rdx}" (buf.len),
        : "memory", "rcx", "r11"
    ) == buf.len);
}

pub fn exit(ret: u8) noreturn {
    asm volatile ("syscall"
        :
        : [n] "{rax}" (1),
          [ret] "{rdi}" (ret),
        : "rax", "memory", "rcx", "r11"
    );
    unreachable;
}

pub fn fork() usize {
    return asm volatile ("syscall"
        : [ret] "={rax}" (-> usize),
        : [n] "{rax}" (2),
        : "memory", "rcx", "r11"
    );
}
