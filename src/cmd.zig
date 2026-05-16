const std = @import("std");
const Parsed = std.json.Parsed;
const slurm = @import("slurm");
const json = @import("json.zig");
const AllocatingWriter = std.Io.Writer.Allocating;
const Registry = @import("Registry.zig");
const CLIOptions = Registry.Backend.CLIOptions;
const log = std.log.scoped(.cmd);

fn handleSpawnError(err: anytype, command: []const u8) !void {
    switch (err) {
        error.FileNotFound => log.err("Required Command {s} not found", .{command}),
        else => log.err("Unexpected failure executing {s}: {s}", .{command, @errorName(err)}),
    }
    return err;
}

pub fn run(allocator: std.mem.Allocator, argv: []const []const u8) !AllocatingWriter {
    var buf: [1024]u8 = undefined;

    var command: std.process.Child = .init(argv, allocator);
    command.stdin_behavior = .Ignore;
    command.stderr_behavior = .Pipe;
    command.stdout_behavior = .Pipe;

    command.spawn() catch |err| try handleSpawnError(err, argv[0]);

    const stdout = command.stdout.?;
    var stdout_reader = stdout.reader(&buf);
    var reader = &stdout_reader.interface;

    var line_writer: AllocatingWriter = .init(allocator);
    errdefer line_writer.deinit();

    _ = try reader.streamRemaining(&line_writer.writer);
    _ = command.wait() catch |err| try handleSpawnError(err, argv[0]);

    return line_writer;
}

pub fn runAndParse(comptime T: type, allocator: std.mem.Allocator, comptime argv: []const []const u8, options: CLIOptions) !Parsed(T) {
    var buf: [32]u8 = undefined;
    const json_flag = try std.fmt.bufPrint(&buf, "--json={s}", .{@tagName(options.plugin)});

    var writer = try run(allocator, argv ++ [_][]const u8{json_flag});
    defer writer.deinit();
    return json.parse(T, allocator, writer.written());
}
