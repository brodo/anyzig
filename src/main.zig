const std = @import("std");
const builtin = @import("builtin");
const build_options = @import("build_options");
const assert = std.debug.assert;
const Io = std.Io;
const Dir = std.Io.Dir;
const fs = std.fs;
const mem = std.mem;
const process = std.process;
const Allocator = mem.Allocator;
const Color = std.zig.Color;
const Cache = std.Build.Cache;
const Directory = std.Build.Cache.Directory;
const EnvVar = std.zig.EnvVar;

const zig = @import("zig");

const Package = zig.Package;
const introspect = zig.introspect;

pub const log = std.log;

const hashstore = @import("hashstore.zig");
const LockFile = @import("LockFile.zig");
const Cmdline = @import("Cmdline.zig");

pub const std_options: std.Options = .{
    .logFn = anyzigLog,
};

pub const exe_str = @tagName(build_options.exe);

const Verbosity = enum {
    debug,
    warn,
    pub const default: Verbosity = .debug;
};

const global = struct {
    var gpa: Allocator = undefined;
    var arena: Allocator = undefined;
    var io: Io = undefined;
    var environ_map: *const std.process.Environ.Map = undefined;

    var cached_verbosity: ?Verbosity = null;
    var cached_app_data_dir: ?union(enum) {
        ok: []const u8,
        err: anyerror,
    } = null;

    fn getAppDataDir() ![]const u8 {
        if (cached_app_data_dir == null) {
            cached_app_data_dir = if (resolveAppDataDir(arena, environ_map)) |dir|
                .{ .ok = dir }
            else |e|
                .{ .err = e };
        }
        return switch (cached_app_data_dir.?) {
            .ok => |d| d,
            .err => |e| e,
        };
    }

    var root_progress_node: ?std.Progress.Node = null;
    fn getRootProgressNode() std.Progress.Node {
        if (root_progress_node == null) {
            root_progress_node = std.Progress.start(io, .{ .root_name = "anyzig" });
        }
        return root_progress_node.?;
    }
};
/// Returns the app data dir for the current OS
fn resolveAppDataDir(
    arena: Allocator,
    environ_map: *const std.process.Environ.Map,
) ![]const u8 {
    const app_name = "anyzig";
    // todo: make this overwritable using an env var
    switch (builtin.os.tag) {
        .windows => {
            const local_app_data = environ_map.get("LOCALAPPDATA") orelse
                return error.AppDataDirUnavailable;
            return fs.path.join(arena, &.{ local_app_data, app_name });
        },
        .macos => {
            const home = environ_map.get("HOME") orelse return error.AppDataDirUnavailable;
            return fs.path.join(arena, &.{ home, "Library", "Application Support", app_name });
        },
        else => {
            if (environ_map.get("XDG_DATA_HOME")) |data_home| {
                if (data_home.len > 0) return fs.path.join(arena, &.{ data_home, app_name });
            }
            const home = environ_map.get("HOME") orelse return error.AppDataDirUnavailable;
            return fs.path.join(arena, &.{ home, ".local", "share", app_name });
        },
    }
}

/// Takes the stderr lock so output cannot be interleaved with the progress display.
fn stderrPrint(comptime format: []const u8, args: anytype) void {
    var buffer: [1024]u8 = undefined;
    const stderr = std.debug.lockStderr(&buffer);
    defer std.debug.unlockStderr();
    stderr.file_writer.interface.print(format, args) catch return;
    stderr.file_writer.interface.flush() catch return;
}

fn stdoutPrint(comptime format: []const u8, args: anytype) !void {
    var buffer: [1024]u8 = undefined;
    var file_writer = Io.File.stdout().writerStreaming(global.io, &buffer);
    try file_writer.interface.print(format, args);
    try file_writer.interface.flush();
}

fn readVerbosityFile() union(enum) {
    no_app_data_dir,
    no_file,
    loaded_from_file: Verbosity,
} {
    const app_data_dir = global.getAppDataDir() catch return .no_app_data_dir;
    const verbosity_path = std.fs.path.join(global.arena, &.{ app_data_dir, "verbosity" }) catch |e| oom(e);
    defer global.arena.free(verbosity_path);
    const content = Dir.cwd().readFileAlloc(
        global.io,
        verbosity_path,
        global.arena,
        .unlimited,
    ) catch |err| switch (err) {
        error.FileNotFound => return .no_file,
        else => |e| std.debug.panic("read '{s}' failed with {s}", .{ verbosity_path, @errorName(e) }),
    };
    defer global.arena.free(content);
    const content_trimmed = std.mem.trimEnd(u8, content, &std.ascii.whitespace);
    if (std.mem.eql(u8, content_trimmed, "debug")) return .{ .loaded_from_file = .debug };
    if (std.mem.eql(u8, content_trimmed, "warn")) return .{ .loaded_from_file = .warn };
    std.debug.panic(
        "file '{s}' had the following unexpected content:\n" ++
            "---\n{s}\n---\n" ++
            "we currently only expect the content to be 'debug' or 'warn'",
        .{ verbosity_path, content },
    );
}

fn anyzigLog(
    comptime level: std.log.Level,
    comptime scope: @EnumLiteral(),
    comptime format: []const u8,
    args: anytype,
) void {
    const scope_level = comptime (switch (scope) {
        .default => switch (level) {
            .info => "",
            inline else => ": " ++ level.asText(),
        },
        else => |s| "(" ++ @tagName(s) ++ "): " ++ level.asText(),
    });

    check_verbosity: {
        switch (level) {
            .err, .warn => break :check_verbosity,
            .info, .debug => {},
        }
        if (global.cached_verbosity == null) {
            global.cached_verbosity = switch (readVerbosityFile()) {
                .no_app_data_dir => .debug,
                .no_file => .default,
                .loaded_from_file => |v| v,
            };
        }
        switch (global.cached_verbosity.?) {
            .debug => {},
            .warn => return,
        }
    }

    stderrPrint("anyzig" ++ scope_level ++ ": " ++ format ++ "\n", args);
}

