// Copyright (C) 2026 Helmholtz Centre for Environmental Research GmbH - UFZ
// SPDX-License-Identifier: GPL-3.0-or-later

const std = @import("std");
const slurm = @import("slurm");
const m = @import("metrics");
const Allocator = std.mem.Allocator;
const utils = @import("../util.zig");

const Controller = @This();

const MICROSECONDS = 1000000.0;

fn toFloat(comptime T: type, value: u64) T {
    return @as(T, @floatFromInt(value)) / MICROSECONDS;
}

// Common slurmctld Diagnostics
server_threads: m.Gauge(u32),
agent_queue_size: m.Gauge(u32),
agents: m.Gauge(u32),
agent_threads: m.Gauge(u32),
dbd_agent_queue_size: m.Gauge(u32),
data_since_timestamp: m.Gauge(std.posix.time_t),
jobs_total: m.CounterVec(u32, LabelsForJobStats),
jobs_timestamp: m.Gauge(std.posix.time_t),

// Main Scheduler Statistics
cycle_max_seconds: m.Gauge(f32),
cycles_total: m.Counter(u32),
cycles_seconds_total: m.Counter(f64),
cycle_depth: m.Gauge(u32),
cycles_per_minute: m.Gauge(isize),
cycle_mean: m.Gauge(f64),
cycle_mean_depth: m.Gauge(u32),

// Backfill Scheduler Statistics
backfill_last_cycle_timestamp: m.Gauge(std.posix.time_t),
backfill_active: m.Gauge(u32),
backfill_jobs_total: m.Counter(u32),
backfill_het_jobs_total: m.Counter(u32),
backfill_cycles_total: m.Counter(u32),
backfill_cycles_seconds_total: m.Counter(f64),
backfill_jobs: m.Gauge(u32),
backfill_cycle_max_seconds: m.Gauge(f32),
backfill_cycle_last_seconds: m.Gauge(f32),
backfill_cycle_last_depth: m.Gauge(u32),
backfill_cycle_last_depth_try: m.Gauge(u32),
backfill_queue_length: m.Gauge(u32),
backfill_queue_length_mean: m.Gauge(u32),
backfill_queue_length_total: m.Counter(u32),
backfill_table_size: m.Gauge(u32),
backfill_table_size_mean: m.Gauge(u32),
backfill_table_size_total: m.Counter(u32),
backfill_cycle_mean: m.Gauge(f64),
backfill_cycle_mean_depth: m.Gauge(u32),
backfill_cycle_mean_depth_try: m.Gauge(u32),

const LabelsForJobStats = struct {
    state: []const u8,
};

