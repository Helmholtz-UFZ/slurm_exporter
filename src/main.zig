// Copyright (C) 2026 Helmholtz Centre for Environmental Research GmbH - UFZ
// SPDX-License-Identifier: GPL-3.0-or-later

const std = @import("std");
const slurm = @import("slurm");
const controller =  @import("controller.zig");
const node =  @import("node.zig");
const queue =  @import("queue.zig");
const shares =  @import("shares.zig");
const cli = @import("cli");
const Allocator = std.mem.Allocator;
const Collector = @import("Collector.zig");
const Registry = @import("Registry.zig");
const httpz = @import("httpz");

var rt: Runtime = undefined;
var registry: Registry = undefined;

pub const Runtime = struct {
    allocator: Allocator,
    cli_args: struct {
        collectors: []const u8 = "node,controller,share,queue",
    } = .{},

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

    var r = try cli.AppRunner.init(rt.allocator);

    const app = cli.App{
        .command = cli.Command{
            .name = "slurm-exporter",
            .options = try r.allocOptions(&.{
                .{
                    .long_name = "collectors.enable",
                    .help = "Which Collectors to enable",
                    .value_ref = r.mkRef(&rt.cli_args.collectors),
                },
            }),
            .target = cli.CommandTarget{
                .action = cli.CommandAction{ .exec = run },
            },
        },
    };

    return r.run(&app);
}

pub fn shouldEnableCollector(name: []const u8) bool {
    return if (std.mem.containsAtLeast(u8, rt.cli_args.collectors, 1, name))
        true
    else
        false;
}

fn run() !void {
    registry = .init(rt.allocator);
    defer registry.deinit();

    if (shouldEnableCollector("node")) try registry.register(node.Metrics);
    if (shouldEnableCollector("controller")) try registry.register(controller.Metrics);
    if (shouldEnableCollector("queue")) try registry.register(queue.Metrics);
    if (shouldEnableCollector("share")) try registry.register(shares.Metrics);

    var server = try httpz.Server(void).init(rt.allocator, .{
        .address = .localhost(5882),
    }, {});
    defer {
        server.stop();
        server.deinit();
    }

    var router = try server.router(.{});
    router.get("/metrics", metrics, .{});

    try server.listen();

}

pub fn metrics(_: *httpz.Request, res: *httpz.Response) !void {
    registry.reset();
    try registry.collect();
    try registry.write(res.writer());
}
