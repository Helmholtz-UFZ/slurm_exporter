const std = @import("std");
const Parsed = std.json.Parsed;
const slurm = @import("slurm");
const json = @import("json.zig");
const AllocatingWriter = std.Io.Writer.Allocating;

pub fn run(allocator: std.mem.Allocator, argv: []const []const u8) !AllocatingWriter {
    var buf: [1024]u8 = undefined;

    var command: std.process.Child = .init(argv, allocator);
    command.stdin_behavior = .Ignore;
    command.stderr_behavior = .Pipe;
    command.stdout_behavior = .Pipe;

    try command.spawn();
    const stdout = command.stdout.?;
    var stdout_reader = stdout.reader(&buf);
    var reader = &stdout_reader.interface;

    var line_writer: AllocatingWriter = .init(allocator);
    errdefer line_writer.deinit();

    _ = try reader.streamRemaining(&line_writer.writer);
    _ = try command.wait();

    return line_writer;
}

pub fn runAndParse(comptime T: type, allocator: std.mem.Allocator, argv: []const []const u8) !Parsed(T) {
    var writer = try run(allocator, argv);
    defer writer.deinit();
    return json.parse(T, allocator, writer.written());
}
