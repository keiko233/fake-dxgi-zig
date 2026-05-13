const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // GPU name can be overridden via `-Dfake-gpu-name="..."`
    const fake_gpu_name = b.option(
        []const u8,
        "fake-gpu-name",
        "Fake GPU name to report (default: NVIDIA GeForce GTX 1050 Ti)",
    ) orelse "NVIDIA GeForce GTX 1050 Ti";

    const build_options = b.addOptions();
    build_options.addOption([]const u8, "fake_gpu_name", fake_gpu_name);
    const opts_mod = build_options.createModule();

    // ── core module ────────────────────────────────────────────────────────
    const core_mod = b.createModule(.{
        .root_source_file = b.path("src/core/hook.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "build_options", .module = opts_mod },
        },
    });

    // ── dxgi.dll ──────────────────────────────────────────────────────────
    const dxgi_mod = b.createModule(.{
        .root_source_file = b.path("src/dxgi.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "build_options", .module = opts_mod },
            .{ .name = "core", .module = core_mod },
        },
    });

    const dxgi = b.addLibrary(.{
        .name = "dxgi",
        .linkage = .dynamic,
        .root_module = dxgi_mod,
    });

    // Pass the .def file so exports are clean (no @N suffix)
    // LLD on Windows recognises .def files as linker input directly.
    dxgi_mod.addObjectFile(b.path("src/dxgi.def"));

    b.installArtifact(dxgi);
}
