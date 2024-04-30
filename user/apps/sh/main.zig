const std = @import("std");
const chain = @import("chain");

comptime {
    @export(chain._start, .{ .name = "_start" });
}

pub fn main() void {
    chain.print("SH");

    while (true) {}
}
