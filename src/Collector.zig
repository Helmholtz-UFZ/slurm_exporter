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

fn noop(self: *anyopaque) void {
    _ = self;
}

pub fn init(ptr: anytype) Collector {
    const T = @TypeOf(ptr);
    const ptr_info = @typeInfo(T);

    const gen = struct {
      pub fn collect(pointer: *anyopaque, allocator: std.mem.Allocator) anyerror!void {
        const self: T = @ptrCast(@alignCast(pointer));
        return ptr_info.@"pointer".child.collect(self, allocator);
      }

      pub fn write(pointer: *anyopaque, writer: *std.Io.Writer) anyerror!void {
        const self: T = @ptrCast(@alignCast(pointer));
        return ptr_info.@"pointer".child.write(self, writer);
      }

      pub fn reset(pointer: *anyopaque ) void {
        const self: T = @ptrCast(@alignCast(pointer));
        ptr_info.@"pointer".child.reset(self);
      }

      pub fn deinit(pointer: *anyopaque ) void {
        const self: T = @ptrCast(@alignCast(pointer));
        ptr_info.@"pointer".child.deinit(self);
      }

      pub fn defaultDeinit(pointer: *anyopaque ) void {
        const self: T = @ptrCast(@alignCast(pointer));
        utils.deinit(self);
      }

      pub fn defaultWrite(pointer: *anyopaque, writer: *std.Io.Writer) anyerror!void {
        const self: T = @ptrCast(@alignCast(pointer));
        return m.write(self, writer);
      }

    };

    return .{
      .ptr = ptr,
      .vtable = &.{
        .collect = gen.collect,
        .write = switch (@hasDecl(ptr_info.@"pointer".child, "write")) {
            true => gen.write,
            false => gen.defaultWrite,
        },
        .reset = switch (@hasDecl(ptr_info.@"pointer".child, "reset")) {
            true => gen.reset,
            false => noop,
        },
        .deinit = switch (@hasDecl(ptr_info.@"pointer".child, "deinit")) {
            true => gen.deinit,
            false => gen.defaultDeinit,
        },
      },
    };
}
