// Copyright (C) 2026 Helmholtz Centre for Environmental Research GmbH - UFZ
// SPDX-License-Identifier: GPL-3.0-or-later

const std = @import("std");
const m = @import("metrics");
const slurm = @import("slurm");
const Allocator = std.mem.Allocator;
const Node = @This();
const json = @import("../json.zig");
const utils = @import("../util.zig");
const cmd = @import("../cmd.zig");
const mebi_to_bytes = utils.mebi_to_bytes;
const contains = std.mem.containsAtLeast;
const eql = std.mem.eql;
const splitScalar = std.mem.splitScalar;
const slurmStrToSlice = utils.slurmStrToSlice;
const Internal = json.Node.Internal;

states: States,
cpus: CPUs,
memory: Memory,

pub const cli_command = "scontrol";

pub const LabelsPerHost = struct {
    state: []const u8 = "unknown",
    partition: []const u8 = "unknown",
};

pub const LabelsStateCount = struct {
    state: []const u8,
    reason: []const u8 = "None",
};

const States = m.GaugeVec(u64, LabelsStateCount);
const CPUs = m.GaugeVec(u32, LabelsPerHost);
const Memory = m.GaugeVec(u128, LabelsPerHost);

pub fn init(arena: Allocator) !Node {
    return .{
        .states = try .init(
            arena,
            "slurm_node_states",
            .{ .help = "State of the Nodes" },
            .{},
        ),
        .cpus = try .init(
            arena,
            "slurm_node_cpus",
            .{ .help = "CPUs of the Nodes" },
            .{},
        ),
        .memory = try .init(
            arena,
            "slurm_node_mem_bytes",
            .{ .help = "Memory of the Nodes" },
            .{},
        ),
    };
}

pub fn collect(self: *Node, arena: Allocator) !void {
    var node_resp = try slurm.node.load();
    defer node_resp.deinit();

    var node_iter = node_resp.iter();
    while (node_iter.next()) |node| {
        const name = slurm.parseCStr(node.name) orelse continue;
        const util = node.utilization();
        const internal: Internal = .{
            .state = .{
                .base = node.state.base,
                .flags = node.state.flags,
                .flags_slice = try node.state.flags.toSlice(arena),
            },
        };
        const schema: json.Node = .{
            .name = name,
            .partitions = try slurmStrToSlice(node.partitions, arena, ','),
            .alloc_cpus = util.alloc_cpus,
            .cpus = util.total_cpus,
            .real_memory = util.real_memory,
            .alloc_idle_cpus = util.idle_cpus,
            .alloc_memory = util.alloc_memory,
            .reason = slurm.parseCStr(node.reason) orelse "",
            .state = &.{},
            .internal = internal,
        };
        try parse(self, arena, &schema);
    }
}

pub fn collectSlurmrestd(self: *Node, arena: Allocator) !void {
    const resp = try json.slurmrestd(json.NodesReponse, arena);
    defer resp.deinit();
    try self.parseJson(arena, resp.value.nodes);
}

pub fn collectCLI(self: *Node, arena: Allocator) !void {
    const resp = try cmd.runAndParse(json.NodesReponse, arena, &.{ "scontrol", "show", "nodes", "--json" });
    defer resp.deinit();
    try self.parseJson(arena, resp.value.nodes);
}

fn parseState(arena: std.mem.Allocator, state: []const []const u8) !Internal.State {
    const base_str = try std.ascii.allocLowerString(arena, state[0]);
    const flag_size = std.meta.fields(slurm.Node.State.Flags).len;
    const flag_str = state[1..];
    const flag_str_lower = try utils.asciiLowerSlice(arena, flag_str, flag_size);
    return .{
        .base = std.meta.stringToEnum(slurm.Node.State.Base, base_str) orelse .unknown,
        .flags = .fromSlice(flag_str_lower),
        .flags_slice = flag_str_lower
    };
}

fn parse(self: *Node, arena: Allocator, node: *const json.Node) !void {
    const state = if (node.internal.state) |s| s else try parseState(arena, node.state);

    var node_labels: Node.LabelsPerHost = .{};
    var state_count_labels: Node.LabelsStateCount = .{
        .state = @tagName(state.base),
    };

    const err = slurm.err.toEntry(error.SlurmdKillTaskFailed);
    if (contains(u8, node.reason, 1, err.description)) {
        if (state.flags.drain) {
            state_count_labels.state = "drain";
        }
        state_count_labels.reason = err.description;
    }
    try self.states.incr(state_count_labels);

    for (state.flags_slice) |status| {
        if (status.len == 0) continue;
        state_count_labels.state = status;
        try self.states.incr(state_count_labels);
    }

    for (node.partitions) |part| {
        node_labels.partition = part;

        if (state.flags.drain) {
            node_labels.state = "drain";
            try self.cpus.incrBy(node_labels, node.cpus);
        }

        switch (state.base) {
            .down => {
                node_labels.state = "down";
                try self.cpus.incrBy(node_labels, node.cpus);
            },
            .idle, .allocated, .mixed => {
                node_labels.state = "allocated";
                try self.cpus.incrBy(node_labels, node.alloc_cpus);
                try self.memory.incrBy(node_labels, node.alloc_memory * mebi_to_bytes);

                node_labels.state = "idle";
                try self.cpus.incrBy(node_labels, node.alloc_idle_cpus);
                const idle_memory = node.real_memory - node.alloc_memory;
                try self.memory.incrBy(node_labels, idle_memory * mebi_to_bytes);
            },
            else => {},
        }

        node_labels.state = "total";
        try self.cpus.incrBy(node_labels, node.cpus);
        try self.memory.incrBy(node_labels, node.real_memory * mebi_to_bytes);
    }
}

fn parseJson(self: *Node, arena: Allocator, nodes: []json.Node) !void {
    for (nodes) |node| {
        try parse(self, arena, &node);
    }
}