pub fn init(allocator: Allocator, comptime opts: m.RegistryOpts) Controller {
    return .{
        .server_threads = .init(
            "controller_server_threads",
            .{ .help = "Number of currently active Server Threads" },
            opts,
        ),
        .agent_queue_size = .init(
            "controller_agent_queue_size",
            .{ .help = "Current Size of the Agent Queue" },
            opts,
        ),
        .agents = .init(
            "controller_agents",
            .{ .help = "Number of currently active Agents" },
            opts,
        ),
        .agent_threads = .init(
            "controller_agent_threads",
            .{ .help = "Number of currently active Agent Threads" },
            opts,
        ),
        .dbd_agent_queue_size = .init(
            "controller_database_agent_queue_size",
            .{ .help = "Current Size of the Database Agent Queue" },
            opts,
        ),
        .data_since_timestamp = .init(
            "controller_data_since_timestamp",
            .{ .help = "Since when this data is being recorded (last slurmctld reset)" },
            opts,
        ),
        .jobs_total = try .init(
            allocator,
            "controller_jobs_total",
            .{ .help = "Number of total Jobs processed per state since last reset" },
            opts,
        ),
        .jobs_timestamp = .init(
            "controller_jobs_timestamp",
            .{ .help = "Timestamp when the Job State Counts were last gathered" },
            opts,
        ),
        .cycle_max_seconds = .init(
            "controller_sched_cycle_max",
            .{ .help = "Sched cycle max" },
            opts,
        ),
        .cycles_total = .init(
            "controller_sched_cycles_total",
            .{ .help = "Total Scheduling Cycles since last restart" },
            opts,
        ),
        .cycles_seconds_total = .init(
            "controller_sched_cycles_seconds_total",
            .{ .help = "Time in seconds it took all Scheduling cycles to run since last reset" },
            opts,
        ),
        .cycle_depth = .init(
            "controller_sched_cycle_depth",
            .{ .help = "Sched cycle depth" },
            opts,
        ),
        .cycles_per_minute = .init(
            "controller_sched_cycles_per_minute",
            .{ .help = "Scheduling cycles per minute" },
            opts,
        ),
        .cycle_mean = .init(
            "controller_sched_cycle_mean",
            .{ .help = "Sched cycle mean" },
            opts,
        ),
        .cycle_mean_depth = .init(
            "controller_sched_cycle_mean_depth",
            .{ .help = "Sched cycle mean depth" },
            opts,
        ),
        .backfill_last_cycle_timestamp = .init(
            "controller_backfill_last_cycle_timestamp",
            .{ .help = "When the last backfill cycle was run (UNIX Timestamp)" },
            opts,
        ),
        .backfill_active = .init(
            "controller_backfill_active",
            .{ .help = "If the Backfill alrogithm currently runs or not" },
            opts,
        ),
        .backfill_jobs_total = .init(
            "controller_backfill_jobs_total",
            .{ .help = "Total backfilled Jobs" },
            opts,
        ),
        .backfill_het_jobs_total = .init(
            "controller_backfill_het_jobs_total",
            .{ .help = "Total backfilled Het Jobs" },
            opts,
        ),
        .backfill_cycles_total = .init(
            "controller_backfill_cycles_total",
            .{ .help = "Number of total Backfill cycles ran" },
            opts,
        ),
        .backfill_cycles_seconds_total = .init(
            "controller_backfill_cycles_seconds_total",
            .{ .help = "Time in seconds it took all Backfill cycles to run since last reset" },
            opts,
        ),
        .backfill_jobs = .init(
            "controller_backfill_jobs",
            .{ .help = "Jobs backfilled in the last backfill run" },
            opts,
        ),
        .backfill_cycle_max_seconds = .init(
            "controller_backfill_cycle_max_seconds",
            .{ .help = "How many seconds the longest backfill cycle has taken" },
            opts,
        ),
        .backfill_cycle_last_seconds = .init(
            "controller_backfill_cycle_last_seconds",
            .{ .help = "How many seconds the last backfill cycle has taken" },
            opts,
        ),
        .backfill_cycle_last_depth = .init(
            "controller_backfill_cycle_last_depth",
            .{ .help = "Number of Jobs processed during the last Backfill cycle" },
            opts,
        ),
        .backfill_cycle_last_depth_try = .init(
            "controller_backfill_cycle_last_depth_try",
            .{ .help = "Number of Jobs processed during last Backfill cycle that had a chance to start using available resources." },
            opts,
        ),
        .backfill_queue_length = .init(
            "controller_backfill_queue_length",
            .{ .help = "Number of Jobs pending to be processed by Backfilling" },
            opts,
        ),
        .backfill_queue_length_total = .init(
            "controller_backfill_queue_length_total",
            .{ .help = "Total number of Jobs pending to be processed by Backfilling since last reset" },
            opts,
        ),
        .backfill_table_size = .init(
            "controller_backfill_table_size",
            .{ .help = "Current Backfill table size" },
            opts,
        ),
        .backfill_table_size_total = .init(
            "controller_backfill_table_size_total",
            .{ .help = "Total amount of backfill table size" },
            opts,
        ),

        .backfill_cycle_mean = .init(
            "controller_backfill_cycle_mean",
            .{ .help = "Average seconds it takes to run a Backfill cycle" },
            opts,
        ),
        .backfill_cycle_mean_depth = .init(
            "controller_backfill_cycle_mean_depth",
            .{ .help = "Average seconds it takes for backfill cycle depth" },
            opts,
        ),
        .backfill_cycle_mean_depth_try = .init(
            "controller_backfill_cycle_mean_depth_try",
            .{ .help = "Average seconds it takes for backfill cycle depth try" },
            opts,
        ),
        .backfill_queue_length_mean = .init(
            "controller_backfill_queue_length_mean",
            .{ .help = "Average backfill queue length count" },
            opts,
        ),
        .backfill_table_size_mean = .init(
            "controller_backfill_table_size_mean",
            .{ .help = "Average backfill table size" },
            opts,
        ),
    };
}

