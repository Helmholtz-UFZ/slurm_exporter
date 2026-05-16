const std = @import("std");
const cli = @import("cli");
const log = std.log.scoped(.main);
const config = @import("config");
const Allocator = std.mem.Allocator;
const Registry = @import("Registry.zig");
const build_meta = @import("build.zig.zon");
const comptimePrint = std.fmt.comptimePrint;
const fatal = @import("util.zig").exit;

pub const app_name = "slurm-exporter";

const default_backend: Registry.Backend = if (config.backends.libslurm)
    .libslurm
else if (config.backends.cli)
    .cli
else
    .slurmrestd;

pub const Arguments = struct {
    collectors: []const u8 = "node,controller,shares,queue",
    web_listen_address: []const u8 = "127.0.0.1:5882",
    web_telemetry_path: []const u8 = "/metrics",
    version_info: bool = false,
    stdout: bool = false,
    backend: Registry.Backend = default_backend,
    list_backends: bool = false,
    backend_slurmrestd_options: Registry.Backend.SlurmrestdOptions = .{},
    backend_cli_options: Registry.Backend.CLIOptions = .{},

    pub const default: Arguments = .{};
};

pub fn run(arena: Allocator, arg_store: *Arguments, exec: cli.ExecFn) !void {
    var r: cli.AppRunner = try .init(arena);
    const opts = try options(arena, arg_store, &r);
    const app = cli.App{
        .command = cli.Command{
            .name = app_name,
            .options = try r.allocOptions(opts),
            .target = cli.CommandTarget{
                .action = cli.CommandAction{ .exec = exec },
            },
        },
        .version = build_meta.version,
    };
    return r.run(&app);
}

pub fn options(arena: Allocator, arg_store: *Arguments, r: *cli.AppRunner) ![]const cli.Option {
    const default_options: Arguments = .default;

    var opts: std.ArrayList(cli.Option) = .empty;
    defer opts.deinit(arena);

    const base_cli_options: []const cli.Option = &.{
        .{
            .long_name = "collectors.enable",
            .help =
                \\Which Collectors to enable.
                \\Available:
                ++ " " ++ default_options.collectors
                ++ " (default: all)"
                ,
            .value_ref = r.mkRef(&arg_store.collectors),
        },
        .{
            .long_name = "web.listen-address",
            .help = "Host and Port to listen on. " ++ comptimePrint("(default: {s})", .{default_options.web_listen_address}),
            .value_ref = r.mkRef(&arg_store.web_listen_address),
        },
        .{
            .long_name = "web.telemetry-path",
            .help = "Path under which the metrics should be exposed. " ++ comptimePrint("(default: {s})", .{default_options.web_telemetry_path}),
            .value_ref = r.mkRef(&arg_store.web_telemetry_path),
        },
        .{
            .long_name = "version",
            .short_alias = 'v',
            .help = "Show application version",
            .value_ref = r.mkRef(&arg_store.version_info),
        },
        .{
            .long_name = "stdout",
            .help = "Collect metrics once, print to stdout and exit. " ++ comptimePrint("(default: {})", .{default_options.stdout}),
            .value_ref = r.mkRef(&arg_store.stdout),
        },
        .{
            .long_name = "backend",
            .short_alias = 'b',
            .help =
                \\From which API the metrics should be collected.
                \\Available:
                ++ " " ++ config.backends_str ++ " (default: " ++ @tagName(default_backend) ++ ")"
                ,
            .value_ref = r.mkRef(&arg_store.backend),
            .value_name = "backend",
        },
    };
    try opts.appendSlice(arena, base_cli_options);

    if (config.backends.slurmrestd) {
        const backend_slurmrestd_options: []const cli.Option = &.{
            .{
                .long_name = "backend.slurmrestd.address",
                .help = "Address for contacting the slurmrestd. " ++ comptimePrint("(default: {s})", .{default_options.backend_slurmrestd_options.address}),
                .value_ref = r.mkRef(&arg_store.backend_slurmrestd_options.address),
            },
            .{
                .long_name = "backend.slurmrestd.plugin",
                .help = "Which data parser plugin to use for slurmrestd",
                .value_ref = r.mkRef(&arg_store.backend_slurmrestd_options.plugin),
            },
            .{
                .long_name = "backend.slurmrestd.base-path",
                .help =
                    \\Path that gets appended after the Address.
                    \\Useful when slurmrestd is behind a Proxy and not directly available under /
                    ,
                .value_ref = r.mkRef(&arg_store.backend_slurmrestd_options.base_path),
                .value_name = "path",
            },
            .{
                .long_name = "backend.slurmrestd.tls",
                .help =
                    \\Make the requests to slurmrestd with HTTPS instead
                    \\Primarily useful when slurmrestd is behind a Proxy like NGINX
                    ++ " " ++ comptimePrint("(default: {})", .{default_options.backend_slurmrestd_options.tls})
                    ,
                .value_ref = r.mkRef(&arg_store.backend_slurmrestd_options.tls),
            },
            .{
                .long_name = "backend.slurmrestd.jwt-file",
                .help =
                    \\File from which the JWT token should be read.
                    \\If not specified, it is read from the SLURM_JWT environment variable.
                    ,
                .value_ref = r.mkRef(&arg_store.backend_slurmrestd_options.jwt_file_path),
                .value_name = "path",
            },
        };
        try opts.appendSlice(arena, backend_slurmrestd_options);
    }
    if (config.backends.cli) {
        const backend_cli_options: []const cli.Option = &.{
            .{
                .long_name = "backend.cli.plugin",
                .help = "Which data parser plugin to use for the commands",
                .value_ref = r.mkRef(&arg_store.backend_cli_options.plugin),
            },
        };
        try opts.appendSlice(arena, backend_cli_options);
    }

    return opts.toOwnedSlice(arena);
}
