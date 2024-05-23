const std = @import("std");
const builtin = @import("builtin");
const limine = @import("limine");
const options = @import("options");
const hal = @import("hal.zig");

pub export var smp_req = limine.SmpRequest{};

const log = std.log.scoped(.smp);

var cores_buf: [options.max_cpus]hal.CoreInfo = undefined;
var core_count: usize = 0;

pub const SpinLock = struct {
    data: std.atomic.Value(u32) = .{ .raw = 0 },
    refcount: std.atomic.Value(usize) = .{ .raw = 0 },
    int_enabled: bool = false,

    pub fn lock(self: *SpinLock) void {
        _ = self.refcount.fetchAdd(1, .monotonic);

        const int_enabled = hal.interruptsEnabled();

        hal.disableInterrupts();

        while (true) {
            if (self.data.swap(1, .acquire) == 0) {
                break;
            }

            while (self.data.fetchAdd(0, .monotonic) != 0) {
                if (int_enabled) hal.enableInterrupts();
                std.atomic.spinLoopHint();
                hal.disableInterrupts();
            }
        }

        _ = self.refcount.fetchSub(1, .monotonic);
        @fence(.acquire);
        self.int_enabled = int_enabled;
    }

    pub fn unlock(self: *SpinLock) void {
        self.data.store(0, .release);
        @fence(.release);
        if (self.int_enabled) hal.enableInterrupts();
    }
};

pub fn init(comptime jmp: fn () callconv(.C) noreturn) noreturn {
    log.debug("Initializing...", .{});
    defer log.debug("Initialization done", .{});

    if (smp_req.response) |smp_res| {
        core_count = smp_res.cpu_count;
        log.debug("{d} CPUs found", .{core_count});

        if (core_count > options.max_cpus) std.debug.panic("Too many CPUs! ({d}, max is {d})", .{ core_count, options.max_cpus });

        for (smp_res.cpus(), 0..) |core, i| {
            log.debug(
                \\Waking up CPU{d} (i={d})
            , .{ core.processor_id, i });

            std.debug.assert(core.processor_id == i);

            cores_buf[0..core_count][i].id = core.processor_id;

            const wrapper = struct {
                fn f(info: *limine.SmpInfo) callconv(.C) noreturn {
                    if (!options.enable_smp) hal.halt();
                    switch (builtin.cpu.arch) {
                        .x86_64 => @import("arch/x86_64/cpu.zig").Msr.write(.KERNEL_GS_BASE, @intFromPtr(&cores_buf[0..core_count][info.processor_id])),
                        else => |other| @compileError(@tagName(other) ++ " not supported"),
                    }
                    jmp();
                }
            }.f;

            if (core.processor_id != 0) {
                @atomicStore(@TypeOf(core.goto_address), &core.goto_address, wrapper, .monotonic);
            }
        }
    } else @panic("No SMP bootloader response");

    switch (builtin.cpu.arch) {
        .x86_64 => @import("arch/x86_64/cpu.zig").Msr.write(.KERNEL_GS_BASE, @intFromPtr(&cores_buf[0])),
        .aarch64 => {},
        else => |other| @compileError(@tagName(other) ++ " not supported"),
    }
    jmp();
}

pub fn cpuid() usize {
    return if (getCoreInfoInner()) |info| info.id else 0;
}

pub fn count() usize {
    return core_count;
}

fn getCoreInfoInner() ?*hal.CoreInfo {
    return if (core_count > 0) switch (builtin.cpu.arch) {
        .x86_64 => @as(?*hal.CoreInfo, @ptrFromInt(@import("arch/x86_64/cpu.zig").Msr.read(.KERNEL_GS_BASE))),
        else => |other| @compileError(@tagName(other) ++ " not supported"),
    } else null;
}

pub fn getCoreInfo() *hal.CoreInfo {
    return getCoreInfoInner().?;
}
