const std = @import("std");
const Parsed = std.json.Parsed;
const slurm = @import("slurm");

pub const PluginType = enum {
    @"v0.0.44",
    @"v0.0.43",
};

pub fn Number(comptime T: type) type {
    return struct {
        set: bool = false,
        infinite: bool = false,
        number: T = 0,
    };
}

pub const Error = struct {
    description: ?[]const u8 = null,
    error_number: u32 = 0,
    @"error": ?[]const u8 = null,
    source: ?[]const u8 = null,
};

pub const Warning = struct {
    description: ?[]const u8 = null,
    source: ?[]const u8 = null,
};

pub const Meta = struct {
    plugin: Plugin = .{},
    client: Client = .{},
    command: []const []const u8 = &.{},
    slurm: Slurm = .{},

    const Plugin = struct {
        @"type": ?[]const u8 = null,
        name: ?[]const u8 = null,
        data_parser: ?[]const u8 = null,
        accounting_storage: ?[]const u8 = null,
    };

    const Client = struct {
        source: ?[]const u8 = null,
        user: ?[]const u8 = null,
        group: ?[]const u8 = null,
    };

    const Slurm = struct {
        version: Version = .{},
        release: ?[]const u8 = null,
        cluster: ?[]const u8 = null,

        const Version = struct {
            major: ?[]const u8 = null,
            minor: ?[]const u8 = null,
            micro: ?[]const u8 = null,
        };
    };
};

pub const SharesResponse = struct {
    shares: Data = .{},
    meta: Meta = .{},
    errors: []Error = &.{},
    warnings: []Warning = &.{},

    pub const Data = struct {
        shares: []Shares = &.{},
        total_shares: u64 = 0,
    };

    pub const endpoint = "shares";
};

pub const JobsResponse = struct {
    jobs: []Job = &.{},
    last_backfill: Number(u64),
    last_update: Number(u64),
    meta: Meta = .{},
    errors: []Error = &.{},
    warnings: []Warning = &.{},

    pub const endpoint = "jobs";
};

pub const DiagResponse = struct {
    statistics: Statistics,
    meta: Meta = .{},
    errors: []Error = &.{},
    warnings: []Warning = &.{},

    pub const endpoint = "diag";
};

pub const NodesReponse = struct {
    nodes: []Node = &.{},
    last_update: Number(u64),
    meta: Meta = .{},
    errors: []Error = &.{},
    warnings: []Warning = &.{},

    pub const endpoint = "nodes";
};

pub const Statistics = struct {
    server_thread_count: u32,
    agent_queue_size: u32,
    agent_count: u32,
    agent_thread_count: u32,
    dbd_agent_queue_size: u32,
    req_time_start: Number(isize),

    schedule_cycle_max: u32,
    schedule_cycle_total: u32,
    schedule_cycle_sum: u64,
    schedule_cycle_mean: u64,
    schedule_cycle_mean_depth: u32,
    schedule_cycle_depth: u32,
    schedule_cycle_per_minute: isize,

    jobs_submitted: u32,
    jobs_started: u32,
    jobs_completed: u32,
    jobs_canceled: u32,
    jobs_failed: u32,
    jobs_pending: u32,
    jobs_running: u32,
    job_states_ts: Number(isize),

    bf_backfilled_jobs: u32,
    bf_backfilled_het_jobs: u32,
    bf_cycle_counter: u32,
    bf_cycle_sum: u64,
    bf_when_last_cycle: Number(isize),
    bf_active: bool,
    bf_last_backfilled_jobs: u32,
    bf_cycle_max: u32,
    bf_cycle_last: u32,
    bf_last_depth: u32,
    bf_last_depth_try: u32,
    bf_queue_len: u32,
    bf_queue_len_sum: u64,
    bf_table_size: u32,
    bf_table_size_sum: u32,

    bf_cycle_mean: u64,
    bf_depth_mean: u64,
    bf_depth_mean_try: u64,
    bf_queue_len_mean: u64,
    bf_table_size_mean: u64,
};

pub const Node = struct {
    name: []const u8,
    cpus: u32,
    alloc_cpus: u32,
    alloc_memory: u128,
    alloc_idle_cpus: u32,
    real_memory: u128,
    partitions: []const []const u8,
    state: []const []const u8,
    reason: []const u8,
    internal: Internal = .{},

    pub const Internal = struct {
        state: ?Internal.State = null,

        pub const State = struct {
            base: slurm.Node.State.Base,
            flags_slice: []const []const u8 = &.{},
            flags: slurm.Node.State.Flags,
        };
    };
};

pub const Job = struct {
    account: []const u8,
    cpus: Number(u32),
    partition: []const u8,
    user_name: []const u8,
    job_state: []const []const u8,
    tres_req_str: []const u8,
    tres_alloc_str: []const u8,
};

pub const Shares = struct {
    name: []const u8,
    parent: []const u8,
    effective_usage: Number(f64),
    usage_normalized: Number(f64),
    usage: u64,
    @"type": []const []const u8,
    fairshare: Fairshare,

    const Fairshare = struct {
        factor: Number(f64),
        level: Number(f64) = .{ .number = 0 },
    };
};

pub fn parse(comptime T: type, allocator: std.mem.Allocator, data: []u8) !Parsed(T) {
    const parsed = try std.json.parseFromSlice(T, allocator, data, .{
        .allocate = .alloc_always,
        .parse_numbers = true,
        .ignore_unknown_fields = true,
    });
    return parsed;
}
