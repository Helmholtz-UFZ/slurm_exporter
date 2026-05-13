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
const config = @import("config");
const json = @import("json.zig");
const comptimePrint = std.fmt.comptimePrint;

pub const std_options: std.Options = .{
    .logFn = logFn,
};

var rt: Runtime = undefined;
var registry: Registry = undefined;
const default_backend: Registry.Backend = if (config.backends.libslurm)
    .libslurm
else if (config.backends.cli)
    .cli
else
    .slurmrestd;

const CliOptions = struct {
    collectors: []const u8 = "node,controller,share,queue",
    web_listen_address: []const u8 = "127.0.0.1:5882",
    web_telemetry_path: []const u8 = "/metrics",
    version_info: bool = false,
    stdout: bool = false,
    backend: Registry.Backend = default_backend,
    list_backends: bool = false,
    web_slurmrestd_address: []const u8 = "127.0.0.1:6820",
    web_slurmrestd_plugin: json.PluginType = .@"v0.0.44",
};

pub const Runtime = struct {
    allocator: Allocator,
    cli_args: CliOptions = .{},

    pub fn init(allocator: Allocator) !Runtime {
        if (config.backends.libslurm) slurm.init(null);
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

    var options: std.ArrayList(cli.Option) = .empty;
    defer options.deinit(rt.allocator);

    const base_cli_options: []const cli.Option = &.{
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
            .short_alias = 'v',
            .help = "Show application version",
            .value_ref = r.mkRef(&rt.cli_args.version_info),
        },
        .{
            .long_name = "stdout",
            .help = "Collect metrics once, print to stdout and exit. Default is " ++ comptimePrint("{}", .{default_cli_options.stdout}),
            .value_ref = r.mkRef(&rt.cli_args.stdout),
        },
        .{
            .long_name = "collectors.backend",
            .help = "From which API the Metrics should be gathered. Default is " ++ @tagName(default_backend),
            .value_ref = r.mkRef(&rt.cli_args.backend),
        },
        .{
            .long_name = "list-backends",
            .help = "Show available Backends that can be used.",
            .value_ref = r.mkRef(&rt.cli_args.list_backends),
        },
    };

    try options.appendSlice(rt.allocator, base_cli_options);
    if (config.backends.slurmrestd) {
        const slurmrestd_cli_options: []const cli.Option = &.{
            .{
                .long_name = "web.slurmrestd.address",
                .help = "Address for contacting the slurmrestd",
                .value_ref = r.mkRef(&rt.cli_args.web_slurmrestd_address),
            },
            .{
                .long_name = "web.slurmrestd.plugin",
                .help = "Which data parser plugin to use",
                .value_ref = r.mkRef(&rt.cli_args.web_slurmrestd_plugin),
            },
        };
        try options.appendSlice(rt.allocator, slurmrestd_cli_options);
    }

    const app = cli.App{
        .command = cli.Command{
            .name = "slurm-exporter",
            .options = try r.allocOptions(try options.toOwnedSlice(rt.allocator)),
            .target = cli.CommandTarget{
                .action = cli.CommandAction{ .exec = run },
            },
        },
        .version = build_meta.version,
    };

    return r.run(&app);
}

pub fn validateBackend() void {
    const backend = @tagName(rt.cli_args.backend);
    inline for (std.meta.fields(@TypeOf(config.backends))) |field| {
        if (std.mem.eql(u8, field.name, backend)) {
            const is_enabled = @field(config.backends, field.name);
            if (!is_enabled) {
                log.err("slurm-exporter is not compiled with {s} capabilites", .{backend});
                log.err("Use a different backend, or recompile with -Dbackends={s}", .{backend});
                std.process.exit(1);
            }
        }

        // TODO: If the backend is .cli or .slurmrestd, check if Slurm is
        // compiled with JSON support, and whether we can find all binaries. If
        // not, we can fail immediately.
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

    registry = .{ .backend = rt.cli_args.backend };
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
