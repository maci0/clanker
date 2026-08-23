//! CLI plugins (PRD 0012 Goal 3).
//!
//! Tier 1 — one JSON file per command under the configured plugins dir
//! (default "cli-plugins"):
//!
//!   { "command": "myreport", "description": "Summarize the last N runs",
//!     "tool": "my_report_tool" }
//!
//! `clanker myreport --since 7d` resolves the manifest and invokes the
//! sandboxed tool non-interactively with the remaining argv passed as
//! {"args":["--since","7d"]} — no new trust surface, the tool's own
//! descriptor already declares its reach.
//!
//! Tier 2 — `clanker-<name>` binaries found on PATH and under
//! ~/.clanker/plugins/, exec'd with the remaining argv and inherited stdio.
//! Real code execution with no sandbox, trusted like anything else the
//! operator put on their own PATH.
//!
//! Order: built-in Command first (never shadowed by a plugin), then Tier 1
//! (sandboxed, declarative), then Tier 2 (external, operator-trusted) —
//! narrowest trust wins ties. Presence on disk is not consent to run: a
//! plugin must be enabled in the state/cli_plugins.json enabled-list
//! (default off), the same stance as state/webui_plugins.json.

const std = @import("std");
const log = @import("../util/log.zig");

pub const state_path = "state/cli_plugins.json";

pub const Manifest = struct {
    /// The subcommand name (`clanker <command> [args...]`).
    command: []const u8,
    /// One line for `clanker help` / listing.
    description: []const u8 = "",
    /// The sandboxed WASM tool this command dispatches to.
    tool: []const u8,
};

const max_file_bytes: usize = 16 * 1024;
const max_dir_entries: usize = 128;

/// The enabled-list. Missing state file means everything is off.
pub const EnabledState = struct {
    enabled: []const []const u8 = &.{},
};

pub fn loadEnabled(io: std.Io, arena: std.mem.Allocator) []const []const u8 {
    const raw = std.Io.Dir.cwd().readFileAlloc(io, state_path, arena, .limited(max_file_bytes)) catch |err| {
        // A missing state file is the normal everything-off default. Any
        // other failure silently disabling every plugin is the defect PRD
        // 0012's failure modes forbid: empty enabled-list, plus a warning.
        if (err != error.FileNotFound)
            log.log(.warn, "{s}: unreadable ({s}); treating every CLI plugin as disabled", .{ state_path, @errorName(err) });
        return &.{};
    };
    return parseEnabled(arena, raw) orelse {
        log.log(.warn, "{s}: not valid state JSON; treating every CLI plugin as disabled until the next toggle rewrites it", .{state_path});
        return &.{};
    };
}

/// The parsed enabled-list, or null when the bytes are not the state file's
/// shape. Split from loadEnabled so the corrupt-file fallback is testable.
fn parseEnabled(arena: std.mem.Allocator, raw: []const u8) ?[]const []const u8 {
    const st = std.json.parseFromSliceLeaky(EnabledState, arena, raw, .{ .ignore_unknown_fields = true }) catch return null;
    return st.enabled;
}

test "parseEnabled reads the enabled-list and refuses corrupt bytes" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const good = parseEnabled(arena, "{\"enabled\":[\"myreport\"]}").?;
    try std.testing.expectEqual(@as(usize, 1), good.len);
    try std.testing.expectEqualStrings("myreport", good[0]);
    // Corrupt bytes and a wrong shape both fall back to null, which
    // loadEnabled turns into "everything off" plus a warning.
    try std.testing.expect(parseEnabled(arena, "{not json") == null);
    try std.testing.expect(parseEnabled(arena, "42") == null);
}

pub fn isEnabled(enabled: []const []const u8, command: []const u8) bool {
    for (enabled) |name| if (std.mem.eql(u8, name, command)) return true;
    return false;
}

/// Tier 1: the enabled manifest whose command matches, or null.
pub fn resolveTier1(
    io: std.Io,
    arena: std.mem.Allocator,
    base: std.Io.Dir,
    plugins_dir: []const u8,
    command: []const u8,
    enabled: []const []const u8,
) ?Manifest {
    var dir = base.openDir(io, plugins_dir, .{ .iterate = true }) catch return null;
    defer dir.close(io);

    var it = dir.iterate();
    while (it.next(io) catch null) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.name, ".json")) continue;
        const raw = dir.readFileAlloc(io, entry.name, arena, .limited(max_file_bytes)) catch continue;
        const m = std.json.parseFromSliceLeaky(Manifest, arena, raw, .{ .ignore_unknown_fields = true }) catch continue;
        if (m.tool.len == 0) continue;
        if (!std.mem.eql(u8, m.command, command)) continue;
        if (!isEnabled(enabled, command)) return null;
        return m;
    }
    return null;
}

/// Tier 2: the absolute path of `clanker-<name>` on PATH or under
/// ~/.clanker/plugins/, or null when not found.
pub fn findTier2(
    io: std.Io,
    arena: std.mem.Allocator,
    environ_map: *const std.process.Environ.Map,
    name: []const u8,
) ?[]const u8 {
    const exe = std.fmt.allocPrint(arena, "clanker-{s}", .{name}) catch return null;
    // Reject names that could escape the executable-name shape; a plugin is
    // a bare word by construction (parse rejects multi-word commands), so
    // this is defense in depth for the PATH walk below.
    for (exe) |c| {
        if (!(std.ascii.isAlphanumeric(c) or c == '-' or c == '_' or c == '.')) return null;
    }

    if (environ_map.get("PATH")) |path_var| {
        var it = std.mem.splitScalar(u8, path_var, ':');
        while (it.next()) |dir_name| {
            if (dir_name.len == 0) continue;
            const candidate = std.fmt.allocPrint(arena, "{s}/{s}", .{ dir_name, exe }) catch continue;
            if (executable(io, candidate)) return candidate;
        }
    }
    if (environ_map.get("HOME")) |home| {
        const candidate = std.fmt.allocPrint(arena, "{s}/.clanker/plugins/{s}", .{ home, exe }) catch return null;
        if (executable(io, candidate)) return candidate;
    }
    return null;
}

fn executable(io: std.Io, path: []const u8) bool {
    const stat = std.Io.Dir.cwd().statFile(io, path, .{}) catch return false;
    if (stat.kind != .file) return false;
    return (stat.permissions.toMode() & 0o111) != 0;
}

/// Writes the enabled-list back to state/cli_plugins.json (used by tests and
/// any future toggle surface).
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
    const atomic_write = @import("../util/atomic_write.zig");
    try atomic_write.writeFilePerms(io, std.Io.Dir.cwd(), state_path, out.written(), atomic_write.private_file);
}
