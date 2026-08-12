//! Improvement history: JSONL log + per-attempt file snapshots + revert.

const std = @import("std");
const json = std.json;
const log = @import("../util/log.zig");
const filelock = @import("../util/filelock.zig");

pub const Status = enum {
    accepted,
    rejected,
    failed,

    pub fn asStr(self: Status) []const u8 {
        return switch (self) {
            .accepted => "accepted",
            .rejected => "rejected",
            .failed => "failed",
        };
    }
};

pub const History = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    /// Base directory all paths resolve against.
    base: std.Io.Dir,
    /// Directory (relative to `base`) holding improvements.jsonl + history/.
    state_dir: []const u8,
    log_path: []const u8,
    history_dir: []const u8,

    pub fn init(gpa: std.mem.Allocator, io: std.Io, base: std.Io.Dir, state_dir: []const u8) History {
        return .{
            .gpa = gpa,
            .io = io,
            .base = base,
            .state_dir = state_dir,
            .log_path = std.fmt.allocPrint(gpa, "{s}/improvements.jsonl", .{state_dir}) catch "",
            .history_dir = std.fmt.allocPrint(gpa, "{s}/history", .{state_dir}) catch "",
        };
    }

    pub fn deinit(self: *History) void {
        if (self.log_path.len > 0) self.gpa.free(self.log_path);
        if (self.history_dir.len > 0) self.gpa.free(self.history_dir);
    }

    pub fn logPath(self: *const History) []const u8 {
        return self.log_path;
    }

    fn dir(self: *const History) std.Io.Dir {
        return self.base;
    }

    /// A stable fingerprint of one edit: the file it targets, the text it
    /// matches, and the text it writes. Two proposals with the same
    /// fingerprint are literally the same edit, whatever their summaries say.
    pub fn changeFingerprint(file: []const u8, old: []const u8, new: []const u8) u64 {
        var h = std.hash.Wyhash.init(0x1F0DE57);
        h.update(file);
        h.update("\x00");
        h.update(old);
        h.update("\x00");
        h.update(new);
        return h.final();
    }

    /// A region fingerprint: file + old text only. Two proposals with the
    /// same region fingerprint target the same code even if the replacement
    /// differs — a variation of a failing edit that fails for the same
    /// structural reason.
    pub fn regionFingerprint(file: []const u8, old: []const u8) u64 {
        var h = std.hash.Wyhash.init(0xAE610D);
        h.update(file);
        h.update("\x00");
        h.update(old);
        return h.final();
    }

    /// True when a recently rejected attempt targeted the same region
    /// (file + old text) even with different replacement text. Catches
    /// the model proposing variations of a structurally failing edit.
    pub fn sameRegionRejected(self: *History, arena: std.mem.Allocator, region_fps: []const u64, max_lookback: usize) !bool {
        if (region_fps.len == 0) return false;
        const entries = try self.loadAll(arena);
        if (entries.len == 0) return false;
        const start = if (entries.len > max_lookback) entries.len - max_lookback else 0;
        for (entries[start..]) |e| {
            if (!std.mem.eql(u8, e.status, "rejected")) continue;
            if (e.region_fps.len == 0) continue;
            // Any overlap means the proposal revisits a rejected region.
            for (region_fps) |fp| {
                for (e.region_fps) |seen| {
                    if (seen == fp) return true;
                }
            }
        }
        return false;
    }

    /// True when an accepted improvement already made exactly this edit.
    ///
    /// The gates answer "is this change correct", never "is this change new",
    /// so a redundant edit passes them all: it builds, tests, formats and
    /// lints. Without this the loop re-promoted the same one-line insertion
    /// three times.
    pub fn alreadyAccepted(self: *History, arena: std.mem.Allocator, fingerprints: []const u64) !bool {
        if (fingerprints.len == 0) return false;
        const entries = try self.loadAll(arena);
        for (entries) |e| {
            if (!std.mem.eql(u8, e.status, "accepted")) continue;
            if (e.changes.len == 0) continue;
            if (e.changes.len != fingerprints.len) continue;
            var all = true;
            for (fingerprints) |fp| {
                var found = false;
                for (e.changes) |seen| {
                    if (seen == fp) found = true;
                }
                if (!found) all = false;
            }
            if (all) return true;
        }
        return false;
    }

    /// True when a recently rejected attempt shares at least one change
    /// fingerprint with the proposed set. Unlike `alreadyRejected` (which
    /// requires an exact set match), this catches proposals that recycle a
    /// subset of a failing edit alongside new changes — the recycled part
    /// fails for the same reason, and the whole proposal is wasted.
    /// Returns the number of overlapping fingerprints, so the caller can
    /// decide whether a single shared change is worth blocking on.
    pub fn partialOverlapRejected(self: *History, arena: std.mem.Allocator, fingerprints: []const u64, max_lookback: usize) !usize {
        if (fingerprints.len == 0) return 0;
        const entries = try self.loadAll(arena);
        if (entries.len == 0) return 0;
        const start = if (entries.len > max_lookback) entries.len - max_lookback else 0;
        var max_overlap: usize = 0;
        for (entries[start..]) |e| {
            if (!std.mem.eql(u8, e.status, "rejected")) continue;
            if (e.changes.len == 0) continue;
            var overlap: usize = 0;
            for (fingerprints) |fp| {
                for (e.changes) |seen| {
                    if (seen == fp) {
                        overlap += 1;
                        break;
                    }
                }
            }
            if (overlap > max_overlap) max_overlap = overlap;
        }
        return max_overlap;
    }

    /// True when a recently rejected attempt proposed exactly this set of
    /// edits. Without this the loop re-proposes the same failing change
    /// indefinitely — it knows not to repeat accepted work but has no memory
    /// of rejected work beyond the summary text. `max_lookback` limits how
    /// far back to search: a very old rejection may no longer apply after
    /// surrounding code changed.
    pub fn alreadyRejected(self: *History, arena: std.mem.Allocator, fingerprints: []const u64, max_lookback: usize) !bool {
        if (fingerprints.len == 0) return false;
        const entries = try self.loadAll(arena);
        if (entries.len == 0) return false;
        const start = if (entries.len > max_lookback) entries.len - max_lookback else 0;
        for (entries[start..]) |e| {
            if (!std.mem.eql(u8, e.status, "rejected")) continue;
            if (e.changes.len == 0) continue;
            if (e.changes.len != fingerprints.len) continue;
            var all = true;
            for (fingerprints) |fp| {
                var found = false;
                for (e.changes) |seen| {
                    if (seen == fp) found = true;
                }
                if (!found) all = false;
            }
            if (all) return true;
        }
        return false;
    }

    /// Appends one JSON line describing an attempt.
    pub fn append(
        self: *History,
        id: []const u8,
        status: Status,
        instruction: []const u8,
        summary: []const u8,
        files: []const []const u8,
        score_before: f64,
        score_after: f64,
        detail: []const u8,
        changes: []const u64,
    ) !void {
        return self.appendFull(id, status, instruction, summary, files, score_before, score_after, detail, changes, &.{});
    }

    /// Like `append` but also records region fingerprints for same-region
    /// rejection detection.
    pub fn appendFull(
        self: *History,
        id: []const u8,
        status: Status,
        instruction: []const u8,
        summary: []const u8,
        files: []const []const u8,
        score_before: f64,
        score_after: f64,
        detail: []const u8,
        changes: []const u64,
        region_fps: []const u64,
    ) !void {
        self.base.createDirPath(self.io, self.state_dir) catch |err|
            log.log(.warn, "mkdir {s} failed: {t}", .{ self.state_dir, err });
        self.base.createDirPath(self.io, self.history_dir) catch |err|
            log.log(.warn, "mkdir {s} failed: {t}", .{ self.history_dir, err });

        // Read-modify-write, so it has to be serialised: an improve run and
        // the staged evals a gate spawns are separate processes sharing this
        // file, and a lost entry is a run the next prompt never learns about.
        var guard = filelock.acquire(self.io, self.base, self.state_dir, "improvements", self.gpa);
        defer guard.release();

        var buf: std.ArrayList(u8) = .empty;
        defer buf.deinit(self.gpa);

        // Carry the existing log forward. `writeFile` replaces, so building
        // only the new record here meant every improvement erased the record
        // of the one before it: a .jsonl that never held more than one line.
        // With no memory of what it had already done, the loop re-proposed the
        // same change until something else happened to stop it — the reason
        // `repl_md = .{};` was promoted into src/cli.zig three separate times.
        if (self.dir().readFileAlloc(self.io, self.logPath(), self.gpa, .limited(1 << 24)) catch null) |prior| {
            defer self.gpa.free(prior);
            try buf.appendSlice(self.gpa, prior);
            if (prior.len > 0 and prior[prior.len - 1] != '\n') try buf.append(self.gpa, '\n');
        }

        var w: std.Io.Writer = .fixed(try self.gpa.alloc(u8, 1 << 20));
        defer self.gpa.free(w.buffer);
        var s = json.Stringify{ .writer = &w, .options = .{ .emit_null_optional_fields = false } };

        try s.beginObject();
        try s.objectField("id");
        try s.write(id);
        try s.objectField("ts");
        try s.write(std.Io.Timestamp.now(self.io, .real).nanoseconds);
        try s.objectField("status");
        try s.write(status.asStr());
        try s.objectField("instruction");
        try s.write(instruction);
        try s.objectField("summary");
        try s.write(summary);
        try s.objectField("files");
        try s.beginArray();
        for (files) |f| try s.write(f);
        try s.endArray();
        try s.objectField("score_before");
        try s.print("{d}", .{score_before});
        try s.objectField("score_after");
        try s.print("{d}", .{score_after});
        try s.objectField("detail");
        try s.write(detail);
        try s.objectField("changes");
        try s.beginArray();
        // Hex strings, not numbers: a Wyhash fingerprint is a full u64 and
        // JSON's integer range is signed, so anything above i64 max would not
        // survive the round trip and the edit would look new again.
        for (changes) |c| {
            var fp_buf: [16]u8 = undefined;
            try s.write(std.fmt.bufPrint(&fp_buf, "{x:0>16}", .{c}) catch continue);
        }
        try s.endArray();
        if (region_fps.len > 0) {
            try s.objectField("region_fps");
            try s.beginArray();
            for (region_fps) |r| {
                var rfp_buf: [16]u8 = undefined;
                try s.write(std.fmt.bufPrint(&rfp_buf, "{x:0>16}", .{r}) catch continue);
            }
            try s.endArray();
        }
        try s.endObject();

        try buf.appendSlice(self.gpa, w.buffer[0..w.end]);
        try buf.append(self.gpa, '\n');
        try self.dir().writeFile(self.io, .{ .sub_path = self.logPath(), .data = buf.items });
    }

    /// Snapshots the given live files (relative paths) into state/history/<id>/.
    pub fn snapshot(self: *History, id: []const u8, files: []const []const u8) !void {
        for (files) |f| {
            const dst = try std.fmt.allocPrint(self.gpa, "{s}/{s}/{s}", .{ self.history_dir, id, f });
            defer self.gpa.free(dst);
            self.base.createDirPath(self.io, dirName(dst)) catch {};
            copyFile(self.io, self.gpa, self.base, f, dst) catch |err| {
                // A new file has no previous version to snapshot; that is not
                // a failure and should not hide real snapshot problems.
                if (err != error.FileNotFound) {
                    log.log(.warn, "snapshot of '{s}' failed: {s}", .{ f, @errorName(err) });
                }
            };
        }
    }

    /// Restores files straight from an id's snapshot, given the file list
    /// directly rather than looking it up from a logged entry. For unwinding
    /// a promotion that failed partway through, before any log entry for
    /// `id` exists (`revert` cannot find it without one). Best-effort per
    /// file: a file that fails to restore is logged, not propagated, so one
    /// bad copy does not stop the rest of the set from being undone.
    pub fn restoreFiles(self: *History, id: []const u8, files: []const []const u8) void {
        for (files) |f| {
            const src = std.fmt.allocPrint(self.gpa, "{s}/{s}/{s}", .{ self.history_dir, id, f }) catch {
                log.log(.error_, "restore of '{s}' failed: out of memory", .{f});
                continue;
            };
            defer self.gpa.free(src);
            copyFile(self.io, self.gpa, self.base, src, f) catch |err| {
                log.log(.error_, "restore of '{s}' failed: {s}", .{ f, @errorName(err) });
            };
        }
        log.log(.info, "restored the pre-promotion snapshot for improvement {s} ({d} file(s))", .{ id, files.len });
    }

    /// Number of files that were successfully restored from a snapshot.
    /// Returns the count so the caller can decide whether the restore
    /// was complete. Unlike `restoreFiles` (which is fire-and-forget),
    /// this variant is useful when the caller needs to act on partial
    /// restores.
    pub fn restoreFilesCount(self: *History, id: []const u8, files: []const []const u8) usize {
        var restored: usize = 0;
        for (files) |f| {
            const src = std.fmt.allocPrint(self.gpa, "{s}/{s}/{s}", .{ self.history_dir, id, f }) catch {
                log.log(.error_, "restore of '{s}' failed: out of memory", .{f});
                continue;
            };
            defer self.gpa.free(src);
            copyFile(self.io, self.gpa, self.base, src, f) catch |err| {
                log.log(.error_, "restore of '{s}' failed: {s}", .{ f, @errorName(err) });
                continue;
            };
            restored += 1;
        }
        log.log(.info, "restored the pre-promotion snapshot for improvement {s} ({d}/{d} file(s))", .{ id, restored, files.len });
        return restored;
    }

    /// Restores files for an improvement id from its snapshot.
    pub fn revert(self: *History, id: []const u8) !void {
        var arena_state = std.heap.ArenaAllocator.init(self.gpa);
        defer arena_state.deinit();
        const arena = arena_state.allocator();
        const entries = try self.loadAll(arena);
        for (entries) |e| {
            if (std.mem.eql(u8, e.id, id)) {
                for (e.files) |f| {
                    const src = try std.fmt.allocPrint(self.gpa, "{s}/{s}/{s}", .{ self.history_dir, id, f });
                    defer self.gpa.free(src);
                    copyFile(self.io, self.gpa, self.base, src, f) catch |err| {
                        log.log(.error_, "revert of '{s}' failed: {s}", .{ f, @errorName(err) });
                        return err;
                    };
                }
                log.log(.info, "reverted improvement {s} ({d} file(s))", .{ id, e.files.len });
                return;
            }
        }
        return error.ImprovementNotFound;
    }

    const Entry = struct {
        id: []const u8,
        status: []const u8,
        files: []const []const u8,
        summary: []const u8 = "",
        detail: []const u8 = "",
        score_before: ?f64 = null,
        score_after: ?f64 = null,
        /// Empty for entries written before fingerprints existed; those simply
        /// cannot be matched against, rather than matching everything.
        changes: []const u64 = &.{},
        /// Region fingerprints (file+old only), for same-region detection.
        region_fps: []const u64 = &.{},
    };

    fn loadAll(self: *History, arena: std.mem.Allocator) ![]Entry {
        var out: std.ArrayList(Entry) = .empty;
        const raw = self.base.readFileAlloc(self.io, self.logPath(), arena, .limited(1 << 24)) catch return &.{};

        var lines = std.mem.splitScalar(u8, raw, '\n');
        while (lines.next()) |line| {
            if (line.len == 0) continue;
            const v = json.parseFromSliceLeaky(json.Value, arena, line, .{}) catch continue;
            const obj = switch (v) {
                .object => |o| o,
                else => continue,
            };
            var files: std.ArrayList([]const u8) = .empty;
            if (obj.get("files")) |f| {
                switch (f) {
                    .array => |arr| for (arr.items) |item| switch (item) {
                        .string => |s| try files.append(arena, s),
                        else => {},
                    },
                    else => {},
                }
            }
            const id = if (obj.get("id")) |x| switch (x) {
                .string => |s| s,
                else => continue,
            } else continue;
            const status = if (obj.get("status")) |x| switch (x) {
                .string => |s| s,
                else => continue,
            } else continue;
            var fps: std.ArrayList(u64) = .empty;
            if (obj.get("changes")) |cv| {
                switch (cv) {
                    .array => |arr| for (arr.items) |item| switch (item) {
                        .string => |sv| try fps.append(arena, std.fmt.parseInt(u64, sv, 16) catch continue),
                        // Entries written before fingerprints were hex.
                        .integer => |n| try fps.append(arena, @bitCast(n)),
                        else => {},
                    },
                    else => {},
                }
            }
            var rfps: std.ArrayList(u64) = .empty;
            if (obj.get("region_fps")) |rv| {
                switch (rv) {
                    .array => |arr| for (arr.items) |item| switch (item) {
                        .string => |sv| try rfps.append(arena, std.fmt.parseInt(u64, sv, 16) catch continue),
                        .integer => |n| try rfps.append(arena, @bitCast(n)),
                        else => {},
                    },
                    else => {},
                }
            }
            const text = struct {
                fn get(o: json.ObjectMap, key: []const u8) []const u8 {
                    const x = o.get(key) orelse return "";
                    return switch (x) {
                        .string => |str| str,
                        else => "",
                    };
                }
            }.get;
            const score_b: ?f64 = if (obj.get("score_before")) |sv| switch (sv) {
                .float => |f| f,
                .integer => |i| @floatFromInt(i),
                else => null,
            } else null;
            const score_a: ?f64 = if (obj.get("score_after")) |sv| switch (sv) {
                .float => |f| f,
                .integer => |i| @floatFromInt(i),
                else => null,
            } else null;
            try out.append(arena, .{
                .id = id,
                .status = status,
                .files = try files.toOwnedSlice(arena),
                .summary = text(obj, "summary"),
                .detail = text(obj, "detail"),
                .score_before = score_b,
                .score_after = score_a,
                .changes = try fps.toOwnedSlice(arena),
                .region_fps = try rfps.toOwnedSlice(arena),
            });
        }
        return out.toOwnedSlice(arena);
    }

    /// (file, old_text) pairs from the last `max_entries` rejected attempts,
    /// for the stale-region gate. Only rejected entries carry useful signal:
    /// an accepted edit landing again is caught by `alreadyAccepted`, and a
    /// failed attempt's old text is what the model should stop retargeting.
    pub fn recentRejectedEdits(self: *History, arena: std.mem.Allocator, max_entries: usize) ![]const RecentEdit {
        const entries = try self.loadAll(arena);
        if (entries.len == 0) return &.{};
        const start = if (entries.len > max_entries) entries.len - max_entries else 0;

        var out: std.ArrayList(RecentEdit) = .empty;
        for (entries[start..]) |e| {
            if (!std.mem.eql(u8, e.status, "rejected")) continue;
            for (e.files) |f| {
                // Load the snapshotted version of the file so the staleness
                // gate can compare proposed old text against what the rejected
                // attempt actually targeted, rather than comparing it against
                // the rejection reason string.
                const src = std.fmt.allocPrint(arena, "{s}/{s}/{s}", .{ self.history_dir, e.id, f }) catch continue;
                const content = self.base.readFileAlloc(self.io, src, arena, .limited(1 << 20)) catch |err| {
                    // No snapshot (new file, or snapshot failed): fall back to
                    // file name only so the gate can still match on path.
                    _ = err;
                    try out.append(arena, .{ .file = f, .old = "" });
                    continue;
                };
                try out.append(arena, .{ .file = f, .old = content });
            }
        }
        return out.toOwnedSlice(arena);
    }

    pub const RecentEdit = struct {
        file: []const u8,
        old: []const u8,
    };

    /// Files from recent rejected attempts, ranked by how many distinct
    /// rejections targeted them. A file that keeps appearing in failed
    /// proposals is one the model should either avoid or approach with a
    /// fundamentally different strategy. Returns (file, count) pairs sorted
    /// by descending count.
    pub fn hotFiles(self: *History, arena: std.mem.Allocator, max_entries: usize) ![]const HotFile {
        const entries = try self.loadAll(arena);
        if (entries.len == 0) return &.{};
        const start = if (entries.len > max_entries) entries.len - max_entries else 0;

        var counts: std.StringHashMapUnmanaged(u32) = .empty;
        for (entries[start..]) |e| {
            if (!std.mem.eql(u8, e.status, "rejected")) continue;
            for (e.files) |f| {
                const gop = try counts.getOrPut(arena, f);
                if (!gop.found_existing) gop.value_ptr.* = 0;
                gop.value_ptr.* += 1;
            }
        }

        var out: std.ArrayList(HotFile) = .empty;
        var it = counts.iterator();
        while (it.next()) |kv| {
            try out.append(arena, .{ .file = kv.key_ptr.*, .rejections = kv.value_ptr.* });
        }
        std.mem.sort(HotFile, out.items, {}, struct {
            fn desc(_: void, a: HotFile, b: HotFile) bool {
                return a.rejections > b.rejections;
            }
        }.desc);
        return out.toOwnedSlice(arena);
    }

    pub const HotFile = struct {
        file: []const u8,
        rejections: u32,
    };

    /// Ratio of unique files to total file touches across the last
    /// `max_entries` attempts. A value near 1.0 means every attempt
    /// targeted a different file (high diversity); near 0.0 means the
    /// same file(s) keep being retried (low diversity). The engine can
    /// threshold on this to force exploration of new targets when the
    /// model is stuck hammering the same area.
    pub fn attemptDiversity(self: *History, arena: std.mem.Allocator, max_entries: usize) !f64 {
        const entries = try self.loadAll(arena);
        if (entries.len == 0) return 1.0;
        const start = if (entries.len > max_entries) entries.len - max_entries else 0;

        var unique: std.StringHashMapUnmanaged(void) = .empty;
        var total: usize = 0;
        for (entries[start..]) |e| {
            for (e.files) |f| {
                total += 1;
                const gop = try unique.getOrPut(arena, f);
                _ = gop;
            }
        }
        if (total == 0) return 1.0;
        return @as(f64, @floatFromInt(unique.count())) / @as(f64, @floatFromInt(total));
    }

    /// Files from the last `max_entries` rejected attempts, deduplicated.
    /// Unlike `hotFiles` (which counts across all rejections), this returns
    /// the set of files that failed most recently — the ones the model
    /// should cool off from before retrying.
    pub fn recentlyRejectedFiles(self: *History, arena: std.mem.Allocator, max_entries: usize) ![]const []const u8 {
        const entries = try self.loadAll(arena);
        if (entries.len == 0) return &.{};
        const start = if (entries.len > max_entries) entries.len - max_entries else 0;

        var out: std.ArrayList([]const u8) = .empty;
        // Walk backwards so the most recently rejected files come first.
        var i: usize = entries.len;
        while (i > start) {
            i -= 1;
            const e = entries[i];
            if (!std.mem.eql(u8, e.status, "rejected")) continue;
            for (e.files) |f| {
                var seen = false;
                for (out.items) |have| {
                    if (std.mem.eql(u8, have, f)) {
                        seen = true;
                        break;
                    }
                }
                if (!seen) try out.append(arena, f);
            }
        }
        return out.toOwnedSlice(arena);
    }

    /// Number of consecutive non-accepted entries at the tail of the log.
    /// A streak of 3+ means the model has been failing repeatedly and
    /// should try something fundamentally different. The engine uses this
    /// to adjust strategy: switch providers, raise temperature, or request
    /// a completely different approach.
    pub fn currentStreak(self: *History, arena: std.mem.Allocator) !usize {
        const entries = try self.loadAll(arena);
        return self.trailingRejectionStreak(entries, 0);
    }

    /// Deduplicated, non-empty rejection reasons from the last
    /// `max_lookback` entries, most recent first. The engine can feed
    /// these to the prompt as a concise "avoid these failure modes" list
    /// without parsing the full summary text.
    pub fn recentFailureReasons(self: *History, arena: std.mem.Allocator, max_lookback: usize) ![]const []const u8 {
        const entries = try self.loadAll(arena);
        if (entries.len == 0) return &.{};
        const start = if (entries.len > max_lookback) entries.len - max_lookback else 0;

        var out: std.ArrayList([]const u8) = .empty;
        var i: usize = entries.len;
        while (i > start) {
            i -= 1;
            const e = entries[i];
            if (!std.mem.eql(u8, e.status, "rejected") and !std.mem.eql(u8, e.status, "failed")) continue;
            const reason = std.mem.trim(u8, e.detail, " \t\r\n");
            if (reason.len == 0) continue;
            // Deduplicate: skip if we already have this exact reason.
            var seen = false;
            for (out.items) |have| {
                if (std.mem.eql(u8, have, reason)) {
                    seen = true;
                    break;
                }
            }
            if (!seen) try out.append(arena, reason);
        }
        return out.toOwnedSlice(arena);
    }

    /// Number of consecutive non-accepted entries at the tail of the
    /// window `entries[start..]`. A streak of 3+ means the model has been
    /// failing repeatedly and should try something fundamentally different.
    fn trailingRejectionStreak(self: *const History, entries: []const Entry, start: usize) usize {
        _ = self;
        if (entries.len == 0) return 0;
        var streak: usize = 0;
        var i: usize = entries.len;
        while (i > start) {
            i -= 1;
            if (std.mem.eql(u8, entries[i].status, "accepted")) break;
            streak += 1;
        }
        return streak;
    }

    /// A file path with the status of the attempt it came from.
    pub const TouchedFile = struct {
        file: []const u8,
        status: []const u8,
        summary: []const u8 = "",
    };

    /// Every file touched by the last `max_entries` attempts, tagged with
    /// whether that attempt was accepted, rejected or failed. The improve
    /// prompt can use this to avoid conflicting with recently accepted work
    /// and to skip files that keep failing.
    pub fn recentlyTouchedWithStatus(self: *History, arena: std.mem.Allocator, max_entries: usize) ![]const TouchedFile {
        const entries = try self.loadAll(arena);
        if (entries.len == 0) return &.{};
        const start = if (entries.len > max_entries) entries.len - max_entries else 0;

        var out: std.ArrayList(TouchedFile) = .empty;
        for (entries[start..]) |e| {
            for (e.files) |f| {
                try out.append(arena, .{ .file = f, .status = e.status, .summary = e.summary });
            }
        }
        return out.toOwnedSlice(arena);
    }

    /// Every file touched by the last `max_entries` attempts.
    ///
    /// These are the files most likely to change again, and a file that
    /// changes invalidates the cache block it sits in. Keeping them out of the
    /// stable bulk is what lets the bulk survive from one run to the next.
    pub fn recentlyTouched(self: *History, arena: std.mem.Allocator, max_entries: usize) ![]const []const u8 {
        const entries = try self.loadAll(arena);
        if (entries.len == 0) return &.{};
        const start = if (entries.len > max_entries) entries.len - max_entries else 0;

        var out: std.ArrayList([]const u8) = .empty;
        for (entries[start..]) |e| {
            for (e.files) |f| {
                var seen = false;
                for (out.items) |have| {
                    if (std.mem.eql(u8, have, f)) seen = true;
                }
                if (!seen) try out.append(arena, f);
            }
        }
        return out.toOwnedSlice(arena);
    }

    /// The last `max_entries` attempts, as a block for the improve prompt:
    /// what was already done, and what was tried and rejected.
    ///
    /// Nothing carried across runs before this, so the same mistake came back
    /// indefinitely — one wrong import proposed in three separate runs — and
    /// work already promoted got proposed again as a no-op that passed every
    /// gate because it changed nothing that mattered.
    pub fn recentSummary(self: *History, arena: std.mem.Allocator, max_entries: usize) ![]const u8 {
        const entries = try self.loadAll(arena);
        if (entries.len == 0) return "";
        const start = if (entries.len > max_entries) entries.len - max_entries else 0;

        var buf: std.ArrayList(u8) = .empty;
        for (entries[start..]) |e| {
            if (e.summary.len == 0) continue;
            try buf.appendSlice(arena, "- ");
            try buf.appendSlice(arena, e.status);
            try buf.appendSlice(arena, " (");
            try buf.appendSlice(arena, e.id);
            try buf.appendSlice(arena, "): ");
            try buf.appendSlice(arena, firstLine(e.summary, 160));
            // How many individual edits the attempt contained.
            if (e.changes.len > 0) {
                var cbuf: [64]u8 = undefined;
                var cw: std.Io.Writer = .fixed(&cbuf);
                cw.print(" [{d} change(s)]", .{e.changes.len}) catch {};
                try buf.appendSlice(arena, cbuf[0..cw.end]);
            }
            // Which files were touched: helps the model see what area was
            // already attempted so it can vary its approach or target.
            if (e.files.len > 0) {
                try buf.appendSlice(arena, "\n    files: ");
                for (e.files, 0..) |file, fi| {
                    if (fi > 0) try buf.appendSlice(arena, ", ");
                    try buf.appendSlice(arena, file);
                }
            }
            // Scores give the model a sense of how close the attempt was.
            if (e.score_before != null or e.score_after != null) {
                var sbuf: [64]u8 = undefined;
                var sw: std.Io.Writer = .fixed(&sbuf);
                sw.print("\n    scores: ", .{}) catch {};
                if (e.score_before) |sb| sw.print("{d:.2}", .{sb}) catch {} else sw.print("?", .{}) catch {};
                sw.print(" -> ", .{}) catch {};
                if (e.score_after) |sa| sw.print("{d:.2}", .{sa}) catch {} else sw.print("?", .{}) catch {};
                try buf.appendSlice(arena, sbuf[0..sw.end]);
            }
            // Why it failed is the part worth carrying: the summary alone says
            // what was attempted, not what went wrong with it.
            if (!std.mem.eql(u8, e.status, "accepted") and e.detail.len > 0) {
                try buf.appendSlice(arena, "\n    rejected because: ");
                try buf.appendSlice(arena, firstLine(e.detail, 200));
            }
            try buf.appendSlice(arena, "\n");
        }
        // Score regressions: attempts that actively made things worse.
        // These are the strongest signal to avoid an approach entirely.
        var has_regression = false;
        for (entries[start..]) |e| {
            if (!std.mem.eql(u8, e.status, "rejected") and !std.mem.eql(u8, e.status, "failed")) continue;
            if (e.score_before != null and e.score_after != null) {
                if (e.score_after.? < e.score_before.?) {
                    has_regression = true;
                    break;
                }
            }
        }
        if (has_regression) {
            try buf.appendSlice(arena, "\n⚠ WARNING: Some recent attempts caused score REGRESSIONS (score went down). These approaches actively broke things:\n");
            for (entries[start..]) |e| {
                if (!std.mem.eql(u8, e.status, "rejected") and !std.mem.eql(u8, e.status, "failed")) continue;
                const sb = e.score_before orelse continue;
                const sa = e.score_after orelse continue;
                if (sa >= sb) continue;
                try buf.appendSlice(arena, "- ");
                try buf.appendSlice(arena, e.id);
                try buf.appendSlice(arena, ": ");
                try buf.appendSlice(arena, firstLine(e.summary, 120));
                var rbuf2: [64]u8 = undefined;
                var rw2: std.Io.Writer = .fixed(&rbuf2);
                rw2.print(" (score {d:.2} -> {d:.2})", .{ sb, sa }) catch {};
                try buf.appendSlice(arena, rbuf2[0..rw2.end]);
                if (e.files.len > 0) {
                    try buf.appendSlice(arena, " files: ");
                    for (e.files, 0..) |file, fi| {
                        if (fi > 0) try buf.appendSlice(arena, ", ");
                        try buf.appendSlice(arena, file);
                    }
                }
                try buf.appendSlice(arena, "\n");
            }
            try buf.appendSlice(arena, "Do NOT retry these approaches or similar changes to these files.\n");
        }

        // Trailing rejection streak: how many consecutive non-accepted
        // attempts end the window. A long streak is the signal to try a
        // fundamentally different approach, not a variation of the last one.
        const streak = self.trailingRejectionStreak(entries, start);
        if (streak >= 2) {
            var streak_buf: [128]u8 = undefined;
            var streak_w: std.Io.Writer = .fixed(&streak_buf);
            streak_w.print("\nNote: the last {d} consecutive attempts were rejected. Try a fundamentally different file or approach.\n", .{streak}) catch {};
            try buf.appendSlice(arena, streak_buf[0..streak_w.end]);
        }

        // Warn explicitly about the same-region gate so the model knows
        // re-targeting a previously rejected code region will be caught.
        var has_region_fps = false;
        for (entries[start..]) |e| {
            if (std.mem.eql(u8, e.status, "rejected") and e.region_fps.len > 0) {
                has_region_fps = true;
                break;
            }
        }
        if (has_region_fps) {
            try buf.appendSlice(arena, "\nRecent rejected attempts targeted specific code regions (file + matched text). ");
            try buf.appendSlice(arena, "Proposing a different replacement for the same old text in the same file will be automatically rejected. ");
            try buf.appendSlice(arena, "To fix code in those regions, use a different (larger or shifted) match span, or fix a different file entirely.\n");
        }

        // Cooldown list: files from the very last rejection should be
        // avoided entirely for this attempt so the model explores new
        // targets instead of hammering the same file.
        const cool = try self.recentlyRejectedFiles(arena, 3);
        if (cool.len > 0) {
            try buf.appendSlice(arena, "\nFiles rejected in the last few attempts (cool off — try different files first):\n");
            for (cool) |cf| {
                try buf.appendSlice(arena, "- ");
                try buf.appendSlice(arena, cf);
                try buf.appendSlice(arena, "\n");
            }
        }

        // Recently accepted changes: list them so the model knows what
        // areas were just modified and can avoid conflicting edits or
        // redundant re-proposals.
        const touched = try self.recentlyTouchedWithStatus(arena, max_entries);
        var has_accepted = false;
        for (touched) |t| {
            if (std.mem.eql(u8, t.status, "accepted")) {
                has_accepted = true;
                break;
            }
        }
        if (has_accepted) {
            try buf.appendSlice(arena, "\nRecently accepted changes (avoid conflicting edits to these files):\n");
            for (touched) |t| {
                if (!std.mem.eql(u8, t.status, "accepted")) continue;
                try buf.appendSlice(arena, "- ");
                try buf.appendSlice(arena, t.file);
                if (t.summary.len > 0) {
                    try buf.appendSlice(arena, ": ");
                    try buf.appendSlice(arena, firstLine(t.summary, 120));
                }
                try buf.appendSlice(arena, "\n");
            }
        }

        // Append a hot-files section when files have been rejected multiple
        // times, so the model sees which targets to avoid or approach
        // differently.
        const hot = try self.hotFiles(arena, max_entries);
        if (hot.len > 0) {
            var any_hot = false;
            for (hot) |h| {
                if (h.rejections >= 2) {
                    any_hot = true;
                    break;
                }
            }
            if (any_hot) {
                try buf.appendSlice(arena, "\nFiles with repeated rejections (try a different file or a fundamentally different approach):\n");
                for (hot) |h| {
                    if (h.rejections < 2) continue;
                    var rbuf: [128]u8 = undefined;
                    var rw: std.Io.Writer = .fixed(&rbuf);
                    rw.print("- {s} ({d} rejections)\n", .{ h.file, h.rejections }) catch {};
                    try buf.appendSlice(arena, rbuf[0..rw.end]);
                }
            }
        }

        return buf.toOwnedSlice(arena);
    }
};

