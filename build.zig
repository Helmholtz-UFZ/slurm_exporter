// Copyright (C) 2026 Helmholtz Centre for Environmental Research GmbH - UFZ
// SPDX-License-Identifier: GPL-3.0-or-later

const std = @import("std");
const slurm = @import("slurm");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const exe_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });

    const exe = b.addExecutable(.{
        .name = "slurm-exporter",
        .root_module = exe_mod,
    });

    slurm.setupSlurmPath(b, exe);
    const slurm_dep = b.dependency("slurm", .{
        .target = target,
        .optimize = optimize,
        .@"use-slurmfull" = true,
    });

    const metrics_dep = b.dependency("metrics", .{
        .target = target,
        .optimize = optimize,
    });

    const cli_dep = b.dependency("cli", .{
        .target = target,
        .optimize = optimize,
    });

    const httpz = b.dependency("httpz", .{
        .target = target,
        .optimize = optimize,
    });

    exe.root_module.addImport("slurm", slurm_dep.module("slurm"));
    exe.root_module.addImport("metrics", metrics_dep.module("metrics"));
    exe.root_module.addImport("cli", cli_dep.module("cli"));
    exe.root_module.addImport("httpz", httpz.module("httpz"));

    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());

    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);

    const exe_unit_tests = b.addTest(.{
        .root_module = exe_mod,
    });

    const run_exe_unit_tests = b.addRunArtifact(exe_unit_tests);

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_exe_unit_tests.step);
}
