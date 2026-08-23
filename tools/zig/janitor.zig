//! janitor: sweep up what old runs left behind.
//!
//! Scans state/ for orphaned staging directories, excess run graphs, excess
//! improve logs, compare-and-swap lock files nothing has re-acquired in half a
//! day, and spilled tool results past their retention. Returns a summary (scan)
//! or deletes and reports (prune).
//!
//! Input:  {"op": "scan"|"prune"|"json", "state_dir": "state"}
//! Output: {"ok": true, "text": "...", "items": N, "bytes": N}
//!
//! Moved from src/janitor.zig: bounded fs work, rare invocation, fully
//! outside the trust boundary.

const std = @import("std");
const lib = @import("lib.zig");
const graph_listing = @import("graph_listing.zig");
const cas_lock_record = @import("cas_lock_record.zig");
const spill_logic = @import("spill_logic.zig");

const keep_runs: usize = 200;
const keep_logs: usize = 20;

/// How long a compare-and-swap lock file is kept after its last acquisition.
///
/// From the shared record module, because the host sweeps the same directory on
/// the `ck_fs_write_if` path: a second copy of the number here would be a
/// second retention policy the moment either is edited. Why twelve hours and
/// why this is not a liveness timeout is written there.
const keep_lock_ms: i64 = cas_lock_record.keep_ms;

const Candidate = struct {
    path: []const u8,
    bytes: u64,
    kind: Kind,

    const Kind = enum { staging, run, improve_log, cas_lock, spill };
};

fn isImpId(name: []const u8) bool {
    if (!std.mem.startsWith(u8, name, "imp-")) return false;
    if (name.len <= 4) return false;
    for (name[4..]) |c| {
        if (!std.ascii.isDigit(c)) return false;
    }
    return true;
}

/// Both graph shapes: a top-level `run-<unix seconds>.json` and a nested
/// `sub-<unix nanoseconds>.json`. Spelling out only `run-` here left every
/// sub-agent graph outside the newest-200 retention *and* outside the
/// delete-time recheck, so they accumulated in `state/runs/` for good.
const isRunGraph = graph_listing.isRunGraphName;

fn isImproveLog(name: []const u8) bool {
    return std.mem.startsWith(u8, name, "improve-") and std.mem.endsWith(u8, name, ".log");
}

fn removable(state_dir: []const u8, path: []const u8) bool {
    if (std.mem.find(u8, path, "..") != null) return false;
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
    var buf4: [512]u8 = undefined;
    const locks_prefix = std.fmt.bufPrint(&buf4, "{s}/locks/", .{state_dir}) catch return false;
    if (std.mem.startsWith(u8, path, locks_prefix)) return isCasLock(path[locks_prefix.len..]);
    var buf5: [512]u8 = undefined;
    const spills_prefix = std.fmt.bufPrint(&buf5, "{s}/spills/", .{state_dir}) catch return false;
    if (std.mem.startsWith(u8, path, spills_prefix)) {
        // `<session>/<id>.txt`, one level deep and no deeper: the session
        // segment is checked with the same rule the guest writes under, so a
        // path that nests further cannot reach the delete.
        const rest = path[spills_prefix.len..];
        const slash = std.mem.findScalar(u8, rest, '/') orelse return false;
        if (!spill_logic.validSessionId(rest[0..slash])) return false;
        return spill_logic.isSpillFileName(rest[slash + 1 ..]);
    }
    return false;
}

/// A lock file name is the hex SHA-256 of its target path. Checking the shape
/// rather than just the suffix keeps the delete path from following anything
/// else that happens to land in the directory.
fn isCasLock(name: []const u8) bool {
    if (!std.mem.endsWith(u8, name, ".lock")) return false;
    const stem = name[0 .. name.len - ".lock".len];
    if (stem.len != 64) return false;
    for (stem) |c| {
        if (!std.ascii.isHex(c)) return false;
    }
    return true;
}