const Extent = struct { start: usize, limit: usize };

const key_minimum_zig_version = ".minimum_zig_version";
const key_zig_version = ".zig_version";
const key_mach_zig_version = ".mach_zig_version";

fn extractZigVersion(zon: []const u8, needle: []const u8) ?Extent {
    var offset: usize = 0;
    while (true) {
        offset = skipWhitespaceAndComments(zon, offset);
        const minimum_zig_version = std.mem.indexOfPos(u8, zon, offset, needle) orelse return null;
        offset = skipWhitespaceAndComments(zon, minimum_zig_version + needle.len);
        if (zonInsideComment(zon, minimum_zig_version))
            continue;
        if (offset >= zon.len or zon[offset] != '=') {
            log.debug("build.zig.zon syntax error (missing '=' after '{s}')", .{needle});
            return null;
        }
        offset = skipWhitespaceAndComments(zon, offset + 1);
        if (offset >= zon.len or zon[offset] != '\"') {
            log.debug("build.zig.zon syntax error", .{});
            return null;
        }
        const version_start = offset + 1;
        while (true) {
            offset += 1;
            if (offset >= zon.len) {
                log.debug("build.zig.zon syntax error", .{});
                return null;
            }
            if (zon[offset] == '"') break;
        }
        return .{ .start = version_start, .limit = offset };
    }
}

fn zonInsideComment(zon: []const u8, start: usize) bool {
    if (start < 2) return false;
    if (zon[start - 1] == '\n') return false;
    var offset = start - 2;
    while (true) : (offset -= 1) {
        if (zon[offset] == '\n') return false;
        if (zon[offset] == '/' and zon[offset + 1] == '/') return true;
        if (offset == 0) return false;
    }
    return false;
}

fn skipWhitespaceAndComments(s: []const u8, start: usize) usize {
    var offset = start;
    var previous_was_slash = false;
    while (offset < s.len) {
        const double_slash = blk: {
            const at_slash = s[offset] == '/';
            const double_slash = previous_was_slash and at_slash;
            previous_was_slash = at_slash;
            break :blk double_slash;
        };
        if (double_slash) {
            while (true) {
                offset += 1;
                if (offset == s.len) break;
                if (s[offset] == '\n') {
                    offset += 1;
                    break;
                }
            }
        } else if (!std.ascii.isWhitespace(s[offset])) {
            break;
        } else {
            offset += 1;
        }
    }
    return offset;
}

fn loadBuildZigZon(arena: Allocator, build_root: BuildRoot) !?[]const u8 {
    return build_root.directory.handle.readFileAlloc(
        global.io,
        "build.zig.zon",
        arena,
        .unlimited,
    ) catch |err| switch (err) {
        error.FileNotFound => null,
        else => |e| e,
    };
}

fn isMachVersion(v: SemanticVersion) bool {
    if (v.build == null) {
        if (v.pre) |pre| return std.mem.eql(u8, pre.slice(), "mach");
    }
    return false;
}

fn determineSemanticVersion(scratch: Allocator, build_root: BuildRoot) !SemanticVersion {
    const zon = try loadBuildZigZon(scratch, build_root) orelse {
        log.err("TODO: no build.zig.zon file, maybe try determining zig version from build.zig?", .{});
        std.process.exit(0xff);
    };
    defer scratch.free(zon);

    for ([_][]const u8{
        key_mach_zig_version,
        key_zig_version,
        key_minimum_zig_version,
    }) |key_version| {
        const version_extent = extractZigVersion(zon, key_version) orelse continue;
        const version = zon[version_extent.start..version_extent.limit];

        if (key_version.ptr == key_mach_zig_version.ptr) {
            if (!std.mem.endsWith(u8, version, "-mach")) errExit(
                "expected the " ++ key_mach_zig_version ++ " to end with '-mach' but got '{s}'",
                .{version},
            );
        }

        log.info(
            "{s} '{s}' pulled from '{f}build.zig.zon'",
            .{ key_version, version, build_root.directory },
        );
        return SemanticVersion.parse(version) orelse errExit(
            "{f}build.zig.zon has invalid {s} \"{s}\"",
            .{ build_root.directory, key_version, version },
        );
    }

    errExit(
        "build.zig.zon is missing minimum_zig_version, either add it or run '{s} VERSION' to specify a version",
        .{@tagName(build_options.exe)},
    );

    // !!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!
    // TODO: if we find ".{ .path = "..." }" in build.zig then we know zig must be older than 0.13.0

    // 0.12.0
    // <         .root_source_file = b.path("src/root.zig"),
    // 0.11.0
    // >         .root_source_file = .{ .path = "src/main.zig" },

    // log.info("fallback to default zig version 0.13.0", .{});
    // return "0.13.0";
}

