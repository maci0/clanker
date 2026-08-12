//! Detecting human reverts of promoted improvements from git history.
//!
//! A merge is not the end of a change's review: maintainers revert
//! improvement commits after the fact, and until that signal lands back in
//! improvements.jsonl the loop's memory says "accepted" about work that is
//! no longer in the tree. That mismatch is worse than no memory at all:
//! the prompt tells the model the work is already in the source while the
//! source shows it undone, which is how one improvement got merged,
//! reverted, re-proposed, re-merged and reverted again. This module reads
//! the revert signal out of `git log` so history can record it.
//!
//! Two shapes of revert commit are recognised:
//!   - `git revert`'s own: a `Revert "<original subject>"` subject (which
//!     quotes the original's `[imp-...]` tag) and a `This reverts commit
//!     <sha>` body line.
//!   - the manual style used on this repository: a subject ending in
//!     `(revert of <sha>[/<sha>...])`.
//! Referenced shas are resolved against the same log by prefix, so a revert
//! whose message names commits that never reached this clone (rebased away,
//! reverted elsewhere) is simply not matched rather than mismatched.
//!
//! Message shapes are not enough, though: humans word reverts freely. Both
//! real reverts of promoted improvements on this repository were prose:
//! "Reverted in the working tree before this commit, not by me", naming no
//! sha and matching neither shape, so the loop's history kept saying
//! accepted and it re-proposed and re-merged the exact same work. The
//! second half of this module is therefore message-blind: `addedLines` and
//! `presence` decide from content whether the lines an improvement commit
//! added still exist in the tree. All of them gone means the work was
//! undone, however the undoing was worded.

const std = @import("std");

/// A promoted improvement a later commit undid.
pub const Reverted = struct {
    /// The improvement id from the original commit's `[imp-...]` tag.
    id: []const u8,
    /// Subject of the commit that reverted it, for the log line.
    by: []const u8,
};

/// The `git log` invocation `scan` parses: one record per commit, fields
/// split by the unit separator, records by the record separator, bytes no
/// subject can contain, unlike the newlines a `%b` body is full of.
pub const git_log_args = [_][]const u8{ "log", "-n", "400", "--format=%H%x1f%s%x1f%b%x1e" };

const Commit = struct { sha: []const u8, subject: []const u8, body: []const u8 };

/// The improvement id an engine-authored commit subject carries:
/// `clanker: ... [imp-1786528675805548694]` -> `imp-1786528675805548694`.
pub fn impTag(subject: []const u8) ?[]const u8 {
    const open = std.mem.lastIndexOf(u8, subject, "[imp-") orelse return null;
    const rest = subject[open + 1 ..];
    const close = std.mem.findScalar(u8, rest, ']') orelse return null;
    const id = rest[0..close];
    if (id.len <= "imp-".len) return null;
    return id;
}

/// The reverted improvements named by the given `git log` output (in the
/// `git_log_args` format), deduplicated by id. Only ids that resolve to an
/// improvement commit in the same log are returned: a revert of ordinary
/// work carries no imp tag and matches nothing.
pub fn scan(arena: std.mem.Allocator, raw: []const u8) ![]const Reverted {
    const commits = try parseCommits(arena, raw);

    var out: std.ArrayList(Reverted) = .empty;
    for (commits.items) |c| {
        if (!isRevert(c)) continue;

        // `git revert` quotes the original subject, tag included.
        if (impTag(c.subject)) |id| try addReverted(arena, &out, id, c.subject);

        var refs: std.ArrayList([]const u8) = .empty;
        try harvestShas(arena, &refs, c.body, "This reverts commit ");
        try harvestShas(arena, &refs, c.subject, "revert of ");
        for (refs.items) |ref| {
            for (commits.items) |orig| {
                if (!std.mem.startsWith(u8, orig.sha, ref)) continue;
                if (isRevert(orig)) continue;
                if (impTag(orig.subject)) |id| try addReverted(arena, &out, id, c.subject);
            }
        }
    }
    return try out.toOwnedSlice(arena);
}

