//! Classic `*`/`?` glob matching, one implementation.
//!
//! The same match decides four unrelated things: which directory entries
//! `ck_fs_find` returns, which hostnames `network_allow` grants, which argv a
//! governed `ck_exec` may run, and which tools a preset allows. The `gh` and
//! `git` guests mirror the host's answer so their in-tool refusal message
//! matches the one the host would give. Four copies of one loop is four
//! chances to disagree, and they had: `src/preset/preset.zig` carried a
//! single-`*` prefix/suffix approximation that said `ab*bc` matched `abc`
//! (the prefix and suffix overlapped) and that `a*b*c` matched nothing.

const std = @import("std");
const fuzz_corpus = @import("fuzz_corpus.zig");

/// Longest pattern or name a fuzz iteration feeds the table walk, which keeps
/// its two rows on the stack.
const fuzz_max_len = 128;

/// Whether `name` matches `pattern`. `*` matches any run of characters
/// including none, `?` matches exactly one character other than '/', and
/// every other byte is literal and case-sensitive.
pub fn match(pattern: []const u8, name: []const u8) bool {
    var pattern_index: usize = 0;
    var name_index: usize = 0;
    var star_pattern_index: ?usize = null;
    var star_name_index: usize = 0;
    while (name_index < name.len or pattern_index < pattern.len) {
        if (pattern_index < pattern.len and pattern[pattern_index] == '*') {
            star_pattern_index = pattern_index;
            star_name_index = name_index;
            pattern_index += 1;
            continue;
        }
        if (name_index < name.len and pattern_index < pattern.len) {
            if (pattern[pattern_index] == '?' and name[name_index] != '/') {
                pattern_index += 1;
                name_index += 1;
                continue;
            }
            if (pattern[pattern_index] == name[name_index]) {
                pattern_index += 1;
                name_index += 1;
                continue;
            }
        }
        if (star_pattern_index) |star| {
            // Give the last `*` one more character and retry from just after
            // it. Bounded: star_name_index only grows and stops at name.len.
            pattern_index = star + 1;
            star_name_index += 1;
            if (star_name_index > name.len) return false;
            name_index = star_name_index;
            continue;
        }
        return false;
    }
    return true;
}

test "match handles basic patterns" {
    try std.testing.expect(match("foo.zig", "foo.zig"));
    try std.testing.expect(!match("foo.zig", "bar.zig"));

    try std.testing.expect(match("*.zig", "foo.zig"));
    try std.testing.expect(match("*.zig", ".zig"));
    try std.testing.expect(!match("*.zig", "foo.txt"));
    try std.testing.expect(match("foo.*", "foo.txt"));
    try std.testing.expect(match("foo.*", "foo."));
    try std.testing.expect(match("*", "anything"));
    try std.testing.expect(match("*", ""));

    try std.testing.expect(match("?.zig", "a.zig"));
    try std.testing.expect(!match("?.zig", "ab.zig"));
    try std.testing.expect(!match("?.zig", ".zig"));

    // `?` refuses to cross a directory separator while `*` may: a find/allow
    // pattern must not jump between path components through a `?`.
    try std.testing.expect(!match("?", "/"));
    try std.testing.expect(!match("a?c", "a/c"));
    try std.testing.expect(!match("??", "a/b"));
    try std.testing.expect(match("a*c", "a/c"));

    // Matching is case-sensitive.
    try std.testing.expect(!match("FOO.zig", "foo.zig"));
    try std.testing.expect(!match("*.ZIG", "foo.zig"));

    try std.testing.expect(match("test_*.zig", "test_foo.zig"));
    try std.testing.expect(!match("test_*.zig", "best_foo.zig"));

    try std.testing.expect(match("*foo*", "xfooy"));
    try std.testing.expect(match("*foo*", "foo"));
    try std.testing.expect(!match("*foo*", "bar"));

    try std.testing.expect(match("", ""));
    try std.testing.expect(!match("", "x"));
}

test "match does not let a prefix and a suffix overlap" {
    // The preset copy answered true here: it checked startsWith("ab") and
    // endsWith("bc") separately, so the single 'b' satisfied both.
    try std.testing.expect(!match("ab*bc", "abc"));
    try std.testing.expect(match("ab*bc", "abbc"));
    try std.testing.expect(match("ab*bc", "abxbc"));
}

