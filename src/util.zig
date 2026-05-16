// Copyright (C) 2026 Helmholtz Centre for Environmental Research GmbH - UFZ
// SPDX-License-Identifier: GPL-3.0-or-later

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const mebi_to_bytes = std.math.pow(u32, 2, 20);
pub const MICROSECONDS = 1000000.0;

pub fn microToSeconds(comptime T: type, value: u64) T {
    return @as(T, @floatFromInt(value)) / MICROSECONDS;
}

pub fn exit(logFn: anytype, comptime fmt: []const u8, args: anytype) noreturn {
    defer std.process.exit(1);
    logFn(fmt, args);
}

pub fn typeNameLower(comptime T: type) []const u8 {
    const orig = @typeName(T);
    var iter = std.mem.splitBackwardsScalar(u8, orig, '.');
    const name = iter.first();
    var buf: [orig.len]u8 = undefined;
    const result = std.ascii.lowerString(&buf, name);
    return result;
}

pub fn uidToName(allocator: Allocator, uid: std.posix.uid_t) ![:0]const u8 {
    //  if (job.user_name) |uname| {
    //      return std.mem.span(uname);
    //  }

    const passwd_info = std.c.getpwuid(uid);
    if (passwd_info) |pwd| {
        if (pwd.name) |name| {
            const pwd_name = std.mem.span(name);
            return try allocator.dupeZ(u8, pwd_name);
        }
    }

    return try std.fmt.allocPrintSentinel(allocator, "{d}", .{uid}, 0);
}

pub fn strToSlice(data: []const u8, allocator: std.mem.Allocator, comptime delim: u8) ![]const []const u8 {
    var iter = std.mem.splitScalar(u8, data, delim);
    var buf: std.ArrayList([]const u8) = .empty;
    while (iter.next()) |item| {
        try buf.append(allocator, item);
    }
    return buf.toOwnedSlice(allocator);
}

pub fn slurmStrToSlice(data: ?[*:0]const u8, allocator: std.mem.Allocator, comptime delim: u8) ![]const []const u8 {
    const str = if (data) |d| std.mem.span(d) else "";
    return strToSlice(str, allocator, delim);
}

pub fn asciiLowerSlice(allocator: std.mem.Allocator, data: []const []const u8, comptime size: usize) !@TypeOf(data) {
    // Assume that if the first char is already lowercase, the rest is too.
    if (data.len > 0 and std.ascii.isLower(data[0][0])) return data;

    var buf: [size][]const u8 = undefined;
    var idx: usize = 0;
    for (data) |item| {
        buf[idx] = try std.ascii.allocLowerString(allocator, item);
        idx += 1;
    }
    return allocator.dupe([]const u8, buf[0..idx]);
}
