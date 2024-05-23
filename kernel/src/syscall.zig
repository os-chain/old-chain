const std = @import("std");
const abi = @import("abi");
const hal = @import("hal.zig");
const task = @import("task.zig");

pub fn getFunction(comptime syscall: abi.Syscall) @TypeOf(@field(funcs, @tagName(syscall))) {
    return @field(funcs, @tagName(syscall));
}

const funcs = struct {
    fn write(_: *hal.ContextFrame, _fd: u64, _buf_ptr: u64, _buf_len: u64) u64 {
        const fd: task.Fd = _fd;
        const buf_ptr: [*]const u8 = @ptrFromInt(_buf_ptr);
        const buf_len: usize = _buf_len;
        const buf = buf_ptr[0..buf_len];

        const t = task.getCurrentTask().?;

        if (fd >= t.files.items.len or t.files.items[fd] == null) return 0; // TODO: Signal this
        const stdout = t.files.items[fd].?;

        return stdout.write(0, buf);
    }

    fn read(_: *hal.ContextFrame, _fd: u64, _buf_ptr: u64, _buf_len: u64) u64 {
        const fd: task.Fd = _fd;
        const buf_ptr: [*]u8 = @ptrFromInt(_buf_ptr);
        const buf_len: usize = _buf_len;
        const buf = buf_ptr[0..buf_len];

        const t = task.getCurrentTask().?;

        if (fd >= t.files.items.len or t.files.items[fd] == null) return 0; // TODO: Signal this
        const stdout = t.files.items[fd].?;

        return stdout.read(0, buf);
    }

    fn exit(frame: *hal.ContextFrame, _code: u64) void {
        const code: u8 = @truncate(_code);
        _ = code;
        // TODO: Return code

        task.exit(frame);
    }

    fn fork(frame: *hal.ContextFrame) u64 {
        return task.fork(frame);
    }

    fn execve(frame: *hal.ContextFrame, _argc: usize, _argv: usize) abi.Syscall.execve.GetErrorEnum().? {
        const argv = @as([*]const []const u8, @ptrFromInt(_argv))[0.._argc];
        task.execve(frame, argv) catch |err| switch (err) {
            error.CannotOpenFile => return .cannot_open_file,
        };

        return @enumFromInt(0);
    }
};
