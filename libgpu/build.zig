const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.resolveTargetQuery(.{
        .cpu_arch = .x86_64,
        .os_tag = .linux,
        .abi = .gnu
    });
    const optimize = b.standardOptimizeOption(.{});
    const lib = b.addStaticLibrary(.{
        .name = "gpu",
        .root_source_file = b.path("src/lib.zig"),
        .target = target,
        .optimize = optimize,
        .pic = true,
    });
    lib.bundle_compiler_rt = true;
    lib.installHeadersDirectory(b.path("src/include"), "libgpu", .{});
    b.installArtifact(lib);
}