fn parseCommits(arena: std.mem.Allocator, raw: []const u8) !std.ArrayList(Commit) {
    var commits: std.ArrayList(Commit) = .empty;
    var records = std.mem.splitScalar(u8, raw, '\x1e');
    while (records.next()) |rec| {
        const trimmed = std.mem.trim(u8, rec, "\r\n ");
        if (trimmed.len == 0) continue;
        var fields = std.mem.splitScalar(u8, trimmed, '\x1f');
        const sha = fields.next() orelse continue;
        const subject = fields.next() orelse continue;
        const body = fields.rest();
        if (sha.len < 7 or !isHexRun(sha)) continue;
        try commits.append(arena, .{ .sha = sha, .subject = subject, .body = body });
    }
    return commits;
}

/// An engine-authored improvement commit found in the log.
pub const ImpCommit = struct { sha: []const u8, id: []const u8 };

/// Every non-revert commit in the log (in the `git_log_args` format)
/// carrying an `[imp-...]` tag, in log order. The same id can appear more
/// than once, an improvement that was reverted and re-landed has two
/// commits, and a caller judging whether the work is still in the tree
/// must consider all of them.
pub fn improvementCommits(arena: std.mem.Allocator, raw: []const u8) ![]const ImpCommit {
    const commits = try parseCommits(arena, raw);
    var out: std.ArrayList(ImpCommit) = .empty;
    for (commits.items) |c| {
        if (isRevert(c)) continue;
        if (impTag(c.subject)) |id| try out.append(arena, .{ .sha = c.sha, .id = id });
    }
    return try out.toOwnedSlice(arena);
}

/// The `git show` invocation whose output `addedLines` parses: no commit
/// message, no context lines, no colour, just the patch.
pub const git_show_args = [_][]const u8{ "show", "--format=", "--unified=0", "--no-color" };

/// The lines a commit added to one file, trimmed of surrounding whitespace
/// so a survivor is found whatever its current indentation.
pub const FileAdds = struct { path: []const u8, lines: []const []const u8 };

/// An added line too short to be distinctive carries no revert signal: `}`
/// or `break;` exists in every file whether the improvement survived or not.
const min_added_line_len = 8;

/// Parses a `git_show_args` diff into the significant lines it added, per
/// file. Deleted files contribute nothing (their `+++` side is /dev/null);
/// so do context-free noise lines shorter than `min_added_line_len`.
pub fn addedLines(arena: std.mem.Allocator, diff: []const u8) ![]const FileAdds {
    var out: std.ArrayList(FileAdds) = .empty;
    var lines: std.ArrayList([]const u8) = .empty;
    var path: ?[]const u8 = null;

    var it = std.mem.splitScalar(u8, diff, '\n');
    while (it.next()) |line| {
        if (std.mem.startsWith(u8, line, "+++ ")) {
            if (path) |p| {
                if (lines.items.len > 0) try out.append(arena, .{ .path = p, .lines = try lines.toOwnedSlice(arena) });
                lines = .empty;
            }
            const target = std.mem.trimEnd(u8, line["+++ ".len..], "\r\t ");
            path = if (std.mem.startsWith(u8, target, "b/")) target["b/".len..] else null;
            continue;
        }
        if (line.len < 1 or line[0] != '+') continue;
        if (path == null) continue;
        const added = std.mem.trim(u8, line[1..], "\r\t ");
        if (added.len < min_added_line_len) continue;
        try lines.append(arena, added);
    }
    if (path) |p| {
        if (lines.items.len > 0) try out.append(arena, .{ .path = p, .lines = try lines.toOwnedSlice(arena) });
    }
    return try out.toOwnedSlice(arena);
}

