// Copyright (C) 2026 Helmholtz Centre for Environmental Research GmbH - UFZ
// SPDX-License-Identifier: GPL-3.0-or-later

const std = @import("std");
const Allocator = std.mem.Allocator;

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

pub fn deinit(metrics: anytype) void {
    const S = @typeInfo(@TypeOf(metrics)).pointer.child;
    const fields = @typeInfo(S).@"struct".fields;

    inline for (fields) |f| {
        switch (@typeInfo(f.type)) {
            .@"union" => {
                const h = @constCast(&@field(metrics, f.name));
                switch (h.*) {
                   .noop => {},
                   .impl => |*impl| {
                        if (@hasDecl(@TypeOf(impl.*), "deinit")) {
                            impl.deinit();
                        }
                   }
                }
            },
            else => {},
        }
    }
}

pub fn resetSingle(metrics: anytype) void {
    const T = @TypeOf(metrics.impl);

    if (@hasField(T, "values")) {
        var it = metrics.impl.values.iterator();
        while (it.next()) |kv| {
            const InnerT = @TypeOf(kv.value_ptr.*);
            if (@hasField(InnerT, "value")) {
                kv.value_ptr.value = 0;
            } else if (@hasField(InnerT, "count")) {
                kv.value_ptr.count = 0;
            }
        }
    } else if (@hasField(T, "value")) {
        metrics.impl.value = 0;
    } else if (@hasField(T, "count")) {
        metrics.impl.count = 0;
    }
}

pub fn reset(metrics: anytype) void {
    const T = @TypeOf(metrics);
    const S = @typeInfo(T).pointer.child;
    const fields = @typeInfo(S).@"struct".fields;

    inline for (fields) |f| {
        switch (@typeInfo(f.type)) {
            .@"union" => {
                resetSingle(@constCast(&@field(metrics, f.name)));
            },
            else => {},
        }
    }
}
