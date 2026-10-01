//! Pure grouping / validation / topo-sort for `smart_commit`.

const std = @import("std");
const utf8 = @import("utf8");

pub const types = [_][]const u8{
    "feat", "fix", "docs", "style", "refactor", "perf", "test", "build", "ci", "chore", "revert",
};

/// One proposed commit, in the shape the `smart_commit` guest emits.
pub const Commit = struct {
    message: []const u8 = "",
    files: []const []const u8 = &.{},
};

/// A whole `smart_commit` answer. `message` is the top-level one `writeEmpty`
/// uses ("nothing to commit"); the per-commit messages live on `commits`.
pub const Plan = struct {
    dry_run: bool = false,
    /// Why the grouping deviated, when it did (a degenerate dependency cycle
    /// collapses every group into one commit).
    note: []const u8 = "",
    /// Paths the guest refused to stage, lock files above all. A reader who
    /// does not see them here will assume they were committed.
    excluded: []const []const u8 = &.{},
    commits: []const Commit = &.{},
    message: []const u8 = "",
};

/// Renders a plan for a terminal.
///
/// The guest answers structured JSON and this is the one place that turns it
/// into prose, so `clanker commit` and any other surface show the same thing.
/// It lives here rather than in the guest because a rendered `text` field
/// would force every consumer -- the web UI, the model -- to parse prose back
/// out of a reply that was already structured.
///
/// The dry-run and applied wordings are deliberately different: the defect
/// this replaces printed a proposal, asked for confirmation, and then reported
/// success without writing anything.
pub fn renderPlan(alloc: std.mem.Allocator, plan: Plan) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;

    if (plan.commits.len == 0) {
        const why = if (plan.message.len > 0) plan.message else "nothing to commit";
        try out.print(alloc, "{s}\n", .{why});
        try appendExcluded(alloc, &out, plan.excluded);
        return out.toOwnedSlice(alloc);
    }

    try out.print(alloc, "{s} {d} commit(s):\n\n", .{
        if (plan.dry_run) "would write" else "committed",
        plan.commits.len,
    });
    for (plan.commits) |c| {
        try out.print(alloc, "  {s}\n", .{c.message});
        for (c.files) |f| try out.print(alloc, "      {s}\n", .{f});
        try out.appendSlice(alloc, "\n");
    }
    try appendExcluded(alloc, &out, plan.excluded);
    if (plan.note.len > 0) try out.print(alloc, "note: {s}\n", .{plan.note});
    return out.toOwnedSlice(alloc);
}

fn appendExcluded(alloc: std.mem.Allocator, out: *std.ArrayList(u8), excluded: []const []const u8) !void {
    if (excluded.len == 0) return;
    try out.appendSlice(alloc, "excluded:\n");
    for (excluded) |f| try out.print(alloc, "  {s}\n", .{f});
}

/// Unions newline-separated git listings into one file list.
///
/// Scope "all" of `smart_commit` reads more than one git listing (worktree
/// diff, staged diff, untracked files); a path can arrive from two of them
/// when it is staged and then modified again, and it must appear once or it
/// would be grouped, shown, and committed twice. Lock files go to `excluded`
/// so the preview can name what was left out rather than dropping it silently.
pub fn collectFiles(
    alloc: std.mem.Allocator,
    listings: []const []const u8,
    files: *std.ArrayList([]const u8),
    excluded: *std.ArrayList([]const u8),
) !void {
    for (listings) |listing| {
        var it = std.mem.splitScalar(u8, std.mem.trim(u8, listing, " \t\r\n"), '\n');
        while (it.next()) |line| {
            if (line.len == 0) continue;
            const dest: *std.ArrayList([]const u8) = if (isLockFile(line)) excluded else files;
            var seen = false;
            for (dest.items) |f| {
                if (std.mem.eql(u8, f, line)) {
                    seen = true;
                    break;
                }
            }
            if (!seen) try dest.append(alloc, line);
        }
    }
}

pub fn isLockFile(path: []const u8) bool {
    if (std.mem.endsWith(u8, path, ".lock")) return true;
    const base = std.fs.path.basename(path);
    return std.mem.eql(u8, base, "package-lock.json") or
        std.mem.eql(u8, base, "yarn.lock") or
        std.mem.eql(u8, base, "Cargo.lock") or
        std.mem.eql(u8, base, "go.sum") or
        std.mem.eql(u8, base, "zig.lock");
}

