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