pub fn reset(self: *Controller) void {
    utils.reset(self);
}

pub fn collect(self: *Controller, allocator: Allocator) !void {
    _ = allocator;

    const stats = try slurm.slurmctld.loadStats();

    self.server_threads.incrBy(stats.server_thread_count);
    self.agent_queue_size.incrBy(stats.agent_queue_size);
    self.agents.incrBy(stats.agent_count);
    self.agent_threads.incrBy(stats.agent_thread_count);
    self.dbd_agent_queue_size.incrBy(stats.dbd_agent_queue_size);
    self.data_since_timestamp.incrBy(stats.req_time_start);

    self.cycle_max_seconds.incrBy(toFloat(f32, stats.schedule_cycle_max));
    self.cycles_total.incrBy(stats.schedule_cycle_counter);
    self.cycles_seconds_total.incrBy(toFloat(f64, stats.schedule_cycle_sum));
    self.cycle_mean.incrBy(toFloat(f64, stats.meanCycle()));
    self.cycle_mean_depth.incrBy(stats.meanDepthCycle());
    self.cycle_depth.incrBy(stats.schedule_cycle_depth);
    self.cycles_per_minute.incrBy(stats.cyclesPerMinute());

    self.backfill_jobs_total.incrBy(stats.bf_backfilled_jobs);
    self.backfill_het_jobs_total.incrBy(stats.bf_backfilled_het_jobs);
    self.backfill_cycles_total.incrBy(stats.bf_cycle_counter);
    self.backfill_cycles_seconds_total.incrBy(toFloat(f64, stats.bf_cycle_sum));
    self.backfill_last_cycle_timestamp.incrBy(stats.bf_when_last_cycle);
    self.backfill_active.incrBy(stats.bf_active);
    self.backfill_jobs.incrBy(stats.bf_last_backfilled_jobs);
    self.backfill_cycle_max_seconds.incrBy(toFloat(f32, stats.bf_cycle_max));
    self.backfill_cycle_last_seconds.incrBy(toFloat(f32, stats.bf_cycle_last));
    self.backfill_cycle_last_depth.incrBy(stats.bf_last_depth);
    self.backfill_cycle_last_depth_try.incrBy(stats.bf_last_depth_try);
    self.backfill_queue_length.incrBy(stats.bf_queue_len);
    self.backfill_queue_length_total.incrBy(stats.bf_queue_len_sum);
    self.backfill_table_size.incrBy(stats.bf_table_size);
    self.backfill_table_size_total.incrBy(stats.bf_table_size_sum);
    self.backfill_cycle_mean.incrBy(toFloat(f64, stats.bfCycleMean()));
    self.backfill_cycle_mean_depth.incrBy(stats.bfCycleMeanDepth());
    self.backfill_cycle_mean_depth_try.incrBy(stats.bfCycleMeanDepthTry());
    self.backfill_queue_length_mean.incrBy(stats.bfMeanQueueLength());
    self.backfill_table_size_mean.incrBy(stats.bfMeanTableSize());

    try self.jobs_total.incrBy(.{ .state = "submitted"}, stats.jobs_submitted);
    try self.jobs_total.incrBy(.{ .state = "started"}, stats.jobs_started);
    try self.jobs_total.incrBy(.{ .state = "completed"}, stats.jobs_completed);
    try self.jobs_total.incrBy(.{ .state = "cancelled"}, stats.jobs_canceled);
    try self.jobs_total.incrBy(.{ .state = "failed"}, stats.jobs_failed);
    try self.jobs_total.incrBy(.{ .state = "pending"}, stats.jobs_pending);
    try self.jobs_total.incrBy(.{ .state = "running"}, stats.jobs_running);
    self.jobs_timestamp.incrBy(stats.job_states_ts);
}

