const std = @import("std");
const limine = @import("limine");
const hal = @import("hal.zig");

pub export var rsdp_req = limine.RsdpRequest{};

const log = std.log.scoped(.acpi);

pub var root_sdt: *Rsdt = undefined;
pub var fadt: ?*Fadt = null;
pub var dsdt: ?*Dsdt = null;
pub var madt: ?*Madt = null;

pub const Rsdp = extern struct {
    signature: [8]u8 align(1),
    checksum: u8 align(1),
    oemid: [6]u8 align(1),
    revision: u8 align(1),
    rsdt_addr: u32 align(1),
};

pub const SdtHeader = extern struct {
    signature: [4]u8 align(1),
    length: u32 align(1),
    revision: u8 align(1),
    checksum: u8 align(1),
    oemid: [6]u8 align(1),
    oem_table_id: [8]u8 align(1),
    oem_revision: u32 align(1),
    creator_id: u32 align(1),
    creator_revision: u32 align(1),
};

pub const Rsdt = extern struct {
    header: SdtHeader align(1),
    tables: [256]u32 align(1),
};

pub const Fadt = extern struct {
    header: SdtHeader align(1),
    firmware_ctrl: u32 align(1),
    dsdt: u32 align(1),
    rsv_a: u32 align(1) = 0,
    preferred_power_management_profile: u8 align(1),
    sci_interrupt: u16 align(1),
    smi_command_port: u32 align(1),
    acpi_enable: u8 align(1),
    acpi_disable: u8 align(1),
    s4bios_req: u8 align(1),
    pstate_control: u8 align(1),
    pm1a_event_block: u32 align(1),
    pm1b_event_block: u32 align(1),
    pm1a_control_block: u32 align(1),
    pm1b_control_block: u32 align(1),
    pm2_control_block: u32 align(1),
    pm_timer_block: u32 align(1),
    gpe0_block: u32 align(1),
    gpe1_block: u32 align(1),
    pm1_event_length: u8 align(1),
    pm1_control_length: u8 align(1),
    pm2_control_length: u8 align(1),
    pm_timer_length: u8 align(1),
    gpe0_length: u8 align(1),
    gpe1_length: u8 align(1),
    gpe1_base: u8 align(1),
    cstate_control: u8 align(1),
    worst_c2_latency: u16 align(1),
    worst_c3_latency: u16 align(1),
    flush_size: u16 align(1),
    flush_stride: u16 align(1),
    duty_offset: u8 align(1),
    duty_width: u8 align(1),
    day_alarm: u8 align(1),
    month_alarm: u8 align(1),
    century: u8 align(1),
    rsv_b: u16 align(1) = 0,
    rsv_c: u8 align(1) = 0,
    flags: u32 align(1),
    reset_reg: [12]u8 align(1),
    reset_value: u8 align(1),
    rsv_d: u16 align(1) = 0,
    rsv_e: u8 align(1) = 0,
};

pub const Dsdt = extern struct {
    header: SdtHeader align(1),
};

pub const Madt = extern struct {
    header: SdtHeader align(1),
    lapic_addr: u32 align(1),
    flags: u32 align(1),

    /// Returns the (virtual) address of the I/O APIC
    pub fn getIoApicAddr(self: *Madt) usize {
        var ptr = @as([*]u8, @ptrCast(self));

        ptr += @sizeOf(Madt);

        while (true) {
            if (ptr[0] == 1) {
                return hal.virtFromPhys(std.mem.readInt(u32, ptr[4..8], .little));
            } else {
                ptr += ptr[1];
            }
        }
    }
};

pub fn init() !void {
    log.debug("Initializing...", .{});
    defer log.debug("Initialization done", .{});

    if (rsdp_req.response) |rsdp_res| {
        log.debug("RSDP={x}", .{@intFromPtr(rsdp_res.address)});

        const rsdp: *Rsdp = @ptrCast(rsdp_res.address);

        log.debug("RSDP signature=\"{s}\"", .{rsdp.signature});
        if (!std.mem.eql(u8, "RSD PTR ", &rsdp.signature)) return error.BadRsdpSignature;

        log.debug("RSDP revision={x}", .{rsdp.revision});

        switch (rsdp.revision) {
            0 => {
                var checksum: usize = 0;
                for (std.mem.asBytes(rsdp)) |byte| checksum += byte;
                if ((checksum & 0xFF) != 0) return error.BadRsdpChecksum;

                log.debug("RSDP OEMID=\"{s}\"", .{rsdp.oemid});

                log.debug("RSDP addr={x}", .{hal.virtFromPhys(rsdp.rsdt_addr)});
                root_sdt = @ptrFromInt(hal.virtFromPhys(rsdp.rsdt_addr));
                log.debug("Root SDT signature=\"{s}\"", .{root_sdt.header.signature});
                if (!std.mem.eql(u8, "RSDT", &root_sdt.header.signature)) return error.BadRsdpSignature;

                log.debug("Root SDT length={d}", .{root_sdt.header.length});
                const entry_count = (root_sdt.header.length - @sizeOf(SdtHeader)) / 4;
                log.debug("Root SDT count={d}", .{entry_count});

                for (0..entry_count) |i| {
                    log.debug("Entry {d} from SDT addr={x}", .{ i, hal.virtFromPhys(root_sdt.tables[i]) });
                    const entry: *anyopaque = @ptrFromInt(hal.virtFromPhys(root_sdt.tables[i]));

                    log.debug("Entry {d} from SDT signature=\"{s}\"", .{ i, @as(*SdtHeader, @ptrCast(entry)).signature });
                    if (std.mem.eql(u8, "FACP", &@as(*SdtHeader, @ptrCast(entry)).signature)) {
                        fadt = @ptrCast(entry);
                        log.debug("FADT found at {x}", .{@intFromPtr(fadt.?)});

                        log.debug("DSDT addr={x}", .{hal.virtFromPhys(fadt.?.dsdt)});
                        dsdt = @ptrFromInt(hal.virtFromPhys(fadt.?.dsdt));

                        log.debug("DSDT signature=\"{s}\"", .{dsdt.?.header.signature});
                        if (!std.mem.eql(u8, "DSDT", &dsdt.?.header.signature)) return error.BadDsdtSignature;
                    } else if (std.mem.eql(u8, "APIC", &@as(*SdtHeader, @ptrCast(entry)).signature)) {
                        madt = @ptrCast(entry);
                        log.debug("MADT found at {x}", .{@intFromPtr(madt.?)});
                    }
                }
            },
            else => @panic("Unsupported ACPI version"),
        }
    } else return error.NoRsdp;
}
