// Copyright (C) 2026 Helmholtz Centre for Environmental Research GmbH - UFZ
// SPDX-License-Identifier: GPL-3.0-or-later

const std = @import("std");
const mem = std.mem;
const m = @import("metrics");
const slurm = @import("slurm");
const Allocator = std.mem.Allocator;
const Registry = @import("../Registry.zig");
const slurmrestd = @import("../slurmrestd.zig");
const Queue = @This();
const util = @import("../util.zig");
const mebi_to_bytes = util.mebi_to_bytes;
const json = @import("../json.zig");
const NoValue = slurm.common.NoValue;
const cmd = @import("../cmd.zig");

jobs: Jobs,
cpus: CPUs,
memory: Memory,
gpus: GPUs,

const Jobs = m.GaugeVec(u32, Labels);
const CPUs = m.GaugeVec(u32, Labels);
const Memory = m.GaugeVec(u64, Labels);
const GPUs = m.GaugeVec(u64, Labels);

pub const cli_command = "squeue";

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
        const schema: json.Job = .{
            .user_name = try util.uidToName(allocator, job.user_id),
            .partition = slurm.parseCStr(job.partition) orelse "unknown",
            .account = slurm.parseCStr(job.account) orelse "unknown",
            .cpus = .{ .set = job.num_cpus != NoValue.u32, .number = job.num_cpus },
            .job_state = &.{ @tagName(job.state.base) },
            .tres_req_str = slurm.parseCStr(job.tres_req_str) orelse "",
            .tres_alloc_str = slurm.parseCStr(job.tres_alloc_str) orelse "",
        };
        try parse(self, allocator, &schema);
    }
}

pub fn collectSlurmrestd(self: *Queue, allocator: Allocator, options: Registry.Backend.SlurmrestdOptions) !void {
    const resp = try slurmrestd.get(json.JobsResponse, allocator, options);
    defer resp.deinit();
    try self.parseJson(allocator, resp.value.jobs);
}

pub fn collectCLI(self: *Queue, allocator: Allocator, options: Registry.Backend.CLIOptions) !void {
    const resp = try cmd.runAndParse(json.JobsResponse, allocator, &.{ cli_command }, options);
    defer resp.deinit();
    try self.parseJson(allocator, resp.value.jobs);
}

fn parse(self: *Queue, allocator: Allocator, job: *const json.Job) !void {
    if (job.job_state.len == 0) return;

    // Base State is always first, and we only need that one.
    const state = try std.ascii.allocLowerString(allocator, job.job_state[0]);

    const queue_labels: Queue.Labels = .{
        .partition = job.partition,
        .account = job.account,
        .user = job.user_name,
        .state = state,
    };

    try self.jobs.incr(queue_labels);

    const cpus = if (job.cpus.set) job.cpus.number else 1;
    try self.cpus.incrBy(queue_labels, cpus);

    const tres_str = if (job.tres_alloc_str.len > 0)
        job.tres_alloc_str
    else
        job.tres_req_str;

    var tres_iter = slurm.tres.iter(try allocator.dupeZ(u8, tres_str), ',');
    while (tres_iter.next()) |tres| {
        if (mem.eql(u8, tres.type, "mem")) {
            try self.memory.incrBy(queue_labels, tres.count * mebi_to_bytes);
        }

        if (mem.eql(u8, tres.type, "gres")) {
            const name = tres.name orelse "";
            if (mem.eql(u8, name, "gpu")) {
                try self.gpus.incrBy(queue_labels, tres.count);
            }
        }
    }
}

fn parseJson(self: *Queue, allocator: Allocator, jobs: []json.Job) !void {
    for (jobs) |job| {
        try parse(self, allocator, &job);
    }
}
