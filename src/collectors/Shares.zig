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

pub fn collect(self: *Shares, allocator: Allocator) !void {
    _ = allocator;
    var resp = try slurm.db.association.loadSharesAll();
    defer resp.deinit();

    var resp_iter = try resp.iter();
    while (resp_iter.next()) |share| {
        const is_user_assoc = share.isUserAssociation();
        const account, const user = if (is_user_assoc)
            .{slurm.parseCStr(share.parent) orelse "", slurm.parseCStr(share.name) orelse ""}
        else
            .{slurm.parseCStr(share.name) orelse continue, ""};

        const labels: Shares.Labels = .{
            .account = account,
            .user = user,
        };
        try self.effective_usage.incrBy(labels, share.usage_efctv);
        if (share.usage_norm != NoValue.u32) {
            try self.normalized_usage.incrBy(labels, share.usage_norm);
        }
        if (is_user_assoc) {
            try self.fairshare_factor.incrBy(labels, share.fs_factor);
        }
        try self.raw_usage.incrBy(labels, share.usage_raw);
    }
}

pub const AssociationType = enum {
    association,
    user,
};

pub fn collect_slurmrestd(self: *Shares, allocator: Allocator) !void {
    const shares_resp = try json.get(json.SharesResponse, allocator);
    defer shares_resp.deinit();

    for (shares_resp.value.shares.shares) |share| {
        const assoc_type: AssociationType = blk: {
            if (share.@"type".len == 0) continue;

            if (std.mem.eql(u8, share.type[0], "ASSOCIATION")) break :blk .association;
            if (std.mem.eql(u8, share.type[0], "USER")) break :blk .user;

            continue;
        };

        const account, const user = switch (assoc_type) {
            .user => .{share.parent, share.name},
            .association => .{share.name, ""},
        };

        const labels: Shares.Labels = .{
            .account = account,
            .user = user,
        };

        try self.effective_usage.incrBy(labels, share.effective_usage.number);
        if (share.usage_normalized.set) {
            try self.normalized_usage.incrBy(labels, share.usage_normalized.number);
        }
        if (assoc_type == .user and share.fairshare.factor.set) {
            try self.fairshare_factor.incrBy(labels, share.fairshare.factor.number);
        }
        try self.raw_usage.incrBy(labels, share.usage);
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
