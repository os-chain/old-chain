const int = @import("int.zig");
const gdt = @import("gdt.zig");

pub inline fn halt() noreturn {
    while (true) hlt();
}

pub inline fn hlt() void {
    asm volatile ("hlt");
}

pub inline fn cli() void {
    asm volatile ("cli");
}

pub inline fn sti() void {
    asm volatile ("sti");
}

pub inline fn inb(port: u16) u8 {
    return asm volatile ("inb %[port], %[result]"
        : [result] "={al}" (-> u8),
        : [port] "N{dx}" (port),
    );
}

pub inline fn inw(port: u16) u16 {
    return asm volatile ("inw %[port], %[result]"
        : [result] "={ax}" (-> u16),
        : [port] "N{dx}" (port),
    );
}

pub inline fn outb(port: u16, data: u8) void {
    asm volatile ("outb %[data], %[port]"
        :
        : [data] "{al}" (data),
          [port] "N{dx}" (port),
    );
}

pub inline fn outw(port: u16, data: u16) void {
    asm volatile ("outw %[data], %[port]"
        :
        : [data] "{ax}" (data),
          [port] "N{dx}" (port),
    );
}

pub inline fn lidt(idtd: *const int.Idtd) void {
    asm volatile ("lidt (%%rax)"
        :
        : [idtd] "{rax}" (idtd),
    );
}

pub inline fn lgdt(gdtd: *const gdt.Gdtd) void {
    asm volatile ("lgdt (%%rax)"
        :
        : [gdtd] "{rax}" (gdtd),
    );
}

pub const CpuidResult = struct {
    rax: u64,
    rbx: u64,
    rcx: u64,
    rdx: u64,
};

pub inline fn cpuid(rax_in: u64) CpuidResult {
    var rax_out: u64 = undefined;
    var rbx_out: u64 = undefined;
    var rcx_out: u64 = undefined;
    var rdx_out: u64 = undefined;

    asm volatile ("cpuid"
        : [rax_out] "=%[rax]" (rax_out),
          [rbx_out] "=%[rbx]" (rbx_out),
          [rcx_out] "=%[rcx]" (rcx_out),
          [rdx_out] "=%[rdx]" (rdx_out),
        : [rax_in] "{rax}" (rax_in),
    );

    return .{
        .rax = rax_out,
        .rbx = rbx_out,
        .rcx = rcx_out,
        .rdx = rdx_out,
    };
}
