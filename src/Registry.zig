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

pub const Backend = enum {
    libslurm,
    slurmrestd,
    cli,
};

pub fn Initializer(comptime T: type) type {
    return ?*const @TypeOf(T.init);
}

pub const Collectors = struct {
    node: Initializer(Node) = Node.init,
    controller: Initializer(Controller) = Controller.init,
    share: Initializer(Shares) = Shares.init,
    queue: Initializer(Queue) = Queue.init,

    pub const Result = struct {
        node: ?Node = null,
        controller: ?Controller = null,
        share: ?Shares = null,
        queue: ?Queue = null,

        pub fn write(self: *const Result, writer: *std.Io.Writer) !void {
            inline for (std.meta.fields(Result)) |field| {
                if (@field(self, field.name)) |collector| {
                    try m.write(&collector, writer);
                }
            }
        }
    };
};

const opts: m.RegistryOpts = .{
    .prefix = "slurm_",
};

collectors: Collectors = .{},
backend: Backend,
//slurmrestd_options: json.SlurmrestdOptions,

pub fn register(self: *Registry, allocator: std.mem.Allocator, names: []const u8, stdout: bool) !void {
    const names_lower = try std.ascii.allocLowerString(allocator, names);
    const collectors = std.meta.fields(Collectors);

    var iter = std.mem.splitScalar(u8, names_lower, ',');
    next: while (iter.next()) |item| {
        inline for (collectors) |field| {
            if (std.mem.eql(u8, item, field.name)) continue :next;
        }

        log.err("Invalid Collector: {s}", .{item});
        std.process.exit(1);
    }

    inline for (collectors) |field| {
        if (!std.mem.containsAtLeast(u8, names_lower, 1, field.name)) {
            @field(self.collectors, field.name) = null;
        }
    }

    if (!stdout) {
        log.info("Enabled Collectors: {s}", .{names_lower});
    }
}

pub fn collect(self: *Registry, arena: std.mem.Allocator) !Collectors.Result {
    var result: Collectors.Result = .{};

    inline for (std.meta.fields(Collectors)) |field| {
        if (@field(self.collectors, field.name)) |collectorInit| {
            var collector = try collectorInit(arena);
            switch (self.backend) {
                .libslurm => if (config.backends.libslurm) try collector.collect(arena),
                .slurmrestd => if (config.backends.slurmrestd) try collector.collectSlurmrestd(arena),
                .cli => if (config.backends.cli) try collector.collectCLI(arena),
            }
            @field(result, field.name) = collector;
        }
    }
    return result;
}
