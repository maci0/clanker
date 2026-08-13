//! janitor: sweep up what old runs left behind.
//!
//! Scans state/ for orphaned staging directories, excess run graphs, and
//! excess improve logs. Returns a summary (scan) or deletes and reports
//! (prune).
//!
//! Input:  {"op": "scan"|"prune", "state_dir": "state"}
//! Output: {"ok": true, "text": "...", "items": N, "bytes": N}
//!
//! Moved from src/janitor.zig: bounded fs work, rare invocation, fully
//! outside the trust boundary.

const std = @import("std");
const lib = @import("lib.zig");

const keep_runs: usize = 200;
const keep_logs: usize = 20;

const Candidate = struct {
    path: []const u8,
    bytes: u64,
    kind: Kind,

    const Kind = enum { staging, run, improve_log };
};

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
    return false;
}

fn lessThanName(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.lessThan(u8, a, b);
}

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
                            if (sz == .integer) total += @intCast(sz.integer);
                        }
                    }
                }
            }
            return total;
        }
    }
    if (parsed.object.get("size")) |sz| {
        if (sz == .integer) return @intCast(sz.integer);
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
    return out.items;
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
    for (candidates) |c| {
        total += c.bytes;
        switch (c.kind) {
            .staging => staging_n += 1,
            .run => runs_n += 1,
            .improve_log => logs_n += 1,
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
            .staging => lib.fsDeleteTree(a, c.path),
            .run, .improve_log => lib.fsDelete(c.path) catch {
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
