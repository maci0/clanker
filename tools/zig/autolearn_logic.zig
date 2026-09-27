//! Pure helpers for the autolearn guest: observation tail, synthesis
//! prompts, and the ROADMAP section merge. Host-tested so the CLI and the
//! guest cannot drift on what a synthesized "## Autolearn" section replaces.

const std = @import("std");

/// Bound on the raw observation tail fed to the synthesizer. A long log
/// must not blow the prompt; only whole lines, so JSON fragments are never cut.
pub const max_observation_bytes: usize = 64 * 1024;

/// Output budget for the synthesis call, and the value the descriptor grants
/// (`ck_llm` clamps a request to the grant, so the two must move together).
/// Sized for a reasoning model, not for the section alone: `max_tokens` bounds
/// reasoning and content together, and a section-sized 2500 was spent entirely
/// on reasoning by deepseek-v4-pro, which answered 200 with empty content and
/// failed the run as "synthesizer returned an empty section".
pub const synthesis_max_tokens: u32 = 16000;

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

/// The tail of the observations fed to the rewrite prompt is bounded by
/// `tail.onLineBoundary` (`src/util/tail.zig`, `max_observation_bytes`),
/// so only whole lines reach the model.
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

/// One `(name, count)` row, in the order a rendered item reads best: most
/// calls first, name ascending within a tie.
///
/// The name tiebreak is the point. The aggregation counts into a hash map, so
/// a sort on the count alone leaves equal counts to the map's iteration
/// order, which is a fact about insertion sequence and capacity rather than
/// about the observations. The section is committed to docs/ROADMAP.md, is
/// part of the synthesizer's prompt, and is read back as backlog seed, and
/// the "most-used tools" item cuts the list to the top three, so a tie there
/// decided which tool got named. Ordering the rows makes the file a function
/// of the counts.
pub const Row = struct { name: []const u8, n: u64 };

/// A counted row that also carries the detail the map already resolved to
/// (last write wins), so ordering the rows does not re-pick which detail a
/// line names.
pub const CountRow = struct { name: []const u8, n: u64, detail: []const u8 };

fn rowLessThan(_: void, a: Row, b: Row) bool {
    if (a.n != b.n) return a.n > b.n;
    return std.mem.lessThan(u8, a.name, b.name);
}

fn countRowLessThan(_: void, a: CountRow, b: CountRow) bool {
    if (a.n != b.n) return a.n > b.n;
    return std.mem.lessThan(u8, a.name, b.name);
}

/// `map` walked into a list ordered by `rowLessThan`.
pub fn sortedUses(alloc: std.mem.Allocator, map: std.array_hash_map.String(u64)) !std.ArrayList(Row) {
    var list: std.ArrayList(Row) = .empty;
    var it = map.iterator();
    while (it.next()) |kv| try list.append(alloc, .{ .name = kv.key_ptr.*, .n = kv.value_ptr.* });
    std.mem.sort(Row, list.items, {}, rowLessThan);
    return list;
}

/// `map` walked into a list ordered by `countRowLessThan`. The value type is
/// structural so the guest's aggregate map can be passed straight through
/// (a `{ n: u64, detail: []const u8 }` store is not a named type here).
pub fn sortedCounts(alloc: std.mem.Allocator, map: anytype) !std.ArrayList(CountRow) {
    var list: std.ArrayList(CountRow) = .empty;
    var it = map.iterator();
    while (it.next()) |kv| {
        try list.append(alloc, .{ .name = kv.key_ptr.*, .n = kv.value_ptr.n, .detail = kv.value_ptr.detail });
    }
    std.mem.sort(CountRow, list.items, {}, countRowLessThan);
    return list;
}

test "equal counts order by name, not by the order the map hands rows out" {
    var uses: std.array_hash_map.String(u64) = .empty;
    defer uses.deinit(std.testing.allocator);
    // Inserted in an order the rows must not inherit.
    for ([_]struct { []const u8, u64 }{ .{ "write_file", 3 }, .{ "read_file", 3 }, .{ "list_files", 9 } }) |row| {
        try uses.put(std.testing.allocator, row[0], row[1]);
    }

    var rows = try sortedUses(std.testing.allocator, uses);
    defer rows.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 3), rows.items.len);
    try std.testing.expectEqualStrings("list_files", rows.items[0].name);
    try std.testing.expectEqualStrings("read_file", rows.items[1].name);
    try std.testing.expectEqualStrings("write_file", rows.items[2].name);
}

