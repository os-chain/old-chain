const std = @import("std");
const cpu = @import("cpu.zig");
const gdt = @import("gdt.zig");
const lapic = @import("lapic.zig");
const task = @import("../../task.zig");

const log = std.log.scoped(.int);

pub const Idt = [256]IdtEntry;

pub const IdtEntry = packed struct(u128) {
    offset_low: u16,
    segment: u16,
    ist: u3,
    rsv_a: u5 = 0,
    type: Type,
    rsv_b: u1 = 0,
    ring: u2,
    present: bool,
    offset_high: u48,
    rsv_c: u32 = undefined,

    pub const Type = enum(u4) {
        tss_available = 0b1001,
        tss_busy = 0b1011,
        call = 0b1100,
        interrupt = 0b1110,
        trap = 0b1111,
    };

    pub inline fn getOffset(self: IdtEntry) u64 {
        return (@as(u64, self.offset_high) << 16) | self.offset_low;
    }

    pub inline fn setOffset(self: *IdtEntry, offset: u64) void {
        self.offset_low = @truncate(offset);
        self.offset_high = @truncate(offset >> 16);
    }

    test "getOffset() and setOffset()" {
        var entry: IdtEntry = undefined;
        entry.setOffset(0);
        try std.testing.expectEqual(@as(u16, 0), entry.offset_low);
        try std.testing.expectEqual(@as(u48, 0), entry.offset_high);
        try std.testing.expectEqual(@as(u64, 0), entry.getOffset());

        entry.setOffset(0xFFFFFFFFFFFFFFFF);
        try std.testing.expectEqual(@as(u16, 0xFFFF), entry.offset_low);
        try std.testing.expectEqual(@as(u48, 0xFFFFFFFFFFFF), entry.offset_high);
        try std.testing.expectEqual(@as(u64, 0xFFFFFFFFFFFFFFFF), entry.getOffset());

        entry.setOffset(0xDEADBEEFDEADBEEF);
        try std.testing.expectEqual(@as(u16, 0xBEEF), entry.offset_low);
        try std.testing.expectEqual(@as(u48, 0xDEADBEEFDEAD), entry.offset_high);
        try std.testing.expectEqual(@as(u64, 0xDEADBEEFDEADBEEF), entry.getOffset());

        entry.setOffset(0xFEDCBA9876543210);
        try std.testing.expectEqual(@as(u16, 0x3210), entry.offset_low);
        try std.testing.expectEqual(@as(u48, 0xFEDCBA987654), entry.offset_high);
        try std.testing.expectEqual(@as(u64, 0xFEDCBA9876543210), entry.getOffset());
    }
};

pub const Idtd = packed struct(u80) {
    limit: u16,
    base: *const Idt,
};

pub const Exception = enum(u8) {
    DE = 0,
    DB = 1,
    BP = 3,
    OF = 4,
    BR = 5,
    UD = 6,
    NM = 7,
    DF = 8,
    TS = 10,
    NP = 11,
    SS = 12,
    GP = 13,
    PF = 14,
    MF = 16,
    AC = 17,
    MC = 18,
    XM = 19,
    VE = 20,
    CP = 21,

    pub inline fn getMnemonic(self: Exception) []const u8 {
        return switch (self) {
            inline else => |e| "#" ++ @tagName(e),
        };
    }

    pub inline fn getDescription(self: Exception) []const u8 {
        // From Intel 64 and IA-32 Architectures Software Developer's Manual
        return switch (self) {
            .DE => "Divide Error",
            .DB => "Debug Exception",
            .BP => "Breakpoint",
            .OF => "Overflow",
            .BR => "BOUND Range Exceeded",
            .UD => "Invalid Opcode",
            .NM => "No Math Coprocessor",
            .DF => "Double Fault",
            .TS => "Invalid TSS",
            .NP => "Segment Not Present",
            .SS => "Stack-Segment Fault",
            .GP => "General Protection",
            .PF => "Page Fault",
            .MF => "Math Fault",
            .AC => "Alignment Check",
            .MC => "Machine Check",
            .XM => "SIMD Floating-Point Exception",
            .VE => "Virtualization Exception",
            .CP => "Control Protection Exception",
        };
    }

    pub inline fn hasErrorCode(self: Exception) bool {
        return switch (self) {
            .DE, .DB, .BP, .OF, .BR, .UD, .NM, .MF, .MC, .XM, .VE => false,
            .DF, .TS, .NP, .SS, .GP, .PF, .AC, .CP => true,
        };
    }
};

var idtd: Idtd = .{
    .limit = @sizeOf(Idt) - 1,
    .base = undefined,
};

export var idt: Idt = [1]IdtEntry{.{
    .offset_low = 0,
    .offset_high = 0,
    .segment = 0,
    .ist = 0,
    .type = .trap,
    .ring = 0,
    .present = false,
}} ** 256;