pub fn validMessage(msg: []const u8) bool {
    for (types) |t| {
        if (!std.mem.startsWith(u8, msg, t)) continue;
        var rest = msg[t.len..];
        if (rest.len > 0 and rest[0] == '(') {
            const close = std.mem.findScalar(u8, rest, ')') orelse return false;
            rest = rest[close + 1 ..];
        }
        if (rest.len < 3 or rest[0] != ':' or rest[1] != ' ') return false;
        return rest[2] != ' ';
    }
    return false;
}

pub fn isTestPath(path: []const u8) bool {
    return std.mem.find(u8, path, "test_") != null or
        std.mem.find(u8, path, "_test.") != null or
        std.mem.find(u8, path, ".test.") != null or
        std.mem.find(u8, path, "tests/") != null;
}

pub fn isDocPath(path: []const u8) bool {
    return std.mem.endsWith(u8, path, ".md") or std.mem.startsWith(u8, path, "docs/");
}

pub fn isConfigPath(path: []const u8) bool {
    const base = std.fs.path.basename(path);
    return std.mem.eql(u8, base, "config.toml") or
        std.mem.endsWith(u8, path, ".toml") or
        std.mem.endsWith(u8, path, ".yaml") or
        (std.mem.endsWith(u8, path, ".json") and std.mem.findScalar(u8, path, '/') == null);
}

pub fn fileRank(path: []const u8) u8 {
    if (isTestPath(path)) return 1;
    if (isDocPath(path)) return 2;
    if (isConfigPath(path)) return 3;
    return 0;
}

pub fn sortFiles(files: [][]const u8) void {
    std.mem.sort([]const u8, files, {}, struct {
        fn less(_: void, a: []const u8, b: []const u8) bool {
            const ra = fileRank(a);
            const rb = fileRank(b);
            if (ra != rb) return ra < rb;
            return std.mem.lessThan(u8, a, b);
        }
    }.less);
}

pub const Group = struct {
    message: []const u8,
    files: []const []const u8,
};

/// Longest commit message accepted from the grouping model. A conventional
/// commit is a one-line subject, so this is generous rather than tight; the
/// point is that a model cannot write a novel into a commit subject.
pub const max_message_bytes: usize = 400;

/// Make a model-proposed commit message safe to hand to `git commit -m`.
///
/// The message is the one field of the grouping answer that reaches git
/// history verbatim, and it is the one field no schema constrains. Two classes
/// of model output have to be refused rather than forwarded:
/// control bytes (a newline turns the subject into an arbitrary multi-paragraph
/// body; a NUL truncates the argv element, silently committing a different
/// message than the one shown in the dry run), and unbounded length.
///
/// Returns a single line of at most `max_message_bytes`, or null when the
/// input carries nothing usable (empty, or control bytes only). Callers that
/// must produce a commit fall back to `messageOrDefault`.
pub fn sanitizeMessage(alloc: std.mem.Allocator, raw: []const u8) !?[]const u8 {
    var line: std.ArrayList(u8) = .empty;
    // `collapsed` makes runs of whitespace (including newlines) read as one
    // space, so a message that wrapped across lines is still one subject.
    var collapsed = false;
    for (raw) |c| {
        // Every kind of whitespace folds into the same single separator, and
        // a run at the very start folds into nothing, so a message that
        // wrapped or was indented still reads as one subject.
        if (c <= 0x20 or c == 0x7f) {
            if (!std.ascii.isWhitespace(c)) return null; // a control byte that is not whitespace
            if (line.items.len > 0) collapsed = true;
            continue;
        }
        if (collapsed) try line.append(alloc, ' ');
        collapsed = false;
        try line.append(alloc, c);
    }
    if (line.items.len == 0) return null;
    // Cap on a codepoint boundary, not a byte. A raw byte cut through a
    // multi-byte character yields a shorter string that is not a string: it is
    // invalid UTF-8, and this value becomes a commit subject, so those bytes
    // land in `git commit -m` argv and in history, where a later amend can
    // rewrite the wording but not the invalid bytes underneath it. `utf8.cap`
    // is the helper the repo already uses for this, and it leaves the ASCII
    // case exact: there is no codepoint boundary to snap back to.
    if (line.items.len > max_message_bytes) line.shrinkRetainingCapacity(utf8.cap(line.items, max_message_bytes).len);
    const trimmed = std.mem.trimEnd(u8, line.items, " ");
    if (trimmed.len == 0) return null;
    return try alloc.dupe(u8, trimmed);
}

