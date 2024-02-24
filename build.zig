const std = @import("std");

const version = std.SemanticVersion.parse("0.1.0-dev") catch unreachable;

pub fn getTarget(b: *std.Build, arch: std.Target.Cpu.Arch) !std.Build.ResolvedTarget {
    return b.resolveTargetQuery(.{
        .cpu_arch = arch,
        .os_tag = .freestanding,
        .abi = .none,
        .cpu_features_add = switch (arch) {
            .x86_64 => blk: {
                var features = std.Target.Cpu.Feature.Set.empty;
                features.addFeature(@intFromEnum(std.Target.x86.Feature.soft_float));
                break :blk features;
            },
            else => return error.UnsupportedArch,
        },
        .cpu_features_sub = switch (arch) {
            .x86_64 => blk: {
                var features = std.Target.Cpu.Feature.Set.empty;
                features.addFeature(@intFromEnum(std.Target.x86.Feature.mmx));
                features.addFeature(@intFromEnum(std.Target.x86.Feature.sse));
                features.addFeature(@intFromEnum(std.Target.x86.Feature.sse2));
                features.addFeature(@intFromEnum(std.Target.x86.Feature.avx));
                features.addFeature(@intFromEnum(std.Target.x86.Feature.avx2));
                break :blk features;
            },
            else => return error.UnsupportedArch,
        },
    });
}

pub fn build(b: *std.Build) !void {
    const build_options = .{
        .arch = b.option(std.Target.Cpu.Arch, "arch", "The architecture to build for") orelse b.host.result.cpu.arch,
    };

    const target = try getTarget(b, build_options.arch);

    const optimize = b.standardOptimizeOption(.{});

    const limine_zig = b.dependency("limine_zig", .{}).module("limine");

    const kernel = b.addExecutable(.{
        .name = "kernel",
        .root_source_file = .{ .path = "kernel/src/main.zig" },
        .target = target,
        .optimize = optimize,
        .single_threaded = true,
        .code_model = .kernel,
        .pic = true,
    });
    kernel.root_module.addImport("limine", limine_zig);
    kernel.setLinkerScript(.{ .path = b.fmt("kernel/linker-{s}.ld", .{@tagName(build_options.arch)}) });

    const kernel_options = b.addOptions();
    kernel_options.addOption(std.SemanticVersion, "version", version);
    kernel.root_module.addOptions("options", kernel_options);

    const kernel_step = b.step("kernel", "Build the kernel");
    kernel_step.dependOn(&b.addInstallArtifact(kernel, .{}).step);

    const limine = b.dependency("limine", .{});

    const limine_exe = b.addExecutable(.{
        .name = "limine",
        .target = b.host,
        .optimize = .ReleaseSafe,
    });
    limine_exe.addCSourceFile(.{ .file = limine.path("limine.c"), .flags = &[_][]const u8{"-std=c99"} });
    limine_exe.linkLibC();
    const limine_exe_run = b.addRunArtifact(limine_exe);

    const iso_tree = b.addWriteFiles();
    _ = iso_tree.addCopyFile(kernel.getEmittedBin(), "kernel.elf");
    _ = iso_tree.addCopyFile(.{ .path = "limine.cfg" }, "limine.cfg");
    _ = iso_tree.addCopyFile(limine.path("limine-bios.sys"), "limine-bios.sys");
    _ = iso_tree.addCopyFile(limine.path("limine-bios-cd.bin"), "limine-bios-cd.bin");
    _ = iso_tree.addCopyFile(limine.path("limine-uefi-cd.bin"), "limine-uefi-cd.bin");
    _ = iso_tree.addCopyFile(limine.path("BOOTX64.EFI"), "EFI/BOOT/BOOTX64.EFI");
    _ = iso_tree.addCopyFile(limine.path("BOOTIA32.EFI"), "EFI/BOOT/BOOTIA32.EFI");

    const iso_cmd = b.addSystemCommand(&.{"xorriso"});
    iso_cmd.addArg("-as");
    iso_cmd.addArg("mkisofs");
    iso_cmd.addArg("-b");
    iso_cmd.addArg("limine-bios-cd.bin");
    iso_cmd.addArg("-no-emul-boot");
    iso_cmd.addArg("-boot-load-size");
    iso_cmd.addArg("4");
    iso_cmd.addArg("-boot-info-table");
    iso_cmd.addArg("--efi-boot");
    iso_cmd.addArg("limine-uefi-cd.bin");
    iso_cmd.addArg("-efi-boot-part");
    iso_cmd.addArg("--efi-boot-image");
    iso_cmd.addArg("--protective-msdos-label");
    iso_cmd.addDirectoryArg(iso_tree.getDirectory());
    iso_cmd.addArg("-o");
    const xorriso_iso_output = iso_cmd.addOutputFileArg("chain.iso");

    limine_exe_run.addArg("bios-install");
    limine_exe_run.addFileArg(xorriso_iso_output);

    const iso_output_dir = b.addWriteFiles();
    iso_output_dir.step.dependOn(&limine_exe_run.step);
    const iso_output = iso_output_dir.addCopyFile(xorriso_iso_output, "chain.iso");

    const iso_step = b.step("iso", "Create an ISO image");
    iso_step.dependOn(&b.addInstallFile(iso_output, "chain.iso").step);
    b.default_step = iso_step;

    const qemu_cmd = b.addSystemCommand(&.{switch (build_options.arch) {
        .x86_64 => "qemu-system-x86_64",
        else => return error.UnsupportedArch,
    }});

    switch (build_options.arch) {
        .x86_64 => {
            qemu_cmd.addArgs(&.{ "-M", "q35" });
            qemu_cmd.addArgs(&.{ "-m", "2G" });
            qemu_cmd.addArg("-cdrom");
            qemu_cmd.addFileArg(iso_output);
            qemu_cmd.addArgs(&.{ "-boot", "d" });
            qemu_cmd.addArgs(&.{ "-debugcon", "stdio" });
        },
        else => return error.UnsupportedArch,
    }

    const qemu_step = b.step("qemu", "Run in QEMU");
    qemu_step.dependOn(&qemu_cmd.step);
}
