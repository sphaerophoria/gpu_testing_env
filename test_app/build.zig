const std = @import("std");

pub fn build(b: *std.Build) !void {
    const target = b.resolveTargetQuery(.{
        .cpu_arch = .x86_64,
        .os_tag = .linux,
        .abi = .gnu
    });
    const optimize = b.standardOptimizeOption(.{});

    const exe = b.addExecutable(.{
        .name = "test_app",
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });

    exe.addCSourceFile(.{
        .file = b.path("src/stb_image.c"),
    });

    exe.addSystemIncludePath(b.path("../build/buildroot/staging/usr/include"));
    exe.addSystemIncludePath(b.path("../build/buildroot/staging/usr/include/drm"));
    exe.addSystemIncludePath(b.path("../src/linux-6.11/include/"));
    exe.addLibraryPath(b.path("../build/buildroot/staging/usr/lib"));
    exe.addIncludePath(b.path("src"));
    exe.linkSystemLibrary("drm");
    exe.linkLibC();

    b.installArtifact(exe);
}