var irqs: [16]?*const fn (frame: *cpu.ContextFrame) void = .{null} ** 16;

pub fn init() void {
    log.debug("Initializing", .{});
    defer log.debug("Initialization done", .{});

    idtd.base = &idt;

    inline for (0..256) |i_raw| {
        const i: u8 = @truncate(i_raw);
        idt[i] = .{
            .segment = gdt.selectors.kcode_64,
            .ist = 1,
            .type = switch (i) {
                0...31 => .trap,
                32...255 => .interrupt,
            },
            .ring = 3,
            .present = true,

            .offset_low = undefined,
            .offset_high = undefined,
        };
        idt[i].setOffset(@intFromPtr(getVector(i)));
    }

    log.debug("Loading IDTD...", .{});
    cpu.lidt(&idtd);
    log.debug("IDTD loaded", .{});

    log.debug("Enabling interrupts...", .{});
    cpu.sti();
    log.debug("Interrupts enabled", .{});
}

fn getVector(comptime i: u8) *const fn () callconv(.Naked) void {
    return struct {
        fn f() callconv(.Naked) void {
            switch (i) {
                inline 0, 1, 3...8, 10...14, 16...21 => |exception_i| {
                    const exception: Exception = comptime @enumFromInt(exception_i);
                    asm volatile (if (!exception.hasErrorCode()) "push $0\n" else "" ++
                            \\push %[i]
                            \\jmp interruptCommon
                        :
                        : [i] "i" (i),
                    );
                },
                inline else => {
                    asm volatile (
                        \\push $0
                        \\push %[i]
                        \\jmp interruptCommon
                        :
                        : [i] "i" (i),
                    );
                },
            }
        }
    }.f;
}

export fn interruptCommon() callconv(.Naked) void {
    asm volatile (
        \\push %%rax
        \\push %%rbx
        \\push %%rcx
        \\push %%rdx
        \\push %%rbp
        \\push %%rsi
        \\push %%rdi
        \\push %%r8
        \\push %%r9
        \\push %%r10
        \\push %%r11
        \\push %%r12
        \\push %%r13
        \\push %%r14
        \\push %%r15
        \\mov %%ds, %%rax
        \\push %%rax
        \\mov %%es, %%rax
        \\push %%rax
        \\mov %%rsp, %%rdi
        \\mov %[kdata], %%ax
        \\mov %%ax, %%es
        \\mov %%ax, %%ds
        \\call interruptHandler
        \\pop %%rax
        \\mov %%rax, %%es
        \\pop %%rax
        \\mov %%rax, %%ds
        \\pop %%r15
        \\pop %%r14
        \\pop %%r13
        \\pop %%r12
        \\pop %%r11
        \\pop %%r10
        \\pop %%r9
        \\pop %%r8
        \\pop %%rdi
        \\pop %%rsi
        \\pop %%rbp
        \\pop %%rdx
        \\pop %%rcx
        \\pop %%rbx
        \\pop %%rax
        \\add $16, %%rsp
        \\iretq
        :
        : [kdata] "i" (gdt.selectors.kdata_64),
    );
}

export fn interruptHandler(frame: *cpu.ContextFrame) void {
    frame.int_num &= 0xFF;

    switch (frame.int_num) {
        inline 0, 1, 3...8, 10...14, 16...21 => |exception_i| {
            const exception: Exception = @enumFromInt(exception_i);

            cpu.cli();

            log.err(
                \\Exception: {s} ({s})
                \\v={x:0>2} err={x}
                \\rax={x:0>16} rbx={x:0>16} rcx={x:0>16} rdx={x:0>16}
                \\rip={x:0>16} rsp={x:0>16} rbp={x:0>16}
                \\cr2={x:0>16} cr3={x:0>16}
                \\pid={?x}
            , .{ exception.getMnemonic(), exception.getDescription(), frame.int_num, frame.err, frame.rax, frame.rbx, frame.rcx, frame.rdx, frame.rip, frame.rsp, frame.rbp, cpu.Cr2.read(), cpu.Cr3.read(), task.getCurrentPid() });

            cpu.halt();
        },
        32...48 => |int_i| {
            const irq_i = int_i - 32;
            if (irqs[irq_i]) |irq| {
                irq(frame);
                lapic.getLapic().writeRegister(.eoi, 0);
            } else log.warn("IRQ{d} called without a handler registered", .{irq_i});
        },
        else => |i| {
            log.debug("Unhandled interrupt {d}", .{i});
        },
    }
}

pub fn intFromIrq(irq: u4) u8 {
    return @as(u8, irq) + 32;
}

pub fn registerIrq(irq: u4, handler: *const fn (frame: *cpu.ContextFrame) void) void {
    irqs[irq] = handler;
}