pub fn main(init: std.process.Init) !void {
    global.gpa = init.gpa;
    global.arena = init.arena.allocator();
    global.io = init.io;
    global.environ_map = init.environ_map;

    defer if (global.root_progress_node) |n| {
        n.end();
    };

    const gpa = global.gpa;
    const arena = global.arena;
    const io = global.io;

    const cmdline: Cmdline = try .alloc(init.minimal.args, arena);
    defer cmdline.free(arena);

    const cmdline_offset: usize, const manual_version: ?VersionSpecifier = blk: {
        if (cmdline.len() >= 2) {
            if (VersionSpecifier.parse(cmdline.arg(1))) |v| break :blk .{ 2, v };
        }
        break :blk .{ 1, null };
    };

    const maybe_command: ?[]const u8 = if (cmdline_offset >= cmdline.len()) null else cmdline.arg(cmdline_offset);

    const build_root_options = blk: {
        var options: FindBuildRootOptions = .{};
        switch (build_options.exe) {
            .zig => {
                if (maybe_command) |command| {
                    if (std.mem.eql(u8, command, "build")) {
                        var index: usize = cmdline_offset + 1;
                        while (index < cmdline.len()) : (index += 1) {
                            const arg = cmdline.arg(index);
                            if (std.mem.eql(u8, arg, "--build-file")) {
                                if (index == cmdline.len()) break;
                                index += 1;
                                options.build_file = cmdline.arg(index);
                                log.info("build file '{s}'", .{options.build_file.?});
                            }
                        }
                    }
                }
            },
            .zls => {},
        }
        break :blk options;
    };

    const version_specifier: VersionSpecifier, const is_init = blk: {
        if (maybe_command) |command| {
            if (std.mem.startsWith(u8, command, "-") and !std.mem.eql(u8, command, "-h") and !std.mem.eql(u8, command, "--help")) {
                stderrPrint("error: expected a command but got '{s}'\n", .{command});
                std.process.exit(0xff);
            }
            if (build_options.exe == .zig and (std.mem.eql(u8, command, "init") or std.mem.eql(u8, command, "init-exe") or std.mem.eql(u8, command, "init-lib"))) {
                const is_help = blk_is_help: {
                    var index: usize = cmdline_offset + 1;
                    while (index < cmdline.len()) : (index += 1) {
                        const arg = cmdline.arg(index);
                        if (std.mem.eql(u8, arg, "-h")) break :blk_is_help true;
                        if (std.mem.eql(u8, arg, "--help")) break :blk_is_help true;
                    } else break :blk_is_help false;
                };

                if (manual_version) |version| break :blk .{ version, !is_help };
                stderrPrint(
                    "error: anyzig init requires a version, i.e. 'zig 0.13.0 {s}'\n",
                    .{command},
                );
                std.process.exit(0xff);
            }
            if (std.mem.eql(u8, command, "any")) std.process.exit(try anyCommand(cmdline, cmdline_offset + 1));
        }
        if (manual_version) |version| break :blk .{ version, false };
        const build_root = try findBuildRoot(arena, build_root_options) orelse {
            stderrPrint(
                "no build.zig to pull a zig version from, you can:\n" ++
                    "  1. run '" ++ exe_str ++ " VERSION' to specify a version\n" ++
                    "  2. run from a directory where a build.zig can be found\n",
                .{},
            );
            std.process.exit(0xff);
        };
        break :blk .{ .{ .semantic = try determineSemanticVersion(arena, build_root) }, false };
    };

    const app_data_path = try resolveAppDataDir(arena, global.environ_map);
    defer arena.free(app_data_path);
    log.info("appdata '{s}'", .{app_data_path});

    const semantic_version = semantic_version: switch (version_specifier) {
        .semantic => |v| v,
        .master => {
            const download_index_kind: DownloadIndexKind = .official;
            const index_path = try std.fs.path.join(arena, &.{ app_data_path, download_index_kind.basename() });
            defer arena.free(index_path);
            try fetchFile(arena, download_index_kind.uri(), index_path);
            // since we just downloaded the file, this should always succeed now
            const index_content = try Dir.cwd().readFileAlloc(io, index_path, arena, .unlimited);
            defer arena.free(index_content);
            break :semantic_version extractMasterVersion(arena, index_path, index_content);
        },
    };
    if (version_specifier == .master) {
        std.log.info("master is at {f}", .{semantic_version});
    }

    const hashstore_path = try std.fs.path.join(arena, &.{ app_data_path, "hashstore" });
    // no need to free
    try hashstore.init(io, hashstore_path);

    const hashstore_name = std.fmt.allocPrint(arena, exe_str ++ "-{f}", .{semantic_version}) catch |e| oom(e);
    // no need to free

    const maybe_hash = maybeHashAndPath(try hashstore.find(io, hashstore_path, hashstore_name));

    const override_global_cache_dir: ?[]const u8 = EnvVar.ZIG_GLOBAL_CACHE_DIR.get(global.environ_map);
    var global_cache_directory: Directory = l: {
        const p = override_global_cache_dir orelse
            try introspect.resolveGlobalCacheDir(arena, global.environ_map);
        break :l .{
            .handle = try Dir.cwd().createDirPathOpen(io, p, .{}),
            .path = p,
        };
    };
    defer global_cache_directory.handle.close(io);

    const hash = blk: {
        if (maybe_hash) |hash| {
            if (global_cache_directory.handle.access(io, hash.path(), .{})) |_| {
                log.info(
                    "{s} '{f}' already exists at '{f}{s}'",
                    .{ @tagName(build_options.exe), semantic_version, global_cache_directory, hash.path() },
                );
                break :blk hash;
            } else |err| switch (err) {
                error.FileNotFound => {},
                else => |e| return e,
            }
        }

        const url = try getVersionUrl(arena, app_data_path, semantic_version);
        defer url.deinit(arena);
        const hash = hashAndPath(try cmdFetch(
            gpa,
            arena,
            global_cache_directory,
            url.fetch,
            .{ .debug_hash = false },
        ));
        log.info("downloaded {s} to '{f}{s}'", .{ hashstore_name, global_cache_directory, hash.path() });
        if (maybe_hash) |*previous_hash| {
            if (previous_hash.val.eql(&hash.val)) {
                log.info("{s} was already in the hashstore as {s}", .{ hashstore_name, hash.val.toSlice() });
            } else {
                log.warn(
                    "{s} hash has changed!\nold:{s}\nnew:{s}\n",
                    .{ hashstore_name, previous_hash.val.toSlice(), hash.val.toSlice() },
                );
                try hashstore.delete(io, hashstore_path, hashstore_name);
                try hashstore.save(io, hashstore_path, hashstore_name, hash.val.toSlice());
            }
        } else {
            try hashstore.save(io, hashstore_path, hashstore_name, hash.val.toSlice());
        }
        break :blk hash;
    };

    const versioned_exe = try global_cache_directory.joinZ(arena, &.{ hash.path(), exe_str });
    defer arena.free(versioned_exe);

    const stay_alive = is_init or (builtin.os.tag == .windows);

    if (stay_alive) {
        // !!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!
        // TODO: if on windows, create a job so our child process gets killed if
        //       our process gets killed
        var al: std.ArrayListUnmanaged([]const u8) = .empty;
        try al.append(arena, versioned_exe);
        for (cmdline_offset..cmdline.len()) |arg_index| {
            try al.append(arena, cmdline.arg(arg_index));
        }
        var child = try std.process.spawn(io, .{ .argv = al.items });
        const result = try child.wait(io);
        switch (result) {
            .exited => |code| if (code != 0) std.process.exit(0xff),
            else => std.process.exit(0xff),
        }
    }

    if (is_init) {
        const build_root = try findBuildRoot(arena, build_root_options) orelse @panic("init did not create a build.zig file");
        log.info("{f}{s}", .{ build_root.directory, build_root.build_zig_basename });
        const zon = try loadBuildZigZon(arena, build_root) orelse {
            // !!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!
            // TODO: maybe don't use .name = placeholder?
            const content = try std.fmt.allocPrint(arena,
                \\.{{
                \\    .name = "placeholder",
                \\    .version = "0.0.0",
                \\    .minimum_zig_version = "{f}",
                \\}}
                \\
            , .{semantic_version});
            defer arena.free(content);
            try Dir.cwd().writeFile(io, .{ .sub_path = "build.zig.zon", .data = content });
            return;
        };
        const version_extent = extractZigVersion(zon, key_minimum_zig_version) orelse {
            if (!std.mem.startsWith(u8, zon, ".{")) @panic("zon file did not start with '.{'");
            if (zon.len < 2 or zon[2] != '\n') @panic("zon file not start with '.{\\n");
            const content = try std.fmt.allocPrint(
                arena,
                "{s}    .minimum_zig_version = \"{f}\",\n{s}",
                .{ zon[0..3], semantic_version, zon[3..] },
            );
            defer arena.free(content);
            try Dir.cwd().writeFile(io, .{ .sub_path = "build.zig.zon", .data = content });
            return;
        };

        const generated_version_str = zon[version_extent.start..version_extent.limit];
        const generated_version = SemanticVersion.parse(generated_version_str) orelse errExit(
            "unable to parse zig version '{s}' generated by init",
            .{generated_version_str},
        );
        if (generated_version.eql(semantic_version))
            return;
        std.debug.panic(
            "zig init generated version '{f}' but expected '{f}'",
            .{ generated_version, semantic_version },
        );
    }

    if (!stay_alive) {
        var al: std.ArrayListUnmanaged([]const u8) = .empty;
        try al.append(arena, versioned_exe);
        for (cmdline_offset..cmdline.len()) |arg_index| {
            try al.append(arena, cmdline.arg(arg_index));
        }
        const err = std.process.replace(io, .{ .argv = al.items });
        log.err("exec '{s}' failed with {s}", .{ versioned_exe, @errorName(err) });
        process.exit(0xff);
    }
}

