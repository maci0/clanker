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
const plugin_state = @import("../util/plugin_state.zig");

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

/// The enabled-list. Missing state file means everything is off. The read,
/// parse and failure posture live in `util/plugin_state.zig`, shared with the
/// TUI slash-command surface so the two tiers cannot drift apart.
pub fn loadEnabled(io: std.Io, arena: std.mem.Allocator) []const []const u8 {
    return plugin_state.loadEnabled(io, arena, std.Io.Dir.cwd(), state_path, "CLI");
}

/// Consent check against the enabled-list; shared with the TUI surface.
pub const isEnabled = plugin_state.isEnabled;

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

    // Bounded like the TUI surface's scanAll: a directory walk never reads
    // more than max_dir_entries manifests.
    var seen: usize = 0;
    var it = dir.iterate();
    while (it.next(io) catch null) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.name, ".json")) continue;
        seen += 1;
        if (seen > max_dir_entries) break;
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

/// Tier 2 as the dispatcher may use it: discovery **and** consent.
///
/// `findTier2` is the bare PATH/home-dir walk, which `clanker help` wants
/// ungated so it can list an installed-but-off plugin. Nothing may *run* a
/// name the operator has not enabled. PRD 0012 Design: "Presence of a manifest
/// or PATH binary is not consent to run it; the operator enables each name
/// explicitly." The dispatcher used to call `findTier2` directly, so any
/// executable `clanker-<word>` anywhere on PATH was spawned unsandboxed by a
/// bare `clanker <word>` with no opt-in — and *disabling* a Tier 1 manifest
/// promoted the unsandboxed binary of the same name into its place, inverting
/// "narrowest trust wins ties".
pub fn resolveTier2(
    io: std.Io,
    arena: std.mem.Allocator,
    environ_map: *const std.process.Environ.Map,
    name: []const u8,
    enabled: []const []const u8,
) ?[]const u8 {
    if (!isEnabled(enabled, name)) return null;
    return findTier2(io, arena, environ_map, name);
}

fn executable(io: std.Io, path: []const u8) bool {
    const stat = std.Io.Dir.cwd().statFile(io, path, .{}) catch return false;
    if (stat.kind != .file) return false;
    return (stat.permissions.toMode() & 0o111) != 0;
}

/// Writes the enabled-list back to state/cli_plugins.json (used by tests and
/// any future toggle surface).
pub fn saveEnabled(io: std.Io, gpa: std.mem.Allocator, enabled: []const []const u8) !void {
    return plugin_state.saveEnabled(io, gpa, std.Io.Dir.cwd(), state_path, enabled);
}

test "a PATH binary is discovered but not run until the enabled-list names it" {
    const io = std.testing.io;
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const atomic_write = @import("../util/atomic_write.zig");
    const mode_755: std.Io.File.Permissions = @enumFromInt(@as(std.posix.mode_t, 0o755));
    atomic_write.writeFilePerms(io, tmp.dir, "clanker-myreport", "#!/bin/sh\nexit 0\n", mode_755) catch
        return error.SkipZigTest;

    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(io, &root_buf);
    var env = std.process.Environ.Map.init(std.testing.allocator);
    defer env.deinit();
    try env.put("PATH", root_buf[0..root_len]);

    // Discovery is unchanged: `clanker help` lists an installed plugin whether
    // or not it is enabled, which is how an operator finds the name to enable.
    try std.testing.expect(findTier2(io, arena, &env, "myreport") != null);

    // Consent is separate. The dispatcher goes through resolveTier2, and an
    // empty enabled-list must not resolve to an unsandboxed exec.
    try std.testing.expect(resolveTier2(io, arena, &env, "myreport", &.{}) == null);
    const other = [_][]const u8{"somethingelse"};
    try std.testing.expect(resolveTier2(io, arena, &env, "myreport", &other) == null);

    const on = [_][]const u8{"myreport"};
    const path = resolveTier2(io, arena, &env, "myreport", &on) orelse return error.EnabledPluginNotResolved;
    try std.testing.expect(std.mem.endsWith(u8, path, "/clanker-myreport"));
}