/// A deterministic conventional-commit subject for a group whose proposed
/// message did not survive `sanitizeMessage`. Losing the model's wording costs
/// nothing worth failing the commit over; a group with no message at all would
/// hand git an empty subject.
pub fn messageOrDefault(alloc: std.mem.Allocator, files: []const []const u8) ![]const u8 {
    if (files.len == 0) return "chore: update staged files";
    const subject = std.mem.trim(u8, files[0], "/");
    return std.fmt.allocPrint(alloc, "chore: update {s}", .{subject});
}

pub const OrderError = error{ PartialCycle, DegenerateCycle, OutOfMemory };

/// Kahn topo sort. `deps[i]` lists group indices that must come before i.
pub fn topoSort(arena: std.mem.Allocator, n: usize, deps: []const []const usize) OrderError![]usize {
    var indeg = try arena.alloc(usize, n);
    @memset(indeg, 0);
    for (deps) |ds| {
        for (ds) |_| {}
    }
    for (deps) |ds| for (ds) |_| {};
    for (0..n) |i| {
        for (deps[i]) |_| indeg[i] += 1;
    }
    var ready: std.ArrayList(usize) = .empty;
    for (indeg, 0..) |d, i| {
        if (d == 0) try ready.append(arena, i);
    }
    var out: std.ArrayList(usize) = .empty;
    while (ready.items.len > 0) {
        const i = ready.pop().?;
        try out.append(arena, i);
        for (0..n) |j| {
            for (deps[j]) |d| {
                if (d == i) {
                    indeg[j] -= 1;
                    if (indeg[j] == 0) try ready.append(arena, j);
                }
            }
        }
    }
    if (out.items.len == n) return out.toOwnedSlice(arena);
    if (out.items.len == 0) return error.DegenerateCycle;
    return error.PartialCycle;
}

pub fn references(src: []const u8, other_file: []const u8) bool {
    const base = std.fs.path.basename(other_file);
    const stem = if (std.mem.findScalarLast(u8, base, '.')) |dot| base[0..dot] else base;
    if (std.mem.find(u8, src, other_file) != null) return true;
    if (std.mem.find(u8, src, stem) != null and
        (std.mem.find(u8, src, "import") != null or
            std.mem.find(u8, src, "@import") != null or
            std.mem.find(u8, src, "require") != null or
            std.mem.find(u8, src, "#include") != null)) return true;
    return false;
}

test "lock files are excluded" {
    try std.testing.expect(isLockFile("foo.lock"));
    try std.testing.expect(isLockFile("go.sum"));
    try std.testing.expect(isLockFile("package-lock.json"));
    try std.testing.expect(!isLockFile("src/foo.zig"));
}

test "collectFiles unions listings, dedupes, and routes lock files to excluded" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // The scope-"all" shape: a tracked modification, a file staged and then
    // modified again (listed by both diffs), a staged-only new file, and an
    // untracked one.
    const worktree = "src/a.zig\nsrc/b.zig\n";
    const staged = "src/b.zig\nstaged-new.txt\n";
    const others = "untracked.txt\npackage-lock.json\n";
    var files: std.ArrayList([]const u8) = .empty;
    var excluded: std.ArrayList([]const u8) = .empty;
    try collectFiles(arena, &.{ worktree, staged, others }, &files, &excluded);

    try std.testing.expectEqual(@as(usize, 4), files.items.len);
    try std.testing.expectEqualStrings("src/a.zig", files.items[0]);
    try std.testing.expectEqualStrings("src/b.zig", files.items[1]);
    try std.testing.expectEqualStrings("staged-new.txt", files.items[2]);
    try std.testing.expectEqualStrings("untracked.txt", files.items[3]);
    try std.testing.expectEqual(@as(usize, 1), excluded.items.len);
    try std.testing.expectEqualStrings("package-lock.json", excluded.items[0]);
}