/// Drops added lines that already existed in the parent version of their
/// file. Boilerplate a commit repeats, `defer arena_state.deinit();`, a
/// test's scaffolding, a loop header the file already had, matches the
/// tree whether the improvement survived or not, and counting it as a
/// survivor is how one fully reverted improvement kept reading as present:
/// its 8 "surviving" lines were all in the parent file too. `parents` is
/// anything with `read(path) ?[]const u8` returning the file's content at
/// the commit's parent, or null when the file did not exist yet (every
/// line of a new file is distinctive).
pub fn distinctiveAdds(arena: std.mem.Allocator, adds: []const FileAdds, parents: anytype) ![]const FileAdds {
    var out: std.ArrayList(FileAdds) = .empty;
    for (adds) |fa| {
        const parent = parents.read(fa.path) orelse {
            try out.append(arena, fa);
            continue;
        };
        var lines: std.ArrayList([]const u8) = .empty;
        for (fa.lines) |line| {
            if (std.mem.find(u8, parent, line) != null) continue;
            try lines.append(arena, line);
        }
        if (lines.items.len > 0) try out.append(arena, .{ .path = fa.path, .lines = try lines.toOwnedSlice(arena) });
    }
    return try out.toOwnedSlice(arena);
}

/// Whether the lines a commit added still exist in the tree.
pub const Presence = enum {
    /// At least one significant added line survives somewhere it was put.
    present,
    /// Every significant added line is gone: the work was undone.
    gone,
    /// Too few significant lines to judge either way.
    inconclusive,
};

/// A commit below this many significant added lines gives no verdict: one
/// vanished line is as likely a follow-up edit as a revert.
const min_content_signal = 3;

/// Decides `Presence` for a parsed diff against the current tree. `files`
/// is anything with `read(path) ?[]const u8` returning a file's current
/// contents, or null when it no longer exists (a deleted file's lines are
/// all gone by definition). Matching is substring on the trimmed line, so
/// re-indented survivors still count, the check errs toward `present`,
/// because a false `gone` would brand live work as human-refused, while a
/// false `present` merely leaves the message-based scan to catch it.
pub fn presence(adds: []const FileAdds, files: anytype) Presence {
    var total: usize = 0;
    var surviving: usize = 0;
    for (adds) |fa| {
        const content = files.read(fa.path);
        for (fa.lines) |line| {
            total += 1;
            if (content) |c| {
                if (std.mem.find(u8, c, line) != null) surviving += 1;
            }
        }
    }
    if (total < min_content_signal) return .inconclusive;
    return if (surviving == 0) .gone else .present;
}

/// Whether the commit undoes another, in either recognised shape. Checked
/// on the original side of a sha match too, so a revert-of-a-revert does
/// not read as the improvement it un-undid.
fn isRevert(c: Commit) bool {
    if (std.mem.startsWith(u8, c.subject, "Revert ")) return true;
    if (std.ascii.indexOfIgnoreCase(c.subject, "revert of ") != null) return true;
    if (std.mem.find(u8, c.body, "This reverts commit ") != null) return true;
    return false;
}

/// Appends every hex run of at least 7 chars found right after each
/// occurrence of `marker`, following `/`-separated lists so the manual
/// `(revert of cbe4e49/ea3c7b8)` style yields both shas.
fn harvestShas(arena: std.mem.Allocator, refs: *std.ArrayList([]const u8), text: []const u8, marker: []const u8) !void {
    var rest = text;
    while (std.ascii.indexOfIgnoreCase(rest, marker)) |at| {
        var p = rest[at + marker.len ..];
        while (true) {
            var n: usize = 0;
            while (n < p.len and isHexChar(p[n])) n += 1;
            if (n < 7) break;
            try refs.append(arena, p[0..n]);
            p = p[n..];
            if (p.len == 0 or p[0] != '/') break;
            p = p[1..];
        }
        rest = rest[at + marker.len ..];
    }
}

fn isHexChar(ch: u8) bool {
    return (ch >= '0' and ch <= '9') or (ch >= 'a' and ch <= 'f') or (ch >= 'A' and ch <= 'F');
}

