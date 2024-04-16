const std = @import("std");

export fn _start() callconv(.Naked) void {
    asm volatile ("syscall"
        :
        : [n] "rax" (1),
    );
    asm volatile ("syscall"
        :
        : [n] "rax" (2),
    );
    asm volatile ("syscall"
        :
        : [n] "rax" (3),
    );
    while (true) {}
}