/// First non-empty line, clipped. A gate detail can be a whole build log, and
/// the first error line is the part that says what to do differently.
fn firstLine(s: []const u8, max: usize) []const u8 {
    const trimmed = std.mem.trim(u8, s, " \t\r\n");
    const end = std.mem.indexOfScalar(u8, trimmed, '\n') orelse trimmed.len;
    return trimmed[0..@min(end, max)];
}

fn dirName(path: []const u8) []const u8 {
    if (std.mem.lastIndexOfScalar(u8, path, '/')) |i| return path[0..i];
    return ".";
}

fn copyFile(io: std.Io, gpa: std.mem.Allocator, base: std.Io.Dir, src: []const u8, dst: []const u8) !void {
    const data = try base.readFileAlloc(io, src, gpa, .limited(1 << 24));
    defer gpa.free(data);
    try base.writeFile(io, .{ .sub_path = dst, .data = data });
}

/// Produces a short strategic hint for the next improve-self attempt based on
/// recent history patterns: trailing streak direction, file diversity, and
/// failure reasons. Returns an empty string when history is too short to
/// say anything useful.
pub fn strategyHint(self: *const History, arena: std.mem.Allocator) ![]const u8 {
    if (self.entries.items.len == 0) return "";

    const streak = self.trailingStreak();
    const diversity = self.attemptDiversity(8);

    var buf: std.ArrayList(u8) = .empty;

    if (streak.len > 0 and !streak.accepted) {
        // Consecutive failures: warn and suggest pivoting.
        try buf.appendSlice(arena, "Recent streak: ");
        try std.fmt.format(buf.writer(arena), "{d}", .{streak.len});
        try buf.appendSlice(arena, " consecutive rejection(s). ");

        if (diversity.unique_files > 0 and diversity.total_files > 0) {
            const ratio = @as(f64, @floatFromInt(diversity.unique_files)) / @as(f64, @floatFromInt(diversity.total_files));
            if (ratio < 0.4) {
                try buf.appendSlice(arena, "File diversity is low (");
                try std.fmt.format(buf.writer(arena), "{d}", .{diversity.unique_files});
                try buf.appendSlice(arena, " unique out of ");
                try std.fmt.format(buf.writer(arena), "{d}", .{diversity.total_files});
                try buf.appendSlice(arena, " total); try a different area of the codebase. ");
            }
        }

        // Surface the most recent failure reason if available.
        const reasons = self.recentFailureReasons(3);
        if (reasons.len > 0) {
            try buf.appendSlice(arena, "Recent failure reasons: ");
            for (reasons, 0..) |r, i| {
                if (i > 0) try buf.appendSlice(arena, ", ");
                const trimmed = if (r.len > 80) r[0..80] else r;
                try buf.appendSlice(arena, trimmed);
            }
            try buf.appendSlice(arena, ". ");
        }
    } else if (streak.len >= 3 and streak.accepted) {
        try buf.appendSlice(arena, "Good momentum: ");
        try std.fmt.format(buf.writer(arena), "{d}", .{streak.len});
        try buf.appendSlice(arena, " accepted in a row. Keep improving but watch for diminishing returns on the same files.");
    }

    // Check for cooldown files — files rejected too recently to retry.
    const cooled = self.cooledDownFiles(5);
    if (cooled.len > 0) {
        if (buf.items.len > 0) try buf.appendSlice(arena, "\n");
        try buf.appendSlice(arena, "Files on cooldown (recently rejected, avoid): ");
        for (cooled, 0..) |f, i| {
            if (i > 0) try buf.appendSlice(arena, ", ");
            try buf.appendSlice(arena, f);
            if (i >= 4) {
                try buf.appendSlice(arena, ", ...");
                break;
            }
        }
    }

    return buf.toOwnedSlice(arena);
}

