// Copyright (C) 2026 Helmholtz Centre for Environmental Research GmbH - UFZ
// SPDX-License-Identifier: GPL-3.0-or-later

const std = @import("std");
const m = @import("metrics");
const slurm = @import("slurm");
const Allocator = std.mem.Allocator;
const Node = @This();
const json = @import("../json.zig");
const utils = @import("../util.zig");
const mebi_to_bytes = utils.mebi_to_bytes;
const contains = std.mem.containsAtLeast;
const eql = std.mem.eql;
const splitScalar = std.mem.splitScalar;

pub fn containsSlice(haystack: []const []const u8, needle: []const u8) bool {
    for (haystack) |item| {
        if (eql(u8, item, needle)) return true;
    }
    return false;
}

states: States,
cpus: CPUs,
memory: Memory,

pub const LabelsPerHost = struct {
    state: []const u8,
    partition: []const u8,
};

pub const LabelsStateCount = struct {
    state: []const u8,
    reason: []const u8,
};

const States = m.GaugeVec(u64, LabelsStateCount);
const CPUs = m.GaugeVec(u32, LabelsPerHost);
const Memory = m.GaugeVec(u128, LabelsPerHost);

pub fn init(allocator: Allocator) !Node {
    return .{
        .states = try .init(
            allocator,
            "slurm_node_states_count",
            .{ .help = "State of the Nodes" },
            .{},
        ),
        .cpus = try .init(
            allocator,
            "slurm_node_cpus_count",
            .{ .help = "CPUs of the Nodes" },
            .{},
        ),
        .memory = try .init(
            allocator,
            "slurm_node_mem_bytes",
            .{ .help = "Memory of the Nodes" },
            .{},
        ),
    };
}

pub fn collect(self: *Node, allocator: Allocator) !void {
    var node_resp = try slurm.node.load();
    defer node_resp.deinit();
    var node_iter = node_resp.iter();

    while (node_iter.next()) |node| {
        _ = slurm.parseCStr(node.name) orelse continue;
        const partitions = slurm.parseCStr(node.partitions) orelse "unknown";
        const util = node.utilization();
        const reason = slurm.parseCStr(node.reason) orelse "";
        const base_state = node.state.base;
        const state_flags = try node.state.flags.toStr(allocator, ",");

        var node_labels: Node.LabelsPerHost = .{
            .state = "unknown",
            .partition = "unknown",
        };

        var state_count_labels: Node.LabelsStateCount = .{
            .state = @tagName(base_state),
            .reason = "None",
        };

        const err = slurm.err.toEntry(error.SlurmdKillTaskFailed);
        if (std.mem.containsAtLeast(u8, reason, 1, err.description)) {
            const state = blk: {
                if (node.state.flags.drain) break :blk "drained";
                if (base_state == .down) break :blk "down";

                break :blk @tagName(base_state);
            };

            state_count_labels.state = state;
            state_count_labels.reason = err.description;
        }

        try self.states.incr(state_count_labels);

        var state_iter = std.mem.splitScalar(u8, state_flags, ',');
        while (state_iter.next()) |status| {
            if (std.mem.eql(u8, status, "")) continue;
            state_count_labels.state = status;
            try self.states.incr(state_count_labels);
        }

        var part_iter = std.mem.splitScalar(u8, partitions, ',');
        while (part_iter.next()) |part| {
            node_labels.partition = part;

            if (node.state.flags.drain) {
                node_labels.state = "drained";
                try self.cpus.incrBy(node_labels, util.total_cpus);
            }

            switch (base_state) {
                .down => {
                    node_labels.state = "down";
                    try self.cpus.incrBy(node_labels, util.total_cpus);
                },
                .idle, .allocated, .mixed => {
                    node_labels.state = "allocated";
                    try self.cpus.incrBy(node_labels, util.alloc_cpus);
                    try self.memory.incrBy(node_labels, util.alloc_memory * mebi_to_bytes);

                    node_labels.state = "idle";
                    try self.cpus.incrBy(node_labels, util.idle_cpus);
                    try self.memory.incrBy(node_labels, util.idle_memory * mebi_to_bytes);
                },
                else => {},
            }

//              if (base_state == .down) {
//              } else if (base_state == .idle or base_state == .allocated or base_state == .mixed) {
//              }

            node_labels.state = "total";
            try self.cpus.incrBy(node_labels, util.total_cpus);
            try self.memory.incrBy(node_labels, util.real_memory * mebi_to_bytes);
        }
    }
}

pub fn collect_slurmrestd(self: *Node, allocator: Allocator) !void {
    const resp = try json.get(json.NodesReponse, allocator);
    defer resp.deinit();

    for (resp.value.nodes) |node| {
        const partitions = node.partitions;
        const reason = node.reason;

        const base_state = if (node.state.len >= 1)
            try std.ascii.allocLowerString(allocator, node.state[0])
        else
            "unknown";

        const state_flags: []const []const u8 = if (node.state.len >= 2)
            node.state[1..]
            //try std.ascii.allocLowerString(allocator, node.state[1..])
        else
            &.{};

        var node_labels: Node.LabelsPerHost = .{
            .state = "unknown",
            .partition = "unknown",
        };

        var state_count_labels: Node.LabelsStateCount = .{
            .state = base_state,
            .reason = "None",
        };

        const kill_task_failed = "Kill task failed";
        if (contains(u8, reason, 1, kill_task_failed)) {
            const state = blk: {
                if (containsSlice(state_flags, "DRAIN")) break: blk "drained";
                if (eql(u8, base_state, "down")) break :blk "down";

                break :blk base_state;
            };

            state_count_labels.state = state;
            state_count_labels.reason = kill_task_failed;
        }
        try self.states.incr(state_count_labels);

//        var state_iter = splitScalar(u8, state_flags, ',');
        for (state_flags) |status| {
            if (std.mem.eql(u8, status, "")) continue;
            state_count_labels.state = status;
            try self.states.incr(state_count_labels);
        }

        // var part_iter = splitScalar(u8, partitions, ',');
        for (partitions) |part| {
            node_labels.partition = part;

            if (containsSlice(state_flags, "DRAIN")) {
                node_labels.state = "drained";
                try self.cpus.incrBy(node_labels, node.cpus);
            }

            if (eql(u8, base_state, "down")) {
                node_labels.state = "down";
                try self.cpus.incrBy(node_labels, node.cpus);
            } else if (eql(u8, base_state, "idle") or eql(u8, base_state, "idle") or eql(u8, base_state, "mixed")) {
                node_labels.state = "allocated";
                try self.cpus.incrBy(node_labels, node.alloc_cpus);
                try self.memory.incrBy(node_labels, node.alloc_memory * mebi_to_bytes);

                node_labels.state = "idle";
                try self.cpus.incrBy(node_labels, node.alloc_idle_cpus);
                const idle_memory = node.real_memory - node.alloc_memory;
                try self.memory.incrBy(node_labels, idle_memory * mebi_to_bytes);
            }

//              if (base_state == .down) {
//              } else if (base_state == .idle or base_state == .allocated or base_state == .mixed) {
//              }

            node_labels.state = "total";
            try self.cpus.incrBy(node_labels, node.cpus);
            try self.memory.incrBy(node_labels, node.real_memory * mebi_to_bytes);
        }
    }
}