/// Oldest first: `collectOldest` deletes the front of this order, so a graph
/// has to rank by the instant it was recorded. Ordering `run-<unix seconds>`
/// ids by name only agrees with that while every id has the same digit width,
/// and it disagrees outright once a `sub-<unix nanoseconds>` id is in the set.
/// Names of neither shape (the improve logs) keep plain name order.
const lessThanName = graph_listing.lessThanChronological;

fn dirSize(a: std.mem.Allocator, path: []const u8) u64 {
    const raw = lib.fsStat(path) catch return 0;
    const parsed = std.json.parseFromSliceLeaky(std.json.Value, a, raw, .{}) catch return 0;
    if (parsed != .object) return 0;
    if (parsed.object.get("kind")) |k| {
        if (k == .string and std.mem.eql(u8, k.string, "directory")) {
            var total: u64 = 0;
            const listing = lib.fsList(path) catch return 0;
            const names = std.json.parseFromSliceLeaky(std.json.Value, a, listing, .{}) catch return 0;
            if (names != .array) return 0;
            for (names.array.items) |item| {
                if (item != .string) continue;
                const name = item.string;
                if (name.len == 0) continue;
                if (name[name.len - 1] == '/') {
                    const sub = std.fmt.allocPrint(a, "{s}/{s}", .{ path, name[0 .. name.len - 1] }) catch continue;
                    total += dirSize(a, sub);
                } else {
                    const sub = std.fmt.allocPrint(a, "{s}/{s}", .{ path, name }) catch continue;
                    const st = lib.fsStat(sub) catch continue;
                    const sv = std.json.parseFromSliceLeaky(std.json.Value, a, st, .{}) catch continue;
                    if (sv == .object) {
                        if (sv.object.get("size")) |sz| {
                            if (sz == .integer) total +|= std.math.lossyCast(u64, sz.integer);
                        }
                    }
                }
            }
            return total;
        }
    }
    if (parsed.object.get("size")) |sz| {
        if (sz == .integer) return std.math.lossyCast(u64, sz.integer);
    }
    return 0;
}

fn namesMatching(a: std.mem.Allocator, rel: []const u8, match: *const fn ([]const u8) bool) []const []const u8 {
    const raw = lib.fsList(rel) catch return &.{};
    const names = std.json.parseFromSliceLeaky(std.json.Value, a, raw, .{}) catch return &.{};
    if (names != .array) return &.{};
    var out: std.ArrayList([]const u8) = .empty;
    for (names.array.items) |item| {
        if (item != .string) continue;
        if (!match(item.string)) continue;
        out.append(a, a.dupe(u8, item.string) catch continue) catch continue;
    }
    std.mem.sort([]const u8, out.items, {}, lessThanName);
    return out.items;
}

fn scan(a: std.mem.Allocator, state_dir: []const u8) []const Candidate {
    var out: std.ArrayList(Candidate) = .empty;

    // Orphaned staging directories.
    const staging_rel = std.fmt.allocPrint(a, "{s}/staging", .{state_dir}) catch return &.{};
    const staging_listing = lib.fsList(staging_rel) catch "";
    if (staging_listing.len > 0) {
        const entries = std.json.parseFromSliceLeaky(std.json.Value, a, staging_listing, .{}) catch null;
        if (entries) |names| {
            if (names == .array) {
                for (names.array.items) |item| {
                    if (item != .string) continue;
                    var name = item.string;
                    if (name.len > 0 and name[name.len - 1] == '/') name = name[0 .. name.len - 1];
                    if (!isImpId(name)) continue;
                    const rel = std.fmt.allocPrint(a, "{s}/{s}", .{ staging_rel, name }) catch continue;
                    out.append(a, .{
                        .path = rel,
                        .bytes = dirSize(a, rel),
                        .kind = .staging,
                    }) catch continue;
                }
            }
        }
    }

    collectOldest(a, state_dir, "runs", isRunGraph, keep_runs, .run, &out);
    collectOldest(a, state_dir, "logs", isImproveLog, keep_logs, .improve_log, &out);
    collectAgedLocks(a, state_dir, &out);
    collectAgedSpills(a, state_dir, &out);
    return out.items;
}