fn isHexRun(s: []const u8) bool {
    for (s) |ch| {
        if (!isHexChar(ch)) return false;
    }
    return true;
}

fn addReverted(arena: std.mem.Allocator, out: *std.ArrayList(Reverted), id: []const u8, by: []const u8) !void {
    for (out.items) |have| {
        if (std.mem.eql(u8, have.id, id)) return;
    }
    try out.append(arena, .{ .id = id, .by = by });
}

// ------------------------------------------------------------------- tests --

test "impTag extracts the id and rejects subjects without one" {
    try std.testing.expectEqualStrings(
        "imp-1786528675805548694",
        impTag("clanker: ensure the file exists [imp-1786528675805548694]").?,
    );
    // git revert quotes the original subject; the tag survives inside it.
    try std.testing.expectEqualStrings(
        "imp-42x",
        impTag("Revert \"clanker: do a thing [imp-42x]\"").?,
    );
    try std.testing.expectEqual(@as(?[]const u8, null), impTag("worktree: revert the check (revert of cbe4e49)"));
    try std.testing.expectEqual(@as(?[]const u8, null), impTag("clanker: unclosed tag [imp-123"));
    try std.testing.expectEqual(@as(?[]const u8, null), impTag("clanker: empty tag [imp-]"));
}

fn fakeLog(arena: std.mem.Allocator, entries: []const Commit) ![]const u8 {
    var buf: std.ArrayList(u8) = .empty;
    for (entries) |e| {
        try buf.appendSlice(arena, e.sha);
        try buf.append(arena, '\x1f');
        try buf.appendSlice(arena, e.subject);
        try buf.append(arena, '\x1f');
        try buf.appendSlice(arena, e.body);
        try buf.append(arena, '\x1e');
        try buf.append(arena, '\n');
    }
    return buf.toOwnedSlice(arena);
}

test "scan resolves the manual multi-sha revert style" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const raw = try fakeLog(arena, &.{
        .{ .sha = "6d2454f000000000000000000000000000000000", .subject = "worktree: revert the state sharing (revert of cbe4e49/ea3c7b8)", .body = "" },
        .{ .sha = "cbe4e49000000000000000000000000000000000", .subject = "clanker: ensure improvements.jsonl exists [imp-111]", .body = "" },
        .{ .sha = "ea3c7b8000000000000000000000000000000000", .subject = "clanker: validate the base branch [imp-222]", .body = "" },
        .{ .sha = "aaaaaaa000000000000000000000000000000000", .subject = "clanker: untouched work [imp-333]", .body = "" },
    });
    const found = try scan(arena, raw);
    try std.testing.expectEqual(@as(usize, 2), found.len);
    try std.testing.expectEqualStrings("imp-111", found[0].id);
    try std.testing.expectEqualStrings("imp-222", found[1].id);
    try std.testing.expect(std.mem.find(u8, found[0].by, "revert the state sharing") != null);
}

test "scan resolves git revert's body footer and quoted subject tag" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const raw = try fakeLog(arena, &.{
        .{
            .sha = "1111111000000000000000000000000000000000",
            .subject = "Revert \"clanker: cache the registry [imp-444]\"",
            .body = "This reverts commit 2222222000000000000000000000000000000000.",
        },
        .{ .sha = "2222222000000000000000000000000000000000", .subject = "clanker: cache the registry [imp-444]", .body = "" },
    });
    const found = try scan(arena, raw);
    // The quoted tag and the resolved sha name the same improvement: one entry.
    try std.testing.expectEqual(@as(usize, 1), found.len);
    try std.testing.expectEqualStrings("imp-444", found[0].id);
}

