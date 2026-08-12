//! Improvement history: JSONL log + per-attempt file snapshots + revert.

const std = @import("std");
const json = std.json;
const log = @import("../util/log.zig");
const filelock = @import("../util/filelock.zig");
const inert = @import("inert.zig");

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
        /// What the change did, when the caller got far enough to know. null
        /// at the failure paths that reject a proposal before it is
        /// classified — a build that never compiled has no class, and writing
        /// one anyway would put guesses into the record the next run reads.
        class: ?inert.Class,
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

        // Grows to fit the record rather than a fixed cap: a build-failure
        // detail can legitimately exceed 1 MiB, and the old fixed buffer
        // made the whole append error out at that size, silently dropping
        // the entry and any memory of the failed attempt.
        var out: std.Io.Writer.Allocating = .init(self.gpa);
        defer out.deinit();
        var s = json.Stringify{ .writer = &out.writer, .options = .{ .emit_null_optional_fields = false } };

        try s.beginObject();
        // Written from entry 1 on: `changes` already needed one silent format
        // migration (bare u64 -> hex string) inferred per-field from old data.
        // A version lets the next one branch on "v" instead of re-deriving
        // "this must be an old entry" from field shape.
        try s.objectField("v");
        try s.write(1);
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
        if (class) |k| {
            try s.objectField("class");
            try s.write(k.asStr());
        }
        try s.endObject();

        try buf.appendSlice(self.gpa, out.written());
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
        /// Empty for entries written before fingerprints existed; those simply
        /// cannot be matched against, rather than matching everything.
        changes: []const u64 = &.{},
        /// What the change did, as `inert.Class.asStr` wrote it. Absent on
        /// entries written before classification existed, which read back as
        /// `behavior` — an unclassified promotion must not be counted toward a
        /// monoculture streak nobody measured.
        class: []const u8 = "",
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
            const text = struct {
                fn get(o: json.ObjectMap, key: []const u8) []const u8 {
                    const x = o.get(key) orelse return "";
                    return switch (x) {
                        .string => |str| str,
                        else => "",
                    };
                }
            }.get;
            try out.append(arena, .{
                .id = id,
                .status = status,
                .files = try files.toOwnedSlice(arena),
                .summary = text(obj, "summary"),
                .detail = text(obj, "detail"),
                .changes = try fps.toOwnedSlice(arena),
                .class = text(obj, "class"),
            });
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
            // What the change did, not just that it landed. "accepted" on its
            // own reads as an endorsement, and a run whose last ten lines all
            // said "accepted" was being told, ten times over, that adding a
            // test block is what success looks like here.
            if (e.class.len > 0) {
                try buf.appendSlice(arena, " [");
                try buf.appendSlice(arena, e.class);
                try buf.appendSlice(arena, "]");
            }
            try buf.appendSlice(arena, ": ");
            try buf.appendSlice(arena, firstLine(e.summary, 160));
            // Why it failed is the part worth carrying: the summary alone says
            // what was attempted, not what went wrong with it.
            if (!std.mem.eql(u8, e.status, "accepted") and e.detail.len > 0) {
                try buf.appendSlice(arena, "\n    rejected because: ");
                try buf.appendSlice(arena, firstLine(e.detail, 200));
            }
            try buf.appendSlice(arena, "\n");
        }
        return buf.toOwnedSlice(arena);
    }

    /// The classes of the last `max_entries` *accepted* improvements, oldest
    /// first. Rejections are left out: the question this answers is what the
    /// loop has been rewarded for, and a rejected proposal was rewarded for
    /// nothing.
    pub fn recentAcceptedClasses(self: *History, arena: std.mem.Allocator, max_entries: usize) ![]const inert.Class {
        const entries = try self.loadAll(arena);
        var out: std.ArrayList(inert.Class) = .empty;
        var i = entries.len;
        while (i > 0 and out.items.len < max_entries) {
            i -= 1;
            const e = entries[i];
            if (!std.mem.eql(u8, e.status, "accepted")) continue;
            // Only entries that carry the field. An unclassified promotion is
            // not evidence either way, and counting it as `behavior` would
            // silently reset a streak that a fresh log would have caught.
            if (e.class.len == 0) continue;
            try out.append(arena, inert.Class.fromStr(e.class));
        }
        std.mem.reverse(inert.Class, out.items);
        return out.toOwnedSlice(arena);
    }

    /// How many of the most recent accepted improvements were `want`, counting
    /// back from the newest and stopping at the first that was not.
    pub fn trailingClassStreak(self: *History, arena: std.mem.Allocator, want: inert.Class, max_entries: usize) !usize {
        const classes = try self.recentAcceptedClasses(arena, max_entries);
        var n: usize = 0;
        var i = classes.len;
        while (i > 0) {
            i -= 1;
            if (classes[i] != want) break;
            n += 1;
        }
        return n;
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
    try hist.append("test-id-1", .accepted, "instruction", "summary", &.{"src/main.zig"}, 0.0, 1.0, "", &.{}, null);
    // revert of an unknown id errors cleanly
    try std.testing.expectError(error.ImprovementNotFound, hist.revert("nope"));
    // the log file exists with one line
    const raw = try tmp.dir.readFileAlloc(io, "state/improvements.jsonl", gpa, .limited(1 << 20));
    defer gpa.free(raw);
    try std.testing.expect(std.mem.indexOf(u8, raw, "test-id-1") != null);
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

    try hist.append("imp-1", .accepted, "i", "reset repl_md", &.{"src/cli.zig"}, 0.0, 1.0, "", &.{fp}, null);
    try std.testing.expect(try hist.alreadyAccepted(arena, &.{fp}));

    // A different edit to the same file is still new.
    const other = History.changeFingerprint("src/cli.zig", "something else", "replacement");
    try std.testing.expect(!try hist.alreadyAccepted(arena, &.{other}));

    // A rejected attempt is not a reason to refuse the work.
    const refused = History.changeFingerprint("src/a.zig", "x", "y");
    try hist.append("imp-2", .rejected, "i", "s", &.{"src/a.zig"}, 0.0, 0.0, "", &.{refused}, null);
    try std.testing.expect(!try hist.alreadyAccepted(arena, &.{refused}));
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
    try hist.append("imp-1", .accepted, "first", "did a thing", &.{"src/a.zig"}, 0.0, 1.0, "", &.{}, null);
    try hist.append("imp-2", .accepted, "second", "did another", &.{"src/b.zig"}, 1.0, 2.0, "", &.{}, null);
    try hist.append("imp-3", .rejected, "third", "was refused", &.{"src/c.zig"}, 2.0, 2.0, "", &.{}, null);

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
                h.append(id, .accepted, "instruction", "summary", &.{}, 0, 0, "", &.{}, null) catch return;
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

test "recentlyTouched deduplicates files from the recent window and recentSummary renders status lines" {
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

    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // Four attempts: only the last two fall inside the "recent" window.
    try hist.append("e1", .accepted, "i1", "one", &.{"src/one.zig"}, 0, 1, "", &.{}, null);
    try hist.append("e2", .accepted, "i2", "two", &.{"src/two.zig"}, 0, 1, "", &.{}, null);
    try hist.append("e3", .rejected, "i3", "three", &.{ "src/three.zig", "src/one.zig" }, 0, 0, "why not", &.{}, null);
    try hist.append("e4", .accepted, "i4", "four", &.{ "src/one.zig", "src/four.zig" }, 0, 1, "", &.{}, null);

    {
        const recent = try hist.recentlyTouched(arena, 2);
        // Last two entries are e3 and e4: files src/three.zig, src/one.zig,
        // src/four.zig (src/one.zig appears in both e3 and e4 -> kept once).
        try std.testing.expectEqual(@as(usize, 3), recent.len);
        try std.testing.expectEqualStrings("src/three.zig", recent[0]);
        try std.testing.expectEqualStrings("src/one.zig", recent[1]);
        try std.testing.expectEqualStrings("src/four.zig", recent[2]);
    }

    {
        const summary = try hist.recentSummary(arena, 2);
        // e3 is rejected and has detail; e4 is accepted.
        try std.testing.expect(std.mem.indexOf(u8, summary, "- rejected: three") != null);
        try std.testing.expect(std.mem.indexOf(u8, summary, "rejected because: why not") != null);
        try std.testing.expect(std.mem.indexOf(u8, summary, "- accepted: four") != null);
    }
}

test "the class of an accepted change is recorded, rendered, and counted as a streak" {
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

    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // An entry from before classification existed, then a real change, then
    // three test-only promotions in a row.
    try hist.append("e0", .accepted, "i", "unclassified", &.{"src/a.zig"}, 0, 1, "", &.{}, null);
    try hist.append("e1", .accepted, "i", "real work", &.{"src/a.zig"}, 0, 1, "", &.{}, .behavior);
    try hist.append("e2", .accepted, "i", "a test", &.{"src/a.zig"}, 0, 1, "", &.{}, .test_only);
    // A rejection between them must not break the streak: the streak is about
    // what the loop was rewarded for, and this was rewarded with nothing.
    try hist.append("e3", .rejected, "i", "refused", &.{"src/a.zig"}, 0, 0, "no", &.{}, .inert);
    try hist.append("e4", .accepted, "i", "another test", &.{"src/a.zig"}, 0, 1, "", &.{}, .test_only);
    try hist.append("e5", .accepted, "i", "a third test", &.{"src/a.zig"}, 0, 1, "", &.{}, .test_only);

    const classes = try hist.recentAcceptedClasses(arena, 12);
    // Oldest first, rejections and the unclassified entry left out.
    try std.testing.expectEqual(@as(usize, 4), classes.len);
    try std.testing.expectEqual(inert.Class.behavior, classes[0]);
    try std.testing.expectEqual(inert.Class.test_only, classes[3]);

    try std.testing.expectEqual(@as(usize, 3), try hist.trailingClassStreak(arena, .test_only, 12));
    try std.testing.expectEqual(@as(usize, 0), try hist.trailingClassStreak(arena, .behavior, 12));

    const summary = try hist.recentSummary(arena, 6);
    try std.testing.expect(std.mem.indexOf(u8, summary, "- accepted [test_only]: a third test") != null);
    try std.testing.expect(std.mem.indexOf(u8, summary, "- rejected [inert]: refused") != null);
    // The pre-classification entry has no tag to render.
    try std.testing.expect(std.mem.indexOf(u8, summary, "- accepted: unclassified") != null);
}

test "an over-1 MiB detail is logged whole, not dropped by a fixed buffer" {
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

    // A build-failure detail can push a record past 1 MiB; it must be logged
    // whole. The old fixed 1 MiB record buffer errored the append at that
    // size, so the entry silently disappeared.
    const big_detail = try gpa.alloc(u8, (1 << 20) + 500);
    defer gpa.free(big_detail);
    @memset(big_detail, 'x');

    try hist.append("big", .failed, "instruction", "summary", &.{"src/main.zig"}, 0.0, 0.0, big_detail, &.{}, null);

    const raw = try tmp.dir.readFileAlloc(io, "state/improvements.jsonl", gpa, .limited(1 << 24));
    defer gpa.free(raw);
    try std.testing.expect(std.mem.indexOf(u8, raw, "\"id\":\"big\"") != null);
    // The full detail survives the round trip; a fixed-buffer write would
    // have errored the append and left no entry at all.
    try std.testing.expect(std.mem.indexOf(u8, raw, big_detail) != null);
}

test "firstLine trims, takes the first line, and clips to max" {
    // Overall leading/trailing whitespace is trimmed before the first line
    // is taken; the first line's own trailing spaces before a newline are
    // kept, because trimming only happens at the whole-string ends.
    try std.testing.expectEqualStrings("hello world", firstLine("  hello world\n  second", 100));
    // A first line longer than max is clipped to max bytes.
    try std.testing.expectEqualStrings("hel", firstLine("  hello world\n  second", 3));
    // No newline: the whole trimmed string is returned (and clipped).
    try std.testing.expectEqualStrings("world", firstLine("  world  ", 10));
    // Empty / whitespace-only input yields empty.
    try std.testing.expectEqualStrings("", firstLine("   \n  ", 10));
}
