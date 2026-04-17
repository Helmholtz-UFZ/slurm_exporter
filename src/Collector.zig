// Copyright (C) 2026 Helmholtz Centre for Environmental Research GmbH - UFZ
// SPDX-License-Identifier: GPL-3.0-or-later

const std = @import("std");
const utils = @import("util.zig");
const m = @import("metrics");

const Collector = @This();

ptr: *anyopaque,
vtable: *const VTable,

pub const VTable = struct {
    collect: *const fn (*anyopaque, allocator: std.mem.Allocator) anyerror!void,
    write: *const fn (*anyopaque, writer: *std.Io.Writer) anyerror!void,
    reset: *const fn (*anyopaque) void,
    deinit: *const fn (*anyopaque) void,
};

pub fn init(allocator: std.mem.Allocator, instance: anytype) !Collector {
    const T = @TypeOf(instance.*);
    const impl = Delegate(T);

    const ptr = try allocator.create(T);
    ptr.* = instance.*;

    return .{
      .ptr = ptr,
      .vtable = &.{
        .collect = impl.collect,
        .write = impl.write,
        .reset = impl.reset,
        .deinit = impl.deinit,
      },
    };
}

pub const Initializer = *const fn (std.mem.Allocator) anyerror!Collector;
pub fn initializer(comptime T: type) Initializer {
    return T.init;
}

pub fn collect(self: Collector, allocator: std.mem.Allocator) anyerror!void {
    try self.vtable.collect(self.ptr, allocator);
}

pub fn write(self: Collector, writer: *std.Io.Writer) anyerror!void {
    try self.vtable.write(self.ptr, writer);
}

pub fn reset(self: Collector) void {
    self.vtable.reset(self.ptr);
}

pub fn deinit(self: Collector) void {
    self.vtable.deinit(self.ptr);
}

fn CastPtr(comptime T: type, ptr: *anyopaque) *T {
    return @as(*T, @ptrCast(@alignCast(ptr)));
}

inline fn Delegate(comptime T: type) type {

    if (!@hasDecl(T, "collect")) {
        @compileError("You must implement a 'collect' method on Type: " ++ @typeName(T));
    }

    return struct {
        pub fn collect(pointer: *anyopaque, allocator: std.mem.Allocator) anyerror!void {
            try CastPtr(T, pointer).collect(allocator);
        }

        pub fn write(pointer: *anyopaque, writer: *std.Io.Writer) anyerror!void {
            const self: *T = CastPtr(T, pointer);
            switch (@hasDecl(T, "write")) {
                true => try self.write(writer),
                false => try m.write(self, writer),
            }
        }

        pub fn reset(pointer: *anyopaque ) void {
            switch (@hasDecl(T, "reset")) {
                true => CastPtr(T, pointer).reset(),
                false => {},
            }
        }

        pub fn deinit(pointer: *anyopaque ) void {
            const self: *T = CastPtr(T, pointer);
            switch (@hasDecl(T, "deinit")) {
                true => self.deinit(),
                false => utils.deinit(self),
            }
        }
    };
}

