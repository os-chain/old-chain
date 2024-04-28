const std = @import("std");
const chain = @import("chain");

comptime {
    @export(chain._start, .{ .name = "_start" });
}

pub fn main() void {
    chain.print("Hello from \x1b[94m\x1b[4muserspace\x1b[0m!\n");

    const child = chain.fork();

    while (true) {
        if (child == 0) {
            chain.print("A");
        } else {
            chain.print("B");
        }
    }
}