fn anyCommandUsage() !u8 {
    stderrPrint(
        "any" ++ @tagName(build_options.exe) ++ " {s} from https://github.com/marler8997/anyzig\n" ++
            "Here are the anyzig-specific subcommands:\n" ++
            "  zig any set-verbosity LEVEL    | sets the default system-wide verbosity\n" ++
            "                                 | accepts 'warn' or 'debug'\n" ++
            "  zig any version                | print the version of anyzig to stdout\n" ++
            "  zig any list-installed         | list all versions of zig installed in the global cache\n",
        .{@embedFile("version")},
    );
    return 0xff;
}

fn anyCommand(cmdline: Cmdline, cmdline_offset: usize) !u8 {
    if (cmdline_offset == cmdline.len()) {
        std.process.exit(try anyCommandUsage());
    }
    const command = cmdline.arg(cmdline_offset);
    const arg_offset = cmdline_offset + 1;

    if (std.mem.eql(u8, command, "version")) {
        if (arg_offset < cmdline.len()) errExit("the 'version' subcommand does not take any cmdline args", .{});
        try stdoutPrint("{s}\n", .{@embedFile("version")});
        return 0;
    } else if (std.mem.eql(u8, command, "set-verbosity")) {
        if (arg_offset >= cmdline.len()) errExit("missing VERBOSITY (either 'warn' or 'debug')", .{});
        if (arg_offset + 1 < cmdline.len()) errExit("too many cmdline args", .{});
        const level_str = cmdline.arg(arg_offset);
        const level: Verbosity = blk: {
            if (std.mem.eql(u8, level_str, "warn")) break :blk .warn;
            if (std.mem.eql(u8, level_str, "debug")) break :blk .debug;
            errExit("unknown VERBOSITY '{s}', expected 'warn' or 'debug'", .{level_str});
        };
        {
            const app_data_dir = try global.getAppDataDir();
            const verbosity_path = std.fs.path.join(
                global.arena,
                &.{ app_data_dir, "verbosity" },
            ) catch |e| oom(e);
            defer global.arena.free(verbosity_path);
            if (std.fs.path.dirname(verbosity_path)) |dir| {
                try Dir.cwd().createDirPath(global.io, dir);
            }
            const content = try std.fmt.allocPrint(global.arena, "{s}\n", .{level_str});
            defer global.arena.free(content);
            try Dir.cwd().writeFile(global.io, .{
                .sub_path = verbosity_path,
                .data = content,
            });
        }
        switch (readVerbosityFile()) {
            .no_app_data_dir => @panic("no app data dir?"),
            .no_file => @panic("no file after writing it?"),
            .loaded_from_file => |l| std.debug.assert(l == level),
        }
        return 0;
    } else if (std.mem.eql(u8, command, "list-installed")) {
        if (arg_offset < cmdline.len()) errExit("the 'list-installed' subcommand does not take any cmdline args", .{});
        try listInstalled();
        return 0;
    } else errExit("unknown zig any '{s}' command", .{command});
}

