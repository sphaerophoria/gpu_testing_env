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

    const shader = b.addStaticLibrary(.{
        .name = "gpushader",
        .root_source_file = b.path("src/shader_c_bindings.zig"),
        .target = target,
        .optimize = optimize,
        .pic = true,
    });
    // FIXME: Split headers between libraries
    shader.bundle_compiler_rt = true;
    shader.installHeadersDirectory(b.path("src/include"), "libgpu", .{});

    const replay = b.addExecutable(.{
        .name = "replay",
        .root_source_file = b.path("src/replay.zig"),
        .target = target,
        .optimize = optimize,
    });
    b.installArtifact(replay);

    const tests = b.addTest(.{
        .root_source_file = b.path("src/lib.zig"),
        .target = target,
    });

    const run_tests = b.addRunArtifact(tests);
    const test_step = b.step("test", "");
    test_step.dependOn(&run_tests.step);

    b.installArtifact(lib);
    b.installArtifact(shader);
}
