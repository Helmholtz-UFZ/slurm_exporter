// Copyright (C) 2026 Helmholtz Centre for Environmental Research GmbH - UFZ
// SPDX-License-Identifier: GPL-3.0-or-later

const std = @import("std");
const m = @import("metrics");
const slurm = @import("slurm");
const Allocator = std.mem.Allocator;
const Queue = @This();
const util = @import("../util.zig");
const mebi_to_bytes = util.mebi_to_bytes;
const json = @import("../json.zig");

jobs: Jobs,
cpus: CPUs,
memory: Memory,
gpus: GPUs,

const Jobs = m.GaugeVec(u32, Labels);
const CPUs = m.GaugeVec(u32, Labels);
const Memory = m.GaugeVec(u64, Labels);
const GPUs = m.GaugeVec(u64, Labels);

pub const Labels = struct {
    partition: []const u8,
    account: []const u8,
    state: []const u8,
    user: []const u8,
};

pub fn init(allocator: Allocator) !Queue {
    return .{
        .jobs = try .init(
            allocator,
            "slurm_queue_jobs",
            .{ .help = "Amount of Jobs in the Queue" },
            .{},
        ),
        .cpus = try .init(
            allocator,
            "slurm_queue_cpus",
            .{ .help = "Amount of CPUs in the Queue" },
            .{},
        ),
        .memory = try .init(
            allocator,
            "slurm_queue_mem",
            .{ .help = "Amount of Memory in the Queue" },
            .{},
        ),
        .gpus = try .init(
            allocator,
            "slurm_queue_gpus",
            .{ .help = "Amount of GPUs in the Queue" },
            .{},
        ),
    };
}

pub fn collect(self: *Queue, allocator: Allocator) !void {
    var jobs = try slurm.job.load();
    defer jobs.deinit();

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
        try self.memory.incrBy(queue_labels, job.memoryTotal() * mebi_to_bytes);

        // TODO: For GPUS pending count (tres_req_str)?
        const tres_alloc = slurm.parseCStrZ(job.tres_alloc_str) orelse "";
        var gpu_iter = slurm.gres.GPU.iter(tres_alloc, ',');
        while (gpu_iter.next()) |gpu| {
            if (gpu.type) |_| continue;

            try self.gpus.incrBy(queue_labels, gpu.count);
        }
    }
}

pub fn collect_slurmrestd(self: *Queue, allocator: Allocator) !void {
    const job_resp = try json.get(json.JobsResponse, allocator);
    defer job_resp.deinit();

    for (job_resp.value.jobs) |job| {
        if (job.job_state.len == 0) continue;

        const cpus = if (job.cpus.set) job.cpus.number else 1;
        // Base State is always first, and we only need that one.
        const state = try std.ascii.allocLowerString(allocator, job.job_state[0]);

        const queue_labels: Queue.Labels = .{
            .partition = job.partition,
            .account = job.account,
            .user = job.user_name,
            .state = state,
        };

        try self.jobs.incr(queue_labels);
        try self.cpus.incrBy(queue_labels, cpus);

        const tres_str = if (job.tres_alloc_str.len > 0)
            job.tres_alloc_str
        else
            job.tres_req_str;

        var tres_iter = slurm.tres.iter(try allocator.dupeZ(u8, tres_str), ',');
        while (tres_iter.next()) |tres| {
            if (std.mem.eql(u8, tres.type, "mem")) {
                try self.memory.incrBy(queue_labels, tres.count * mebi_to_bytes);
            }

            if (std.mem.eql(u8, tres.type, "gres") and std.mem.eql(u8, tres.name.?, "gpu")) {
                try self.gpus.incrBy(queue_labels, tres.count);
            }
        }
    }
}