test "collectFiles accepts empty listings and empty input" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var files: std.ArrayList([]const u8) = .empty;
    var excluded: std.ArrayList([]const u8) = .empty;
    try collectFiles(arena, &.{ "", "\n" }, &files, &excluded);
    try std.testing.expectEqual(@as(usize, 0), files.items.len);
    try std.testing.expectEqual(@as(usize, 0), excluded.items.len);
}

test "conventional commit regex" {
    try std.testing.expect(validMessage("feat: add x"));
    try std.testing.expect(validMessage("fix(parser): handle empty"));
    try std.testing.expect(!validMessage("added a thing"));
    try std.testing.expect(!validMessage("feat:"));
}

test "source files rank before tests and docs" {
    var files = [_][]const u8{ "docs/a.md", "src/a.zig", "tests/a_test.zig" };
    sortFiles(&files);
    try std.testing.expectEqualStrings("src/a.zig", files[0]);
    try std.testing.expectEqualStrings("tests/a_test.zig", files[1]);
    try std.testing.expectEqualStrings("docs/a.md", files[2]);
}

test "topo sort orders a dependency first" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var d0 = [_]usize{};
    var d1 = [_]usize{0};
    const deps = [_][]const usize{ &d0, &d1 };
    const order = try topoSort(arena, 2, &deps);
    try std.testing.expectEqual(@as(usize, 0), order[0]);
    try std.testing.expectEqual(@as(usize, 1), order[1]);
}

test "partial cycle is an error" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var d0 = [_]usize{1};
    var d1 = [_]usize{0};
    var d2 = [_]usize{};
    const deps = [_][]const usize{ &d0, &d1, &d2 };
    try std.testing.expectError(error.PartialCycle, topoSort(arena_state.allocator(), 3, &deps));
}

test "all-groups cycle is degenerate" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var d0 = [_]usize{1};
    var d1 = [_]usize{0};
    const deps = [_][]const usize{ &d0, &d1 };
    try std.testing.expectError(error.DegenerateCycle, topoSort(arena_state.allocator(), 2, &deps));
}

test "renderPlan lists each proposed commit with its files" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const files_a = [_][]const u8{ "src/cli.zig", "src/main.zig" };
    const files_b = [_][]const u8{"docs/README.md"};
    const commits = [_]Commit{
        .{ .message = "fix(cli): stop double-wrapping structured tool input", .files = &files_a },
        .{ .message = "docs: record the commit contract", .files = &files_b },
    };
    const text = try renderPlan(arena, .{ .dry_run = true, .commits = &commits });

    // A proposal a person is about to approve has to show what it would do:
    // the message it would write and the files each commit would carry.
    try std.testing.expect(std.mem.find(u8, text, "fix(cli): stop double-wrapping structured tool input") != null);
    try std.testing.expect(std.mem.find(u8, text, "src/cli.zig") != null);
    try std.testing.expect(std.mem.find(u8, text, "docs/README.md") != null);
    try std.testing.expect(std.mem.endsWith(u8, text, "\n"));
}

test "renderPlan names the empty case rather than printing nothing" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // writeEmpty in the guest answers {ok, commits:[], message:"nothing to
    // commit"}: a top-level message, not a per-commit one, so the renderer
    // has to read both shapes or an empty staging area prints a blank line.
    const text = try renderPlan(arena, .{ .commits = &.{}, .message = "nothing to commit" });
    try std.testing.expect(std.mem.find(u8, text, "nothing to commit") != null);
}

test "renderPlan surfaces excluded files and the note" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const excluded = [_][]const u8{"zig-out/bin/clanker.lock"};
    const files = [_][]const u8{"src/a.zig"};
    const commits = [_]Commit{.{ .message = "chore: touch a", .files = &files }};
    const text = try renderPlan(arena, .{
        .dry_run = true,
        .commits = &commits,
        .excluded = &excluded,
        .note = "one group fell back to a single commit",
    });
    // Excluded paths are the ones a reader would otherwise assume were
    // committed, so they cannot be silently dropped from the preview.
    try std.testing.expect(std.mem.find(u8, text, "zig-out/bin/clanker.lock") != null);
    try std.testing.expect(std.mem.find(u8, text, "one group fell back to a single commit") != null);
}

