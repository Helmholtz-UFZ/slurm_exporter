// Copyright (C) 2026 Helmholtz Centre for Environmental Research GmbH - UFZ
// SPDX-License-Identifier: GPL-3.0-or-later

const std = @import("std");
const m = @import("metrics");
const log = std.log.scoped(.registry);
const Registry = @This();
const Controller = @import("collectors/Controller.zig");
const Node = @import("collectors/Node.zig");
const Queue = @import("collectors/Queue.zig");
const Shares = @import("collectors/Shares.zig");
const config = @import("config");
const json = @import("json.zig");
const cmd = @import("cmd.zig");

pub const Backend = enum {
    libslurm,
    slurmrestd,
    cli,
};

pub fn typeNameLower(comptime T: type) []const u8 {
    var iter = std.mem.splitBackwardsScalar(u8, @typeName(T), '.');
    const name = iter.first();
    var buf: [name.len]u8 = undefined;
    const result = std.ascii.lowerString(&buf, name);
    return result;
}

pub const Collector = union(enum) {
    node: Node,
    controller: Controller,
    shares: Shares,
    queue: Queue,

    pub const fields = std.meta.fields(Collector);

    pub fn init(self: Collector, arena: std.mem.Allocator) !Collector {
        switch (self) {
            inline else => |v| {
                const T = @TypeOf(v);
                return @unionInit(Collector, typeNameLower(T), try T.init(arena));
            }
        }
    }

    pub fn collect(self: *Collector, arena: std.mem.Allocator, backend: Backend) !void {
        switch (self.*) {
            inline else => |*v| switch (backend) {
                .libslurm => if (config.backends.libslurm) try v.collect(arena),
                .slurmrestd => if (config.backends.slurmrestd) try v.collectSlurmrestd(arena),
                .cli => if (config.backends.cli) try v.collectCLI(arena),
            },
        }
    }

    pub fn write(self: Collector, writer: *std.Io.Writer) !void {
        switch (self) {
            inline else => |v| return m.write(&v, writer),
        }
    }

    pub fn checkCLICommand(self: Collector, arena: std.mem.Allocator) !void {
        switch (self) {
            inline else => |v| {
                const T = @TypeOf(v);
                _ = cmd.run(arena, &.{ T.cli_command, "--help" }) catch |e| switch(e) {
                    error.FileNotFound => {
                        log.err("Required command {s} was not found for {s}", .{T.cli_command, @typeName(T)});
                        std.process.exit(1);
                    },
                    else => return e,
                };
            },
        }
    }
};

pub const CollectionResult = struct {
    inner: std.ArrayList(Collector) = .empty,

    pub fn write(self: *const CollectionResult, writer: *std.Io.Writer) !void {
        for (self.inner.items) |result| {
            try result.write(writer);
        }
    }

    pub fn append(self: *CollectionResult, allocator: std.mem.Allocator, item: Collector) !void {
        try self.inner.append(allocator, item);
    }
};


const opts: m.RegistryOpts = .{
    .prefix = "slurm_",
};

enabled_collectors: std.ArrayList(Collector) = .empty,
backend: Backend,
//slurmrestd_options: json.SlurmrestdOptions,

pub fn register(self: *Registry, allocator: std.mem.Allocator, names: []const u8, stdout: bool) !void {
    const names_lower = try std.ascii.allocLowerString(allocator, names);
    const collectors = Collector.fields;

    var iter = std.mem.splitScalar(u8, names_lower, ',');
    next: while (iter.next()) |item| {
        inline for (collectors) |field| {
            if (std.mem.eql(u8, item, field.name)) continue :next;
        }

        log.err("Invalid Collector: {s}", .{item});
        std.process.exit(1);
    }

    inline for (collectors) |field| {
        if (std.mem.containsAtLeast(u8, names_lower, 1, field.name)) {
            try self.enabled_collectors.append(allocator, @unionInit(Collector, field.name, undefined));
        }
    }

    if (self.backend == .cli and config.backends.cli) {
        for (self.enabled_collectors.items) |c| {
            try c.checkCLICommand(allocator);
        }
    }

    if (!stdout) {
        log.info("Enabled Collectors: {s}", .{names_lower});
    }
}

pub fn collect(self: *Registry, arena: std.mem.Allocator) !CollectionResult {
    var result: CollectionResult = .{};
    for (self.enabled_collectors.items) |item| {
        var collector: Collector = try .init(item, arena);
        try collector.collect(arena, self.backend);
        try result.append(arena, collector);
    }
    return result;
}
