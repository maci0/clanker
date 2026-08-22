//! Pure filename arithmetic behind the record stores' `rename` action.
//!
//! A rename asks two things of a path: what the new filename is, and what the
//! old stem was, so inbound references to it can be reported. Both are string
//! work with no host call in them, so they live here where `zig build test`
//! runs them -- a WASM guest has no test runner, and the guest half of the
//! rename (`records_grep.renameRecord`) is nothing but host calls around this.
//!
//! # The number is not renamable
//!
//! Three of the five stores number their records (`docs/rfcs/0022-...`,
//! `docs/adrs/0048-...`, `docs/prds/0021-...`) and two do not
//! (`docs/research/`, `docs/reports/`). For the numbered ones the slug is a
//! name and the number is an identity, and only the name may move:
//!
//!  - Records are cited by *number in prose* -- "ADR 0012", "PRD 0021",
//!    "RFC 0001" appear throughout `CLAUDE.md`, `AGENTS.md` and source
//!    comments. A rename reports leftover references by grepping its own
//!    store for the old filename stem, which cannot see those citations at
//!    all. Moving the number would break references the tool is structurally
//!    unable to even list, which is the one failure mode `rename` exists to
//!    prevent.
//!  - The number is written three times per record: the filename, the `#`
//!    title line inside the document, and the inventory link *text* in the
//!    store's README (`- [ADR 0048 -- ...](0048-....md)`). Keeping it means a
//!    rename rewrites exactly one copy of the name and leaves the other two
//!    correct; moving it would mean rewriting all three plus every citation.
//!  - An ADR is never reversed by editing: `status ... superseded` links
//!    forward and names what replaced it. That forward link is only as stable
//!    as the number it names.
//!
//! So a caller passes the new *name*; `plan` re-attaches the record's own
//! number. That is the same shape as the `missing-clanker-tool-` marker in the
//! reports store, which `rename` re-applies from the old name rather than
//! trusting the caller to carry it. A slug carrying a *different* number is
//! refused by name rather than silently ignored, because a caller who typed
//! one meant to renumber and needs to be told that is not a thing.
//!
//! `numberPrefix` is deliberately not `doc_scaffold.leadingNumber`: that one
//! answers "is this a document number" and returns a `u32`, guarding against
//! a dated report slug. This one returns the digits *as written*, because the
//! zero padding is part of the filename and must be reproduced byte for byte.
//! Each `host_tested_helpers` entry is built as its own module with only the
//! `utf8` import, so this file stays on `std` alone.

const std = @import("std");

pub const Error = error{
    /// The path does not end in `.md`, or is nothing but the suffix.
    NotAMarkdownPath,
    /// The path has no directory component, so the store cannot be named.
    NoDirectory,
    /// A numbered store's record whose filename carries no `NNNN-` prefix.
    NumberMissing,
    /// The new slug carries a number, and it is not the record's own.
    NumberNotRenamable,
    /// The new name is the name the record already has.
    SameName,
};

pub const Plan = struct {
    /// The directory the record stays in. A rename never changes stores.
    dir: []const u8,
    /// The old filename without `.md` -- what a reference scan greps for.
    old_stem: []const u8,
    /// The new filename without `.md`.
    new_stem: []const u8,
    /// The full new path, `dir ++ "/" ++ new_stem ++ ".md"`.
    new_path: []const u8,
};

/// The leading `NNNN-` of a filename stem, digits only and without the
/// hyphen, or null when the stem does not start with one. Between one and six
/// digits, so a caller-supplied `12-foo` is recognised as a numbered slug and
/// refused rather than being pasted on after the real number.
pub fn numberPrefix(stem: []const u8) ?[]const u8 {
    var digits: usize = 0;
    while (digits < stem.len and std.ascii.isDigit(stem[digits])) digits += 1;
    if (digits == 0 or digits > 6) return null;
    if (digits >= stem.len or stem[digits] != '-') return null;
    return stem[0..digits];
}

/// Where `path` moves when it is renamed to `slug`. `numbered` says whether
/// the store keeps an `NNNN-` prefix; see the file comment for why that
/// prefix is preserved rather than renamed.
///
/// The slug's alphabet is not checked here: every store already validates it
/// with `doc_scaffold.isSlug` before it gets this far, and duplicating that
/// table is how the two spellings drift apart.
pub fn plan(
    alloc: std.mem.Allocator,
    path: []const u8,
    slug: []const u8,
    numbered: bool,
) (Error || std.mem.Allocator.Error)!Plan {
    const dir_end = std.mem.lastIndexOfScalar(u8, path, '/') orelse return Error.NoDirectory;
    const dir = path[0..dir_end];
    const name = path[dir_end + 1 ..];
    if (name.len <= ".md".len or !std.mem.endsWith(u8, name, ".md")) return Error.NotAMarkdownPath;
    const old_stem = name[0 .. name.len - ".md".len];

    // Always owned by `alloc`, numbered or not, so a caller frees one thing
    // either way rather than keeping track of which branch borrowed.
    var new_stem: []const u8 = try alloc.dupe(u8, slug);
    if (numbered) {
        errdefer alloc.free(new_stem);
        const own = numberPrefix(old_stem) orelse return Error.NumberMissing;
        var tail = slug;
        if (numberPrefix(slug)) |given| {
            // The operator copied the whole stem, which is the natural thing
            // to do. Their number has to be the record's own.
            if (!std.mem.eql(u8, given, own)) return Error.NumberNotRenamable;
            tail = slug[given.len + 1 ..];
        } else if (isAllDigits(slug)) {
            // `rfc rename <path> 0031` reads as "make this RFC 0031", not as
            // "call it 0031-0031".
            return Error.NumberNotRenamable;
        }
        const joined = try std.fmt.allocPrint(alloc, "{s}-{s}", .{ own, tail });
        alloc.free(new_stem);
        new_stem = joined;
    }
    errdefer alloc.free(new_stem);
    if (std.mem.eql(u8, new_stem, old_stem)) return Error.SameName;

    return .{
        .dir = dir,
        .old_stem = old_stem,
        .new_stem = new_stem,
        .new_path = try std.fmt.allocPrint(alloc, "{s}/{s}.md", .{ dir, new_stem }),
    };
}

