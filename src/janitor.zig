//! `clanker prune`: the janitor. Sweeps up what the harness leaves behind.
//!
//! Three kinds of litter, all of them real rather than hypothetical:
//!
//!   - **Orphaned staging directories.** The improvement engine copies the
//!     project into `state/staging/imp-<id>` to run its gates, and removes it
//!     on every exit path it knows about. A run that is killed, crashes, or is
//!     interrupted never reaches those paths, and the copy stays. One of them
//!     is a few hundred megabytes.
//!   - **Run graphs.** One JSON per run, kept forever; a busy instance
//!     accumulates thousands.
//!   - **Improve logs.** One per improvement attempt.
//!
//! Deleting is not undoable, so this reports by default and only removes when
//! told to. Every candidate is matched against an exact shape under the
//! configured state directory: a wrong argument here would eat a working tree,
//! which is why `removeTree` in improve/engine.zig carries the same warning.

const std = @import("std");
const config = @import("config.zig");
const diskcap = @import("util/diskcap.zig");
const log = @import("util/log.zig");
const chatrooms = @import("peers/chatrooms.zig");

/// How much of each kind is kept. The newest survive; the rest are litter.
/// Generous on purpose: pruning is for reclaiming hundreds of megabytes, not
/// for keeping a directory tidy.
const keep_runs: usize = 200;
const keep_logs: usize = 20;

const Candidate = struct {
    path: []const u8,
    bytes: u64,
    kind: Kind,

    const Kind = enum { staging, run, improve_log };
};

/// Exactly `imp-` followed by digits, the shape the engine mints. Anything
/// else in the staging directory was not put there by us and is left alone.
fn isImpId(name: []const u8) bool {
    if (!std.mem.startsWith(u8, name, "imp-")) return false;
    if (name.len <= 4) return false;
    for (name[4..]) |c| {
        if (!std.ascii.isDigit(c)) return false;
    }
    return true;
}

fn isRunGraph(name: []const u8) bool {
    return std.mem.startsWith(u8, name, "run-") and std.mem.endsWith(u8, name, ".json");
}

fn isImproveLog(name: []const u8) bool {
    return std.mem.startsWith(u8, name, "improve-") and std.mem.endsWith(u8, name, ".log");
}

fn lessThanName(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.lessThan(u8, a, b);
}

/// Every name in `dir` passing `match`, sorted. Both run graphs and improve
/// logs carry a timestamp in the name, so name order is age order and no stat
/// call is needed to decide what is oldest.
fn namesIn(
    io: std.Io,
    arena: std.mem.Allocator,
    rel: []const u8,
    match: *const fn ([]const u8) bool,
) ![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    var dir = std.Io.Dir.cwd().openDir(io, rel, .{ .iterate = true }) catch return &.{};
    defer dir.close(io);
    var it = dir.iterate();
    while (it.next(io) catch null) |entry| {
        if (entry.kind != .file) continue;
        if (!match(entry.name)) continue;
        try out.append(arena, try arena.dupe(u8, entry.name));
    }
    std.mem.sort([]const u8, out.items, {}, lessThanName);
    return out.items;
}

/// What could be reclaimed, newest-first survivors excluded. Read-only.
pub fn scan(io: std.Io, arena: std.mem.Allocator, state_dir: []const u8) ![]const Candidate {
    var out: std.ArrayList(Candidate) = .empty;

    // Staging: every directory here is an orphan by definition. A live run
    // holds its own copy and removes it when it finishes, so anything still
    // present belongs to a run that is no longer running.
    const staging_rel = try std.fmt.allocPrint(arena, "{s}/staging", .{state_dir});
    if (std.Io.Dir.cwd().openDir(io, staging_rel, .{ .iterate = true })) |*d| {
        var dir = d.*;
        defer dir.close(io);
        var it = dir.iterate();
        while (it.next(io) catch null) |entry| {
            if (entry.kind != .directory) continue;
            if (!isImpId(entry.name)) continue;
            const rel = try std.fmt.allocPrint(arena, "{s}/{s}", .{ staging_rel, entry.name });
            try out.append(arena, .{
                .path = rel,
                .bytes = diskcap.dirSize(io, std.Io.Dir.cwd(), arena, rel),
                .kind = .staging,
            });
        }
    } else |_| {}

    try collectOldest(io, arena, state_dir, "runs", isRunGraph, keep_runs, .run, &out);
    try collectOldest(io, arena, state_dir, "logs", isImproveLog, keep_logs, .improve_log, &out);
    return out.items;
}

