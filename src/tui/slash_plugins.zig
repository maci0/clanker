//! TUI slash-command plugins (PRD 0012 Goal 2).
//!
//! One JSON file per command under the configured plugins dir (default
//! "tui-plugins"):
//!
//!   { "command": "myreport", "help": "Summarize the last N runs",
//!     "tool": "my_report_tool", "args": "" }
//!
//! The REPL scans the dir at startup and appends one CommandSpec per enabled
//! manifest to the built-in command_registry, so /help, tab-complete, the
//! palette and dispatch all see a plugin command exactly like a built-in one.
//! There is no new trust surface: a plugin can only name a tool the sandboxed
//! WASM registry already trusts, and the manifest cannot embed code.
//!
//! Presence on disk is not consent to run: a plugin must be enabled in the
//! state/tui_plugins.json enabled-list (default off), the same stance as
//! state/webui_plugins.json.

const std = @import("std");
const atomic_write = @import("../util/atomic_write.zig");
const log = @import("../util/log.zig");
const test_env = @import("../util/test_env.zig");

pub const state_path = "state/tui_plugins.json";

pub const Manifest = struct {
    /// The slash command, without the leading slash ("myreport" -> /myreport).
    command: []const u8,
    /// One line for the generated /help list. Never empty.
    help: []const u8,
    /// The sandboxed tool this command dispatches to.
    tool: []const u8,
    /// Fixed arguments passed to the tool when the command has none of its own.
    args: []const u8 = "",
};

const max_file_bytes: usize = 16 * 1024;
const max_dir_entries: usize = 128;

/// The enabled-list. Missing state file means everything is off, so a plugin
/// directory someone drops in never starts running on its own.
pub const EnabledState = struct {
    enabled: []const []const u8 = &.{},
};

pub fn loadEnabled(io: std.Io, arena: std.mem.Allocator) []const []const u8 {
    const raw = std.Io.Dir.cwd().readFileAlloc(io, state_path, arena, .limited(max_file_bytes)) catch return &.{};
    const st = std.json.parseFromSliceLeaky(EnabledState, arena, raw, .{ .ignore_unknown_fields = true }) catch return &.{};
    return st.enabled;
}

pub fn isEnabled(enabled: []const []const u8, command: []const u8) bool {
    for (enabled) |name| if (std.mem.eql(u8, name, command)) return true;
    return false;
}

/// Writes the enabled-list back to state/tui_plugins.json.
pub fn saveEnabled(io: std.Io, gpa: std.mem.Allocator, enabled: []const []const u8) !void {
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    var s = std.json.Stringify{ .writer = &out.writer, .options = .{ .emit_null_optional_fields = false } };
    try s.beginObject();
    try s.objectField("enabled");
    try s.beginArray();
    for (enabled) |name| try s.write(name);
    try s.endArray();
    try s.endObject();
    std.Io.Dir.cwd().createDirPath(io, "state") catch {};
    try atomic_write.writeFilePerms(io, std.Io.Dir.cwd(), state_path, out.written(), atomic_write.private_file);
}

