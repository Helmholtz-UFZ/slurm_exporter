const std = @import("std");
const Parsed = std.json.Parsed;
const json = @import("json.zig");
const Registry = @import("Registry.zig");
const Options = Registry.Backend.SlurmrestdOptions;
const allocPrint = std.fmt.allocPrint;

pub fn get(comptime T: type, arena: std.mem.Allocator, options: Options) !Parsed(T) {
    var client = std.http.Client{ .allocator = arena };
    defer client.deinit();

    var body = std.Io.Writer.Allocating.init(arena);
    defer body.deinit();

    const url = try allocPrint(arena, "{f}/{s}", .{options.uri.?, T.endpoint});

    const response = try client.fetch(.{
        .extra_headers = &.{
//            .{ .name = "X-SLURM-USER-NAME", .value = "root" },
            .{ .name = "X-SLURM-USER-TOKEN", .value = options.jwt.? },
        },
        .method = .GET,
        .response_writer = &body.writer,
        .location = .{ .url = url },
        //      .headers = .{
        //          .accept_encoding = .{ .override = "application/json" },
        //      },
    });

    if (response.status != .ok) {
        @panic("TODO: handle errors");
    }

    return json.parse(T, arena, body.written());
}

//  var scanner = std.json.Scanner.initCompleteInput(allocator, body.written());
//  defer scanner.deinit();
//  var jd = std.json.Diagnostics{};
//  scanner.enableDiagnostics(&jd);
//  const parsed = std.json.parseFromTokenSource(T, allocator, &scanner, .{
//      .allocate = .alloc_always,
//      .parse_numbers = true,
//      .ignore_unknown_fields = true,
//  }) catch |err| {
//      std.debug.print("{s}\n", .{body.written()});
//      std.debug.print("{any} on line {d}\n", .{err, jd.line_number});
//      return err;
//  };
