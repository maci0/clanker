//! A scored improvement backlog read from the repository's own records.
//!
//! Until now the only idea sources the plan phase had were the operator's
//! free-text instruction and its own planning call, and the only bridge to
//! the repo's written-down backlog was a shell script sed-scraping ROADMAP
//! checkboxes into the instruction. The repo already records what needs
//! doing — open bug reports, PRD known issues and unchecked requirements,
//! planned ROADMAP items — in formats the record-store tools keep stable.
//! This module reads those at run time, scores them, and hands them to the
//! plan phase as ordinary ideas, so they pass the same tried/writable-target
//! dedup and the same context pinning as a model-proposed idea. The model's
//! planning call remains the fallback once the backlog runs dry.
//!
//! Scoring is deliberately a static ladder, not a learned weight: a reopened
//! report (a fix that did not hold) outranks an open one, reports outrank PRD
//! known issues, known issues outrank unchecked requirement boxes, and
//! ROADMAP wishes come last. Records being worked (`Investigating`) are
//! skipped rather than raced. Everything is read fresh from the tree on each
//! run — the set of open records changes under a long-lived checkout, so
//! nothing here may be cached or baked in at build time.

const std = @import("std");
const plan = @import("plan.zig");
const proposal = @import("proposal.zig");

/// Ceiling on how many backlog ideas one run may seed. A safety bound
/// against a pathological store, not a working set: skipping an
/// already-tried idea costs no model call, so the engine's own dedup — not
/// this cap — is what keeps the head fresh. Measured the day this landed
/// the store held 25 open reports; a tight cap here applied *before* that
/// dedup would have hidden everything below the cut line forever.
pub const default_cap: usize = 64;

/// Per-record read ceiling. Records are prose; the largest report in the
/// tree is well under 100 KiB, and anything bigger is not a record.
const record_read_cap: std.Io.Limit = .limited(1 << 20);

/// The lifecycle states the report store writes into a `## Status` section.
/// Only `open` and `reopened` seed work: `investigating` means someone is
/// already on it, and the rest record finished work.
const Status = enum { open, reopened, investigating, other };

const Scored = struct {
    idea: plan.Idea,
    score: u32,
};

/// Collect backlog ideas from the tree rooted at `base`, best first.
/// Missing directories and unreadable files contribute nothing rather than
/// failing the scan: a worktree without docs/reports/ simply has no report
/// backlog. Only allocation failure propagates.
pub fn collect(
    arena: std.mem.Allocator,
    io: std.Io,
    base: std.Io.Dir,
    cap: usize,
    max_files: usize,
) ![]const plan.Idea {
    var items: std.ArrayList(Scored) = .empty;
    try scanReports(arena, io, base, "docs/reports/bugs", 100, max_files, &items);
    try scanReports(arena, io, base, "docs/reports/investigations", 90, max_files, &items);
    try scanPrds(arena, io, base, max_files, &items);
    try scanRoadmap(arena, io, base, max_files, &items);

    // Stable, so two items from one file keep that file's own order.
    std.sort.insertion(Scored, items.items, {}, better);

    const n = @min(cap, items.items.len);
    const out = try arena.alloc(plan.Idea, n);
    for (out, items.items[0..n]) |*o, s| o.* = s.idea;
    return out;
}

/// Higher score first; ties go to the lexically later origin, which for the
/// date-slugged report files means the newer record.
fn better(_: void, a: Scored, b: Scored) bool {
    if (a.score != b.score) return a.score > b.score;
    const ao = a.idea.origin orelse "";
    const bo = b.idea.origin orelse "";
    return std.mem.order(u8, ao, bo) == .gt;
}