/// Scans the plugins dir and returns every valid, non-colliding manifest
/// (enabled or not), so a listing can show both states. builtin_names is the
/// set of existing slash spellings (with leading slash); a manifest colliding
/// with one is refused at scan time and logged, never silently shadowed —
/// matching the tool registry's name-collision posture. A manifest naming an
/// unknown/disabled tool is not refused here: it fails the same way typing
/// /nonexistent does, at dispatch time.
pub fn scanAll(
    io: std.Io,
    arena: std.mem.Allocator,
    base: std.Io.Dir,
    plugins_dir: []const u8,
    builtin_names: []const []const u8,
) ![]const Manifest {
    var out: std.ArrayList(Manifest) = .empty;

    var dir = base.openDir(io, plugins_dir, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => return out.toOwnedSlice(arena),
        else => return err,
    };
    defer dir.close(io);

    var names: std.ArrayList([]const u8) = .empty;
    var it = dir.iterate();
    while (it.next(io) catch null) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.name, ".json")) continue;
        if (names.items.len >= max_dir_entries) break;
        try names.append(arena, try arena.dupe(u8, entry.name));
    }
    std.mem.sort([]const u8, names.items, {}, struct {
        fn lt(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.lessThan(u8, a, b);
        }
    }.lt);

    for (names.items) |fname| {
        const raw = dir.readFileAlloc(io, fname, arena, .limited(max_file_bytes)) catch |err| {
            log.log(.warn, "tui plugin '{s}': unreadable: {s}", .{ fname, @errorName(err) });
            continue;
        };
        const m = std.json.parseFromSliceLeaky(Manifest, arena, raw, .{ .ignore_unknown_fields = true }) catch |err| {
            log.log(.warn, "tui plugin '{s}': bad manifest: {s}", .{ fname, @errorName(err) });
            continue;
        };
        if (m.command.len == 0 or m.tool.len == 0) {
            log.log(.warn, "tui plugin '{s}': manifest needs non-empty command and tool", .{fname});
            continue;
        }
        // A plugin name colliding with a built-in is refused, not shadowed.
        const slash_name = try std.fmt.allocPrint(arena, "/{s}", .{m.command});
        var collides = false;
        for (builtin_names) |b| {
            if (std.mem.eql(u8, b, slash_name)) {
                log.log(.warn, "tui plugin '{s}': command /{s} collides with a built-in command; refused", .{ fname, m.command });
                collides = true;
                break;
            }
        }
        if (collides) continue;
        try out.append(arena, m);
    }

    return out.toOwnedSlice(arena);
}

/// scanAll filtered down to the enabled-list: the REPL's command set.
pub fn loadEnabledManifests(
    io: std.Io,
    arena: std.mem.Allocator,
    base: std.Io.Dir,
    plugins_dir: []const u8,
    enabled: []const []const u8,
    builtin_names: []const []const u8,
) ![]const Manifest {
    const all = try scanAll(io, arena, base, plugins_dir, builtin_names);
    var out: std.ArrayList(Manifest) = .empty;
    for (all) |m| {
        if (isEnabled(enabled, m.command)) try out.append(arena, m);
    }
    return out.toOwnedSlice(arena);
}

test "loadEnabledManifests honors the enabled-list and refuses built-in collisions" {
    var env: test_env.Env = .init();
    defer env.deinit();
    const io = env.io();
    const arena = env.arena();

    try env.tmp.dir.makePath(io, "tui-plugins");
    const good = try std.json.stringifyAlloc(arena, .{
        .command = "myreport",
        .help = "Summarize the last N runs",
        .tool = "graph",
        .args = "list",
    }, .{});
    try env.tmp.dir.writeFile(io, "tui-plugins/good.json", good);
    const off = try std.json.stringifyAlloc(arena, .{
        .command = "disabledcmd",
        .help = "not enabled",
        .tool = "status",
    }, .{});
    try env.tmp.dir.writeFile(io, "tui-plugins/off.json", off);
    const clash = try std.json.stringifyAlloc(arena, .{
        .command = "help",
        .help = "collides with a built-in",
        .tool = "status",
    }, .{});
    try env.tmp.dir.writeFile(io, "tui-plugins/clash.json", clash);

    const builtin_names = [_][]const u8{"/help"};
    const enabled = [_][]const u8{"myreport"};
    const found = try loadEnabledManifests(io, arena, env.tmp.dir, "tui-plugins", &enabled, &builtin_names);

    // Only the enabled, non-colliding plugin is loaded.
    try std.testing.expectEqual(@as(usize, 1), found.len);
    try std.testing.expectEqualStrings("myreport", found[0].command);
    try std.testing.expectEqualStrings("graph", found[0].tool);
}