fn isAllDigits(s: []const u8) bool {
    if (s.len == 0) return false;
    for (s) |c| {
        if (!std.ascii.isDigit(c)) return false;
    }
    return true;
}

/// Why a rename was refused, as the sentence the operator reads. Kept beside
/// the errors so a new refusal cannot ship without its explanation.
pub fn reason(err: Error) []const u8 {
    return switch (err) {
        Error.NotAMarkdownPath => "path must name a markdown record",
        Error.NoDirectory => "path has no directory",
        Error.NumberMissing => "that record's filename carries no NNNN- number, so a rename has nothing to keep it under",
        Error.NumberNotRenamable => "the record's number is its identity and is not renamable: pass the new name without a number, or with the number the record already has. Records are cited by number across the tree and a filename scan cannot find those citations, so a renumber would break references this tool could not even list.",
        Error.SameName => "the record already has that name",
    };
}

const testing = std.testing;

test "flat store rename takes the slug as the whole stem" {
    const p = try plan(testing.allocator, "docs/research/free-llm-endpoints.md", "free-endpoints", false);
    defer testing.allocator.free(p.new_stem);
    defer testing.allocator.free(p.new_path);
    try testing.expectEqualStrings("docs/research", p.dir);
    try testing.expectEqualStrings("free-llm-endpoints", p.old_stem);
    try testing.expectEqualStrings("free-endpoints", p.new_stem);
    try testing.expectEqualStrings("docs/research/free-endpoints.md", p.new_path);
}

test "numbered store keeps the record's own number" {
    const p = try plan(testing.allocator, "docs/adrs/0048-preparing-a-worktree.md", "worktree-prepare-is-a-verb", true);
    defer testing.allocator.free(p.new_stem);
    defer testing.allocator.free(p.new_path);
    try testing.expectEqualStrings("0048-preparing-a-worktree", p.old_stem);
    try testing.expectEqualStrings("0048-worktree-prepare-is-a-verb", p.new_stem);
    try testing.expectEqualStrings("docs/adrs/0048-worktree-prepare-is-a-verb.md", p.new_path);
}

test "numbered store accepts the record's own number written out" {
    const p = try plan(testing.allocator, "docs/rfcs/0022-http-client.md", "0022-http-client-for-the-proxy", true);
    defer testing.allocator.free(p.new_stem);
    defer testing.allocator.free(p.new_path);
    try testing.expectEqualStrings("0022-http-client-for-the-proxy", p.new_stem);
}

test "numbered store refuses a different number" {
    try testing.expectError(
        Error.NumberNotRenamable,
        plan(testing.allocator, "docs/rfcs/0022-http-client.md", "0031-http-client", true),
    );
}

test "numbered store refuses a bare number as the new name" {
    try testing.expectError(
        Error.NumberNotRenamable,
        plan(testing.allocator, "docs/prds/0021-smart-commit.md", "0031", true),
    );
}

test "a number's zero padding is reproduced as written" {
    const p = try plan(testing.allocator, "docs/prds/0007-memory.md", "memory-layer", true);
    defer testing.allocator.free(p.new_stem);
    defer testing.allocator.free(p.new_path);
    try testing.expectEqualStrings("0007-memory-layer", p.new_stem);
}

test "renaming a record to its own name is refused" {
    try testing.expectError(
        Error.SameName,
        plan(testing.allocator, "docs/research/jcode-features.md", "jcode-features", false),
    );
    try testing.expectError(
        Error.SameName,
        plan(testing.allocator, "docs/adrs/0001-board-is-a-chatroom.md", "board-is-a-chatroom", true),
    );
}

test "a numbered record with no number is refused rather than renumbered" {
    try testing.expectError(
        Error.NumberMissing,
        plan(testing.allocator, "docs/adrs/TEMPLATE.md", "template", true),
    );
}

test "a path that is not markdown is refused" {
    try testing.expectError(
        Error.NotAMarkdownPath,
        plan(testing.allocator, "docs/research/notes.txt", "notes", false),
    );
    try testing.expectError(
        Error.NotAMarkdownPath,
        plan(testing.allocator, "docs/research/.md", "notes", false),
    );
    try testing.expectError(
        Error.NoDirectory,
        plan(testing.allocator, "notes.md", "other", false),
    );
}

test "numberPrefix reads the digits as written and needs a hyphen" {
    try testing.expectEqualStrings("0048", numberPrefix("0048-a-name").?);
    try testing.expectEqualStrings("7", numberPrefix("7-a-name").?);
    try testing.expect(numberPrefix("no-number") == null);
    try testing.expect(numberPrefix("0048") == null);
    try testing.expect(numberPrefix("1234567-too-many") == null);
}