test "counted rows carry their resolved detail and sort the same way" {
    const Count = struct { n: u64 = 0, detail: []const u8 = "" };
    var counts: std.array_hash_map.String(Count) = .empty;
    defer counts.deinit(std.testing.allocator);
    try counts.put(std.testing.allocator, "bash", .{ .n = 2, .detail = "second" });
    try counts.put(std.testing.allocator, "apply_patch", .{ .n = 2, .detail = "first" });
    try counts.put(std.testing.allocator, "grep", .{ .n = 5, .detail = "third" });

    var rows = try sortedCounts(std.testing.allocator, counts);
    defer rows.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("grep", rows.items[0].name);
    try std.testing.expectEqualStrings("third", rows.items[0].detail);
    try std.testing.expectEqualStrings("apply_patch", rows.items[1].name);
    try std.testing.expectEqualStrings("first", rows.items[1].detail);
    try std.testing.expectEqualStrings("bash", rows.items[2].name);
    try std.testing.expectEqualStrings("second", rows.items[2].detail);
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

/// Bound on a synthesized section. The synthesis call is granted
/// `synthesis_max_tokens` tokens, which is a lot of markdown for a
/// ROADMAP section, and ROADMAP is read back as backlog seed material by the
/// improve engine, so an unbounded section is unbounded prompt too.
pub const max_section_bytes: usize = 16 * 1024;

/// Heading the merge marker looks for, and the only level a synthesized
/// section may open.
pub const section_marker = "## Autolearn";

/// Make a model-written ROADMAP section safe to merge into the repository
/// document.
///
/// The synthesizer's reply is markdown the model composed, and it is written
/// to `docs/ROADMAP.md` verbatim, so it carries two things worth bounding
/// before it lands:
///
/// * a sibling `## Some Other Section` heading, which would be a section of
///   ROADMAP that no later run replaces (the merge only rewrites from the
///   `## Autolearn` marker) and that reads to a human as a curated roadmap
///   item rather than model prose. Headings below the marker are demoted one
///   level so they stay part of the Autolearn section.
/// * control bytes and unbounded length, which a committed document has no
///   reason to carry.
///
/// The leading marker is required: the prompt asks for the section to begin
/// with it, and a reply that does not would otherwise be merged as a section
/// no later run could find and replace. Returns null in that case.
pub fn sanitizeSection(alloc: std.mem.Allocator, raw: []const u8) !?[]const u8 {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(alloc);
    var wrote_marker = false;
    var at_line_start = true;
    var skip_to_eol = false;
    var pending_hashes: usize = 0;
    for (raw) |c| {
        if (c < 0x20 and c != '\n' and c != '\t') continue; // drop the rest
        if (at_line_start and c == '#') {
            pending_hashes += 1;
            continue;
        }
        if (pending_hashes > 0) {
            // A run of `#` at the start of a line is a heading; demote it so
            // the section owns every heading it contains.
            const level = @min(pending_hashes + 1, 6);
            if (!wrote_marker) {
                // The first heading is the section's own, whatever the model
                // called it and whatever level it chose: the merge marker is a
                // fixed string, so a deeper first heading would leave a
                // section no later run can find and replace. Its title text is
                // the model's, and the marker already carries the one word a
                // reader needs.
                try out.appendSlice(alloc, section_marker);
                wrote_marker = true;
                skip_to_eol = true;
                pending_hashes = 0;
                at_line_start = false;
                if (c == '\n') {
                    skip_to_eol = false;
                    at_line_start = true;
                    try out.append(alloc, c);
                }
                continue;
            } else {
                try out.appendNTimes(alloc, '#', level);
                // Keep the one space that separates the hashes from the title,
                // or the demotion reads as part of the word.
                if (c == ' ' or c == '\t') try out.append(alloc, ' ');
            }
            pending_hashes = 0;
            at_line_start = false;
            if (c == '\n') {
                skip_to_eol = false;
                at_line_start = true;
                try out.append(alloc, c);
            }
            continue;
        }
        if (skip_to_eol) {
            if (c != '\n') continue;
            skip_to_eol = false;
            try out.append(alloc, c);
            at_line_start = true;
            continue;
        }
        if (out.items.len >= max_section_bytes) break;
        try out.append(alloc, c);
        at_line_start = c == '\n';
    }
    if (!wrote_marker) return null;
    // Duped rather than handed back as a view: the caller frees what it gets,
    // and the ArrayList's own buffer is not its allocation to free.
    return try alloc.dupe(u8, std.mem.trimEnd(u8, out.items, " \t\n"));
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

test "sanitizeSection keeps the model's prose but demotes its headings" {
    const gpa = std.testing.allocator;
    const got = (try sanitizeSection(gpa, "## Autolearn\n\n- [ ] fix a\n  because of b\n\n## Adopted Roadmap\n\n- hijack\n")).?;
    defer gpa.free(got);
    try std.testing.expectEqualStrings(
        "## Autolearn\n\n- [ ] fix a\n  because of b\n\n### Adopted Roadmap\n\n- hijack",
        got,
    );
    // A `##` heading written by the model must not survive at level 2, or it
    // becomes a ROADMAP section no later run replaces.
    try std.testing.expect(std.mem.indexOf(u8, got, "\n## ") == null);
}

test "sanitizeSection refuses a reply that never opens the section" {
    const gpa = std.testing.allocator;
    // A reply with no heading at all would be merged as a section no later
    // run could find, so it is refused rather than written.
    try std.testing.expect((try sanitizeSection(gpa, "just some prose, no heading")) == null);
    try std.testing.expect((try sanitizeSection(gpa, "")) == null);

    // A deeper first heading is still accepted, promoted to the marker.
    const promoted = (try sanitizeSection(gpa, "### Autolearn\n\n- x")).?;
    defer gpa.free(promoted);
    try std.testing.expectEqualStrings("## Autolearn\n\n- x", promoted);
}

test "sanitizeSection drops control bytes and bounds the length" {
    const gpa = std.testing.allocator;
    const dirty = (try sanitizeSection(gpa, "## Autolearn\n\n- a\x00b\x07c")).?;
    defer gpa.free(dirty);
    try std.testing.expectEqualStrings("## Autolearn\n\n- abc", dirty);

    const huge = try gpa.alloc(u8, max_section_bytes * 3);
    defer gpa.free(huge);
    @memset(huge, 'x');
    @memcpy(huge[0..section_marker.len], section_marker);
    const capped = (try sanitizeSection(gpa, huge)).?;
    defer gpa.free(capped);
    try std.testing.expect(capped.len <= max_section_bytes);
    try std.testing.expect(std.mem.startsWith(u8, capped, section_marker));
}
