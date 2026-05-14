// Copyright (C) 2026 Helmholtz Centre for Environmental Research GmbH - UFZ
// SPDX-License-Identifier: GPL-3.0-or-later

const std = @import("std");
const m = @import("metrics");
const slurm = @import("slurm");
const utils = @import("../util.zig");
const Shares = @This();
const Allocator = std.mem.Allocator;
const NoValue = slurm.common.NoValue;
const json = @import("../json.zig");
const cmd = @import("../cmd.zig");

pub const Labels = struct {
    account: []const u8,
    user: []const u8,
};

effective_usage: EffectiveUsage,
normalized_usage: NormalizedUsage,
raw_usage: RawUsage,
fairshare_factor: FairshareFactor,

const EffectiveUsage = m.GaugeVec(f64, Labels);
const NormalizedUsage = m.GaugeVec(f64, Labels);
const RawUsage = m.GaugeVec(u64, Labels);
const FairshareFactor = m.GaugeVec(f64, Labels);

pub fn init(allocator: Allocator) !Shares {
    return .{
        .effective_usage = try .init(
            allocator,
            "slurm_share_effective_usage",
            .{ .help = "Effective Usage" },
            .{},
        ),
        .normalized_usage = try .init(
            allocator,
            "slurm_share_normalized_usage",
            .{ .help = "Normalized Usage" },
            .{},
        ),
        .raw_usage = try .init(
            allocator,
            "slurm_share_raw_usage",
            .{ .help = "Raw Usage" },
            .{},
        ),
        .fairshare_factor = try .init(
            allocator,
            "slurm_share_fairshare_factor",
            .{ .help = "Fairshare Factor" },
            .{},
        ),
    };
}

fn hasValue(value: anytype) bool {
    const nvf64: f64 = comptime @floatFromInt(NoValue.u64);
    if (value == NoValue.u32 or value == nvf64) return false;
    return true;
}

pub fn collect(self: *Shares, allocator: Allocator) !void {
    _ = allocator;
    var resp = try slurm.db.association.loadSharesAll();
    defer resp.deinit();

    var resp_iter = try resp.iter();
    while (resp_iter.next()) |share| {
        const b: json.Shares = .{
            .name = slurm.parseCStr(share.name) orelse "",
            .parent = slurm.parseCStr(share.parent) orelse "",
            .effective_usage = .{
                .set = hasValue(share.usage_efctv),
                .number = share.usage_efctv,
            },
            .usage_normalized = .{
                .set = hasValue(share.usage_norm),
                .number = share.usage_norm,
            },
            .usage = share.usage_raw,
            .fairshare = .{
                .factor = .{
                    .set = hasValue(share.fs_factor),
                    .number = share.fs_factor,
                },
            },
            .type = if (share.isUserAssociation()) &.{"USER"} else &.{"ASSOCIATION"},
        };
        try self.parse(&b);
    }
}

pub const AssociationType = enum {
    association,
    user,
};

pub fn collectSlurmrestd(self: *Shares, allocator: Allocator) !void {
    const resp = try json.slurmrestd(json.SharesResponse, allocator);
    defer resp.deinit();
    try self.parseAll(resp.value.shares.shares);
}

pub fn collectCLI(self: *Shares, allocator: Allocator) !void {
    const resp = try cmd.runAndParse(json.SharesResponse, allocator, &.{ "sshare", "--json" });
    defer resp.deinit();
    try self.parseAll(resp.value.shares.shares);
}

fn parse(self: *Shares, share: *const json.Shares) !void {
    const assoc_type: AssociationType = blk: {
        if (share.type.len == 0) return;

        if (std.mem.eql(u8, share.type[0], "ASSOCIATION")) break :blk .association;
        if (std.mem.eql(u8, share.type[0], "USER")) break :blk .user;

        return;
    };

    const labels: Shares.Labels = switch (assoc_type) {
        .user => .{ .account = share.parent, .user = share.name },
        .association => .{ .account = share.name, .user = "" },
    };

    if (share.effective_usage.set) {
        try self.effective_usage.incrBy(labels, share.effective_usage.number);
    }
    if (share.usage_normalized.set) {
        try self.normalized_usage.incrBy(labels, share.usage_normalized.number);
    }
    if (assoc_type == .user and share.fairshare.factor.set) {
        try self.fairshare_factor.incrBy(labels, share.fairshare.factor.number);
    }
    try self.raw_usage.incrBy(labels, share.usage);
}

fn parseAll(self: *Shares, shares: []json.Shares) !void {
    for (shares) |share| {
        try parse(self, &share);
    }
}

//  const parsed = try std.json.parseFromSlice(
//      json.Shares,
//      allocator,
//      \\{
//      \\  "name": "root",
//      \\  "parent": "root",
//      \\  "user": 1,
//      \\  "effective_usage": {
//      \\      "set": true,
//      \\      "infinite": false,
//      \\      "number": 0.5
//      \\  },
//      \\  "usage_normalized": {
//      \\      "set": true,
//      \\      "infinite": false,
//      \\      "number": 0.2
//      \\  },
//      \\  "usage": 132
//      \\}
//  ,
//      .{.ignore_unknown_fields = true },
//  );
//  defer parsed.deinit();

//  const s = parsed.value;

//  try std.testing.expectEqualStrings("root", s.name);
