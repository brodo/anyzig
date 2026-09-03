const builtin = @import("builtin");
const std = @import("std");
const Io = std.Io;

pub fn main(init: std.process.Init) !u8 {
    const io = init.io;
    const arena = init.arena.allocator();
    const all_args = try init.minimal.args.toSlice(arena);

    const input_dir = all_args[1];
    const output_dir = all_args[2];
    const options = all_args[3];
    const exe_index = 4;

    if (std.mem.eql(u8, options, "nosetup")) {} else if (std.mem.eql(u8, options, "badhash")) {
        @panic("todo");
    } else {
        std.debug.panic("todo: support setup options '{s}'", .{options});
    }
    
    const cwd_path = try std.process.currentPathAlloc(io, arena);
    const argv = try arena.alloc([]const u8, all_args.len - exe_index);
    for (argv, all_args[exe_index..]) |*dest, arg| {
        dest.* = if (std.mem.indexOfAny(u8, arg, "/\\") != null and !std.fs.path.isAbsolute(arg))
            try std.fs.path.resolve(arena, &.{ cwd_path, arg })
        else
            arg;
    }

    const cwd: Io.Dir = .cwd();
    try cwd.deleteTree(io, output_dir);
    try cwd.createDir(io, output_dir, .default_dir);

    if (std.mem.eql(u8, input_dir, "--no-input")) {
        //
    } else {
        try copyDir(arena, io, input_dir, output_dir, input_dir, output_dir);
    }

    try std.process.setCurrentPath(io, output_dir);
    if (builtin.os.tag == .windows) {
        var child = try std.process.spawn(io, .{ .argv = argv });
        const result = try child.wait(io);
        switch (result) {
            .exited => |code| return code,
            inline else => |sig, tag| {
                std.log.err("zig process terminated from {s} with {any}", .{ @tagName(tag), sig });
                return 0xff;
            },
        }
    } else {
        const err = std.process.replace(io, .{ .argv = argv });
        std.log.err("exec '{s}' failed with {s}", .{ argv[0], @errorName(err) });
        return 0xff;
    }
}

fn copyDir(
    allocator: std.mem.Allocator,
    io: Io,
    in_root: []const u8,
    out_root: []const u8,
    in_path: []const u8,
    out_path: []const u8,
) !void {
    const cwd: Io.Dir = .cwd();
    var in_dir = try cwd.openDir(io, in_path, .{ .iterate = true });
    defer in_dir.close(io);

    var it = in_dir.iterate();
    while (try it.next(io)) |entry| {
        const in_sub_path = try std.fs.path.join(allocator, &.{ in_path, entry.name });
        defer allocator.free(in_sub_path);
        const out_sub_path = try std.fs.path.join(allocator, &.{ out_path, entry.name });
        defer allocator.free(out_sub_path);
        switch (entry.kind) {
            .directory => {
                try cwd.createDir(io, out_sub_path, .default_dir);
                try copyDir(allocator, io, in_root, out_root, in_sub_path, out_sub_path);
            },
            .file => try cwd.copyFile(in_sub_path, cwd, out_sub_path, io, .{}),
            .sym_link => {
                var target_buf: [std.fs.max_path_bytes]u8 = undefined;
                const in_target_len = try cwd.readLink(io, in_sub_path, &target_buf);
                const in_target = target_buf[0..in_target_len];
                var out_target_buf: [std.fs.max_path_bytes]u8 = undefined;
                const out_target = blk: {
                    if (std.fs.path.isAbsolute(in_target)) {
                        if (!std.mem.startsWith(u8, in_target, in_root)) std.debug.panic(
                            "expected symlink target to start with '{s}' but got '{s}'",
                            .{ in_root, in_target },
                        );
                        break :blk try std.fmt.bufPrint(
                            &out_target_buf,
                            "{s}{s}",
                            .{ out_root, in_target[in_root.len..] },
                        );
                    }
                    break :blk in_target;
                };

                if (builtin.os.tag == .windows) @panic(
                    "we got a symlink on windows?",
                ) else try cwd.symLink(io, out_target, out_sub_path, .{});
            },
            else => std.debug.panic("copy {any}", .{entry}),
        }
    }
}
