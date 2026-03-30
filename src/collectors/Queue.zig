// Copyright (C) 2026 Helmholtz Centre for Environmental Research GmbH - UFZ
// SPDX-License-Identifier: GPL-3.0-or-later

const std = @import("std");
const slurm = @import("slurm");
const m = @import("metrics");
const util = @import("../util.zig");
const Allocator = std.mem.Allocator;
const Queue = @This();
const mebiToBytes = util.mebiToBytes;

jobs: Jobs,
cpus: CPUs,
memory: Memory,
gpus: GPUs,

const Jobs = m.GaugeVec(u32, Labels);
const CPUs = m.GaugeVec(u32, Labels);
const Memory = m.GaugeVec(u64, Labels);
const GPUs = m.GaugeVec(u64, Labels);

const Labels = struct {
    partition: []const u8,
    account: []const u8,
    state: []const u8,
    user: []const u8,
};

pub fn init(allocator: Allocator, comptime opts: m.RegistryOpts) Queue {
    return .{
        .jobs = try .init(
            allocator,
            "queue_jobs",
            .{ .help = "Amount of Jobs in the Queue" },
            opts,
        ),
        .cpus = try .init(
            allocator,
            "queue_cpus",
            .{ .help = "Amount of CPUs in the Queue" },
            opts,
        ),
        .memory = try .init(
            allocator,
            "queue_mem",
            .{ .help = "Amount of Memory in the Queue" },
            opts,
        ),
        .gpus = try .init(
            allocator,
            "queue_gpus",
            .{ .help = "Amount of GPUs in the Queue" },
            opts,
        ),
    };
}

pub fn reset(self: *Queue) void {
    util.reset(self);
}

pub fn collect(self: *Queue, allocator: Allocator) !void {
    var jobs = try slurm.job.load();

    var job_iter = jobs.iter();
    while (job_iter.next()) |job| {
        const uname = try util.uidToName(allocator, job.user_id);
        const partition = slurm.parseCStr(job.partition) orelse "unknown";
        const account = slurm.parseCStr(job.account) orelse "unknown";
        const cpus = job.num_cpus;

        // TODO: Optionally ignore jobs stuck in DependencyNeverSatisfied

        const queue_labels: Queue.Labels = .{
            .partition = partition,
            .account = account,
            .user = uname,
            .state = @tagName(job.state.base),
        };

        try self.jobs.incr(queue_labels);
        try self.cpus.incrBy(queue_labels, cpus);
        try self.memory.incrBy(queue_labels, mebiToBytes(job.memoryTotal()));

        const tres_alloc = slurm.parseCStrZ(job.tres_alloc_str) orelse "";
        var gpu_iter = slurm.gres.GPU.iter(tres_alloc, ',');
        while (gpu_iter.next()) |gpu| {
            if (gpu.type) |_| continue;

            try self.gpus.incrBy(queue_labels, gpu.count);
        }
    }
}