/// Every open or reopened record in one report directory becomes one idea.
fn scanReports(
    arena: std.mem.Allocator,
    io: std.Io,
    base: std.Io.Dir,
    dir_rel: []const u8,
    base_score: u32,
    max_files: usize,
    items: *std.ArrayList(Scored),
) !void {
    var dir = base.openDir(io, dir_rel, .{ .iterate = true }) catch return;
    defer dir.close(io);
    var it = dir.iterate();
    while (it.next(io) catch null) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.name, ".md")) continue;
        if (std.mem.eql(u8, entry.name, "README.md")) continue;
        // The blank record template carries a placeholder Status of
        // "Open / Resolved / Reopened.", which reads as open. Found live:
        // the very first seeded idea was "Resolve the open report
        // docs/reports/bugs/TEMPLATE.md".
        if (std.mem.eql(u8, entry.name, "TEMPLATE.md")) continue;
        const rel = try std.fmt.allocPrint(arena, "{s}/{s}", .{ dir_rel, entry.name });
        const data = base.readFileAlloc(io, rel, arena, record_read_cap) catch continue;
        const status = statusOf(data);
        const bonus: u32 = switch (status) {
            // A reopened report is evidence an earlier fix did not hold,
            // which is exactly the signal to weight up.
            .reopened => 10,
            .open => 0,
            .investigating, .other => continue,
        };
        const title = recordTitle(data) orelse continue;
        // A `<placeholder>` in the title marks an unfilled template whatever
        // the file is called; a real record's title never keeps the angle
        // brackets.
        if (std.mem.findScalar(u8, title, '<') != null) continue;
        const text = try std.fmt.allocPrint(arena, "Resolve the {s} report {s}: {s}", .{
            if (status == .reopened) "reopened" else "open",
            rel,
            title,
        });
        try items.append(arena, .{
            .idea = .{
                .text = text,
                .files = try pathHints(arena, io, base, data, max_files),
                .origin = rel,
            },
            .score = base_score + bonus,
        });
    }
}

/// PRD known-issue bullets (recorded defects) and unchecked requirement
/// boxes. A handful per document: a PRD with forty open boxes is a design in
/// progress, not forty backlog entries, and the head of each list is the
/// author's own priority order.
fn scanPrds(
    arena: std.mem.Allocator,
    io: std.Io,
    base: std.Io.Dir,
    max_files: usize,
    items: *std.ArrayList(Scored),
) !void {
    var dir = base.openDir(io, "docs/prds", .{ .iterate = true }) catch return;
    defer dir.close(io);
    var it = dir.iterate();
    while (it.next(io) catch null) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.name, ".md")) continue;
        if (std.mem.eql(u8, entry.name, "README.md")) continue;
        const rel = try std.fmt.allocPrint(arena, "docs/prds/{s}", .{entry.name});
        const data = base.readFileAlloc(io, rel, arena, record_read_cap) catch continue;

        var known_left: usize = 2;
        var boxes_left: usize = 2;
        var in_known = false;
        var lines = std.mem.splitScalar(u8, data, '\n');
        while (lines.next()) |raw| {
            const line = std.mem.trim(u8, raw, " \t\r");
            if (std.mem.startsWith(u8, line, "## ")) {
                in_known = std.ascii.startsWithIgnoreCase(line[3..], "known issues");
                continue;
            }
            if (uncheckedItem(line)) |text| {
                if (boxes_left == 0 or isGuardrail(text)) continue;
                boxes_left -= 1;
                try items.append(arena, .{
                    .idea = .{
                        .text = try std.fmt.allocPrint(arena, "Complete an unchecked item in {s}: {s}", .{ rel, text }),
                        .files = try pathHints(arena, io, base, text, max_files),
                        .origin = rel,
                    },
                    .score = 60,
                });
                continue;
            }
            if (in_known and std.mem.startsWith(u8, line, "- ")) {
                const text = std.mem.trim(u8, line[2..], " \t");
                if (known_left == 0 or text.len == 0 or isGuardrail(text)) continue;
                known_left -= 1;
                try items.append(arena, .{
                    .idea = .{
                        .text = try std.fmt.allocPrint(arena, "Fix a known issue recorded in {s}: {s}", .{ rel, text }),
                        .files = try pathHints(arena, io, base, text, max_files),
                        .origin = rel,
                    },
                    .score = 80,
                });
            }
        }
    }
}

/// Unchecked `- [ ]` ROADMAP items. Lowest score of any source: the roadmap
/// records wishes, not defects, and it is known to drift from the tree — an
/// item that names files but none that exist today is skipped outright,
/// because the framing text is what the model would act on.
fn scanRoadmap(
    arena: std.mem.Allocator,
    io: std.Io,
    base: std.Io.Dir,
    max_files: usize,
    items: *std.ArrayList(Scored),
) !void {
    const data = base.readFileAlloc(io, "docs/ROADMAP.md", arena, record_read_cap) catch return;
    var left: usize = 8;
    var lines = std.mem.splitScalar(u8, data, '\n');
    while (lines.next()) |raw| {
        if (left == 0) break;
        const line = std.mem.trim(u8, raw, " \t\r");
        const text = uncheckedItem(line) orelse continue;
        if (isGuardrail(text)) continue;
        const files = try pathHints(arena, io, base, text, max_files);
        if (files.len == 0 and mentionsPath(text)) continue;
        left -= 1;
        try items.append(arena, .{
            .idea = .{
                .text = try std.fmt.allocPrint(arena, "Implement the planned ROADMAP item: {s}", .{text}),
                .files = files,
                .origin = "docs/ROADMAP.md",
            },
            .score = 40,
        });
    }
}

