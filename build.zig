// SPDX-License-Identifier: BSD-2-Clause

const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const math = b.dependency("fluxion_math", .{ .target = target, .optimize = optimize });
    const shader = b.dependency("fluxion_shader", .{ .target = target, .optimize = optimize });
    const rhi = b.dependency("fluxion_rhi", .{ .target = target, .optimize = optimize });

    const mod = b.addModule("fluxion_smooth", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "fluxion_math", .module = math.module("fluxion_math") },
        },
    });

    // The GPU side, as a program builds it: with its own rhi and shader, so
    // that a `Device` stays one type.
    const rhi_mod = b.createModule(.{
        .root_source_file = b.path("src/render/rhi.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "fluxion_smooth", .module = mod },
            .{ .name = "fluxion_rhi", .module = rhi.module("fluxion_rhi") },
            .{ .name = "fluxion_shader", .module = shader.module("fluxion_shader") },
        },
    });

    const test_step = b.step("test", "Run the test suite");
    test_step.dependOn(&b.addRunArtifact(b.addTest(.{ .name = "fluxion-smooth-tests", .root_module = mod })).step);
    test_step.dependOn(&b.addRunArtifact(b.addTest(.{ .name = "fluxion-smooth-rhi-tests", .root_module = rhi_mod })).step);

    // `zig build blue-noise`: the texture made again, into src/blue_noise.bin.
    const maker = b.addExecutable(.{
        .name = "fluxion-smooth-blue-noise",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/blue_noise.zig"),
            .target = target,
            .optimize = .ReleaseFast,
            .imports = &.{.{ .name = "fluxion_smooth", .module = mod }},
        }),
    });
    const make = b.addRunArtifact(maker);
    make.setCwd(b.path("."));
    make.addArg("src/blue_noise.bin");
    b.step("blue-noise", "Make the blue noise texture again, into src/blue_noise.bin").dependOn(&make.step);

    const docs_lib = b.addLibrary(.{ .name = "fluxion-smooth", .root_module = mod });
    const install_docs = b.addInstallDirectory(.{
        .source_dir = docs_lib.getEmittedDocs(),
        .install_dir = .prefix,
        .install_subdir = "docs",
    });
    b.step("docs", "Generate API documentation into zig-out/docs").dependOn(&install_docs.step);
}
