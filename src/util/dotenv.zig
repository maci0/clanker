//! Minimal .env loader: reads KEY=VALUE lines from $CLANKER_ENV_FILE (or
//! ./.env) and fills them into the process environ map WITHOUT overriding
//! values already present in the real environment. Lines starting with '#'
//! are comments; an optional `export ` prefix is accepted; values may be
//! single- or double-quoted.

const std = @import("std");
const log = @import("log.zig");

pub fn load(io: std.Io, gpa: std.mem.Allocator, environ_map: *std.process.Environ.Map) void {
    loadFromDir(io, gpa, environ_map, std.Io.Dir.cwd());
}

pub fn loadFromDir(io: std.Io, gpa: std.mem.Allocator, environ_map: *std.process.Environ.Map, base: std.Io.Dir) void {
    const path: ?[]const u8 = if (environ_map.get("CLANKER_ENV_FILE")) |p| (if (p.len > 0) p else null) else null;

    const data = if (path) |p|
        base.readFileAlloc(io, p, gpa, .limited(1 << 16)) catch |err| {
            log.log(.warn, "cannot read CLANKER_ENV_FILE '{s}': {s}", .{ p, @errorName(err) });
            return;
        }
    else
        base.readFileAlloc(io, ".env", gpa, .limited(1 << 16)) catch |err| switch (err) {
            // A checkout with no .env is the normal state for a machine that
            // sets real environment variables; stay silent there. Anything
            // else -- permission denied, a file over the 64 KiB cap -- would
            // otherwise load no keys at all and surface as a baffling
            // "X_API_KEY not set" on the first provider call, so name it now.
            error.FileNotFound => return,
            else => {
                log.log(.warn, "cannot read .env: {s} (real environment variables still apply)", .{@errorName(err)});
                return;
            },
        };
    defer gpa.free(data);

    var loaded: usize = 0;
    var it = std.mem.splitScalar(u8, data, '\n');
    while (it.next()) |raw| {
        var line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0 or line[0] == '#') continue;
        if (std.mem.startsWith(u8, line, "export")) {
            const after_export = line["export".len..];
            if (after_export.len > 0 and (after_export[0] == ' ' or after_export[0] == '\t')) {
                line = std.mem.trimStart(u8, after_export, " \t");
            }
        }
        const eq = std.mem.findScalar(u8, line, '=') orelse continue;
        const key = std.mem.trim(u8, line[0..eq], " \t");
        if (key.len == 0) continue;
        var value = std.mem.trim(u8, line[eq + 1 ..], " \t");
        if (value.len >= 2 and ((value[0] == '"' and value[value.len - 1] == '"') or (value[0] == '\'' and value[value.len - 1] == '\''))) {
            value = value[1 .. value.len - 1];
        }
        if (environ_map.get(key) != null) continue; // real env vars win
        environ_map.put(key, value) catch continue;
        loaded += 1;
    }
    if (loaded > 0) {
        log.log(.debug, "loaded {d} key(s) from {s}", .{ loaded, path orelse ".env" });
    }
}

// ------------------------------------------------------------------- tests --

test "dotenv parses and fills the environ map without overriding" {
    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    // Silence the loader's debug log: stderr output from a test while the
    // runner is in --listen mode breaks the test protocol. Restored after,
    // since std.testing runs all tests in one process and a level left
    // dirty here would silence logs for every test that runs after.
    const saved_level = log.getLevel();
    log.setLevel(.warn);
    defer log.setLevel(saved_level);
    // Use a temp dir with a .env file.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = ".env", .data =
        \\# comment
        \\FOO=bar
        \\export QUOTED="hello world"
        \\EMPTY=
        \\SINGLE='single quoted'
        \\ALREADY=from-dotenv
        \\
    });

    var env = std.process.Environ.Map.init(std.testing.allocator);
    defer env.deinit();
    try env.put("ALREADY", "from-real-env");

    loadFromDir(io, std.testing.allocator, &env, tmp.dir);

    try std.testing.expectEqualStrings("bar", env.get("FOO").?);
    try std.testing.expectEqualStrings("hello world", env.get("QUOTED").?);
    try std.testing.expectEqualStrings("", env.get("EMPTY").?);
    try std.testing.expectEqualStrings("single quoted", env.get("SINGLE").?);
    try std.testing.expectEqualStrings("from-real-env", env.get("ALREADY").?);
}

test "dotenv accepts a tab after export" {
    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const saved_level = log.getLevel();
    log.setLevel(.warn);
    defer log.setLevel(saved_level);

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = ".env", .data = "export\tTABBED='tab value'\n" });

    var env = std.process.Environ.Map.init(std.testing.allocator);
    defer env.deinit();
    loadFromDir(io, std.testing.allocator, &env, tmp.dir);

    try std.testing.expectEqualStrings("tab value", env.get("TABBED").?);
}