/// Spilled tool results nothing can ask for any more.
///
/// A spill is run-scoped: the locator naming one is written onto the request
/// copy of a message and discarded with it, so a finished run leaves files no
/// later message refers to. Nothing swept them, and because every non-repl run
/// shares the `default` bucket they collected there indefinitely.
///
/// Age is the only usable signal — a spill id is a hash of the content, so the
/// names carry no order for a newest-N rule to sort by. A file whose stat
/// cannot be read is left alone rather than treated as ancient.
fn collectAgedSpills(a: std.mem.Allocator, state_dir: []const u8, out: *std.ArrayList(Candidate)) void {
    const root = std.fmt.allocPrint(a, "{s}/spills", .{state_dir}) catch return;
    const raw = lib.fsList(root) catch return;
    const sessions = std.json.parseFromSliceLeaky(std.json.Value, a, raw, .{}) catch return;
    if (sessions != .array) return;

    const now_ms: i64 = @trunc(lib.nowSeconds() * 1000.0);
    for (sessions.array.items) |entry| {
        if (entry != .string) continue;
        var session = entry.string;
        // Only directories: `fsList` marks them with a trailing slash.
        if (session.len == 0 or session[session.len - 1] != '/') continue;
        session = session[0 .. session.len - 1];
        if (!spill_logic.validSessionId(session)) continue;

        const dir = std.fmt.allocPrint(a, "{s}/{s}", .{ root, session }) catch continue;
        const listing = lib.fsList(dir) catch continue;
        const names = std.json.parseFromSliceLeaky(std.json.Value, a, listing, .{}) catch continue;
        if (names != .array) continue;
        for (names.array.items) |item| {
            if (item != .string) continue;
            if (!spill_logic.isSpillFileName(item.string)) continue;
            const path = std.fmt.allocPrint(a, "{s}/{s}", .{ dir, item.string }) catch continue;
            const st = lib.fsStat(path) catch continue;
            const sv = std.json.parseFromSliceLeaky(std.json.Value, a, st, .{}) catch continue;
            if (sv != .object) continue;
            const mtime = switch (sv.object.get("mtime_ms") orelse continue) {
                .integer => |n| n,
                else => continue,
            };
            if (!spill_logic.spillAgedOut(now_ms, mtime, spill_logic.keep_spill_ms)) continue;
            const size: u64 = switch (sv.object.get("size") orelse std.json.Value{ .integer = 0 }) {
                .integer => |n| @intCast(@max(0, n)),
                else => 0,
            };
            out.append(a, .{ .path = path, .bytes = size, .kind = .spill }) catch continue;
        }
    }
}

/// Compare-and-swap lock files whose last acquisition is older than
/// `keep_lock_ms`.
///
/// The lock is keyed by a hash of its target path, so a target that recurs
/// keeps re-acquiring the same lock and its record keeps moving forward; only
/// a target that will never be written again -- a test's tmp tree, an improve
/// staging copy -- leaves a record that ages out. The timestamp is therefore
/// the reuse signal, not a liveness timeout: see `keep_lock_ms` for why an
/// `flock` never needs reclaiming in the first place.
///
/// A record that cannot be read is left alone. Treating it as timestamp zero
/// would date it to 1970 and sweep the whole directory, live locks included.
fn collectAgedLocks(a: std.mem.Allocator, state_dir: []const u8, out: *std.ArrayList(Candidate)) void {
    const rel = std.fmt.allocPrint(a, "{s}/locks", .{state_dir}) catch return;
    const raw = lib.fsList(rel) catch return;
    const names = std.json.parseFromSliceLeaky(std.json.Value, a, raw, .{}) catch return;
    if (names != .array) return;

    const now_ms: i64 = @trunc(lib.nowSeconds() * 1000.0);
    for (names.array.items) |item| {
        if (item != .string) continue;
        const name = item.string;
        if (!std.mem.endsWith(u8, name, ".lock")) continue;
        const path = std.fmt.allocPrint(a, "{s}/{s}", .{ rel, name }) catch continue;
        const record = lib.fsRead(path) catch continue;
        // The rule itself is in the shared record module, where `zig build
        // test` can reach it: a guest carries no test block, and this decision
        // deletes files.
        if (!cas_lock_record.agedOut(record, now_ms, keep_lock_ms)) continue;
        out.append(a, .{
            .path = path,
            .bytes = record.len,
            .kind = .cas_lock,
        }) catch continue;
    }
}

