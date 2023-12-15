const std = @import("std");

const kernel_config = .{
    .arch = std.Target.Cpu.Arch.x86_64,
};

const version = std.SemanticVersion{ .major = 0, .minor = 1, .patch = 0, .pre = "dev" };

fn getFeatures(comptime arch: std.Target.Cpu.Arch) struct { add: std.Target.Cpu.Feature.Set, sub: std.Target.Cpu.Feature.Set } {
    var add = std.Target.Cpu.Feature.Set.empty;
    var sub = std.Target.Cpu.Feature.Set.empty;
    switch (arch) {
        .x86_64 => {
            const Features = std.Target.x86.Feature;

            add.addFeature(@intFromEnum(Features.soft_float));
            sub.addFeature(@intFromEnum(Features.mmx));
            sub.addFeature(@intFromEnum(Features.sse));
            sub.addFeature(@intFromEnum(Features.sse2));
            sub.addFeature(@intFromEnum(Features.avx));
            sub.addFeature(@intFromEnum(Features.avx2));
        },
        else => @compileError(@tagName(arch) ++ "not implemented"),
    }

    return .{ .add = add, .sub = sub };
}

pub fn build(b: *std.Build) void {
    const features = getFeatures(kernel_config.arch);

    const target: std.zig.CrossTarget = .{
        .cpu_arch = kernel_config.arch,
        .os_tag = .freestanding,
        .abi = .none,
        .cpu_features_add = features.add,
        .cpu_features_sub = features.sub,
    };

    const optimize = b.standardOptimizeOption(.{});

    const kernel = b.addExecutable(.{
        .name = "kernel",
        .root_source_file = .{ .path = "kernel/src/arch/" ++ @tagName(kernel_config.arch) ++ "/start.zig" },
        .main_mod_path = .{ .path = "kernel/src" },
        .target = target,
        .optimize = optimize,
    });
    kernel.setLinkerScript(.{ .path = "kernel/linker-" ++ @tagName(kernel_config.arch) ++ ".ld" });
    kernel.pie = true;
    if (kernel_config.arch.isX86()) kernel.code_model = .kernel;

    const kernel_options = b.addOptions();
    kernel_options.addOption(std.SemanticVersion, "version", version);

    kernel.addOptions("options", kernel_options);

    const kernel_step = b.step("kernel", "Build the kernel");
    kernel_step.dependOn(&b.addInstallArtifact(kernel, .{}).step);

    const limine_cmd = b.addSystemCommand(&.{
        "bash", "-c",
        \\rm -rf zig-cache/limine
        \\git clone https://github.com/limine-bootloader/limine.git zig-cache/limine --branch=v5.x-branch-binary --depth=1
        \\make -C zig-cache/limine
    });
    const limine_step = b.step("limine", "Download and build the limine bootloader");
    limine_step.dependOn(&limine_cmd.step);

    const iso_cmd = b.addSystemCommand(&.{
        "bash", "-c",
        \\rm -rf zig-cache/iso_root
        \\mkdir -p zig-cache/iso_root
        \\cp -v zig-out/bin/kernel zig-cache/iso_root/kernel.elf
        \\cp -v limine.cfg zig-cache/limine/limine-bios.sys zig-cache/limine/limine-bios-cd.bin zig-cache/limine/limine-uefi-cd.bin zig-cache/iso_root
        \\mkdir -p zig-cache/iso_root/EFI/BOOT
        \\cp -v zig-cache/limine/BOOTX64.EFI zig-cache/iso_root/EFI/BOOT
        \\cp -v zig-cache/limine/BOOTIA32.EFI zig-cache/iso_root/EFI/BOOT
        \\xorriso -as mkisofs -b limine-bios-cd.bin -no-emul-boot -boot-load-size 4 -boot-info-table --efi-boot limine-uefi-cd.bin -efi-boot-part --efi-boot-image --protective-msdos-label zig-cache/iso_root -o zig-out/bin/chain.iso
        \\./zig-cache/limine/limine bios-install zig-out/bin/chain.iso
    });
    iso_cmd.step.dependOn(limine_step);
    iso_cmd.step.dependOn(kernel_step);
    const iso_step = b.step("iso", "Build the ISO image");
    iso_step.dependOn(&iso_cmd.step);
    b.default_step = iso_step;

    const qemu_cmd = b.addSystemCommand(switch (kernel_config.arch) {
        .x86_64 => &.{
            "qemu-system-x86_64",
            "-M",
            "q35",
            "-m",
            "2G",
            "-cdrom",
            "zig-out/bin/chain.iso",
            "-boot",
            "d",
            "-debugcon",
            "stdio",
        },
        else => |other| @compileError(@tagName(other) ++ " not implemented"),
    });
    qemu_cmd.step.dependOn(iso_step);

    const qemu_step = b.step("qemu", "Run inside QEMU");
    qemu_step.dependOn(&qemu_cmd.step);

    const kernel_unit_tests = b.addTest(.{
        .root_source_file = .{ .path = "kernel/src/arch/" ++ @tagName(kernel_config.arch) ++ "/start.zig" },
        .optimize = optimize,
    });
    kernel_unit_tests.addOptions("options", kernel_options);

    const run_kernel_unit_tests = b.addRunArtifact(kernel_unit_tests);

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_kernel_unit_tests.step);
}
