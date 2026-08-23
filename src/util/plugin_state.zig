//! The plugin enabled-list shared by the CLI command plugins
//! (`src/cli/cli_plugins.zig`) and the TUI slash-command plugins
//! (`src/tui/slash_plugins.zig`), both PRD 0012.
//!
//! Each surface keeps its own state file (`state/cli_plugins.json`,
//! `state/tui_plugins.json`) with one shape: `{"enabled":["name",...]}`.
//! Presence of a manifest or PATH binary is not consent to run; only a name
//! on this list runs. Missing file means everything off, and so does any
//! unreadable or wrong-shape body — plus a warning, because silently
//! disabling every plugin is the failure mode PRD 0012 forbids. One
//! implementation here keeps that posture identical across both surfaces.

const std = @import("std");
const atomic_write = @import("atomic_write.zig");
const log = @import("log.zig");

/// Ceiling for one state file. A list longer than this is not an enabled-list
/// anyone maintains by hand; refusing to read it falls back to "everything
/// off", which is the safe side.
pub const max_file_bytes: usize = 16 * 1024;

/// The enabled-list. Missing state file means everything is off.
pub const EnabledState = struct {
    enabled: []const []const u8 = &.{},
};

/// Reads the enabled-list at `base/state_path`. `surface` names the tier in
/// the warning text ("CLI" / "TUI").
pub fn loadEnabled(
    io: std.Io,
    arena: std.mem.Allocator,
    base: std.Io.Dir,
    state_path: []const u8,
    surface: []const u8,
) []const []const u8 {
    const raw = base.readFileAlloc(io, state_path, arena, .limited(max_file_bytes)) catch |err| {
        // A missing state file is the normal everything-off default. Any
        // other failure silently disabling every plugin is the defect PRD
        // 0012's failure modes forbid: empty enabled-list, plus a warning.
        if (err != error.FileNotFound)
            log.log(.warn, "{s}: unreadable ({s}); treating every {s} plugin as disabled", .{ state_path, @errorName(err), surface });
        return &.{};
    };
    return parseEnabled(arena, raw) orelse {
        log.log(.warn, "{s}: not valid state JSON; treating every {s} plugin as disabled until the next toggle rewrites it", .{ state_path, surface });
        return &.{};
    };
}

/// The parsed enabled-list, or null when the bytes are not the state file's
/// shape. Split from `loadEnabled` so the corrupt-file fallback is testable.
pub fn parseEnabled(arena: std.mem.Allocator, raw: []const u8) ?[]const []const u8 {
    const st = std.json.parseFromSliceLeaky(EnabledState, arena, raw, .{ .ignore_unknown_fields = true }) catch return null;
    return st.enabled;
}

pub fn isEnabled(enabled: []const []const u8, name: []const u8) bool {
    for (enabled) |candidate| if (std.mem.eql(u8, candidate, name)) return true;
    return false;
}

/// Writes the enabled-list back atomically (used by toggles and tests).
pub fn saveEnabled(
    io: std.Io,
    gpa: std.mem.Allocator,
    base: std.Io.Dir,
    state_path: []const u8,
    enabled: []const []const u8,
) !void {
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    var s = std.json.Stringify{ .writer = &out.writer, .options = .{ .emit_null_optional_fields = false } };
    try s.beginObject();
    try s.objectField("enabled");
    try s.beginArray();
    for (enabled) |name| try s.write(name);
    try s.endArray();
    try s.endObject();
    if (std.fs.path.dirname(state_path)) |dir| base.createDirPath(io, dir) catch {};
    try atomic_write.writeFilePerms(io, base, state_path, out.written(), atomic_write.private_file);
}

// ------------------------------------------------------------------- tests --

const testing = std.testing;
const test_env = @import("test_env.zig");

test "parseEnabled reads the enabled-list and refuses corrupt bytes" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const good = parseEnabled(arena, "{\"enabled\":[\"myreport\",\"other\"]}").?;
    try testing.expectEqual(@as(usize, 2), good.len);
    try testing.expectEqualStrings("myreport", good[0]);
    // Corrupt bytes and a wrong shape both fall back to null, which
    // loadEnabled turns into "everything off" plus a warning.
    try testing.expect(parseEnabled(arena, "{not json") == null);
    try testing.expect(parseEnabled(arena, "42") == null);
    try testing.expect(parseEnabled(arena, "[\"myreport\"]") == null);
}

test "isEnabled answers membership exactly" {
    const enabled = [_][]const u8{ "a", "b" };
    try testing.expect(isEnabled(&enabled, "a"));
    try testing.expect(!isEnabled(&enabled, "c"));
    try testing.expect(!isEnabled(&.{}, "a"));
}

test "loadEnabled reads a saved list; missing file means everything off" {
    var env: test_env.Env = .init();
    defer env.deinit();
    const io = env.io();

    // Missing file: the normal everything-off default, no error.
    try testing.expectEqual(@as(usize, 0), loadEnabled(io, env.arena(), env.tmp.dir, "state/plugins.json", "Test").len);

    try saveEnabled(io, testing.allocator, env.tmp.dir, "state/plugins.json", &.{ "one", "two" });
    const loaded = loadEnabled(io, env.arena(), env.tmp.dir, "state/plugins.json", "Test");
    try testing.expectEqual(@as(usize, 2), loaded.len);
    try testing.expectEqualStrings("one", loaded[0]);
    try testing.expect(isEnabled(loaded, "two"));
}
