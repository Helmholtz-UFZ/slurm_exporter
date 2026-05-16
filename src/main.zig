// Copyright (C) 2026 Helmholtz Centre for Environmental Research GmbH - UFZ
// SPDX-License-Identifier: GPL-3.0-or-later

const std = @import("std");
const slurm = @import("slurm");
const cli = @import("cli.zig");
const Allocator = std.mem.Allocator;
const Registry = @import("Registry.zig");
const httpz = @import("httpz");
const build_meta = @import("build.zig.zon");
const log = std.log.scoped(.main);
const config = @import("config");
const json = @import("json.zig");

pub const std_options: std.Options = .{
    .logFn = logFn,
};

var rt: Runtime = undefined;
var registry: Registry = undefined;
pub const Runtime = struct {
    allocator: Allocator,
    cli_args: cli.Arguments = .{},

    pub fn init(allocator: Allocator) !Runtime {
        if (config.backends.libslurm) slurm.init(null);
        return .{
            .allocator = allocator,
        };
    }
};

pub fn main() !void {
    var arena: std.heap.ArenaAllocator = .init(std.heap.page_allocator);
    defer arena.deinit();

    rt = try .init(arena.allocator());
    return cli.run(rt.allocator, &rt.cli_args, run);
}

pub fn validateBackend() void {
    const backend = @tagName(rt.cli_args.backend);
    inline for (std.meta.fields(@TypeOf(config.backends))) |field| {
        if (std.mem.eql(u8, field.name, backend)) {
            const is_enabled = @field(config.backends, field.name);
            if (!is_enabled) {
                log.err("{s} is not compiled with {s} capabilites", .{cli.app_name, backend});
                log.err("Use a different backend, or recompile with -Dbackends={s}", .{backend});
                std.process.exit(1);
            }
        }
    }
}

fn run() !void {
    if (rt.cli_args.version_info) {
        std.debug.print("{s}\n", .{build_meta.version});
        return;
    }

    if (rt.cli_args.list_backends) {
        std.debug.print("{s}\n", .{config.backends_str});
        return;
    }

    validateBackend();

    registry = .{
        .backend = rt.cli_args.backend,
        .backend_options = switch (rt.cli_args.backend) {
            .cli => .{ .cli = rt.cli_args.backend_cli_options },
            .slurmrestd => .{ .slurmrestd = rt.cli_args.backend_slurmrestd_options },
            .libslurm => .{ .libslurm = {}},
        },
    };
    try registry.register(rt.allocator, rt.cli_args.collectors, rt.cli_args.stdout);

    switch (rt.cli_args.stdout) {
        true => try print(),
        false => try startServer(),
    }
}

fn print() !void {
    var buffer: [1024]u8 = undefined;
    var stdout = std.fs.File.stdout().writerStreaming(&buffer);

    const result = try registry.collect(rt.allocator);
    try result.write(&stdout.interface);

    try stdout.interface.flush();
}

fn startServer() !void {
    var server = try httpz.Server(void).init(rt.allocator, .{
        .address = .{ .addr = try .parseIpAndPort(rt.cli_args.web_listen_address)},
    }, {});
    defer {
        server.stop();
        server.deinit();
    }

    var router = try server.router(.{});
    router.get(rt.cli_args.web_telemetry_path, metrics, .{});

    log.info("Metrics Endpoint is {s}", .{rt.cli_args.web_telemetry_path});
    log.info("Listening on http://{s}", .{rt.cli_args.web_listen_address});
    try server.listen();
}

pub fn metrics(_: *httpz.Request, res: *httpz.Response) !void {
    const result = try registry.collect(res.arena);
    try result.write(res.writer());
}

pub fn logFn(
    comptime level: std.log.Level,
    comptime scope: @Type(.enum_literal),
    comptime format: []const u8,
    log_args: anytype,
) void {
    const scope_name = @tagName(scope);
    const level_prefix = comptime level.asText();
    const scope_prefix = if (scope == .default) ": " else "(" ++ scope_name ++ "): ";

    const fmt = level_prefix ++ scope_prefix ++ format ++ "\n";
    std.debug.print(fmt, log_args);
}