fn collectOldest(
    a: std.mem.Allocator,
    state_dir: []const u8,
    sub: []const u8,
    match: *const fn ([]const u8) bool,
    keep: usize,
    kind: Candidate.Kind,
    out: *std.ArrayList(Candidate),
) void {
    const rel = std.fmt.allocPrint(a, "{s}/{s}", .{ state_dir, sub }) catch return;
    const names = namesMatching(a, rel, match);
    if (names.len <= keep) return;
    for (names[0 .. names.len - keep]) |name| {
        const path = std.fmt.allocPrint(a, "{s}/{s}", .{ rel, name }) catch continue;
        const size = dirSize(a, path);
        out.append(a, .{ .path = path, .bytes = size, .kind = kind }) catch continue;
    }
}

fn human(buf: []u8, bytes: u64) []const u8 {
    if (bytes >= 1024 * 1024 * 1024) return std.fmt.bufPrint(buf, "{d:.1} GB", .{@as(f64, @floatFromInt(bytes)) / (1024.0 * 1024.0 * 1024.0)}) catch "?";
    if (bytes >= 1024 * 1024) return std.fmt.bufPrint(buf, "{d:.1} MB", .{@as(f64, @floatFromInt(bytes)) / (1024.0 * 1024.0)}) catch "?";
    if (bytes >= 1024) return std.fmt.bufPrint(buf, "{d} KB", .{bytes / 1024}) catch "?";
    return std.fmt.bufPrint(buf, "{d} B", .{bytes}) catch "?";
}

const quips = [_][]const u8{
    "Sorry. I clean here.",
    "Is nothing. Small job.",
    "I am only cleaner.",
    "Excuse me. One moment.",
    "Hold my mop.",
    "You train? I clean. Same thing.",
    "Nobody clean this. Okay. I clean this.",
    "Is heavy? For you maybe.",
    "I do not lift. I tidy.",
    "Half gigabyte. Is like warm up.",
    "First mop. Then we talk.",
    "Do not worry. I am professional.",
    "Somebody drop 300 megabyte. I say nothing.",
    "Is fine. Floor is my gym.",
    "Okay. Finish. Where is next mess.",
};

fn quip(n: usize) []const u8 {
    return quips[n % quips.len];
}

fn announce(a: std.mem.Allocator, text: []const u8) void {
    var req: std.Io.Writer.Allocating = .init(a);
    var s = std.json.Stringify{ .writer = &req.writer, .options = .{} };
    s.beginObject() catch return;
    s.objectField("op") catch return;
    s.write("send") catch return;
    s.objectField("room") catch return;
    s.write("general") catch return;
    s.objectField("text") catch return;
    s.write(text) catch return;
    s.endObject() catch return;
    _ = lib.chat(req.written()) catch {};
}

const Input = struct {
    op: []const u8 = "scan",
    state_dir: []const u8 = "state",
};

export fn run(ptr: u32, len: u32) callconv(.c) u64 {
    return lib.run(ptr, len, tool_main);
}