fn listInstalled() !void {
    const io = global.io;
    const app_data_dir = try global.getAppDataDir();

    const hashstore_path = try std.fs.path.join(global.arena, &.{ app_data_dir, "hashstore" });
    // no need to free
    try hashstore.init(io, hashstore_path);
    const reverse_lookup = try hashstore.allocReverseLookup(io, hashstore_path, global.arena);

    const override_global_cache_dir: ?[]const u8 = EnvVar.ZIG_GLOBAL_CACHE_DIR.get(global.environ_map);
    const global_cache_dir_path = override_global_cache_dir orelse
        try introspect.resolveGlobalCacheDir(global.arena, global.environ_map);
    const p_path = std.fs.path.join(global.arena, &.{ global_cache_dir_path, "p" }) catch |e| oom(e);
    defer global.arena.free(p_path);

    var p_dir: Directory = .{
        .handle = try Dir.cwd().createDirPathOpen(io, p_path, .{ .open_options = .{ .iterate = true } }),
        .path = p_path,
    };
    defer p_dir.handle.close(io);

    var it = p_dir.handle.iterate();
    while (try it.next(io)) |entry| {
        if (entry.kind != .directory) continue;
        if (entry.name.len > zig.Package.Hash.max_len) continue;

        const hash_from_cache = zig.Package.Hash.fromSlice(entry.name);
        if (reverse_lookup.get(hash_from_cache)) |versions| {
            for (versions.items) |version| {
                try listVersion(p_path, version, entry.name);
            }
            continue;
        }

        // right now all zig distributed archives don't include a build.zig.zon so they
        // should all start with this
        if (!std.mem.startsWith(u8, entry.name, "N-V-__8AA")) continue;

        const exe_path = try std.fs.path.join(global.arena, &.{
            p_path,
            entry.name,
            comptime exe_str ++ builtin.target.exeFileExt(),
        });
        Dir.cwd().access(io, exe_path, .{}) catch |err| switch (err) {
            error.FileNotFound => continue,
            else => |e| return e,
        };
        // probably not a valid zig
        var child = std.process.spawn(io, .{
            .argv = &.{ exe_path, "version" },
            .stdout = .pipe,
        }) catch continue;

        const child_stdout = blk: {
            var buffer: [100]u8 = undefined;
            var child_reader = child.stdout.?.readerStreaming(io, &buffer);
            break :blk child_reader.interface.allocRemaining(global.arena, .limited(100)) catch {
                _ = child.wait(io) catch {};
                continue;
            };
        };
        defer global.arena.free(child_stdout);
        const result = try child.wait(io);
        if (result != .exited or result.exited != 0) {
            // must not be a zig
            continue;
        }
        const version_str = std.mem.trimEnd(u8, child_stdout, "\r\n");
        const semantic_version = SemanticVersion.parse(version_str) orelse continue;
        const hashstore_name = std.fmt.allocPrint(global.arena, exe_str ++ "-{f}", .{semantic_version}) catch |e| oom(e);
        defer global.arena.free(hashstore_name);
        const maybe_hash = maybeHashAndPath(try hashstore.find(io, hashstore_path, hashstore_name));
        if (maybe_hash) |*anyzig_store_hash| {
            if (!anyzig_store_hash.val.eql(&hash_from_cache)) {
                log.err(
                    "{s} hash differs!\nglobal-cache:{s}\nanyzig-store:{s}\n",
                    .{ hashstore_name, entry.name, anyzig_store_hash.val.toSlice() },
                );
                continue;
                // try hashstore.delete(hashstore_path, hashstore_name);
                // try hashstore.save(hashstore_path, hashstore_name, hash.val.toSlice());
            }
        } else {
            // TODO: should we just trust the hash is good?
            log.info("new hash added to anyzig store: {s}", .{entry.name});
            try hashstore.save(io, hashstore_path, hashstore_name, entry.name);
        }
        try listVersion(p_path, semantic_version, entry.name);
    }
}

fn listVersion(p_path: []const u8, version: SemanticVersion, hash: []const u8) !void {
    try stdoutPrint("{f}\t{s}{s}{s}\n", .{ version, p_path, std.fs.path.sep_str, hash });
}

pub const SemanticVersion = struct {
    const max_component = 50;
    const max_string = 50 + max_component + max_component;

    const Component = struct {
        buf: [max_component]u8,
        len: usize,

        fn init(what: []const u8, text: []const u8) Component {
            if (text.len > max_component) std.debug.panic(
                "semantic version {s} '{s}' is too long (max is {d})",
                .{ what, text, max_component },
            );
            var result: Component = .{ .buf = undefined, .len = text.len };
            @memcpy(result.buf[0..text.len], text);
            return result;
        }
        fn slice(self: *const Component) []const u8 {
            return self.buf[0..self.len];
        }
    };

    major: usize,
    minor: usize,
    patch: usize,
    pre: ?Component,
    build: ?Component,

    pub fn string(self: *const SemanticVersion, buffer: *[max_string]u8) []const u8 {
        return std.fmt.bufPrint(buffer, "{f}", .{self}) catch unreachable;
    }

    pub fn parse(s: []const u8) ?SemanticVersion {
        const parsed = std.SemanticVersion.parse(s) catch |e| switch (e) {
            error.Overflow, error.InvalidVersion => return null,
        };
        std.debug.assert(s.len <= max_string);

        var result: SemanticVersion = .{
            .major = parsed.major,
            .minor = parsed.minor,
            .patch = parsed.patch,
            .pre = if (parsed.pre) |pre| .init("pre", pre) else null,
            .build = if (parsed.build) |build| .init("build", build) else null,
        };

        {
            // sanity check, ensure format gives us the same string back we just parsed
            var buffer: [max_string]u8 = undefined;
            const roundtrip = result.string(&buffer);
            if (!std.mem.eql(u8, roundtrip, s)) errExit(
                "codebug parse/format version mismatch:\nparsed: '{s}'\nformat: '{s}'\n",
                .{ s, roundtrip },
            );
        }

        return result;
    }
    pub fn ref(self: *const SemanticVersion) std.SemanticVersion {
        return .{
            .major = self.major,
            .minor = self.minor,
            .patch = self.patch,
            .pre = if (self.pre) |*pre| pre.slice() else null,
            .build = if (self.build) |*build| build.slice() else null,
        };
    }
    pub fn eql(self: SemanticVersion, other: SemanticVersion) bool {
        return self.ref().order(other.ref()) == .eq;
    }
    pub fn format(self: SemanticVersion, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        try self.ref().format(writer);
    }
};

