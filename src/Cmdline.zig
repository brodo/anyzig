//! Provides a platform abstraction for accessing cmdline args efficiently.
//! Only allocates memory on Windows, where the arguments have to be decoded
//! from WTF-16; on other platforms the argument vector is used directly.
const Cmdline = @This();

args: std.process.Args,
win32_slice: switch (builtin.os.tag) {
    .windows => []const [:0]const u8,
    else => void,
},

pub fn alloc(args: std.process.Args, allocator: std.mem.Allocator) !Cmdline {
    return .{
        .args = args,
        .win32_slice = if (builtin.os.tag == .windows) try args.toSlice(allocator) else {},
    };
}

pub fn free(self: Cmdline, allocator: std.mem.Allocator) void {
    if (builtin.os.tag == .windows) {
        allocator.free(self.win32_slice);
    }
}

pub fn len(self: Cmdline) usize {
    return switch (builtin.os.tag) {
        .windows => self.win32_slice.len,
        else => self.args.vector.len,
    };
}
pub fn arg(self: Cmdline, i: usize) [:0]const u8 {
    return switch (builtin.os.tag) {
        .windows => self.win32_slice[i],
        else => std.mem.span(self.args.vector[i]),
    };
}

pub const Optional = switch (builtin.os.tag) {
    .windows => ?Cmdline,
    else => void,
};
pub const optional: Optional = switch (builtin.os.tag) {
    .windows => null,
    else => {},
};

const builtin = @import("builtin");
const std = @import("std");