fn tool_main(input: []const u8, out: *lib.Out) !void {
    const a = lib.alloc;

    const parsed = std.json.parseFromSliceLeaky(Input, a, input, .{ .ignore_unknown_fields = true }) catch Input{};
    const state_dir = parsed.state_dir;
    const apply = std.mem.eql(u8, parsed.op, "prune");

    const candidates = scan(a, state_dir);

    var total: u64 = 0;
    var staging_n: usize = 0;
    var runs_n: usize = 0;
    var logs_n: usize = 0;
    var locks_n: usize = 0;
    var spills_n: usize = 0;
    for (candidates) |c| {
        total += c.bytes;
        switch (c.kind) {
            .staging => staging_n += 1,
            .run => runs_n += 1,
            .improve_log => logs_n += 1,
            .cas_lock => locks_n += 1,
            .spill => spills_n += 1,
        }
    }

    // JSON output for the HTTP API.
    if (std.mem.eql(u8, parsed.op, "json")) {
        var w = out.writer();
        w.print("{{\"ok\":true,\"items\":{d},\"bytes\":{d}}}", .{ candidates.len, total }) catch {};
        out.len = w.end;
        return;
    }

    var text: std.ArrayList(u8) = .empty;

    if (candidates.len == 0) {
        try text.appendSlice(a, "Floor is clean. I sit down now.\n");
        return lib.okText(out, text.items);
    }

    var hbuf: [32]u8 = undefined;
    try text.appendSlice(a, try std.fmt.allocPrint(a, "{s}\n\n", .{quip(candidates.len)}));
    try text.appendSlice(a, try std.fmt.allocPrint(a, "{s} reclaimable\n", .{human(&hbuf, total)}));
    if (staging_n > 0) try text.appendSlice(a, try std.fmt.allocPrint(a, "  {d} orphaned staging director{s} (a killed improve run leaves its copy behind)\n", .{ staging_n, if (staging_n == 1) @as([]const u8, "y") else "ies" }));
    if (runs_n > 0) try text.appendSlice(a, try std.fmt.allocPrint(a, "  {d} run graphs beyond the newest {d}\n", .{ runs_n, keep_runs }));
    if (logs_n > 0) try text.appendSlice(a, try std.fmt.allocPrint(a, "  {d} improve logs beyond the newest {d}\n", .{ logs_n, keep_logs }));
    if (locks_n > 0) try text.appendSlice(a, try std.fmt.allocPrint(a, "  {d} compare-and-swap lock file{s} unused for {d}h (the target is gone or was never rewritten)\n", .{ locks_n, if (locks_n == 1) @as([]const u8, "") else "s", @divTrunc(keep_lock_ms, 60 * 60 * 1000) }));
    if (spills_n > 0) try text.appendSlice(a, try std.fmt.allocPrint(a, "  {d} spilled tool result{s} older than {d}h (the run that could ask for them is over)\n", .{ spills_n, if (spills_n == 1) @as([]const u8, "") else "s", @divTrunc(spill_logic.keep_spill_ms, 60 * 60 * 1000) }));

    if (!apply) {
        try text.appendSlice(a, "\nNothing was deleted. Re-run with --yes to remove it.\n");
        return lib.okText(out, text.items);
    }

    var removed: u64 = 0;
    var failed: usize = 0;
    for (candidates) |c| {
        if (!removable(state_dir, c.path)) {
            failed += 1;
            continue;
        }
        switch (c.kind) {
            .staging => {
                lib.fsDeleteTree(a, c.path);
                // fsDeleteTree is best-effort against a truncating ck_fs_list
                // page, so a large staging tree can survive its own deletion
                // (docs/reports/bugs/2026-08-20-janitor-truncated-list-leaves-staging-behind.md).
                // Re-stat before crediting the bytes: a directory that is still
                // there is a failure, not a reclaim. NotFound is the expected
                // result of a real removal; any other stat outcome is treated
                // conservatively as a survivor.
                if (lib.fsStat(c.path)) |_| {
                    failed += 1;
                    continue;
                } else |_| {}
            },
            .run, .improve_log, .cas_lock, .spill => lib.fsDelete(c.path) catch {
                failed += 1;
                continue;
            },
        }
        removed += c.bytes;
    }
    const closing = quip(candidates.len + 1);
    try text.appendSlice(a, try std.fmt.allocPrint(a, "\n{s}\nRemoved {s}.", .{ closing, human(&hbuf, removed) }));

    var said: [256]u8 = undefined;
    if (std.fmt.bufPrint(&said, "{s} Was {s} on floor. Is clean now.", .{ closing, human(&hbuf, removed) })) |line| {
        announce(a, line);
    } else |_| {}

    if (failed > 0) try text.appendSlice(a, try std.fmt.allocPrint(a, " {d} could not be removed.", .{failed}));
    try text.appendSlice(a, "\n");
    return lib.okText(out, text.items);
}
