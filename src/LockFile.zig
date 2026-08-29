/// A file-based locking mechanism for synchronizing operations between multiple processes
pub const LockFile = @This();

const builtin = @import("builtin");
const std = @import("std");
const Io = std.Io;

path: []const u8,
file: Io.File,
io: Io,

pub fn lock(io: Io, path: []const u8) !LockFile {
    const cwd: Io.Dir = .cwd();
    if (std.fs.path.dirname(path)) |dir| {
        try cwd.createDirPath(io, dir);
    }
    const file = try cwd.createFile(io, path, .{});
    errdefer {
        file.close(io);
        cwd.deleteFile(io, path) catch {};
    }

    try file.lock(io, .exclusive);

    // Write the current process ID to the lock file
    // This is helpful for debugging and allows other processes to detect stale locks
    const pid = switch (builtin.os.tag) {
        .windows => std.os.windows.GetCurrentProcessId(),
        .linux => std.os.linux.getpid(),
        .macos => std.c.getpid(),
        else => @compileError("todo"),
    };
    var pid_buffer: [40]u8 = undefined;
    const pid_text = try std.fmt.bufPrint(&pid_buffer, "{d}", .{pid});
    try file.writeStreamingAll(io, pid_text);
    try file.sync(io);

    return LockFile{
        .file = file,
        .path = path,
        .io = io,
    };
}

pub fn unlock(self: *LockFile) void {
    const io = self.io;
    self.file.unlock(io);
    self.file.close(io);
    Io.Dir.cwd().deleteFile(io, self.path) catch |err| switch (err) {
        error.FileNotFound => {},
        else => |e| std.debug.panic("failed to delete lock file '{s}' with {s}", .{ self.path, @errorName(e) }),
    };
}
