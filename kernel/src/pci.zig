const std = @import("std");
const hal = @import("hal.zig");

const Vendor = enum(u16) {
    _,

    fn valid(self: Vendor) bool {
        return @intFromEnum(self) != 0xffff;
    }
};

const DeviceId = enum(u16) {
    _,
};

const Class = enum(u8) {
    unclassified = 0x00,
    mass_storage_controller = 0x01,
    network_controller = 0x02,
    display_controller = 0x03,
    multimedia_controller = 0x04,
    memory_controller = 0x05,
    bridge = 0x06,
    simple_communication_controller = 0x07,
    base_system_peripheral = 0x08,
    input_device_controller = 0x09,
    docking_station = 0x0a,
    processor = 0x0b,
    serial_bus_controller = 0x0c,
    wireless_controller = 0x0d,
    intelligent_controller = 0x0e,
    satellite_communication_controller = 0x0f,
    encryption_controller = 0x10,
    signal_processing_controller = 0x11,
    processing_accelerator = 0x12,
    non_essential_instrumentation = 0x13,
    co_processor = 0x40,
    unassigned = 0xff,

    fn Subclass(self: Class) type {
        return switch (self) {
            .unclassified => enum(u8) {
                non_vga_compatible = 0x0,
                vga_compatible = 0x1,
            },
            .mass_storage_controller => enum(u8) {
                scsi_bus = 0x00,
                ide = 0x01,
                floppy_disk = 0x02,
                ipi_bus = 0x03,
                raid = 0x04,
                ata = 0x05,
                sata = 0x06,
                serial_attached_scsi = 0x07,
                nvm = 0x08,
                other = 0x80,
            },
            .network_controller => enum(u8) {
                ethernet = 0x00,
                token_ring = 0x01,
                fddi = 0x02,
                atm = 0x03,
                isdn = 0x04,
                worldfip = 0x05,
                picmg_multi_computing = 0x06,
                infiniband = 0x07,
                fabric = 0x08,
                other = 0x80,
            },
            .display_controller => enum(u8) {
                vga_compatible = 0x00,
                xga = 0x01,
                @"3d" = 0x02,
                other = 0x80,
            },
            .multimedia_controller => enum(u8) {
                video_controller = 0x00,
                audio_controller = 0x01,
                computer_telephony_device = 0x02,
                audio_device = 0x03,
                other = 0x80,
            },
            .memory_controller => enum(u8) {
                ram = 0x00,
                flash = 0x01,
                other = 0x80,
            },
            .bridge => enum(u8) {
                host = 0x00,
                isa = 0x01,
                eisa = 0x02,
                mca = 0x03,
                pci_to_pci = 0x04,
                pcmcia = 0x05,
                nubus = 0x06,
                cardbus = 0x07,
                raceway = 0x08,
                pci_to_pci_semi_transparent = 0x09,
                infiniband_to_pci_host = 0x0A,
                other = 0x80,
            },
            .simple_communication_controller => enum(u8) {
                serial = 0x00,
                parallel = 0x01,
                multiport_serial = 0x02,
                modem = 0x03,
                gpib = 0x04,
                smart_card_reader = 0x05,
                other = 0x80,
            },
            .base_system_peripheral => enum(u8) {
                pic = 0x00,
                dma_controller = 0x01,
                timer = 0x02,
                rtc_controller = 0x03,
                pci_hot_plug_controller = 0x04,
                sd_host_controller = 0x05,
                iommu = 0x06,
                other = 0x80,
            },
            .input_device_controller => enum(u8) {
                keyboard = 0x00,
                digitizer_pen = 0x01,
                mouse = 0x02,
                scanner = 0x03,
                gameport = 0x04,
                other = 0x80,
            },
            .docking_station => enum(u8) {
                generic = 0x00,
                other = 0x80,
            },
            .processor => enum(u8) {
                @"386" = 0x00,
                @"486" = 0x01,
                pentium = 0x02,
                pentium_pro = 0x03,
                alpha = 0x10,
                powerpc = 0x20,
                mips = 0x30,
                co_processor = 0x40,
                other = 0x80,
            },
            .serial_bus_controller => enum(u8) {
                firewire = 0x00,
                access_bus = 0x01,
                ssa = 0x02,
                usb = 0x03,
                fibre_channel = 0x04,
                smbus = 0x05,
                infiniband = 0x06,
                ipmi = 0x07,
                sercos = 0x08,
                canbus = 0x09,
                other = 0x80,
            },
            .wireless_controller => enum(u8) {
                irda_compatible = 0x00,
                consumer_ir = 0x01,
                rf = 0x10,
                bluetooth = 0x11,
                broadband = 0x12,
                ethernet_802_1_a = 0x20,
                ethernet_802_1_b = 0x21,
                other = 0x80,
            },
            .intelligent_controller => enum(u8) {
                i20 = 0x00,
            },
            .satellite_communication_controller => enum(u8) {
                tv = 0x01,
                audio = 0x02,
                voice = 0x03,
                data = 0x04,
            },
            .encryption_controller => enum(u8) {
                network_and_computing = 0x00,
                entertainment = 0x10,
                other = 0x80,
            },
            .signal_processing_controller => enum(u8) {
                dpio_modules = 0x00,
                performance_counters = 0x01,
                communication_synchronizer = 0x10,
                signal_processing_management = 0x20,
                other = 0x80,
            },
            .processing_accelerator,
            .non_essential_instrumentation,
            .co_processor,
            .unassigned,
            => enum(u8) {
                generic = 0x00,
                _,
            },
        };
    }
};

