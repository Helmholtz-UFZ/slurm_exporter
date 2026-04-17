// Copyright (C) 2026 Helmholtz Centre for Environmental Research GmbH - UFZ
// SPDX-License-Identifier: GPL-3.0-or-later

const std = @import("std");
const slurm = @import("slurm");
const collectors = @import("collectors.zig");
const cli = @import("cli");
const Allocator = std.mem.Allocator;
const Registry = @import("Registry.zig");
const httpz = @import("httpz");
const build_meta = @import("build.zig.zon");

var rt: Runtime = undefined;
var registry: Registry = undefined;

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
                        \\Which Collectors to enable
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

pub fn shouldEnableCollector(name: []const u8) bool {
    const maybe_enabled = std.mem.containsAtLeast(u8, rt.cli_args.collectors, 1, name);
    if (!rt.cli_args.stdout) {
        switch (maybe_enabled) {
            true => std.debug.print("Enabled Collector: {s}\n", .{name}),
            else => {},
        }
    }
    return maybe_enabled;
}

fn run() !void {

    if (rt.cli_args.version_info) {
        std.debug.print("{s}\n", .{build_meta.version});
        return;
    }

    registry = .init(rt.allocator);
    defer registry.deinit();

    if (shouldEnableCollector("node")) try registry.register(collectors.Node);
    if (shouldEnableCollector("controller")) try registry.register(collectors.Controller);
    if (shouldEnableCollector("queue")) try registry.register(collectors.Queue);
    if (shouldEnableCollector("share")) try registry.register(collectors.Shares);

    switch (rt.cli_args.stdout) {
        true => try print_stdout(),
        false => try start_server(),
    }
}

fn print_stdout() !void {
    var buffer: [1024]u8 = undefined;
    var stdout = std.fs.File.stdout().writerStreaming(&buffer);

    const result = try registry.collect(rt.allocator);
    try result.write(&stdout.interface);

    try stdout.interface.flush();
}

fn start_server() !void {
    var server = try httpz.Server(void).init(rt.allocator, .{
        .address = .{ .addr = try .parseIpAndPort(rt.cli_args.web_listen_address)},
    }, {});
    defer {
        server.stop();
        server.deinit();
    }

    var router = try server.router(.{});
    router.get(rt.cli_args.web_telemetry_path, metrics, .{});

    std.debug.print("Metrics Endpoint is {s}\n", .{rt.cli_args.web_telemetry_path});
    std.debug.print("Listening on http://{s}\n", .{rt.cli_args.web_listen_address});
    try server.listen();
}

pub fn metrics(_: *httpz.Request, res: *httpz.Response) !void {
    const result = try registry.collect(res.arena);
    try result.write(res.writer());
}
