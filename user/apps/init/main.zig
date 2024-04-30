const std = @import("std");
const chain = @import("chain");

comptime {
    @export(chain._start, .{ .name = "_start" });
}

fn runCmd(argv: []const []const u8) void {
    const child = chain.fork();

    if (child == 0) {
        chain.execve(argv);
        chain.print("execve() failed\n");
    }
}

pub fn main() void {
    chain.print("Hello from \x1b[94m\x1b[4muserspace\x1b[0m!\n");

    runCmd(&.{"/bin/sh"});

    while (true) {}
}