// ------------------------------------------------------------------- tests --

test "history append + revert round trip" {
    var gpa_state = std.heap.DebugAllocator(.{}).init;
    defer _ = gpa_state.deinit();
    const gpa = gpa_state.allocator();

    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var hist = History.init(gpa, io, tmp.dir, "state");
    defer hist.deinit();
    try hist.append("test-id-1", .accepted, "instruction", "summary", &.{"src/main.zig"}, 0.0, 1.0, "", &.{});
    // revert of an unknown id errors cleanly
    try std.testing.expectError(error.ImprovementNotFound, hist.revert("nope"));
    // the log file exists with one line
    const raw = try tmp.dir.readFileAlloc(io, "state/improvements.jsonl", gpa, .limited(1 << 20));
    defer gpa.free(raw);
    try std.testing.expect(std.mem.indexOf(u8, raw, "test-id-1") != null);
}

test "hotFiles ranks files by rejection frequency" {
    var gpa_state = std.heap.DebugAllocator(.{}).init;
    defer _ = gpa_state.deinit();
    const gpa = gpa_state.allocator();

    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var hist = History.init(gpa, io, tmp.dir, "state");
    defer hist.deinit();

    try hist.append("r1", .rejected, "i", "s", &.{"src/a.zig"}, 0, 0, "d", &.{});
    try hist.append("r2", .rejected, "i", "s", &.{ "src/a.zig", "src/b.zig" }, 0, 0, "d", &.{});
    try hist.append("r3", .rejected, "i", "s", &.{"src/b.zig"}, 0, 0, "d", &.{});
    try hist.append("a1", .accepted, "i", "s", &.{"src/a.zig"}, 0, 1, "", &.{});

    const hot = try hist.hotFiles(arena, 10);
    // a.zig: 2 rejections, b.zig: 2 rejections, both from rejected entries only
    try std.testing.expectEqual(@as(usize, 2), hot.len);
    // Both have 2 rejections; accepted entry for a.zig is not counted.
    try std.testing.expectEqual(@as(u32, 2), hot[0].rejections);
    try std.testing.expectEqual(@as(u32, 2), hot[1].rejections);

    // With no rejections, the list is empty.
    var tmp2 = std.testing.tmpDir(.{});
    defer tmp2.cleanup();
    var hist2 = History.init(gpa, io, tmp2.dir, "state");
    defer hist2.deinit();
    try hist2.append("a2", .accepted, "i", "s", &.{"src/c.zig"}, 0, 1, "", &.{});
    const empty = try hist2.hotFiles(arena, 10);
    try std.testing.expectEqual(@as(usize, 0), empty.len);
}

