// Copyright (C) 2026 Helmholtz Centre for Environmental Research GmbH - UFZ
// SPDX-License-Identifier: GPL-3.0-or-later

const std = @import("std");
const Collector = @import("Collector.zig");
const m = @import("metrics");
const Registry = @This();

const opts: m.RegistryOpts = .{
    .prefix = "slurm_",
};

const Entry = struct {
    name: []const u8,
    init: Collector.Initializer,
};

allocator: std.mem.Allocator,
entries: std.ArrayList(Entry) = .empty,

pub fn init(allocator: std.mem.Allocator) Registry {
    return .{
        .allocator = allocator,
    };
}

pub fn deinit(self: *Registry) void {
    self.entries.deinit(self.allocator);
}

pub fn register(self: *Registry, comptime T: type) !void {
    const entry: Entry = .{
        .name = @typeName(T),
        .init = Collector.initializer(T),
    };
    try self.entries.append(self.allocator, entry);
}

pub fn collect(self: *Registry, arena: std.mem.Allocator) !CollectionResult {
    var result: CollectionResult = .{};
    for (self.entries.items) |entry| {
        const collector: Collector = try entry.init(arena);
        try collector.collect(arena);
        try result.append(arena, collector);
    }
    return result;
}

pub const CollectionResult = struct {
    inner: std.ArrayList(Collector) = .empty,

    pub fn write(self: *const CollectionResult, writer: *std.Io.Writer) !void {
        for (self.inner.items) |collector| {
            try collector.write(writer);
        }
    }

    pub fn append(self: *CollectionResult, arena: std.mem.Allocator, item: Collector) !void {
        return self.inner.append(arena, item);
    }
};