test "scan ignores unresolvable shas, non-imp reverts, and plain commits" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const raw = try fakeLog(arena, &.{
        // References a sha that never reached this clone.
        .{ .sha = "3333333000000000000000000000000000000000", .subject = "worktree: revert the check (revert of deadbee)", .body = "" },
        // Reverts ordinary human work: no imp tag to resolve to.
        .{ .sha = "4444444000000000000000000000000000000000", .subject = "Revert \"fix the flag parsing\"", .body = "This reverts commit 5555555000000000000000000000000000000000." },
        .{ .sha = "5555555000000000000000000000000000000000", .subject = "fix the flag parsing", .body = "" },
        // An improvement nothing reverted.
        .{ .sha = "6666666000000000000000000000000000000000", .subject = "clanker: real work [imp-777]", .body = "" },
    });
    const found = try scan(arena, raw);
    try std.testing.expectEqual(@as(usize, 0), found.len);
}

test "improvementCommits keeps every instance of an id and skips reverts" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const raw = try fakeLog(arena, &.{
        .{ .sha = "1111111000000000000000000000000000000000", .subject = "worktree: revert the sharing (revert of 2222222)", .body = "" },
        .{ .sha = "2222222000000000000000000000000000000000", .subject = "clanker: share the state [imp-111]", .body = "" },
        .{ .sha = "3333333000000000000000000000000000000000", .subject = "clanker: share the state [imp-111]", .body = "" },
        .{ .sha = "4444444000000000000000000000000000000000", .subject = "fix the flag parsing", .body = "" },
    });
    const found = try improvementCommits(arena, raw);
    try std.testing.expectEqual(@as(usize, 2), found.len);
    try std.testing.expectEqualStrings("imp-111", found[0].id);
    try std.testing.expect(std.mem.startsWith(u8, found[0].sha, "2222222"));
    try std.testing.expect(std.mem.startsWith(u8, found[1].sha, "3333333"));
}

test "addedLines groups significant added lines per file and skips deletions" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const diff =
        "diff --git a/src/a.zig b/src/a.zig\n" ++
        "--- a/src/a.zig\n" ++
        "+++ b/src/a.zig\n" ++
        "@@ -10,0 +11,3 @@\n" ++
        "+    const pruned = try self.pruneStale(arena);\n" ++
        "+    }\n" ++
        "+    log.log(.info, \"pruned {d}\", .{pruned});\n" ++
        "diff --git a/src/gone.zig b/src/gone.zig\n" ++
        "--- a/src/gone.zig\n" ++
        "+++ /dev/null\n" ++
        "@@ -1,2 +0,0 @@\n" ++
        "-const removed = true;\n" ++
        "diff --git a/src/new.zig b/src/new.zig\n" ++
        "--- /dev/null\n" ++
        "+++ b/src/new.zig\n" ++
        "@@ -0,0 +1,1 @@\n" ++
        "+pub const fresh_file_marker = 1;\n";

    const adds = try addedLines(arena, diff);
    try std.testing.expectEqual(@as(usize, 2), adds.len);
    try std.testing.expectEqualStrings("src/a.zig", adds[0].path);
    // The lone `}` is below the significance floor; the two real lines
    // survive, trimmed of their indentation.
    try std.testing.expectEqual(@as(usize, 2), adds[0].lines.len);
    try std.testing.expectEqualStrings("const pruned = try self.pruneStale(arena);", adds[0].lines[0]);
    try std.testing.expectEqualStrings("src/new.zig", adds[1].path);
    try std.testing.expectEqual(@as(usize, 1), adds[1].lines.len);
}

const FakeTree = struct {
    entries: []const struct { path: []const u8, content: []const u8 },
    pub fn read(self: @This(), path: []const u8) ?[]const u8 {
        for (self.entries) |e| {
            if (std.mem.eql(u8, e.path, path)) return e.content;
        }
        return null;
    }
};