test "currentStreak exposes the trailing rejection streak publicly" {
    var gpa_state = std.heap.DebugAllocator(.{}).init;
    defer _ = gpa_state.deinit();
    const gpa = gpa_state.allocator();

    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var hist = History.init(gpa, io, tmp.dir, "state");
    defer hist.deinit();

    try std.testing.expectEqual(@as(usize, 0), try hist.currentStreak(arena));

    try hist.append("cs1", .accepted, "i", "s", &.{}, 0, 1, "", &.{});
    try std.testing.expectEqual(@as(usize, 0), try hist.currentStreak(arena));

    try hist.append("cs2", .rejected, "i", "s", &.{}, 0, 0, "d", &.{});
    try hist.append("cs3", .rejected, "i", "s", &.{}, 0, 0, "d", &.{});
    try std.testing.expectEqual(@as(usize, 2), try hist.currentStreak(arena));
}

test "recentFailureReasons returns deduplicated rejection reasons most-recent first" {
    var gpa_state = std.heap.DebugAllocator(.{}).init;
    defer _ = gpa_state.deinit();
    const gpa = gpa_state.allocator();

    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var hist = History.init(gpa, io, tmp.dir, "state");
    defer hist.deinit();

    // Empty history.
    const empty = try hist.recentFailureReasons(arena, 10);
    try std.testing.expectEqual(@as(usize, 0), empty.len);

    try hist.append("fr1", .rejected, "i", "s", &.{}, 0, 0, "build failed", &.{});
    try hist.append("fr2", .accepted, "i", "s", &.{}, 0, 1, "", &.{});
    try hist.append("fr3", .rejected, "i", "s", &.{}, 0, 0, "test failed", &.{});
    try hist.append("fr4", .rejected, "i", "s", &.{}, 0, 0, "build failed", &.{});
    try hist.append("fr5", .failed, "i", "s", &.{}, 0, 0, "   ", &.{});

    const reasons = try hist.recentFailureReasons(arena, 10);
    // "build failed" appears twice but is deduplicated; empty/whitespace detail is skipped.
    try std.testing.expectEqual(@as(usize, 2), reasons.len);
    // Most recent first: fr4's "build failed" before fr3's "test failed".
    try std.testing.expectEqualStrings("build failed", reasons[0]);
    try std.testing.expectEqualStrings("test failed", reasons[1]);

    // Lookback window of 1 only sees the last entry (whitespace, so 0 reasons).
    const narrow = try hist.recentFailureReasons(arena, 1);
    try std.testing.expectEqual(@as(usize, 0), narrow.len);
}

