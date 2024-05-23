const std = @import("std");
const root = @import("root");

fn _start() callconv(.C) noreturn {
    root.start();

    while (true) {}
}

pub fn initCpuBarebones() void {}
