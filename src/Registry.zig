// Copyright (C) 2026 Helmholtz Centre for Environmental Research GmbH - UFZ
// SPDX-License-Identifier: GPL-3.0-or-later

const std = @import("std");
const Collector = @import("Collector.zig");
const m = @import("metrics");
const Registry = @This();

const opts: m.RegistryOpts = .{
    .prefix = "slurm_",
};

allocator: std.mem.Allocator,
collectors: std.ArrayList(Collector) = .empty,

pub fn init(allocator: std.mem.Allocator) Registry {
    return .{
        .allocator = allocator,
    };
}

pub fn deinit(self: *Registry) void {
    for (self.collectors.items) |collector| {
        collector.deinit();
    }
}

pub fn register(self: *Registry, comptime T: type) !void {
    const ptr = try self.allocator.create(T);
    ptr.* = .init(self.allocator, opts);
    try self.collectors.append(self.allocator, .init(ptr));
}


pub fn reset(self: *Registry) void {
    for (self.collectors.items) |collector| {
        collector.reset();
    }
}

pub fn collect(self: *Registry) !void {
    for (self.collectors.items) |collector| {
        try collector.collect(self.allocator);
    }
}

pub fn write(self: *Registry, writer: *std.Io.Writer) !void {
    for (self.collectors.items) |collector| {
        try collector.write(writer);
    }
}
