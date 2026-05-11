// Copyright (C) 2026 Helmholtz Centre for Environmental Research GmbH - UFZ
// SPDX-License-Identifier: GPL-3.0-or-later

const std = @import("std");
const slurm = @import("slurm");
const contains = std.mem.containsAtLeast;
const log = std.log;
const mem = std.mem;
const splitScalar = std.mem.splitScalar;

const Backends = struct {
    libslurm: bool = false,
    slurmrestd: bool = false,
    cli: bool = false,

    pub const all: Backends = .{ .libslurm = true, .slurmrestd = true, .cli = true };
    pub const Default = "libslurm,slurmrestd,cli";

    pub fn toStr(self: Backends, allocator: std.mem.Allocator) ![]const u8 {
        var buf: std.ArrayList(u8) = .empty;
        defer buf.deinit(allocator);

        const fields = std.meta.fields(Backends);
        inline for (fields) |field| {
            if (@field(self, field.name)) {
                try buf.appendSlice(allocator, field.name);
                try buf.append(allocator, ',');
            }
        }
        return allocator.dupe(u8, buf.items[0 .. buf.items.len - 1]);
    }

    pub fn fromArgs(args: []const u8) Backends {
        const fields = std.meta.fields(Backends);
        var backends: Backends = .{};

        var iter = splitScalar(u8, args, ',');
        next: while (iter.next()) |backend| {
            if (mem.eql(u8, backend, "all")) return .all;

            inline for (fields) |field| {
                if (mem.eql(u8, backend, field.name)) continue :next;
            }
            log.err("Invalid Backend specified: {s}", .{backend});
            std.process.exit(1);
        }

        inline for (fields) |field| {
            if (contains(u8, args, 1, field.name)) {
                @field(backends, field.name) = true;
            }
        }

        return backends;
    }
};

pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const config = b.addOptions();

    const version: ?[]const u8 = b.option(
        []const u8,
        "slurm-version",
        "Which Version of Slurm to target. Only applicable when compiling with -Dbackends=libslurm",
    ) orelse null;

    const backends: Backends = if (b.option(
        []const u8,
        "backends",
        "Which collection backends should be enabled. Default is 'all'. Available: " ++ Backends.Default,
    )) |opt|
        .fromArgs(opt)
    else
        .all;

    const exe_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });

    const build_zig_zon = b.createModule(.{
        .root_source_file = b.path("build.zig.zon"),
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
        .@"use-slurmfull" = false,
        .version = version,
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

    config.addOption(Backends, "backends", backends);
    config.addOption([]const u8, "backends_str", try backends.toStr(b.allocator));
    exe_mod.addOptions("config", config);

    exe.root_module.addImport("slurm", slurm_dep.module("slurm"));
    exe.root_module.addImport("metrics", metrics_dep.module("metrics"));
    exe.root_module.addImport("cli", cli_dep.module("cli"));
    exe.root_module.addImport("httpz", httpz.module("httpz"));
    exe.root_module.addImport("build.zig.zon", build_zig_zon);

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