fn collectOldest(
    io: std.Io,
    arena: std.mem.Allocator,
    state_dir: []const u8,
    sub: []const u8,
    match: *const fn ([]const u8) bool,
    keep: usize,
    kind: Candidate.Kind,
    out: *std.ArrayList(Candidate),
) !void {
    const rel = try std.fmt.allocPrint(arena, "{s}/{s}", .{ state_dir, sub });
    const names = try namesIn(io, arena, rel, match);
    if (names.len <= keep) return;
    for (names[0 .. names.len - keep]) |name| {
        const path = try std.fmt.allocPrint(arena, "{s}/{s}", .{ rel, name });
        const size = blk: {
            const f = std.Io.Dir.cwd().openFile(io, path, .{}) catch break :blk 0;
            defer f.close(io);
            const st = f.stat(io) catch break :blk 0;
            break :blk st.size;
        };
        try out.append(arena, .{ .path = path, .bytes = size, .kind = kind });
    }
}

/// Guard: a candidate must sit under the configured state directory in one of
/// the three shapes above. Checked again at the moment of deletion rather than
/// trusted from the scan, because this is the last thing standing between a
/// bad path and a recursive delete.
pub fn removable(state_dir: []const u8, path: []const u8) bool {
    if (std.mem.indexOf(u8, path, "..") != null) return false;
    var buf: [512]u8 = undefined;
    const staging_prefix = std.fmt.bufPrint(&buf, "{s}/staging/imp-", .{state_dir}) catch return false;
    if (std.mem.startsWith(u8, path, staging_prefix)) {
        return isImpId(path[staging_prefix.len - "imp-".len ..]);
    }
    var buf2: [512]u8 = undefined;
    const runs_prefix = std.fmt.bufPrint(&buf2, "{s}/runs/", .{state_dir}) catch return false;
    if (std.mem.startsWith(u8, path, runs_prefix)) return isRunGraph(path[runs_prefix.len..]);
    var buf3: [512]u8 = undefined;
    const logs_prefix = std.fmt.bufPrint(&buf3, "{s}/logs/", .{state_dir}) catch return false;
    if (std.mem.startsWith(u8, path, logs_prefix)) return isImproveLog(path[logs_prefix.len..]);
    return false;
}

fn human(buf: []u8, bytes: u64) []const u8 {
    if (bytes >= 1024 * 1024 * 1024) return std.fmt.bufPrint(buf, "{d:.1} GB", .{@as(f64, @floatFromInt(bytes)) / (1024.0 * 1024.0 * 1024.0)}) catch "?";
    if (bytes >= 1024 * 1024) return std.fmt.bufPrint(buf, "{d:.1} MB", .{@as(f64, @floatFromInt(bytes)) / (1024.0 * 1024.0)}) catch "?";
    if (bytes >= 1024) return std.fmt.bufPrint(buf, "{d} KB", .{bytes / 1024}) catch "?";
    return std.fmt.bufPrint(buf, "{d} B", .{bytes}) catch "?";
}

/// The janitor's own lines.
///
/// Styled on the gym-cleaner character the request names: he apologises for
/// cleaning around you, deflects any credit ("I am only cleaner"), and
/// understates whatever he just did. The defining trait is that he barely
/// speaks at all, so these are short and few on purpose — a mascot with a
/// joke for every occasion would be a different, worse character.
///
/// Verbatim transcripts were not reachable (YouTube captions are not fetchable
/// here and the transcript mirror refuses), so this follows the documented
/// behaviour rather than quoting lines that could not be checked.
const quips = [_][]const u8{
    "Sorry. I clean here.",
    "Is nothing. Small job.",
    "I am only cleaner.",
    "Excuse me. One moment.",
    "Is my job, hehe.",
    "Okay. Floor good now.",
};

fn quip(n: usize) []const u8 {
    return quips[n % quips.len];
}

/// The janitor says his piece in the room, not only on stdout. He is a peer
/// like any other: the message lands in the room log, so it shows up in Rooms,
/// in any subscribed peer's log, and - because the office animates chat the
/// same way for everybody - as his avatar speaking on the floor. One code path
/// for "someone said something", rather than a special case for the mascot.
fn announce(init: std.process.Init, arena: std.mem.Allocator, cfg: *const config.Config, text: []const u8) void {
    if (!cfg.modules.chatrooms or !cfg.chatrooms.on) return;
    const room = if (cfg.chatrooms.rooms.len > 0) cfg.chatrooms.rooms[0] else "general";
    _ = chatrooms.sendMessage(
        std.Io.Dir.cwd(),
        init.io,
        init.gpa,
        arena,
        cfg.agent.state_dir,
        cfg,
        room,
        text,
    ) catch |err| {
        // Saying so is a courtesy; failing to say it must not fail the sweep.
        log.log(.debug, "janitor could not speak in #{s}: {s}", .{ room, @errorName(err) });
    };
}

