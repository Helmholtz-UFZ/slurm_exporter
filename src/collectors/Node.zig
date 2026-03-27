// Copyright (C) 2026 Helmholtz Centre for Environmental Research GmbH - UFZ
// SPDX-License-Identifier: GPL-3.0-or-later

const std = @import("std");
const slurm = @import("slurm");
const m = @import("metrics");
const utils = @import("../util.zig");
const Allocator = std.mem.Allocator;
const Node = @This();

states: States,
load: Load,
cpus: CPUs,
memory: Memory,

const LabelsPerHost = struct {
    host: []const u8,
    state: []const u8,
    partition: []const u8,
};

const LabelsStateCount = struct {
    state: []const u8,
    reason: []const u8,
};

const States = m.GaugeVec(u64, LabelsStateCount);
const Load = m.GaugeVec(u32, LabelsPerHost);
const CPUs = m.GaugeVec(u32, LabelsPerHost);
const Memory = m.GaugeVec(u128, LabelsPerHost);

pub fn init(allocator: Allocator, comptime opts: m.RegistryOpts) Node {
    return .{
        .states = try .init(
            allocator,
            "node_states_count",
            .{ .help = "State of the Nodes" },
            opts,
        ),
        .load = try .init(
            allocator,
            "node_load",
            .{ .help = "Load of the Nodes" },
            opts,
        ),
        .cpus = try .init(
            allocator,
            "node_cpus_count",
            .{ .help = "CPUs of the Nodes" },
            opts,
        ),
        .memory = try .init(
            allocator,
            "node_mem_bytes",
            .{ .help = "Memory of the Nodes" },
            opts,
        ),
    };
}

pub fn reset(self: *Node) void {
    utils.reset(self);
}

pub fn collect(self: *Node, allocator: Allocator) !void {
    var node_resp = try slurm.loadNodes();
    defer node_resp.deinit();
    var node_iter = node_resp.iter();

    while (node_iter.next()) |node| {
        const node_name = slurm.parseCStr(node.name) orelse continue;
        const partitions = slurm.parseCStr(node.partitions) orelse "unknown";
        const util = node.utilization();
        const reason = slurm.parseCStr(node.reason) orelse "";
        const base_state = node.state.base;
        const state_flags = try node.state.flags.toStr(allocator, ",");

        var node_labels: LabelsPerHost = .{
            .state = "unknown",
            .partition = "unknown",
            .host = node_name,
        };

        var state_count_labels: LabelsStateCount = .{
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
                    try self.memory.incrBy(node_labels, util.alloc_memory);

                    node_labels.state = "idle";
                    try self.cpus.incrBy(node_labels, util.idle_cpus);
                    try self.memory.incrBy(node_labels, util.idle_memory);
                },
                else => {},
            }

//              if (base_state == .down) {
//              } else if (base_state == .idle or base_state == .allocated or base_state == .mixed) {
//              }

            node_labels.state = "total";
            try self.cpus.incrBy(node_labels, util.total_cpus);
            try self.memory.incrBy(node_labels, util.real_memory);
        }
    }
}
