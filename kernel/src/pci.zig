const std = @import("std");
const hal = @import("hal.zig");

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

pub const Bus = struct {
    num: u8,

    pub fn format(self: Bus, comptime _: []const u8, _: std.fmt.FormatOptions, writer: anytype) !void {
        try writer.print("pci@{x:0>2}", .{self.num});
    }

    pub fn queryFunction(self: Bus, query: FunctionQuery) ?Device.Function {
        for (0..32) |device_n| {
            const device = Device{ .bus = self, .num = @intCast(device_n) };
            if (device.queryFunction(query)) |res| {
                return res;
            }
        }

        return null;
    }

    fn check(self: Bus) void {
        for (0..32) |device_n| {
            const device = Device{ .bus = self, .num = @intCast(device_n) };
            device.check();
        }
    }

    pub const Device = struct {
        bus: Bus,
        num: u5,

        pub fn format(self: Device, comptime _: []const u8, _: std.fmt.FormatOptions, writer: anytype) !void {
            try writer.print("{}:{x:0>2}", .{ self.bus, self.num });
        }

        pub fn queryFunction(self: Device, query: FunctionQuery) ?Function {
            for (0..8) |function_n| {
                const function = Function{ .device = self, .num = @intCast(function_n) };
                if (function.matchesQuery(query)) return function;
            }

            return null;
        }

        fn check(self: Device) void {
            var func = Function{ .device = self, .num = 0 };
            const vendor = func.getVendor();
            if (!vendor.valid()) return;

            func.check();
            if (func.getHeaderType().multifunction) {
                for (1..8) |function_n| {
                    func = Function{ .device = self, .num = @intCast(function_n) };
                    if (func.getVendor().valid()) {
                        func.check();
                    }
                }
            }
        }

        pub const Function = struct {
            device: Device,
            num: u3,

            pub fn format(self: Function, comptime fmt: []const u8, _: std.fmt.FormatOptions, writer: anytype) !void {
                const detailed = std.mem.eql(u8, fmt, "detailed");

                const class = self.getClass();
                switch (class) {
                    inline else => |other| {
                        const subclass = self.getSubclass(other);
                        const vendor = self.getVendor();
                        const device_id = self.getDeviceId();

                        try writer.print("{}.{x}", .{ self.device, self.num });

                        if (detailed) {
                            try writer.print(" (class={s}, subclass={s}, vendor={s}:{x:0>4}, device_id={x:0>4})", .{
                                @tagName(class),
                                @tagName(subclass),
                                vendor.getName(),
                                @intFromEnum(vendor),
                                device_id,
                            });
                        }
                    },
                }
            }

            fn readConfig16(self: Function, offset: u8) u16 {
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
                    .function = self.num,
                    .device = self.device.num,
                    .bus = self.device.bus.num,
                };

                hal.cpu.outl(0xCF8, @bitCast(addr));

                return @truncate(hal.cpu.inl(0xCFC) >> @intCast((offset & 2) * 8));
            }

            fn readConfig32(self: Function, offset: u8) u32 {
                return self.readConfig16(offset) | (@as(u32, self.readConfig16(offset + 2)) << 16);
            }

            fn getClassSubclassWord(self: Function) u16 {
                return self.readConfig16(0x0A);
            }

            fn getClass(self: Function) Class {
                const word = self.getClassSubclassWord();
                return @enumFromInt(@as(u8, @intCast(word >> 8)));
            }

            fn getSubclass(self: Function, comptime class: Class) class.Subclass() {
                const word = self.getClassSubclassWord();
                return @enumFromInt(@as(u8, @truncate(word)));
            }

            fn getVendor(self: Function) Vendor {
                return @enumFromInt(self.readConfig16(0x00));
            }

            fn getDeviceId(self: Function) DeviceId {
                return self.readConfig16(0x02);
            }

            fn getHeaderType(self: Function) HeaderType {
                return @bitCast(@as(u8, @truncate(self.readConfig16(0x0E))));
            }

            fn check(self: Function) void {
                log.debug("Found {detailed}", .{self});
            }

            pub fn matchesQuery(self: Function, query: FunctionQuery) bool {
                if (query.vendor) |vendor| {
                    if (self.getVendor() != vendor) {
                        return false;
                    }
                }

                if (query.device_id) |device_id| {
                    if (self.getDeviceId() != device_id) {
                        return false;
                    }
                }

                return true;
            }

            pub fn getBarType(self: Function, n: u8) BarType {
                switch (self.getHeaderType().type) {
                    .general => {
                        std.debug.assert(n <= 5);
                        return @enumFromInt(@as(u1, @truncate(self.readConfig16(0x10 + n * 4))));
                    },
                    .pci_to_pci => {
                        std.debug.assert(n <= 1);
                        return @enumFromInt(@as(u1, @truncate(self.readConfig16(0x10 + n * 4))));
                    },
                    .pci_to_cardbus => @panic("Tried to get BAR type for a PCI-to-CardBus header type"),
                }
            }

            pub fn getBarAddr(self: Function, n: u8) u64 {
                return switch (self.getBarType(n)) {
                    .mmio => (self.readConfig32(0x10 + n * 4) & 0xFFFFFFF0) + (@as(u64, self.readConfig32(0x10 + (n + 4) * 4) & 0xFFFFFFFF) << 32),
                    .ports => @as(u16, @truncate(self.readConfig32(0x10 + n * 4) & 0xFFFFFFFC)),
                };
            }

            pub const BarType = enum(u1) {
                mmio = 0,
                ports = 1,
            };

            pub const Vendor = enum(u16) {
                intel = 0x8086,
                _,

                fn valid(self: Vendor) bool {
                    return @intFromEnum(self) != 0xffff;
                }

                fn getName(self: Vendor) []const u8 {
                    return std.enums.tagName(Vendor, self) orelse "unknown";
                }
            };

            pub const DeviceId = u16;

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
        };
    };
};

fn checkAllBuses() void {
    for (0..256) |bus_n| {
        const bus = Bus{ .num = @intCast(bus_n) };
        bus.check();
    }
}

pub const FunctionQuery = struct {
    vendor: ?Bus.Device.Function.Vendor = null,
    device_id: ?Bus.Device.Function.DeviceId = null,
};

pub fn queryFunction(query: FunctionQuery) ?Bus.Device.Function {
    for (0..255) |bus_n| {
        const bus = Bus{ .num = @intCast(bus_n) };
        if (bus.queryFunction(query)) |res| {
            return res;
        }
    }

    return null;
}

pub fn init() void {
    log.debug("Initializing...", .{});
    defer log.debug("Initialization done", .{});

    checkAllBuses();
}

pub fn deinit() void {}
