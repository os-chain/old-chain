const std = @import("std");
const chain = @import("chain");

comptime {
    @export(chain._start, .{ .name = "_start" });
}

pub fn main() void {
    while (true) {
        var read_buf: [1]u8 = undefined;
        var input_buf: [256]u8 = undefined;
        var input_len: usize = 0;

        chain.print("> ");

        const input = read: while (true) {
            if (chain.read(chain.stdin, &read_buf) != 0 and input_len < input_buf.len) {
                for (read_buf) |char| {
                    if (char == '\n') {
                        chain.print("\n");
                        break :read input_buf[0..input_len];
                    } else if (char == '\x08') {
                        if (input_len > 0) {
                            input_len -= 1;
                            chain.print("\x08");
                        }
                    } else {
                        chain.print(&.{char});
                        input_buf[input_len] = char;
                        input_len += 1;
                    }
                }
            }
        };

        if (input.len > 0) {
            if (input.len == 1 and input[0] == 'q') {
                chain.exit(0);
            } else {
                chain.print("Unknown command: ");
                chain.print(input);
                chain.print("\n");
            }
        }
    }
}