const VersionSpecifier = union(enum) {
    master,
    semantic: SemanticVersion,
    pub fn parse(s: []const u8) ?VersionSpecifier {
        if (SemanticVersion.parse(s)) |v| return .{ .semantic = v };
        return switch (build_options.exe) {
            .zig => return if (std.mem.eql(u8, s, "master")) .master else null,
            .zls => return null,
        };
    }
};

const arch = switch (builtin.cpu.arch) {
    .aarch64 => "aarch64",
    .arm => "armv7a",
    .powerpc64 => "powerpc64",
    .powerpc64le => "powerpc64le",
    .riscv64 => "riscv64",
    .s390x => "s390x",
    .x86 => "x86",
    .x86_64 => "x86_64",
    else => @compileError("Unsupported CPU Architecture"),
};
const os = switch (builtin.os.tag) {
    .freebsd => "freebsd",
    .linux => "linux",
    .macos => "macos",
    .netbsd => "netbsd",
    .windows => "windows",
    else => @compileError("Unsupported OS"),
};

const os_arch = os ++ "-" ++ arch;
const arch_os = arch ++ "-" ++ os;
const archive_ext = if (builtin.os.tag == .windows) "zip" else "tar.xz";

const VersionKind = union(enum) { release: Release, dev };
fn determineVersionKind(v: SemanticVersion) VersionKind {
    return if (v.pre == null and v.build == null) .{ .release = .{
        .major = v.major,
        .minor = v.minor,
        .patch = v.patch,
    } } else .dev;
}

const DownloadIndexKind = enum {
    official,
    mach,
    pub fn url(self: DownloadIndexKind) []const u8 {
        return switch (self) {
            .official => "https://ziglang.org/download/index.json",
            .mach => "https://pkg.hexops.org/zig/index.json",
        };
    }
    pub fn uri(self: DownloadIndexKind) std.Uri {
        return std.Uri.parse(self.url()) catch unreachable;
    }
    pub fn basename(self: DownloadIndexKind) []const u8 {
        return switch (self) {
            .official => "download-index.json",
            .mach => "download-index-mach.json",
        };
    }
};

const DownloadUrl = struct {
    // use to know if two URL's are the same
    official: []const u8,
    // the actual URL to fetch from
    fetch: []const u8,
    pub fn initOfficial(url: []const u8) DownloadUrl {
        return .{ .official = url, .fetch = url };
    }
    pub fn deinit(self: DownloadUrl, allocator: std.mem.Allocator) void {
        allocator.free(self.official);
        if (self.official.ptr != self.fetch.ptr) {
            allocator.free(self.fetch);
        }
    }
};

const Release = struct {
    major: usize,
    minor: usize,
    patch: usize,
    pub fn order(a: Release, b: Release) std.math.Order {
        if (a.major != b.major) return std.math.order(a.major, b.major);
        if (a.minor != b.minor) return std.math.order(a.minor, b.minor);
        return std.math.order(a.patch, b.patch);
    }
};

// The Zig release where the OS-ARCH in the url was swapped to ARCH-OS
const arch_os_swap_release: Release = .{ .major = 0, .minor = 14, .patch = 1 };

fn makeOfficialUrl(arena: Allocator, semantic_version: SemanticVersion) DownloadUrl {
    return switch (determineVersionKind(semantic_version)) {
        .dev => DownloadUrl.initOfficial(std.fmt.allocPrint(
            arena,
            "https://ziglang.org/builds/zig-" ++ arch_os ++ "-{0f}." ++ archive_ext,
            .{semantic_version},
        ) catch |e| oom(e)),
        .release => |release| DownloadUrl.initOfficial(std.fmt.allocPrint(
            arena,
            "https://ziglang.org/download/{0f}/zig-{1s}-{0f}." ++ archive_ext,
            .{
                semantic_version,
                switch (release.order(arch_os_swap_release)) {
                    .lt => os_arch,
                    .gt, .eq => arch_os,
                },
            },
        ) catch |e| oom(e)),
    };
}

fn getVersionUrl(
    arena: Allocator,
    app_data_path: []const u8,
    semantic_version: SemanticVersion,
) !DownloadUrl {
    if (build_options.exe == .zls) return DownloadUrl.initOfficial(std.fmt.allocPrint(
        arena,
        "https://builds.zigtools.org/zls-{s}-{f}.{s}",
        .{ switch (determineVersionKind(semantic_version)) {
            .dev => arch_os,
            .release => |release| switch (release.order(arch_os_swap_release)) {
                .lt => os_arch,
                .gt, .eq => arch_os,
            },
        }, semantic_version, archive_ext },
    ) catch |e| oom(e));

    if (!isMachVersion(semantic_version)) return makeOfficialUrl(arena, semantic_version);

    const download_index_kind: DownloadIndexKind = .mach;
    const index_path = try std.fs.path.join(arena, &.{ app_data_path, download_index_kind.basename() });
    defer arena.free(index_path);

    try_existing_index: {
        const index_content = Dir.cwd().readFileAlloc(
            global.io,
            index_path,
            arena,
            .unlimited,
        ) catch |err| switch (err) {
            error.FileNotFound => break :try_existing_index,
            else => |e| return e,
        };
        defer arena.free(index_content);
        if (extractUrlFromMachDownloadIndex(arena, semantic_version, index_path, index_content)) |url|
            return url;
    }

    try fetchFile(arena, download_index_kind.uri(), index_path);
    // since we just downloaded the file, this should always succeed now
    const index_content = try Dir.cwd().readFileAlloc(global.io, index_path, arena, .unlimited);
    defer arena.free(index_content);
    return extractUrlFromMachDownloadIndex(arena, semantic_version, index_path, index_content) orelse {
        errExit("compiler version '{f}' is missing from download index {s}", .{ semantic_version, index_path });
    };
}

