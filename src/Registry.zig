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
const allocPrint = std.fmt.allocPrint;

pub const Backend = enum {
    libslurm,
    slurmrestd,
    cli,

    pub const CLIOptions = struct {
        plugin: json.PluginType = .@"v0.0.44",
    };

    pub const SlurmrestdOptions = struct {
        address: []const u8 = "127.0.0.1:6820",
        plugin: json.PluginType = .@"v0.0.44",
        endpoint: ?[]const u8 = null,
        jwt_file_path: ?[]const u8 = null,
        tls: bool = false,

        // Internal
        jwt: ?[]const u8 = null,
        uri: ?std.Uri = null,

        fn getJWT(arena: std.mem.Allocator) ![]const u8 {
            if (!std.process.hasEnvVarConstant("SLURM_JWT")) {
                log.err("Unable to get SLURM_JWT env var", .{});
                std.process.exit(1);
            }
            const jwt = try std.process.getEnvVarOwned(arena, "SLURM_JWT");
            return jwt;
        }

        fn parseURI(self: *SlurmrestdOptions, arena: std.mem.Allocator) !std.Uri {
            const endpoint = if (self.endpoint) |e|
                try allocPrint(arena, "/{s}", .{e})
            else
                "";

            const protocol = if (self.tls) "https" else "http";

            const url = try allocPrint(arena, "{s}://{s}{s}/slurm/{s}", .{
                protocol,
                self.address,
                endpoint,
                @tagName(self.plugin),
            });

            return .parse(url);
        }

        pub fn parse(self: *SlurmrestdOptions, arena: std.mem.Allocator) !void {
            self.uri = try self.parseURI(arena);
            log.info("Base URI for slurmrestd is: {f}", .{self.uri.?});

            self.jwt = try getJWT(arena);
        }
    };

    pub const Options = union(enum) {
        cli: CLIOptions,
        slurmrestd: SlurmrestdOptions,
        libslurm: void,
    };
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

    pub fn collect(self: *Collector, arena: std.mem.Allocator, backend: Backend, options: Backend.Options) !void {
        switch (self.*) {
            inline else => |*v| switch (backend) {
                .libslurm => if (config.backends.libslurm) try v.collect(arena),
                .slurmrestd => if (config.backends.slurmrestd) try v.collectSlurmrestd(arena, options.slurmrestd),
                .cli => if (config.backends.cli) try v.collectCLI(arena, options.cli),
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
                // TODO: check if the commands actually support the --json flag
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
backend_options: Backend.Options,
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

    if (self.backend == .slurmrestd and config.backends.slurmrestd) {
        try self.backend_options.slurmrestd.parse(allocator);
    }

    if (!stdout) {
        log.info("Enabled Collectors: {s}", .{names_lower});
    }
}

pub fn collect(self: *Registry, arena: std.mem.Allocator) !CollectionResult {
    var result: CollectionResult = .{};
    for (self.enabled_collectors.items) |item| {
        var collector: Collector = try .init(item, arena);
        try collector.collect(arena, self.backend, self.backend_options);
        try result.append(arena, collector);
    }
    return result;
}
