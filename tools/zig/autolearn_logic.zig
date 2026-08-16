//! Pure helpers for the autolearn guest: observation tail, synthesis
//! prompts, and the ROADMAP section merge. Host-tested so the CLI and the
//! guest cannot drift on what a synthesized "## Autolearn" section replaces.

const std = @import("std");

/// Bound on the raw observation tail fed to the synthesizer. A long log
/// must not blow the prompt; only whole lines, so JSON fragments are never cut.
pub const max_observation_bytes: usize = 64 * 1024;

pub const system_prompt =
    \\You are the autolearn synthesizer for the clanker agent harness. You
    \\review raw usage observations from past runs and write an actionable
    \\"## Autolearn" section for docs/ROADMAP.md: a short intro sentence
    \\followed by a bullet list of concrete improvement items, each a
    \\`- [ ]` checkbox whose title captures the change and whose one-line
    \\body explains the observed reason. Ground every item in the
    \\observations; do not invent work. Return ONLY the markdown section,
    \\beginning with the "## Autolearn" heading.
;

/// The tail of `s` bounded to at most `max_bytes`, aligned to a line boundary
/// (a leading partial line is dropped so only whole lines are fed).
pub fn lastLines(s: []const u8, max_bytes: usize) []const u8 {
    if (s.len <= max_bytes) return s;
    const start = s.len - max_bytes;
    const first_nl = std.mem.find(u8, s[start..], "\n") orelse return s[start..];
    return s[start + first_nl + 1 ..];
}

pub fn userPrompt(alloc: std.mem.Allocator, observations: []const u8, mechanical: []const u8) ![]const u8 {
    return std.fmt.allocPrint(alloc,
        \\Raw observations (state/autolearn.jsonl, tail):
        \\```text
        \\{s}
        \\```
        \\
        \\Current deterministic aggregation:
        \\```markdown
        \\{s}
        \\```
        \\
        \\Rewrite and refine the "## Autolearn" section. Keep what the
        \\deterministic pass got right, fold in anything it missed, and return
        \\the finished markdown section only, starting with the "## Autolearn"
        \\heading.
    , .{ observations, mechanical });
}

/// Replaces any existing "## Autolearn" section (from the marker to EOF,
/// since it is always the last section) with `section`, or appends it.
pub fn mergeRoadmap(alloc: std.mem.Allocator, existing: []const u8, section: []const u8) ![]const u8 {
    const marker = "## Autolearn";
    if (std.mem.find(u8, existing, marker)) |idx| {
        return std.mem.concat(alloc, u8, &.{ existing[0..idx], section });
    }
    if (existing.len == 0) return alloc.dupe(u8, section);
    if (existing[existing.len - 1] == '\n') {
        return std.mem.concat(alloc, u8, &.{ existing, "\n", section });
    }
    return std.mem.concat(alloc, u8, &.{ existing, "\n\n", section });
}

test "lastLines keeps a short buffer and drops a leading partial line" {
    const short = "one\ntwo\n";
    try std.testing.expectEqualStrings(short, lastLines(short, 64));
    try std.testing.expectEqualStrings("", lastLines("", 64));

    const long = "aaaa\nbbbb\ncccc\ndddd\n";
    try std.testing.expectEqualStrings("cccc\ndddd\n", lastLines(long, 11));
    // No newline inside the window: keep the clipped tail as-is.
    try std.testing.expectEqualStrings("yyyy", lastLines("xxxxxyyyy", 4));
}

test "mergeRoadmap replaces from the Autolearn marker and appends when missing" {
    const gpa = std.testing.allocator;
    const section = "## Autolearn\n\n- new\n";

    const replaced = try mergeRoadmap(gpa, "# Title\n\n## Autolearn\n\n- old\n", section);
    defer gpa.free(replaced);
    try std.testing.expectEqualStrings("# Title\n\n## Autolearn\n\n- new\n", replaced);

    const appended = try mergeRoadmap(gpa, "# Title\n", section);
    defer gpa.free(appended);
    try std.testing.expectEqualStrings("# Title\n\n## Autolearn\n\n- new\n", appended);

    const empty = try mergeRoadmap(gpa, "", section);
    defer gpa.free(empty);
    try std.testing.expectEqualStrings(section, empty);
}

test "userPrompt carries both the observation tail and the mechanical draft" {
    const gpa = std.testing.allocator;
    const got = try userPrompt(gpa, "{\"type\":\"run\"}", "## Autolearn\n\n- draft\n");
    defer gpa.free(got);
    try std.testing.expect(std.mem.find(u8, got, "{\"type\":\"run\"}") != null);
    try std.testing.expect(std.mem.find(u8, got, "## Autolearn\n\n- draft\n") != null);
}