fn extractMasterVersion(
    scratch: std.mem.Allocator,
    index_filepath: []const u8,
    download_index: []const u8,
) SemanticVersion {
    const root = std.json.parseFromSlice(std.json.Value, scratch, download_index, .{
        .allocate = .alloc_if_needed,
    }) catch |e| std.debug.panic(
        "failed to parse download index '{s}' as JSON with {s}",
        .{ index_filepath, @errorName(e) },
    );
    defer root.deinit();
    const master_obj = root.value.object.get("master") orelse @panic(
        "download index is missing the 'master' version",
    );
    const version_val = master_obj.object.get("version") orelse errExit(
        "download index \"master\" object is missing the \"version\" property",
        .{},
    );
    return SemanticVersion.parse(version_val.string) orelse errExit(
        "unable to parse download index master version '{s}'",
        .{version_val.string},
    );
}

fn extractUrlFromMachDownloadIndex(
    allocator: std.mem.Allocator,
    semantic_version: SemanticVersion,
    index_filepath: []const u8,
    download_index: []const u8,
) ?DownloadUrl {
    const root = std.json.parseFromSlice(std.json.Value, allocator, download_index, .{
        .allocate = .alloc_if_needed,
    }) catch |e| std.debug.panic(
        "failed to parse download index '{s}' as JSON with {s}",
        .{ index_filepath, @errorName(e) },
    );
    defer root.deinit();
    var version_buffer: [SemanticVersion.max_string]u8 = undefined;
    const version_str = semantic_version.string(&version_buffer);
    const version_obj = root.value.object.get(version_str) orelse return null;
    const arch_os_obj = version_obj.object.get(arch_os) orelse std.debug.panic(
        "compiler version '{s}' does not contain an entry for arch-os '{s}'",
        .{ version_str, arch_os },
    );
    const fetch_url = arch_os_obj.object.get("tarball") orelse std.debug.panic(
        "download index '{s}' version '{s}' arch-os '{s}' is missing the 'tarball' property",
        .{ index_filepath, version_str, arch_os },
    );
    const official_url = arch_os_obj.object.get("zigTarball") orelse std.debug.panic(
        "download index '{s}' version '{s}' arch-os '{s}' is missing the 'zigTarball' property",
        .{ index_filepath, version_str, arch_os },
    );
    return .{
        .fetch = allocator.dupe(u8, fetch_url.string) catch |e| oom(e),
        .official = allocator.dupe(u8, official_url.string) catch |e| oom(e),
    };
}

const HashAndPath = struct {
    val: zig.Package.Hash,
    /// Holds "p" ++ sep ++ hash, inline so this stays trivially copyable.
    path_buf: [2 + zig.Package.Hash.max_len]u8,
    path_len: usize,
    pub fn path(self: *const HashAndPath) []const u8 {
        return self.path_buf[0..self.path_len];
    }
};
fn maybeHashAndPath(maybe_hash: ?zig.Package.Hash) ?HashAndPath {
    return hashAndPath(maybe_hash orelse return null);
}
fn hashAndPath(hash: zig.Package.Hash) HashAndPath {
    const hash_slice = hash.toSlice();
    var result: HashAndPath = .{
        .val = hash,
        .path_buf = undefined,
        .path_len = 2 + hash_slice.len,
    };
    result.path_buf[0] = 'p';
    result.path_buf[1] = std.fs.path.sep;
    @memcpy(result.path_buf[2..][0..hash_slice.len], hash_slice);
    return result;
}

fn fetchFile(
    scratch: Allocator,
    uri: std.Uri,
    out_filepath: []const u8,
) !void {
    const io = global.io;
    log.info("fetch '{f}' to '{s}'", .{ uri, out_filepath });
    const root = global.getRootProgressNode();

    const progress_node_name = std.fmt.allocPrint(scratch, "fetch {f}", .{uri}) catch |e| oom(e);
    defer scratch.free(progress_node_name);
    const node = root.start(progress_node_name, 1);
    defer node.end();

    const lock_filepath = try std.mem.concat(scratch, u8, &.{ out_filepath, ".lock" });
    defer scratch.free(lock_filepath);

    // TODO: might be nice for the lock file to report progress as well?
    var file_lock = try LockFile.lock(io, lock_filepath);
    defer file_lock.unlock();

    var client: std.http.Client = .{ .allocator = scratch, .io = io };
    defer client.deinit();
    client.initDefaultProxies(scratch, global.environ_map) catch |err| std.debug.panic(
        "fetch '{f}': init proxy failed with {s}",
        .{ uri, @errorName(err) },
    );

    const out_filepath_tmp = std.mem.concat(scratch, u8, &.{ out_filepath, ".fetching" }) catch |e| oom(e);
    defer scratch.free(out_filepath_tmp);

    const cwd: Dir = .cwd();
    const file = cwd.createFile(io, out_filepath_tmp, .{}) catch |e| std.debug.panic(
        "create '{s}' failed with {s}",
        .{ out_filepath_tmp, @errorName(e) },
    );
    defer {
        if (cwd.deleteFile(io, out_filepath_tmp)) {
            std.log.info("removed '{s}'", .{out_filepath_tmp});
        } else |err| switch (err) {
            error.FileNotFound => {},
            else => |e| std.log.err("remove '{s}' failed with {s}", .{ out_filepath_tmp, @errorName(e) }),
        }
        file.close(io);
    }

    var write_buffer: [4096]u8 = undefined;
    var file_writer = file.writer(io, &write_buffer);

    // The http client takes care of validating the response body against the
    // Content-Length/chunked framing while streaming it into the file.
    const result = client.fetch(.{
        .location = .{ .uri = uri },
        .method = .GET,
        .keep_alive = false,
        .response_writer = &file_writer.interface,
    }) catch |e| std.debug.panic(
        "fetch '{f}': failed with {s}",
        .{ uri, @errorName(e) },
    );
    if (result.status != .ok) return errExit(
        "fetch '{f}': HTTP response {d} \"{?s}\"",
        .{ uri, @intFromEnum(result.status), result.status.phrase() },
    );
    try file_writer.interface.flush();

    try cwd.rename(out_filepath_tmp, cwd, out_filepath, io);
}

