// Copyright (C) 2026 Helmholtz Centre for Environmental Research GmbH - UFZ
// SPDX-License-Identifier: GPL-3.0-or-later

const std = @import("std");
const slurm = @import("slurm");
const m = @import("metrics");
const Allocator = std.mem.Allocator;
const utils = @import("util.zig");

pub const Metrics = struct {
    cycle_mean: m.Gauge(u64),
    cycle_mean_depth: m.Gauge(u32),
    cycle_max: m.Gauge(u32),
    cycle_counter: m.Gauge(u32),

    pub fn init(allocator: Allocator, comptime opts: m.RegistryOpts) Metrics {
        _ = allocator;
        return .{
            .cycle_mean = .init(
                "sched_cycle_mean",
                .{ .help = "Sched cycle mean" },
                opts,
            ),
            .cycle_mean_depth = .init(
                "sched_cycle_mean_depth",
                .{ .help = "Sched cycle mean depth" },
                opts,
            ),
            .cycle_max = .init(
                "sched_cycle_max",
                .{ .help = "Sched cycle max" },
                opts,
            ),
            .cycle_counter = .init(
                "sched_cycle_counter",
                .{ .help = "Total scheduling cycles" },
                opts,
            ),
        };
    }

    pub fn reset(self: *Metrics) void {
        utils.reset(self);
    }

    pub fn collect(self: *Metrics, allocator: Allocator) !void {
        _ = allocator;

        const stats = try slurm.slurmctld.loadStats();
        const cycle_count = stats.schedule_cycle_counter;
        const bf_cycle_count = stats.bf_cycle_counter;
        _ = bf_cycle_count;

        self.cycle_max.incrBy(stats.schedule_cycle_max);
        self.cycle_counter.incrBy(cycle_count);
        self.cycle_mean.incrBy(stats.meanCycle());
        self.cycle_mean_depth.incrBy(stats.meanDepthCycle());
    }
};

