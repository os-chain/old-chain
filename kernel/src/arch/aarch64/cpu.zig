pub fn halt() noreturn {
    while (true) {
        wfi();
    }
}

pub fn wfi() void {
    asm volatile ("wfi");
}

pub fn daifclr() void {
    asm volatile ("msr daifclr, #3" ::: "memory");
}

pub fn daifset() void {
    asm volatile ("msr daifset, #3" ::: "memory");
}

pub const CoreInfo = packed struct {
    kernel_stack: u64,
    user_stack: u64,
    id: u64,
};
