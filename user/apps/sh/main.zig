const std = @import("std");
const chain = @import("chain");

comptime {
    @export(chain._start, .{ .name = "_start" });
}

pub fn main() void {
    var buf: [1]u8 = undefined;

    while (true) {
        if (chain.read(chain.stdin, &buf) != 0) {
            chain.print(&buf);
        }
    }
}
