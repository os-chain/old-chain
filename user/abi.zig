pub const Syscall = enum {
    write,
    read,
    exit,
    fork,
    execve,

    pub fn GetErrorEnum(comptime self: Syscall) ?type {
        return switch (self) {
            .write => null,
            .read => null,
            .exit => null,
            .fork => null,
            .execve => enum(u8) {
                cannot_open_file,
            },
        };
    }
};
