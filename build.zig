const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const libfast_dep = b.dependency("libfast", .{
        .target = target,
        .optimize = optimize,
    });
    const libfast_module = libfast_dep.module("libfast");

    // Core library module
    const libflux_module = b.createModule(.{
        .root_source_file = b.path("lib/libflux.zig"),
        .target = target,
        .optimize = optimize,
    });
    libflux_module.addImport("libfast", libfast_module);

    // Export module for downstream users.
    const libflux_export = b.addModule("libflux", .{
        .root_source_file = b.path("lib/libflux.zig"),
        .target = target,
        .optimize = optimize,
    });
    libflux_export.addImport("libfast", libfast_module);

    // Build static library artifact: libflux.a
    const lib = b.addLibrary(.{
        .name = "flux",
        .root_module = libflux_module,
        .linkage = .static,
    });

    b.installArtifact(lib);

    // Unit tests
    const lib_unit_tests = b.addTest(.{
        .root_module = libflux_module,
    });

    const run_lib_unit_tests = b.addRunArtifact(lib_unit_tests);

    const parity_module = b.createModule(.{
        .root_source_file = b.path("tests/parity/lsquic/all.zig"),
        .target = target,
        .optimize = optimize,
    });
    parity_module.addImport("libflux", libflux_module);

    const parity_tests = b.addTest(.{
        .root_module = parity_module,
    });
    const run_parity_tests = b.addRunArtifact(parity_tests);

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_lib_unit_tests.step);
    test_step.dependOn(&run_parity_tests.step);

    // Keep Makefile compatibility; tests can be wired later.
    const dual_mode_step = b.step("test-dual-mode-regression", "Run paired TLS/SSH regression tests");
    _ = dual_mode_step;
}