test "match honors every star, not just the first" {
    // The preset copy treated everything after the first `*` as a literal
    // suffix, so a two-star pattern could never match.
    try std.testing.expect(match("a*b*c", "abc"));
    try std.testing.expect(match("a*b*c", "axxbyyc"));
    try std.testing.expect(!match("a*b*c", "acb"));
    try std.testing.expect(match("kanban_*_x*", "kanban_card_xyz"));
}

/// The documented semantics as a table walk, kept beside the greedy loop so
/// the two can be compared on every fuzz iteration.
///
/// Deliberately a different algorithm. A greedy matcher forgets a star it has
/// already passed; a row-at-a-time matcher cannot, because every `*` row also
/// reads the cell above it. Two implementations that fail in different ways
/// are what makes the comparison worth something: a hand-written case can only
/// pin the answers someone already found, and the two copies this module
/// replaced disagreed on `ab*bc` and `a*b*c` for exactly that reason.
fn referenceMatch(pattern: []const u8, name: []const u8) bool {
    // `row[j]` is "pattern[0..i] matches name[0..j]". The empty pattern
    // matches the empty name and nothing else, which is row zero.
    var row: [fuzz_max_len + 1]bool = [_]bool{false} ** (fuzz_max_len + 1);
    var next_row: [fuzz_max_len + 1]bool = undefined;
    row[0] = true;

    for (pattern) |p| {
        // Column zero against one pattern byte: a star stands for the empty
        // run, a `?` cannot stand for nothing, a literal must be the byte
        // that is not there.
        const literal = p != '*' and p != '?' and name.len > 0 and p == name[0];
        next_row[0] = row[0] and (p == '*' or literal);
        for (name, 0..) |n, j| {
            next_row[j + 1] = if (p == '*')
                // Either this star covers nothing (the cell above) or it eats
                // one more character (the cell to the left).
                row[j + 1] or next_row[j]
            else if (p == '?')
                (n != '/') and row[j]
            else
                (p == n) and row[j];
        }
        @memcpy(row[0 .. name.len + 1], next_row[0 .. name.len + 1]);
    }
    return row[name.len];
}

/// Corpus entries as a pattern, a NUL, and the name it is checked against:
/// the pairs these callers actually ask about (an exec verb against its
/// argv, a preset glob against a tool name, a host pattern against a peer).
const match_fuzz_corpus = [_][]const u8{
    fuzz_corpus.entry(""),
    fuzz_corpus.entry("*\x00src/main.zig"),
    fuzz_corpus.entry("git status*\x00git status --short"),
    fuzz_corpus.entry("?\x00/"),
    fuzz_corpus.entry("*.zig\x00"),
    fuzz_corpus.entry("a*b*c\x00abc"),
    fuzz_corpus.entry("ab*bc\x00abc"),
    fuzz_corpus.entry("*a*a*a*\x00aaaaaaaaaaaaaaaaaaaa"),
    fuzz_corpus.entry("kanban_*\x00kanban_card_1"),
    fuzz_corpus.entry("*\x00**"),
};

test "fuzz: the greedy star matcher agrees with the table walk" {
    // One harness, one loop, no crash-only assertion. A refusal here is a
    // capability answer: `exec_pattern_allow` says which argv a governed
    // `ck_exec` may run, `network_allow` which host a guest may reach, a
    // preset which tools load, and `ck_fs_find` which paths come back. The
    // blast radius of a wrong answer there is a command that ran, not a
    // garbled transcript, and the two copies of this loop that disagreed
    // before shared no test to catch it.
    const Ctx = struct {
        fn one(_: void, smith: *std.testing.Smith) anyerror!void {
            var buf: [fuzz_max_len]u8 = undefined;
            const input = buf[0..smith.slice(&buf)];
            // The corpus spells its two halves; a mutation-driven entry has
            // no NUL, and half a pattern against half a name still drives
            // both loops.
            const split = std.mem.indexOfScalar(u8, input, 0) orelse input.len / 2;
            const pattern = input[0..split];
            const name = if (split < input.len) input[split + 1 ..] else input[split..];

            try std.testing.expectEqual(referenceMatch(pattern, name), match(pattern, name));
        }
    };
    try std.testing.fuzz({}, Ctx.one, .{ .corpus = &match_fuzz_corpus });
}