pub fn cmdFetch(
    gpa: Allocator,
    arena: Allocator,
    global_cache_directory: Directory,
    url: []const u8,
    opt: struct {
        debug_hash: bool,
    },
) !zig.Package.Hash {
    const color: Color = .auto;
    const io = global.io;

    var http_client: std.http.Client = .{ .allocator = gpa, .io = io };
    defer http_client.deinit();

    try http_client.initDefaultProxies(arena, global.environ_map);

    var job_queue: Package.Fetch.JobQueue = .{
        .io = io,
        .http_client = &http_client,
        .global_cache = global_cache_directory,
        .local_cache = .{ .root_dir = global_cache_directory, .sub_path = "." },
        // zig 0.16 unpacks packages into `root_pkg_path`; point it at the "p"
        // subdirectory of the global cache so anyzig keeps its existing layout
        // of `<global cache>/p/<hash>`, which `hashAndPath` and
        // `listInstalled` both rely on.
        .root_pkg_path = .{ .root_dir = global_cache_directory, .sub_path = "p" },
        .recursive = false,
        .read_only = false,
        .debug_hash = opt.debug_hash,
        .mode = .needed,
        .prog_node = global.getRootProgressNode(),
    };
    defer job_queue.deinit();

    var fetch: Package.Fetch = .{
        .arena = std.heap.ArenaAllocator.init(gpa),
        .location = .{ .path_or_url = url },
        .location_tok = 0,
        .hash_tok = .none,
        .name_tok = 0,
        .lazy_status = .eager,
        .parent_package_root = undefined,
        .parent_manifest_ast = null,
        .prog_node = global.getRootProgressNode(),
        .job_queue = &job_queue,
        .omit_missing_hash_error = true,
        .allow_missing_paths_field = false,
        .use_latest_commit = true,

        .package_root = undefined,
        .error_bundle = undefined,
        .manifest = undefined,
        .manifest_ast = undefined,
        .have_manifest = false,
        .computed_hash = undefined,
        .has_build_zig = false,
        .oom_flag = false,
        .latest_commit = null,

        .module = null,
    };
    defer fetch.deinit();

    log.info("downloading '{s}'...", .{url});
    fetch.run() catch |err| switch (err) {
        error.OutOfMemory => errExit("out of memory", .{}),
        error.Canceled => |e| return e,
        error.FetchFailed => {}, // error bundle checked below
    };

    try job_queue.group.await(io);

    if (fetch.error_bundle.root_list.items.len > 0) {
        var errors = try fetch.error_bundle.toOwnedBundle("");
        try errors.renderToStderr(io, .{}, color);
        process.exit(1);
    }

    return fetch.computedPackageHash();
}

const BuildRoot = struct {
    directory: Cache.Directory,
    build_zig_basename: []const u8,
    cleanup_build_dir: ?Dir,

    fn deinit(br: *BuildRoot, io: Io) void {
        if (br.cleanup_build_dir) |dir| dir.close(io);
        br.* = undefined;
    }
};

const FindBuildRootOptions = struct {
    build_file: ?[]const u8 = null,
    cwd_path: ?[]const u8 = null,
};

fn findBuildRoot(arena: Allocator, options: FindBuildRootOptions) !?BuildRoot {
    const io = global.io;
    const cwd: Dir = .cwd();
    const cwd_path = options.cwd_path orelse try process.currentPathAlloc(io, arena);
    const build_zig_basename = if (options.build_file) |bf|
        fs.path.basename(bf)
    else
        Package.build_zig_basename;

    if (options.build_file) |bf| {
        if (fs.path.dirname(bf)) |dirname| {
            const dir = cwd.openDir(io, dirname, .{}) catch |err| {
                errExit("unable to open directory to build file from argument 'build-file', '{s}': {s}", .{ dirname, @errorName(err) });
            };
            return .{
                .build_zig_basename = build_zig_basename,
                .directory = .{ .path = dirname, .handle = dir },
                .cleanup_build_dir = dir,
            };
        }

        return .{
            .build_zig_basename = build_zig_basename,
            .directory = .{ .path = null, .handle = cwd },
            .cleanup_build_dir = null,
        };
    }
    // Search up parent directories until we find build.zig.
    var dirname: []const u8 = cwd_path;
    while (true) {
        const joined_path = try fs.path.join(arena, &[_][]const u8{ dirname, build_zig_basename });
        if (cwd.access(io, joined_path, .{})) |_| {
            const dir = cwd.openDir(io, dirname, .{ .iterate = true }) catch |err| {
                errExit("unable to open directory while searching for build.zig file, '{s}': {s}", .{ dirname, @errorName(err) });
            };

            if (try caseMatches(dir, build_zig_basename)) return .{
                .build_zig_basename = build_zig_basename,
                .directory = .{
                    .path = dirname,
                    .handle = dir,
                },
                .cleanup_build_dir = dir,
            };
        } else |err| switch (err) {
            error.FileNotFound => {},
            else => |e| return e,
        }
        dirname = fs.path.dirname(dirname) orelse return null;
    }
}

fn caseMatches(iterable_dir: Dir, name: []const u8) !bool {
    // TODO: maybe there is more efficient platform-specific mechanisms to implement this?
    var iterator = iterable_dir.iterate();
    var found_case_insensitive_match = false;
    while (try iterator.next(global.io)) |entry| {
        if (std.mem.eql(u8, entry.name, name)) return true;
        found_case_insensitive_match = found_case_insensitive_match or std.ascii.eqlIgnoreCase(entry.name, name);
    }
    if (!found_case_insensitive_match) return error.FileNotFound;
    return false;
}

fn errExit(comptime format: []const u8, args: anytype) noreturn {
    log.err(format, args);
    process.exit(1);
}
pub fn oom(e: error{OutOfMemory}) noreturn {
    @panic(@errorName(e));
}