test "trailingRejectionStreak counts consecutive non-accepted entries at the tail" {
    var gpa_state = std.heap.DebugAllocator(.{}).init;
    defer _ = gpa_state.deinit();
    const gpa = gpa_state.allocator();

    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var hist = History.init(gpa, io, tmp.dir, "state");
    defer hist.deinit();

    try hist.append("s1", .accepted, "i", "s", &.{}, 0, 1, "", &.{});
    try hist.append("s2", .rejected, "i", "s", &.{}, 0, 0, "d", &.{});
    try hist.append("s3", .rejected, "i", "s", &.{}, 0, 0, "d", &.{});
    try hist.append("s4", .failed, "i", "s", &.{}, 0, 0, "d", &.{});

    const entries = try hist.loadAll(arena);
    // Three non-accepted entries after the accepted one.
    try std.testing.expectEqual(@as(usize, 3), hist.trailingRejectionStreak(entries, 0));
    // Only looking at last 2 entries: both non-accepted.
    try std.testing.expectEqual(@as(usize, 2), hist.trailingRejectionStreak(entries, 2));
    // The summary must mention the streak.
    const summary = try hist.recentSummary(arena, 10);
    try std.testing.expect(std.mem.indexOf(u8, summary, "consecutive attempts were rejected") != null);
}