const HeaderType = packed struct(u8) {
    type: Type,
    multifunction: bool,

    const Type = enum(u7) {
        general = 0x00,
        pci_to_pci = 0x01,
        pci_to_cardbus = 0x02,
    };
};

const CommandRegister = packed struct(u16) {
    io_space: bool,
    mem_space: bool,
    bus_master: bool,
    special_cycles: bool,
    mem_write_and_inv: bool,
    vga_palette_snoop: bool,
    parity_error_res: ParityErrorResponse,
    rsv_a: u1 = 0,
    serr: bool,
    fast_back_to_back_enabled: bool,
    interrupt: InterruptMode,
    rsv_b: u5 = 0,

    const ParityErrorResponse = enum(u1) {
        @"continue" = 0,
        normal = 1,
    };

    const InterruptMode = enum(u1) {
        enabled = 0,
        disabled = 1,
    };
};

const StatusRegister = packed struct(u16) {
    rsv_a: u3 = 0,
    interrupt_status: bool,
    capabilities_list: bool,
    speed: Speed,
    rsv_b: u1 = 0,
    fast_back_to_back_capable: bool,
    master_data_parity_error: bool,
    devsel_timing: DevselTiming,
    signaled_target_abort: bool,
    received_target_abort: bool,
    received_master_abort: bool,
    signaled_system_error: bool,
    detected_parity_error: bool,

    const Speed = enum(u1) {
        @"33mhz" = 0,
        @"66mhz" = 1,
    };

    const DevselTiming = enum(u2) {
        fast = 0b00,
        medium = 0b01,
        slow = 0b10,
    };
};

const log = std.log.scoped(.pci);

const config_address_port = 0xCF8;
const config_data_port = 0xCFC;

fn configReadWord(bus: u8, device: u5, function: u3, offset: u8) u16 {
    const Address = packed struct(u32) {
        offset: u8,
        function: u3,
        device: u5,
        bus: u8,
        rsv_a: u7 = 0,
        enable: bool = true,
    };

    const addr: Address = .{
        .offset = offset & 0xFC,
        .function = function,
        .device = device,
        .bus = bus,
    };

    hal.cpu.outl(config_address_port, @bitCast(addr));

    return @truncate(hal.cpu.inl(config_data_port) >> @intCast((offset & 2) * 8));
}

fn getVendor(bus: u8, device: u5, function: u3) Vendor {
    return @enumFromInt(configReadWord(bus, device, function, 0));
}

fn getClassSubclassWord(bus: u8, device: u5, function: u3) u16 {
    return configReadWord(bus, device, function, 0xA);
}

fn getClass(bus: u8, device: u5, function: u3) Class {
    const word = getClassSubclassWord(bus, device, function);
    return @enumFromInt(@as(u8, @intCast(word >> 8)));
}

fn getSubclass(bus: u8, device: u5, function: u3, comptime class: Class) class.Subclass() {
    const word = getClassSubclassWord(bus, device, function);
    return @enumFromInt(@as(u8, @truncate(word)));
}

fn getHeaderType(bus: u8, device: u5, function: u3) HeaderType {
    return @bitCast(@as(u8, @truncate(configReadWord(bus, device, function, 0x0E))));
}

fn checkFunction(bus: u8, device: u5, function: u3) void {
    const class = getClass(bus, device, function);
    switch (class) {
        inline else => |other| {
            const subclass = getSubclass(bus, device, function, other);
            log.debug("Found pci@{x:0>2}:{x:0>2}.{x:0>1} (class={s}, subclass={s})", .{ bus, device, function, @tagName(class), @tagName(subclass) });
        },
    }
}

fn checkDevice(bus: u8, device: u5) void {
    const vendor = getVendor(bus, device, 0);
    if (!vendor.valid()) return;

    checkFunction(bus, device, 0);
    const headerType = getHeaderType(bus, device, 0);
    if (headerType.multifunction) {
        for (1..8) |function| {
            if (getVendor(bus, device, @intCast(function)).valid()) {
                checkFunction(bus, device, @intCast(function));
            }
        }
    }
}

fn checkBus(bus: u8) void {
    for (0..32) |device| {
        checkDevice(bus, @intCast(device));
    }
}

fn checkAllBuses() void {
    for (0..256) |bus| {
        checkBus(@intCast(bus));
    }
}

pub fn init() !void {
    log.debug("Initializing...", .{});
    defer log.debug("Initialization done", .{});

    checkAllBuses();
}

pub fn deinit() void {}