pub fn cmdPrune(init: std.process.Init, apply: bool) !void {
    const io = init.io;
    const arena = init.arena.allocator();
    const cfg = try config.Config.load(io, arena, std.Io.Dir.cwd(), "config.json", "config.local.json");
    const state_dir = cfg.agent.state_dir;

    const candidates = try scan(io, arena, state_dir);

    var out = std.Io.File.stdout().writer(io, &.{});
    const w = &out.interface;

    var total: u64 = 0;
    var staging_n: usize = 0;
    var runs_n: usize = 0;
    var logs_n: usize = 0;
    for (candidates) |c| {
        total += c.bytes;
        switch (c.kind) {
            .staging => staging_n += 1,
            .run => runs_n += 1,
            .improve_log => logs_n += 1,
        }
    }

    if (candidates.len == 0) {
        w.writeAll("Floor is clean. I sit down now.\n") catch {};
        out.interface.flush() catch {};
        return;
    }

    var hbuf: [32]u8 = undefined;
    w.print("{s}\n\n", .{quip(candidates.len)}) catch {};
    w.print("{s} reclaimable\n", .{human(&hbuf, total)}) catch {};
    if (staging_n > 0) w.print("  {d} orphaned staging director{s} (a killed improve run leaves its copy behind)\n", .{ staging_n, if (staging_n == 1) @as([]const u8, "y") else "ies" }) catch {};
    if (runs_n > 0) w.print("  {d} run graphs beyond the newest {d}\n", .{ runs_n, keep_runs }) catch {};
    if (logs_n > 0) w.print("  {d} improve logs beyond the newest {d}\n", .{ logs_n, keep_logs }) catch {};

    if (!apply) {
        w.writeAll("\nNothing was deleted. Re-run with --yes to remove it.\n") catch {};
        out.interface.flush() catch {};
        return;
    }

    var removed: u64 = 0;
    var failed: usize = 0;
    for (candidates) |c| {
        if (!removable(state_dir, c.path)) {
            log.log(.warn, "refusing to remove '{s}': not a prunable path", .{c.path});
            failed += 1;
            continue;
        }
        switch (c.kind) {
            .staging => diskcap.removeTree(init.gpa, io, std.Io.Dir.cwd(), c.path),
            .run, .improve_log => std.Io.Dir.cwd().deleteFile(io, c.path) catch {
                failed += 1;
                continue;
            },
        }
        removed += c.bytes;
    }
    const closing = quip(candidates.len + 1);
    w.print("\n{s}\nRemoved {s}.", .{ closing, human(&hbuf, removed) }) catch {};
    var said: [256]u8 = undefined;
    if (std.fmt.bufPrint(&said, "{s} Was {s} on floor. Is clean now.", .{ closing, human(&hbuf, removed) })) |line| {
        announce(init, arena, &cfg, line);
    } else |_| {}
    if (failed > 0) w.print(" {d} could not be removed.", .{failed}) catch {};
    w.writeAll("\n") catch {};
    out.interface.flush() catch {};
}

test "the janitor always has something to say" {
    // Indexing must not fall off the end however many candidates there are.
    try std.testing.expect(quip(0).len > 0);
    try std.testing.expect(quip(quips.len).len > 0);
    try std.testing.expect(quip(99999).len > 0);
    try std.testing.expectEqualStrings(quip(0), quip(quips.len));
}

test "only the three known shapes are removable" {
    // The guard is the last thing between a bad path and a recursive delete,
    // so it is tested against what a mistake would actually look like.
    try std.testing.expect(removable("state", "state/staging/imp-123"));
    try std.testing.expect(removable("state", "state/runs/run-1786.json"));
    try std.testing.expect(removable("state", "state/logs/improve-2026.log"));

    try std.testing.expect(!removable("state", "state/staging/imp-abc"));
    try std.testing.expect(!removable("state", "state/staging"));
    try std.testing.expect(!removable("state", "state/sessions/a.json"));
    try std.testing.expect(!removable("state", "state/runs/../../src"));
    try std.testing.expect(!removable("state", "src"));
    try std.testing.expect(!removable("state", "/etc/passwd"));
    try std.testing.expect(!removable("state", "state/runs/notes.txt"));
    try std.testing.expect(!removable("state", "state/logs/secrets.env"));
    // A different state dir does not make another one's paths removable.
    try std.testing.expect(!removable("other", "state/staging/imp-123"));
}

test "name shapes" {
    try std.testing.expect(isImpId("imp-1786420742038140993"));
    try std.testing.expect(!isImpId("imp-"));
    try std.testing.expect(!isImpId("imp-12a"));
    try std.testing.expect(isRunGraph("run-1786362799.json"));
    try std.testing.expect(!isRunGraph("run-1786362799.json.bak"));
    try std.testing.expect(isImproveLog("improve-20260810-194610.log"));
    try std.testing.expect(!isImproveLog("webui-loop-wrapper.log"));
}