test "recentSummary warns about score regressions" {
    var gpa_state = std.heap.DebugAllocator(.{}).init;
    defer _ = gpa_state.deinit();
    const gpa = gpa_state.allocator();

    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var hist = History.init(gpa, io, tmp.dir, "state");
    defer hist.deinit();

    // A rejection with a score regression (score went down).
    try hist.append("reg-1", .rejected, "i", "broke something", &.{"src/a.zig"}, 0.8, 0.5, "test failed", &.{});
    // A rejection without regression (score unchanged).
    try hist.append("reg-2", .rejected, "i", "no change", &.{"src/b.zig"}, 0.8, 0.8, "gate failed", &.{});

    const summary = try hist.recentSummary(arena, 10);
    // The regression warning must appear.
    try std.testing.expect(std.mem.indexOf(u8, summary, "REGRESSIONS") != null);
    try std.testing.expect(std.mem.indexOf(u8, summary, "reg-1") != null);
    try std.testing.expect(std.mem.indexOf(u8, summary, "broke something") != null);
    // The non-regressing rejection should NOT appear in the regression section.
    // (it appears elsewhere in the summary but not under the regression warning)
    try std.testing.expect(std.mem.indexOf(u8, summary, "Do NOT retry") != null);
}

test "sameRegionRejected catches variations of the same failing edit" {
    var gpa_state = std.heap.DebugAllocator(.{}).init;
    defer _ = gpa_state.deinit();
    const gpa = gpa_state.allocator();

    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var hist = History.init(gpa, io, tmp.dir, "state");
    defer hist.deinit();

    const rfp = History.regionFingerprint("src/foo.zig", "old code");
    try std.testing.expect(!try hist.sameRegionRejected(arena, &.{rfp}, 10));

    // Record a rejected attempt with region fingerprints.
    const fp = History.changeFingerprint("src/foo.zig", "old code", "new code v1");
    try hist.appendFull("imp-r1", .rejected, "i", "bad edit", &.{"src/foo.zig"}, 0.0, 0.0, "build failed", &.{fp}, &.{rfp});
    try std.testing.expect(try hist.sameRegionRejected(arena, &.{rfp}, 10));

    // A different replacement for the same region is still caught.
    const rfp_same = History.regionFingerprint("src/foo.zig", "old code");
    try std.testing.expectEqual(rfp, rfp_same);

    // A different region is not matched.
    const rfp_other = History.regionFingerprint("src/foo.zig", "different old code");
    try std.testing.expect(!try hist.sameRegionRejected(arena, &.{rfp_other}, 10));

    // An accepted entry's region is not matched.
    const rfp_acc = History.regionFingerprint("src/bar.zig", "accepted code");
    const fp_acc = History.changeFingerprint("src/bar.zig", "accepted code", "new");
    try hist.appendFull("imp-a1", .accepted, "i", "good", &.{"src/bar.zig"}, 0.0, 1.0, "", &.{fp_acc}, &.{rfp_acc});
    try std.testing.expect(!try hist.sameRegionRejected(arena, &.{rfp_acc}, 10));
}