/// The text of an unchecked checkbox line, or null.
fn uncheckedItem(trimmed_line: []const u8) ?[]const u8 {
    if (!std.mem.startsWith(u8, trimmed_line, "- [ ] ")) return null;
    const text = std.mem.trim(u8, trimmed_line["- [ ] ".len..], " \t");
    if (text.len == 0) return null;
    return text;
}

/// Checklist bullets that are constraints on how to do the work, not work:
/// "Do not put bytes in @todo" seeded as a task reads as an instruction to
/// do exactly that.
fn isGuardrail(text: []const u8) bool {
    return std.ascii.startsWithIgnoreCase(text, "do not ") or
        std.ascii.startsWithIgnoreCase(text, "don't ") or
        std.ascii.startsWithIgnoreCase(text, "never ");
}

/// The record's `## Status` verdict: the first word of the section's first
/// non-blank line. The store writes the state in two places (a TL;DR bullet
/// and this section); the section is the one `reports status` keeps
/// authoritative, so it is the only one read here.
fn statusOf(data: []const u8) Status {
    var in_status = false;
    var lines = std.mem.splitScalar(u8, data, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (std.mem.startsWith(u8, line, "## ")) {
            in_status = std.ascii.startsWithIgnoreCase(line[3..], "status");
            continue;
        }
        if (!in_status or line.len == 0) continue;
        var end: usize = 0;
        while (end < line.len and std.ascii.isAlphabetic(line[end])) end += 1;
        const word = line[0..end];
        if (std.ascii.eqlIgnoreCase(word, "open")) return .open;
        if (std.ascii.eqlIgnoreCase(word, "reopened")) return .reopened;
        if (std.ascii.eqlIgnoreCase(word, "investigating")) return .investigating;
        return .other;
    }
    return .other;
}

/// The record's `# ` title line, trimmed, or null for a file with none.
fn recordTitle(data: []const u8) ?[]const u8 {
    var lines = std.mem.splitScalar(u8, data, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0) continue;
        if (std.mem.startsWith(u8, line, "# ")) {
            const title = std.mem.trim(u8, line[2..], " \t");
            return if (title.len == 0) null else title;
        }
        return null;
    }
    return null;
}

/// A token stripped of the punctuation prose wraps around a path: quotes,
/// brackets, a trailing `:123` line reference, sentence punctuation.
fn normalizeToken(tok: []const u8) []const u8 {
    var t = tok;
    if (std.mem.findScalar(u8, t, ':')) |i| t = t[0..i];
    return std.mem.trimEnd(u8, t, ".,");
}

/// Repo-relative paths mentioned in `text` that are readable into an improve
/// prompt *and exist in this tree*. The existence check is what keeps a
/// drifted record from pinning a deleted file: `grant` would only report it
/// missing later, after the idea already spent its planning slot.
fn pathHints(
    arena: std.mem.Allocator,
    io: std.Io,
    base: std.Io.Dir,
    text: []const u8,
    max: usize,
) ![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    var it = std.mem.tokenizeAny(u8, text, " \t\r\n`\"'()[]{}<>,;*");
    while (it.next()) |raw_tok| {
        const tok = normalizeToken(raw_tok);
        if (tok.len == 0) continue;
        if (!proposal.validateReadPath(tok)) continue;
        var seen = false;
        for (out.items) |have| {
            if (std.mem.eql(u8, have, tok)) seen = true;
        }
        if (seen) continue;
        base.access(io, tok, .{}) catch continue;
        try out.append(arena, try arena.dupe(u8, tok));
        if (out.items.len >= max) break;
    }
    return try out.toOwnedSlice(arena);
}

/// Whether the text names anything path-shaped at all, existing or not —
/// the difference between "no files named" (fine, the patch call picks) and
/// "files named but none survive validation" (a drifted record).
fn mentionsPath(text: []const u8) bool {
    var it = std.mem.tokenizeAny(u8, text, " \t\r\n`\"'()[]{}<>,;*");
    while (it.next()) |raw_tok| {
        const tok = normalizeToken(raw_tok);
        if (std.mem.findScalar(u8, tok, '/') == null) continue;
        for (proposal.readable_extensions) |e| {
            if (std.mem.endsWith(u8, tok, e)) return true;
        }
    }
    return false;
}