test "presence: all lines gone is gone, one survivor is present, thin diffs are inconclusive" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const adds = try addedLines(arena, "+++ b/src/a.zig\n" ++
        "+    const pruned = try self.pruneStale(arena);\n" ++
        "+    try linkSharedState(arena, dir);\n" ++
        "+    defer guard.release();\n");

    // The file exists but none of the added lines are in it: reverted.
    try std.testing.expectEqual(Presence.gone, presence(adds, FakeTree{ .entries = &.{
        .{ .path = "src/a.zig", .content = "const std = @import(\"std\");\n" },
    } }));
    // The file itself is gone: so are its lines.
    try std.testing.expectEqual(Presence.gone, presence(adds, FakeTree{ .entries = &.{} }));
    // One line survives, re-indented: the work is still in the tree.
    try std.testing.expectEqual(Presence.present, presence(adds, FakeTree{ .entries = &.{
        .{ .path = "src/a.zig", .content = "fn f() void {\n        try linkSharedState(arena, dir);\n}\n" },
    } }));

    // Two significant lines is below the signal floor: no verdict.
    const thin = try addedLines(arena, "+++ b/src/a.zig\n" ++
        "+    const pruned = try self.pruneStale(arena);\n" ++
        "+    try linkSharedState(arena, dir);\n");
    try std.testing.expectEqual(Presence.inconclusive, presence(thin, FakeTree{ .entries = &.{} }));
}

test "distinctiveAdds drops lines the parent file already had and keeps new files whole" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const adds = try addedLines(arena, "+++ b/src/a.zig\n" ++
        "+    var hits: usize = 0;\n" ++
        "+    if (containsToken(prev_toks, t)) hits += 1;\n" ++
        "+++ b/src/new.zig\n" ++
        "+    var hits: usize = 0;\n");

    const distinct = try distinctiveAdds(arena, adds, FakeTree{
        .entries = &.{
            // The parent already had the boilerplate counter; only the real
            // logic line is evidence the commit's work survives.
            .{ .path = "src/a.zig", .content = "fn tried() bool {\n    var hits: usize = 0;\n}\n" },
            // src/new.zig has no parent: every line stays.
        },
    });
    try std.testing.expectEqual(@as(usize, 2), distinct.len);
    try std.testing.expectEqual(@as(usize, 1), distinct[0].lines.len);
    try std.testing.expectEqualStrings("if (containsToken(prev_toks, t)) hits += 1;", distinct[0].lines[0]);
    try std.testing.expectEqualStrings("src/new.zig", distinct[1].path);
    try std.testing.expectEqual(@as(usize, 1), distinct[1].lines.len);

    // A commit whose additions were all boilerplate filters down to
    // nothing, which `presence` then refuses to judge.
    const all_old = try distinctiveAdds(arena, adds[0..1], FakeTree{ .entries = &.{
        .{ .path = "src/a.zig", .content = "var hits: usize = 0;\nif (containsToken(prev_toks, t)) hits += 1;\n" },
    } });
    try std.testing.expectEqual(@as(usize, 0), all_old.len);
    try std.testing.expectEqual(Presence.inconclusive, presence(all_old, FakeTree{ .entries = &.{} }));
}

test "scan does not read a revert-of-a-revert as the improvement it un-undid" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const raw = try fakeLog(arena, &.{
        // Un-reverts the revert below; its referenced sha resolves to a
        // commit that is itself a revert, which must not be treated as an
        // improvement commit.
        .{ .sha = "7777777000000000000000000000000000000000", .subject = "Revert \"worktree: revert the sharing\"", .body = "This reverts commit 9999999000000000000000000000000000000000." },
        .{ .sha = "9999999000000000000000000000000000000000", .subject = "worktree: revert the sharing (revert of 8888888)", .body = "" },
        .{ .sha = "8888888000000000000000000000000000000000", .subject = "clanker: share the state [imp-888]", .body = "" },
    });
    const found = try scan(arena, raw);
    // The inner revert still names imp-888; the outer one names only the
    // revert commit and adds nothing.
    try std.testing.expectEqual(@as(usize, 1), found.len);
    try std.testing.expectEqualStrings("imp-888", found[0].id);
}