test "partialOverlapRejected detects shared changes with rejected proposals" {
    var gpa_state = std.heap.DebugAllocator(.{}).init;
    defer _ = gpa_state.deinit();
    const gpa = gpa_state.allocator();

    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var hist = History.init(gpa, io, tmp.dir, "state");
    defer hist.deinit();

    const fp_a = History.changeFingerprint("src/a.zig", "old_a", "new_a");
    const fp_b = History.changeFingerprint("src/b.zig", "old_b", "new_b");
    const fp_c = History.changeFingerprint("src/c.zig", "old_c", "new_c");

    // No history: no overlap.
    try std.testing.expectEqual(@as(usize, 0), try hist.partialOverlapRejected(arena, &.{ fp_a, fp_c }, 10));

    // Reject a proposal with changes [A, B].
    try hist.append("rej-1", .rejected, "i", "s", &.{ "src/a.zig", "src/b.zig" }, 0, 0, "d", &.{ fp_a, fp_b });

    // A new proposal [A, C] shares one change (A) with the rejected one.
    try std.testing.expectEqual(@as(usize, 1), try hist.partialOverlapRejected(arena, &.{ fp_a, fp_c }, 10));

    // The exact-match check does NOT catch this partial overlap.
    try std.testing.expect(!try hist.alreadyRejected(arena, &.{ fp_a, fp_c }, 10));

    // A proposal with no overlap returns 0.
    try std.testing.expectEqual(@as(usize, 0), try hist.partialOverlapRejected(arena, &.{fp_c}, 10));

    // An accepted entry's fingerprints are not counted.
    try hist.append("acc-1", .accepted, "i", "s", &.{"src/c.zig"}, 0, 1, "", &.{fp_c});
    try std.testing.expectEqual(@as(usize, 0), try hist.partialOverlapRejected(arena, &.{fp_c}, 10));

    // Lookback window of 0 finds nothing.
    try std.testing.expectEqual(@as(usize, 0), try hist.partialOverlapRejected(arena, &.{fp_a}, 0));
}

test "attemptDiversity measures file exploration breadth" {
    var gpa_state = std.heap.DebugAllocator(.{}).init;
    defer _ = gpa_state.deinit();
    const gpa = gpa_state.allocator();

    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var hist = History.init(gpa, io, tmp.dir, "state");
    defer hist.deinit();

    // Empty history: perfect diversity.
    try std.testing.expectEqual(@as(f64, 1.0), try hist.attemptDiversity(arena, 10));

    // All attempts target the same file: diversity = 1/3.
    try hist.append("d1", .rejected, "i", "s", &.{"src/a.zig"}, 0, 0, "d", &.{});
    try hist.append("d2", .rejected, "i", "s", &.{"src/a.zig"}, 0, 0, "d", &.{});
    try hist.append("d3", .rejected, "i", "s", &.{"src/a.zig"}, 0, 0, "d", &.{});
    const low = try hist.attemptDiversity(arena, 10);
    try std.testing.expect(low < 0.4);

    // Each attempt targets a different file: diversity = 1.0.
    var tmp2 = std.testing.tmpDir(.{});
    defer tmp2.cleanup();
    var hist2 = History.init(gpa, io, tmp2.dir, "state");
    defer hist2.deinit();
    try hist2.append("h1", .rejected, "i", "s", &.{"src/a.zig"}, 0, 0, "d", &.{});
    try hist2.append("h2", .rejected, "i", "s", &.{"src/b.zig"}, 0, 0, "d", &.{});
    try hist2.append("h3", .rejected, "i", "s", &.{"src/c.zig"}, 0, 0, "d", &.{});
    const high = try hist2.attemptDiversity(arena, 10);
    try std.testing.expectEqual(@as(f64, 1.0), high);
}

test "recentlyRejectedFiles returns deduplicated files from recent rejections" {
    var gpa_state = std.heap.DebugAllocator(.{}).init;
    defer _ = gpa_state.deinit();
    const gpa = gpa_state.allocator();

    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var hist = History.init(gpa, io, tmp.dir, "state");
    defer hist.deinit();

    try hist.append("rr1", .accepted, "i", "s", &.{"src/a.zig"}, 0, 1, "", &.{});
    try hist.append("rr2", .rejected, "i", "s", &.{ "src/b.zig", "src/c.zig" }, 0, 0, "d", &.{});
    try hist.append("rr3", .rejected, "i", "s", &.{"src/b.zig"}, 0, 0, "d", &.{});

    const files = try hist.recentlyRejectedFiles(arena, 10);
    // src/b.zig appears in both rejections but should be deduplicated.
    try std.testing.expectEqual(@as(usize, 2), files.len);
    // Most recent rejection first.
    try std.testing.expectEqualStrings("src/b.zig", files[0]);
    try std.testing.expectEqualStrings("src/c.zig", files[1]);

    // Accepted files are not included.
    for (files) |f| {
        try std.testing.expect(!std.mem.eql(u8, f, "src/a.zig"));
    }

    // Empty history returns empty.
    var tmp2 = std.testing.tmpDir(.{});
    defer tmp2.cleanup();
    var hist2 = History.init(gpa, io, tmp2.dir, "state");
    defer hist2.deinit();
    const empty = try hist2.recentlyRejectedFiles(arena, 10);
    try std.testing.expectEqual(@as(usize, 0), empty.len);
}

test "recentlyTouchedWithStatus tags files with their attempt status" {
    var gpa_state = std.heap.DebugAllocator(.{}).init;
    defer _ = gpa_state.deinit();
    const gpa = gpa_state.allocator();

    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var hist = History.init(gpa, io, tmp.dir, "state");
    defer hist.deinit();

    try hist.append("t1", .accepted, "i", "added feature", &.{"src/a.zig"}, 0, 1, "", &.{});
    try hist.append("t2", .rejected, "i", "bad change", &.{"src/b.zig"}, 0, 0, "d", &.{});

    const touched = try hist.recentlyTouchedWithStatus(arena, 10);
    try std.testing.expectEqual(@as(usize, 2), touched.len);
    try std.testing.expectEqualStrings("src/a.zig", touched[0].file);
    try std.testing.expectEqualStrings("accepted", touched[0].status);
    try std.testing.expectEqualStrings("added feature", touched[0].summary);
    try std.testing.expectEqualStrings("src/b.zig", touched[1].file);
    try std.testing.expectEqualStrings("rejected", touched[1].status);

    // The summary includes the recently accepted section.
    const summary = try hist.recentSummary(arena, 10);
    try std.testing.expect(std.mem.indexOf(u8, summary, "Recently accepted changes") != null);
    try std.testing.expect(std.mem.indexOf(u8, summary, "src/a.zig") != null);
}

