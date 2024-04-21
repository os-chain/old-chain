const std = @import("std");

export fn _start() callconv(.C) void {
    print("Hello from \x1b[94m\x1b[4muserspace\x1b[0m!\n");
    while (true) {}
}

pub fn print(buf: []const u8) void {
    std.debug.assert(asm volatile ("syscall"
        : [s] "={rax}" (-> usize),
        : [n] "{rax}" (0),
          [fd] "{rdi}" (0),
          [buf_ptr] "{rsi}" (buf.ptr),
          [buf_len] "{rdx}" (buf.len),
    ) == buf.len);
}