test "renderPlan reports what was written once it is not a dry run" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const files = [_][]const u8{"src/a.zig"};
    const commits = [_]Commit{.{ .message = "chore: touch a", .files = &files }};
    const text = try renderPlan(arena, .{ .dry_run = false, .commits = &commits });
    // The applied wording must differ from the proposal wording: the whole
    // failure this renderer exists to fix was a verb that said it had done
    // something it had not.
    try std.testing.expect(std.mem.find(u8, text, "committed") != null);
}

test "sanitizeMessage reduces a model message to one bounded printable line" {
    const gpa = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    try std.testing.expectEqualStrings("fix: guard the cap", (try sanitizeMessage(arena, "  fix: guard the cap  ")).?);
    // A wrapped subject is one line, not a message with a body.
    try std.testing.expectEqualStrings("fix: guard the cap and the fence", (try sanitizeMessage(arena, "fix: guard the cap\nand the fence")).?);
    try std.testing.expectEqualStrings("fix: a b", (try sanitizeMessage(arena, "fix: a\n\n\n  b")).?);

    // No usable subject at all.
    try std.testing.expect((try sanitizeMessage(arena, "   ")) == null);
    try std.testing.expect((try sanitizeMessage(arena, "\n\n")) == null);
    // A control byte that is not whitespace has no one-line spelling, so the
    // message is refused rather than silently mangled into a different one.
    try std.testing.expect((try sanitizeMessage(arena, "fix: a\x00b")) == null);
    try std.testing.expect((try sanitizeMessage(arena, "fix: a\x07b")) == null);

    // A runaway subject is capped, and the cap lands on a whole byte.
    const huge = try arena.alloc(u8, max_message_bytes * 4);
    @memset(huge, 'x');
    const capped = (try sanitizeMessage(arena, huge)).?;
    try std.testing.expectEqual(max_message_bytes, capped.len);
    try std.testing.expect(std.ascii.isPrint(capped[capped.len - 1]));
}

test "the cap never cuts a multi-byte character in half" {
    const gpa = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // A subject one byte past the cap whose last character is wider than one
    // byte puts the cut inside that character. This is not a rendering
    // artifact: the result is a commit subject, so the broken bytes reach
    // `git commit -m` and history, where nothing downstream can fix them.
    for ([_][]const u8{ "\u{e9}", "\u{65e5}", "\u{1f680}" }) |wide| {
        var raw: std.ArrayList(u8) = .empty;
        defer raw.deinit(gpa);
        try raw.appendSlice(gpa, "fix: ");
        // Fill up to the point where this character straddles the cap, so the
        // cut lands inside it: half of its bytes are before the boundary.
        try raw.appendNTimes(gpa, 'x', max_message_bytes - "fix: ".len - wide.len / 2);
        try raw.appendSlice(gpa, wide);
        try raw.appendSlice(gpa, "tail");
        const out = (try sanitizeMessage(arena, raw.items)).?;
        try std.testing.expect(std.unicode.utf8ValidateSlice(out));
        try std.testing.expect(out.len <= max_message_bytes);
    }

    // A subject made entirely of wide characters needs the cap too, and the
    // cut must land between them rather than inside one.
    var wide_only: std.ArrayList(u8) = .empty;
    defer wide_only.deinit(gpa);
    for (0..max_message_bytes) |_| try wide_only.appendSlice(gpa, "\u{1f680}");
    const wide_out = (try sanitizeMessage(arena, wide_only.items)).?;
    try std.testing.expect(std.unicode.utf8ValidateSlice(wide_out));
    // Four bytes each, so the result holds a whole number of them.
    try std.testing.expectEqual(@as(usize, 0), wide_out.len % 4);
}

test "messageOrDefault names the group when the model message is unusable" {
    const gpa = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const files = [_][]const u8{"src/agent/loop.zig"};
    try std.testing.expectEqualStrings("chore: update src/agent/loop.zig", try messageOrDefault(arena, &files));
    try std.testing.expectEqualStrings("chore: update staged files", try messageOrDefault(arena, &.{}));
}