// ------------------------------------------------------------------- tests --

const TestTree = struct {
    tmp: std.testing.TmpDir,

    fn put(self: *TestTree, io: std.Io, sub_path: []const u8, data: []const u8) !void {
        if (std.mem.findScalarLast(u8, sub_path, '/')) |i| {
            try self.tmp.dir.createDirPath(io, sub_path[0..i]);
        }
        try self.tmp.dir.writeFile(io, .{ .sub_path = sub_path, .data = data });
    }
};

test "collect orders reports over PRD items over ROADMAP, reopened first" {
    var gpa_state = std.heap.DebugAllocator(.{}).init;
    defer _ = gpa_state.deinit();
    const gpa = gpa_state.allocator();
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var tree = TestTree{ .tmp = std.testing.tmpDir(.{}) };
    defer tree.tmp.cleanup();

    try tree.put(io, "docs/reports/bugs/2026-08-01-older-open.md",
        \\# Bug — the older open defect
        \\
        \\## Status
        \\
        \\Open.
        \\
    );
    try tree.put(io, "docs/reports/bugs/2026-08-20-newer-open.md",
        \\# Bug — the newer open defect in src/main.zig
        \\
        \\## Status
        \\
        \\Open.
        \\
    );
    try tree.put(io, "docs/reports/bugs/2026-08-10-came-back.md",
        \\# Bug — the fix that did not hold
        \\
        \\## Status
        \\
        \\Reopened.
        \\
    );
    try tree.put(io, "docs/reports/bugs/2026-08-15-done.md",
        \\# Bug — already fixed
        \\
        \\## Status
        \\
        \\Resolved. Fixed in #999.
        \\
    );
    try tree.put(io, "docs/reports/bugs/2026-08-16-taken.md",
        \\# Bug — someone is on this one
        \\
        \\## Status
        \\
        \\Investigating.
        \\
    );
    try tree.put(io, "docs/reports/bugs/README.md", "# index, not a record\n");
    try tree.put(io, "docs/reports/bugs/TEMPLATE.md",
        \\# Bug — <short, user-visible failure>
        \\
        \\## Status
        \\
        \\Open / Resolved / Reopened. Link the investigation.
        \\
    );
    // The same placeholder shape under a non-template name must be skipped
    // off its unfilled title alone.
    try tree.put(io, "docs/reports/bugs/2026-08-21-copied-template.md",
        \\# Bug — <short, user-visible failure>
        \\
        \\## Status
        \\
        \\Open.
        \\
    );
    try tree.put(io, "docs/prds/0007-widget.md",
        \\# PRD 0007 — widget
        \\
        \\## Requirements
        \\
        \\- [x] shipped already
        \\- [ ] the first open requirement
        \\
        \\## Known issues
        \\
        \\- the recorded defect nobody filed as a report
        \\- Do not treat this guardrail as a task.
        \\
    );
    try tree.put(io, "docs/ROADMAP.md",
        \\## Planned
        \\
        \\- [x] done item
        \\- [ ] a planned feature with no file names
        \\
    );
    // src/main.zig must exist for the newer report's path hint to survive.
    try tree.put(io, "src/main.zig", "pub fn main() void {}\n");

    const ideas = try collect(arena, io, tree.tmp.dir, default_cap, 4);
    try std.testing.expectEqual(@as(usize, 6), ideas.len);
    // Reopened outranks open; among equal scores the newer slug wins.
    try std.testing.expect(std.mem.find(u8, ideas[0].text, "reopened report") != null);
    try std.testing.expect(std.mem.find(u8, ideas[0].text, "came-back") != null);
    try std.testing.expect(std.mem.find(u8, ideas[1].text, "newer-open") != null);
    try std.testing.expect(std.mem.find(u8, ideas[2].text, "older-open") != null);
    // Then the PRD known issue, the unchecked box, and the roadmap wish.
    try std.testing.expect(std.mem.find(u8, ideas[3].text, "known issue") != null);
    try std.testing.expect(std.mem.find(u8, ideas[4].text, "first open requirement") != null);
    try std.testing.expect(std.mem.find(u8, ideas[5].text, "ROADMAP item") != null);
    // The resolved, investigating, README, checked and guardrail entries
    // seeded nothing.
    for (ideas) |idea| {
        try std.testing.expect(std.mem.find(u8, idea.text, "already fixed") == null);
        try std.testing.expect(std.mem.find(u8, idea.text, "someone is on this") == null);
        try std.testing.expect(std.mem.find(u8, idea.text, "guardrail") == null);
        try std.testing.expect(std.mem.find(u8, idea.text, "shipped already") == null);
        try std.testing.expect(std.mem.find(u8, idea.text, "done item") == null);
    }
    // Every idea carries its record as origin.
    for (ideas) |idea| try std.testing.expect(idea.origin != null);
    // The path mentioned in the newer report's title survived as a hint.
    try std.testing.expectEqual(@as(usize, 1), ideas[1].files.len);
    try std.testing.expectEqualStrings("src/main.zig", ideas[1].files[0]);
}

