// Copyright (C) 2026 Helmholtz Centre for Environmental Research GmbH - UFZ
// SPDX-License-Identifier: GPL-3.0-or-later

const std = @import("std");
const slurm = @import("slurm");
const cli = @import("cli");
const Allocator = std.mem.Allocator;
const Registry = @import("Registry.zig");
const httpz = @import("httpz");
const build_meta = @import("build.zig.zon");
const log = std.log.scoped(.main);

pub const std_options: std.Options = .{
    .logFn = logFn,
};

var rt: Runtime = undefined;
var registry: Registry = .{};

const CliOptions = struct {
    collectors: []const u8 = "node,controller,share,queue",
    web_listen_address: []const u8 = "127.0.0.1:5882",
    web_telemetry_path: []const u8 = "/metrics",
    version_info: bool = false,
    stdout: bool = false,
};

pub const Runtime = struct {
    allocator: Allocator,
    cli_args: CliOptions = .{},

    pub fn init(allocator: Allocator) !Runtime {
        slurm.init(null);
        return .{
            .allocator = allocator,
        };
    }
};

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    rt = try .init(allocator);

    var r: cli.AppRunner = try .init(rt.allocator);

    const default_cli_options: CliOptions = .{};

    const app = cli.App{
        .command = cli.Command{
            .name = "slurm-exporter",
            .options = try r.allocOptions(&.{
                .{
                    .long_name = "collectors.enable",
                    .help =
                        \\Which Collectors to enable. All are enabled by default
                        \\Available:
                        ++ " " ++ default_cli_options.collectors
                        ,
                    .value_ref = r.mkRef(&rt.cli_args.collectors),
                },
                .{
                    .long_name = "web.listen-address",
                    .help = "Host and Port to listen on. Default is " ++ default_cli_options.web_listen_address,
                    .value_ref = r.mkRef(&rt.cli_args.web_listen_address),
                },
                .{
                    .long_name = "web.telemetry-path",
                    .help = "Path under which the metrics should be exposed. Default is " ++ default_cli_options.web_telemetry_path,
                    .value_ref = r.mkRef(&rt.cli_args.web_telemetry_path),
                },
                .{
                    .long_name = "version",
                    .help = "Show application version",
                    .value_ref = r.mkRef(&rt.cli_args.version_info),
                },
                .{
                    .long_name = "stdout",
                    .help = "Collect metrics once, print to stdout and exit",
                    .value_ref = r.mkRef(&rt.cli_args.stdout),
                },
            }),
            .target = cli.CommandTarget{
                .action = cli.CommandAction{ .exec = run },
            },
        },
        .version = build_meta.version,
    };

    return r.run(&app);
}

fn run() !void {
    if (rt.cli_args.version_info) {
        std.debug.print("{s}\n", .{build_meta.version});
        return;
    }

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
    const scope_name = switch (scope) {
        .main, .registry => @tagName(scope),
        else => return,
    };

    const level_prefix = comptime level.asText();
    const scope_prefix = if (scope == .default) ": " else "(" ++ scope_name ++ "): ";

    const fmt = level_prefix ++ scope_prefix ++ format ++ "\n";
    std.debug.print(fmt, log_args);
}
