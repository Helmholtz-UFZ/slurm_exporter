// Copyright (C) 2026 Helmholtz Centre for Environmental Research GmbH - UFZ
// SPDX-License-Identifier: GPL-3.0-or-later

const std = @import("std");
const slurm = @import("slurm");
const m = @import("metrics");
const utils = @import("../util.zig");
const Shares = @This();
const Allocator = std.mem.Allocator;
const Collector = @import("../Collector.zig");

const Labels = struct {
    account: []const u8,
};

effective_usage: EffectiveUsage,

const EffectiveUsage = m.GaugeVec(f64, Labels);

pub fn init(allocator: Allocator) !Collector {
    const shares: Shares = .{
        .effective_usage = try .init(
            allocator,
            "slurm_account_effective_usage",
            .{ .help = "Effective Usage" },
            .{},
        ),
    };
    return .init(allocator, &shares);
}

pub fn reset(self: *Shares) void {
    utils.reset(self);
}

pub fn collect(self: *Shares, allocator: Allocator) !void {
    _ = allocator;
    var resp = try slurm.db.association.loadSharesAll();
    defer resp.deinit();

    var resp_iter = try resp.iter();
    while (resp_iter.next()) |share| {
        if (share.isUserAssociation()) continue;

        const account = slurm.parseCStr(share.name) orelse continue;

        const labels: Labels = .{
            .account = account
        };

        try self.effective_usage.incrBy(labels, share.usage_efctv);
    }
}