test "collect caps the list and a bare tree yields nothing" {
    var gpa_state = std.heap.DebugAllocator(.{}).init;
    defer _ = gpa_state.deinit();
    const gpa = gpa_state.allocator();
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var tree = TestTree{ .tmp = std.testing.tmpDir(.{}) };
    defer tree.tmp.cleanup();

    try std.testing.expectEqual(@as(usize, 0), (try collect(arena, io, tree.tmp.dir, default_cap, 4)).len);

    var buf: [64]u8 = undefined;
    for (0..5) |i| {
        const name = try std.fmt.bufPrint(&buf, "docs/reports/bugs/2026-08-0{d}-b{d}.md", .{ i + 1, i });
        try tree.put(io, name,
            \\# Bug — one of many
            \\
            \\## Status
            \\
            \\Open.
            \\
        );
    }
    try std.testing.expectEqual(@as(usize, 3), (try collect(arena, io, tree.tmp.dir, 3, 4)).len);
}

test "roadmap items naming only dead files are skipped" {
    var gpa_state = std.heap.DebugAllocator(.{}).init;
    defer _ = gpa_state.deinit();
    const gpa = gpa_state.allocator();
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var tree = TestTree{ .tmp = std.testing.tmpDir(.{}) };
    defer tree.tmp.cleanup();

    try tree.put(io, "docs/ROADMAP.md",
        \\- [ ] wire `src/gone/forever.zig` into the loader
        \\- [ ] keep improving src/still/here.zig somehow
        \\- [ ] a wish with no files at all
        \\
    );
    try tree.put(io, "src/still/here.zig", "// present\n");

    const ideas = try collect(arena, io, tree.tmp.dir, default_cap, 4);
    try std.testing.expectEqual(@as(usize, 2), ideas.len);
    try std.testing.expect(std.mem.find(u8, ideas[0].text, "still/here") != null);
    try std.testing.expectEqualStrings("src/still/here.zig", ideas[0].files[0]);
    try std.testing.expect(std.mem.find(u8, ideas[1].text, "no files at all") != null);
    try std.testing.expectEqual(@as(usize, 0), ideas[1].files.len);
}

test "statusOf reads the section verdict, not the TL;DR" {
    const open_report =
        "# Bug — x\n\n## TL;DR\n\n- **Resolution:** Open.\n\n## Status\n\nOpen.\n";
    try std.testing.expectEqual(Status.open, statusOf(open_report));
    const resolved_report =
        "# Bug — x\n\n## TL;DR\n\n- **Resolution:** Open.\n\n## Status\n\nResolved (2026-08-24).\n";
    try std.testing.expectEqual(Status.other, statusOf(resolved_report));
    try std.testing.expectEqual(Status.reopened, statusOf("## Status\nReopened. Twice now.\n"));
    try std.testing.expectEqual(Status.investigating, statusOf("## Status\n\ninvestigating\n"));
    try std.testing.expectEqual(Status.other, statusOf("# Bug — no status section at all\n"));
}

test "path hints are validated, deduped, stripped of line refs" {
    var gpa_state = std.heap.DebugAllocator(.{}).init;
    defer _ = gpa_state.deinit();
    const gpa = gpa_state.allocator();
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var tree = TestTree{ .tmp = std.testing.tmpDir(.{}) };
    defer tree.tmp.cleanup();
    try tree.put(io, "src/cli.zig", "// x\n");
    try tree.put(io, "src/util/json.zig", "// x\n");

    const text =
        "`src/cli.zig:6480` calls into src/util/json.zig, and src/cli.zig again; " ++
        "see ../etc/passwd, state/secrets.toml, src/missing.zig and tools/x.wasm.";
    const hints = try pathHints(arena, io, tree.tmp.dir, text, 6);
    try std.testing.expectEqual(@as(usize, 2), hints.len);
    try std.testing.expectEqualStrings("src/cli.zig", hints[0]);
    try std.testing.expectEqualStrings("src/util/json.zig", hints[1]);
}