test "an edit already rejected is recognised within the lookback window" {
    var gpa_state = std.heap.DebugAllocator(.{}).init;
    defer _ = gpa_state.deinit();
    const gpa = gpa_state.allocator();

    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var hist = History.init(gpa, io, tmp.dir, "state");
    defer hist.deinit();

    const fp = History.changeFingerprint("src/foo.zig", "old code", "new code");
    try std.testing.expect(!try hist.alreadyRejected(arena, &.{fp}, 10));

    try hist.append("imp-r1", .rejected, "i", "bad edit", &.{"src/foo.zig"}, 0.0, 0.0, "build failed", &.{fp});
    try std.testing.expect(try hist.alreadyRejected(arena, &.{fp}, 10));

    // An accepted edit with the same fingerprint is not a rejection.
    const fp2 = History.changeFingerprint("src/bar.zig", "a", "b");
    try hist.append("imp-a1", .accepted, "i", "good edit", &.{"src/bar.zig"}, 0.0, 1.0, "", &.{fp2});
    try std.testing.expect(!try hist.alreadyRejected(arena, &.{fp2}, 10));

    // A different edit is not matched.
    const fp3 = History.changeFingerprint("src/baz.zig", "x", "y");
    try std.testing.expect(!try hist.alreadyRejected(arena, &.{fp3}, 10));

    // A lookback of 0 finds nothing (the rejection is outside the window).
    try std.testing.expect(!try hist.alreadyRejected(arena, &.{fp}, 0));
}

test "an edit already accepted is recognised, a different one is not" {
    var gpa_state = std.heap.DebugAllocator(.{}).init;
    defer _ = gpa_state.deinit();
    const gpa = gpa_state.allocator();

    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var hist = History.init(gpa, io, tmp.dir, "state");
    defer hist.deinit();

    // The edit that actually got promoted three times.
    const fp = History.changeFingerprint("src/cli.zig", "    const resp = a.run(", "    repl_md = .{};\n    const resp = a.run(");
    try std.testing.expect(!try hist.alreadyAccepted(arena, &.{fp}));

    try hist.append("imp-1", .accepted, "i", "reset repl_md", &.{"src/cli.zig"}, 0.0, 1.0, "", &.{fp});
    try std.testing.expect(try hist.alreadyAccepted(arena, &.{fp}));

    // A different edit to the same file is still new.
    const other = History.changeFingerprint("src/cli.zig", "something else", "replacement");
    try std.testing.expect(!try hist.alreadyAccepted(arena, &.{other}));

    // A rejected attempt is not a reason to refuse the work.
    const refused = History.changeFingerprint("src/a.zig", "x", "y");
    try hist.append("imp-2", .rejected, "i", "s", &.{"src/a.zig"}, 0.0, 0.0, "", &.{refused});
    try std.testing.expect(!try hist.alreadyAccepted(arena, &.{refused}));
}

test "restoreFilesCount reports how many files were actually restored" {
    var gpa_state = std.heap.DebugAllocator(.{}).init;
    defer _ = gpa_state.deinit();
    const gpa = gpa_state.allocator();

    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    tmp.dir.createDirPath(io, "src") catch {};
    try tmp.dir.writeFile(io, .{ .sub_path = "src/exists.zig", .data = "original" });

    var hist = History.init(gpa, io, tmp.dir, "state");
    defer hist.deinit();

    try hist.snapshot("rc-1", &.{ "src/exists.zig", "src/missing.zig" });

    // Overwrite the file so restore has something to revert.
    try tmp.dir.writeFile(io, .{ .sub_path = "src/exists.zig", .data = "modified" });

    // Only 1 of 2 files can be restored (missing.zig was never snapshotted).
    const count = hist.restoreFilesCount("rc-1", &.{ "src/exists.zig", "src/missing.zig" });
    try std.testing.expectEqual(@as(usize, 1), count);

    // The restorable file was actually restored.
    const content = try tmp.dir.readFileAlloc(io, "src/exists.zig", gpa, .limited(1 << 16));
    defer gpa.free(content);
    try std.testing.expectEqualStrings("original", content);
}

test "snapshot silently skips a file that does not exist yet" {
    var gpa_state = std.heap.DebugAllocator(.{}).init;
    defer _ = gpa_state.deinit();
    const gpa = gpa_state.allocator();

    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    // Write one file that exists; leave the other absent (a new file the
    // proposal would create).
    tmp.dir.createDirPath(io, "src") catch {};
    try tmp.dir.writeFile(io, .{ .sub_path = "src/existing.zig", .data = "existing content" });

    var hist = History.init(gpa, io, tmp.dir, "state");
    defer hist.deinit();

    // snapshot must succeed without error even though src/new_file.zig does
    // not exist; existing.zig must be copied.
    try hist.snapshot("snap-1", &.{ "src/existing.zig", "src/new_file.zig" });

    // The existing file was snapshotted.
    const snapped = try tmp.dir.readFileAlloc(io, "state/history/snap-1/src/existing.zig", gpa, .limited(1 << 16));
    defer gpa.free(snapped);
    try std.testing.expectEqualStrings("existing content", snapped);

    // The new file was not snapshotted (no file created for it).
    const absent = tmp.dir.readFileAlloc(io, "state/history/snap-1/src/new_file.zig", gpa, .limited(1 << 16));
    try std.testing.expectError(error.FileNotFound, absent);
}

test "append keeps every prior improvement" {
    var gpa_state = std.heap.DebugAllocator(.{}).init;
    defer _ = gpa_state.deinit();
    const gpa = gpa_state.allocator();

    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var hist = History.init(gpa, io, tmp.dir, "state");
    defer hist.deinit();
    try hist.append("imp-1", .accepted, "first", "did a thing", &.{"src/a.zig"}, 0.0, 1.0, "", &.{});
    try hist.append("imp-2", .accepted, "second", "did another", &.{"src/b.zig"}, 1.0, 2.0, "", &.{});
    try hist.append("imp-3", .rejected, "third", "was refused", &.{"src/c.zig"}, 2.0, 2.0, "", &.{});

    const raw = try tmp.dir.readFileAlloc(io, "state/improvements.jsonl", gpa, .limited(1 << 20));
    defer gpa.free(raw);

    // The whole point of the log: an earlier entry is still there after a
    // later one lands. Without this the improvement loop has no memory and
    // re-proposes work it already promoted.
    try std.testing.expect(std.mem.indexOf(u8, raw, "imp-1") != null);
    try std.testing.expect(std.mem.indexOf(u8, raw, "imp-2") != null);
    try std.testing.expect(std.mem.indexOf(u8, raw, "imp-3") != null);

    var lines: usize = 0;
    var it = std.mem.splitScalar(u8, std.mem.trim(u8, raw, "\n"), '\n');
    while (it.next()) |line| {
        if (line.len > 0) lines += 1;
    }
    try std.testing.expectEqual(@as(usize, 3), lines);
}

test "records from overlapping runs are all kept" {
    // The log is read, extended and written back, so two writers both start
    // from the same contents and one entry is discarded. An improve run and
    // the staged evals its gate spawns are separate processes over one state
    // directory, and this file is what the next run's prompt reads to learn
    // what has already been tried.
    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const writers = 6;
    const per_writer = 8;

    const Worker = struct {
        dir: std.Io.Dir,
        io: std.Io,
        gpa: std.mem.Allocator,
        id: usize,

        fn run(self: *@This()) void {
            var h = History.init(self.gpa, self.io, self.dir, "state");
            defer h.deinit();
            var i: usize = 0;
            while (i < per_writer) : (i += 1) {
                var buf: [64]u8 = undefined;
                const id = std.fmt.bufPrint(&buf, "imp-{d}-{d}", .{ self.id, i }) catch return;
                h.append(id, .accepted, "instruction", "summary", &.{}, 0, 0, "", &.{}) catch return;
            }
        }
    };

    var workers: [writers]Worker = undefined;
    var threads: [writers]std.Thread = undefined;
    for (&workers, 0..) |*w, i| {
        w.* = .{ .dir = tmp.dir, .io = io, .gpa = std.testing.allocator, .id = i };
        threads[i] = try std.Thread.spawn(.{}, Worker.run, .{w});
    }
    for (&threads) |*t| t.join();

    const raw = try tmp.dir.readFileAlloc(io, "state/improvements.jsonl", std.testing.allocator, .limited(1 << 22));
    defer std.testing.allocator.free(raw);

    var kept: usize = 0;
    var it = std.mem.splitScalar(u8, raw, '\n');
    while (it.next()) |line| {
        if (line.len == 0) continue;
        kept += 1;
    }
    try std.testing.expectEqual(@as(usize, writers * per_writer), kept);
}
