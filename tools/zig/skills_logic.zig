//! Pure skill-file filters. No host I/O, so `zig build test` runs it.
//!
//! The `skills` guest, `/api/skills`, and the system prompt share these so a
//! listing and the prompt cannot disagree about which files count.

const std = @import("std");

pub const max_skill_bytes: usize = 24 * 1024;
pub const min_body_bytes: usize = 20;
pub const desc_clip: usize = 220;

/// Markdown files the prompt embeds. `SYSTEM.md` is the base prompt, not a skill.
pub fn isSkillFile(name: []const u8) bool {
    if (!std.mem.endsWith(u8, name, ".md")) return false;
    if (std.mem.eql(u8, name, "SYSTEM.md")) return false;
    return true;
}

pub fn hasMinBody(content: []const u8) bool {
    return std.mem.trim(u8, content, " \t\r\n").len >= min_body_bytes;
}

/// Show/search names are basenames. A path or `..` is refused, not sanitised.
pub fn validSkillName(name: []const u8) bool {
    if (name.len == 0 or name.len > 128) return false;
    if (std.mem.findScalar(u8, name, '/') != null) return false;
    if (std.mem.findScalar(u8, name, '\\') != null) return false;
    if (std.mem.find(u8, name, "..") != null) return false;
    return true;
}

pub fn stemOf(name: []const u8) []const u8 {
    if (std.mem.endsWith(u8, name, ".md")) return name[0 .. name.len - 3];
    return name;
}

pub fn nameMatches(have: []const u8, want: []const u8) bool {
    if (std.mem.eql(u8, have, want)) return true;
    return std.mem.eql(u8, stemOf(have), stemOf(want));
}

pub const Meta = struct {
    title: []const u8,
    description: []const u8,
    enabled: bool = true,
};

pub const overrides_path = "state/skills.json";

/// Optional YAML subset between leading `---` fences: `title`, `description`,
/// `enabled`. Same key:value-per-line dialect workflows use. Slices alias `raw`.
pub const Frontmatter = struct {
    title: []const u8 = "",
    description: []const u8 = "",
    enabled: bool = true,
    body: []const u8,
};

pub fn splitFrontmatter(raw: []const u8) Frontmatter {
    var out = Frontmatter{ .body = raw };
    if (!std.mem.startsWith(u8, raw, "---")) return out;
    const first_nl = std.mem.findScalar(u8, raw, '\n') orelse return out;
    if (!std.mem.eql(u8, std.mem.trim(u8, raw[0..first_nl], " \t\r"), "---")) return out;
    const rest = raw[first_nl + 1 ..];
    const rel = std.mem.find(u8, rest, "\n---") orelse return out;
    const fm = rest[0..rel];
    const after = rest[rel + "\n---".len ..];
    out.body = if (after.len > 0 and after[0] == '\n')
        after[1..]
    else if (after.len > 1 and after[0] == '\r' and after[1] == '\n')
        after[2..]
    else
        after;
    var lines = std.mem.splitScalar(u8, fm, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (trimmed.len == 0 or trimmed[0] == '#') continue;
        const colon = std.mem.findScalar(u8, trimmed, ':') orelse continue;
        const key = std.mem.trim(u8, trimmed[0..colon], " \t");
        var val = std.mem.trim(u8, trimmed[colon + 1 ..], " \t");
        if (val.len >= 2 and ((val[0] == '"' and val[val.len - 1] == '"') or (val[0] == '\'' and val[val.len - 1] == '\''))) {
            val = val[1 .. val.len - 1];
        }
        if (std.ascii.eqlIgnoreCase(key, "title") and val.len > 0) {
            out.title = val;
        } else if (std.ascii.eqlIgnoreCase(key, "description") and val.len > 0) {
            out.description = clipTo(val, desc_clip);
        } else if (std.ascii.eqlIgnoreCase(key, "enabled") and val.len > 0) {
            out.enabled = !(std.ascii.eqlIgnoreCase(val, "false") or std.mem.eql(u8, val, "0") or std.ascii.eqlIgnoreCase(val, "no") or std.ascii.eqlIgnoreCase(val, "off"));
        }
    }
    return out;
}

/// Heading/paragraph fallback, then frontmatter overrides. Null when the
/// remaining body is too short and there is no description to disclose.
pub fn parseMeta(content: []const u8) ?Meta {
    const fm = splitFrontmatter(content);
    if (!hasMinBody(fm.body) and fm.description.len == 0) return null;
    var title: []const u8 = fm.title;
    var description: []const u8 = fm.description;
    if (title.len == 0 or description.len == 0) {
        const heading = headingMeta(fm.body);
        if (title.len == 0) title = heading.title;
        if (description.len == 0) description = heading.description;
    }
    return .{ .title = title, .description = description, .enabled = fm.enabled };
}

fn headingMeta(content: []const u8) Meta {
    var title: []const u8 = "";
    var description: []const u8 = "";
    var lines = std.mem.splitScalar(u8, content, '\n');
    while (lines.next()) |line| {
        const t = std.mem.trim(u8, line, " \t\r");
        if (t.len == 0) continue;
        if (std.mem.startsWith(u8, t, "# ")) {
            if (title.len == 0) title = std.mem.trim(u8, t[2..], " \t\r");
            continue;
        }
        if (std.mem.startsWith(u8, t, "#")) continue;
        description = clipTo(t, desc_clip);
        break;
    }
    return .{ .title = title, .description = description };
}

pub const Overrides = struct {
    disabled: []const []const u8 = &.{},
};

/// `{ "disabled": ["research"] }` in `state/skills.json`. Missing/invalid is none.
pub fn parseOverrides(arena: std.mem.Allocator, json: []const u8) Overrides {
    if (json.len == 0) return .{};
    const parsed = std.json.parseFromSliceLeaky(struct {
        disabled: []const []const u8 = &.{},
    }, arena, json, .{ .ignore_unknown_fields = true }) catch return .{};
    return .{ .disabled = parsed.disabled };
}

pub fn nameIsDisabled(name: []const u8, disabled: []const []const u8) bool {
    for (disabled) |d| {
        if (nameMatches(name, d)) return true;
    }
    return false;
}

/// Frontmatter `enabled: false` wins; the sidecar only turns on-by-default skills off.
pub fn isEnabled(meta: Meta, name: []const u8, disabled: []const []const u8) bool {
    if (!meta.enabled) return false;
    return !nameIsDisabled(name, disabled);
}

pub fn mergeDisabled(
    arena: std.mem.Allocator,
    current: []const []const u8,
    name: []const u8,
    on: bool,
) ![]const []const u8 {
    const stem = stemOf(name);
    var next: std.ArrayList([]const u8) = .empty;
    for (current) |e| {
        if (nameMatches(e, stem)) continue;
        try next.append(arena, e);
    }
    if (!on) try next.append(arena, stem);
    return next.toOwnedSlice(arena);
}

pub fn writeDisabledJson(arena: std.mem.Allocator, disabled: []const []const u8) ![]const u8 {
    var out: std.Io.Writer.Allocating = .init(arena);
    var s = std.json.Stringify{ .writer = &out.writer };
    try s.beginObject();
    try s.objectField("disabled");
    try s.write(disabled);
    try s.endObject();
    return out.written();
}

pub fn matchesQuery(query: []const u8, name: []const u8, title: []const u8, description: []const u8, body: []const u8) bool {
    if (query.len == 0) return true;
    return containsIgnoreCase(name, query) or
        containsIgnoreCase(title, query) or
        containsIgnoreCase(description, query) or
        containsIgnoreCase(body, query);
}

pub fn nameLessThan(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.lessThan(u8, a, b);
}

/// Prefix clip that does not split a UTF-8 codepoint.
pub fn clipTo(s: []const u8, max: usize) []const u8 {
    if (s.len <= max) return s;
    var end = max;
    while (end > 0 and (s[end] & 0xC0) == 0x80) end -= 1;
    return s[0..end];
}

fn containsIgnoreCase(hay: []const u8, needle: []const u8) bool {
    if (needle.len == 0) return true;
    if (hay.len < needle.len) return false;
    var i: usize = 0;
    while (i + needle.len <= hay.len) : (i += 1) {
        if (eqlIgnoreCase(hay[i .. i + needle.len], needle)) return true;
    }
    return false;
}

fn eqlIgnoreCase(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| {
        if (std.ascii.toLower(x) != std.ascii.toLower(y)) return false;
    }
    return true;
}

test "isSkillFile matches the prompt's discovery" {
    try std.testing.expect(isSkillFile("research.md"));
    try std.testing.expect(isSkillFile("auto-research.md"));
    try std.testing.expect(!isSkillFile("SYSTEM.md"));
    try std.testing.expect(!isSkillFile("notes.txt"));
    try std.testing.expect(!isSkillFile("research"));
}

test "parseMeta skips short bodies and takes heading plus first prose" {
    try std.testing.expect(parseMeta("too short") == null);
    const meta = parseMeta("# Autoresearch\n\nRun a command-to-scalar harness loop.\n") orelse
        return error.ExpectedMeta;
    try std.testing.expectEqualStrings("Autoresearch", meta.title);
    try std.testing.expectEqualStrings("Run a command-to-scalar harness loop.", meta.description);
    try std.testing.expect(meta.enabled);
}

test "parseMeta reads frontmatter title description enabled" {
    const raw =
        \\---
        \\title: Web research
        \\description: Look things up.
        \\enabled: false
        \\---
        \\
        \\# Ignored heading
        \\
        \\BODY_MUST_NOT_BE_TITLE
        \\
    ;
    const meta = parseMeta(raw) orelse return error.ExpectedMeta;
    try std.testing.expectEqualStrings("Web research", meta.title);
    try std.testing.expectEqualStrings("Look things up.", meta.description);
    try std.testing.expect(!meta.enabled);
    try std.testing.expect(std.mem.find(u8, splitFrontmatter(raw).body, "BODY_MUST_NOT_BE_TITLE") != null);
}

test "nameIsDisabled and mergeDisabled use stems" {
    try std.testing.expect(nameIsDisabled("research.md", &.{ "research", "other" }));
    try std.testing.expect(!nameIsDisabled("research.md", &.{"autoresearch"}));

    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const off = try mergeDisabled(arena, &.{}, "research.md", false);
    try std.testing.expectEqual(@as(usize, 1), off.len);
    try std.testing.expectEqualStrings("research", off[0]);
    const on = try mergeDisabled(arena, off, "research", true);
    try std.testing.expectEqual(@as(usize, 0), on.len);

    const json = try writeDisabledJson(arena, &.{ "research", "mcp" });
    const parsed = parseOverrides(arena, json);
    try std.testing.expectEqual(@as(usize, 2), parsed.disabled.len);
    try std.testing.expect(nameIsDisabled("mcp.md", parsed.disabled));
}

test "parseMeta ignores extra headings after the title" {
    const meta = parseMeta("# Title\n\n## Sub\n\nThe paragraph.\n") orelse return error.ExpectedMeta;
    try std.testing.expectEqualStrings("Title", meta.title);
    try std.testing.expectEqualStrings("The paragraph.", meta.description);
}

test "validSkillName refuses paths" {
    try std.testing.expect(validSkillName("research"));
    try std.testing.expect(validSkillName("research.md"));
    try std.testing.expect(!validSkillName(""));
    try std.testing.expect(!validSkillName("a/b"));
    try std.testing.expect(!validSkillName("../x"));
    try std.testing.expect(!validSkillName("x\\y"));
}

test "nameMatches accepts stem or filename" {
    try std.testing.expect(nameMatches("research.md", "research"));
    try std.testing.expect(nameMatches("research.md", "research.md"));
    try std.testing.expect(!nameMatches("research.md", "autoresearch"));
}

test "matchesQuery is case-insensitive across name title description body" {
    try std.testing.expect(matchesQuery("WEB", "research.md", "Web research", "Find facts.", "body"));
    try std.testing.expect(matchesQuery("facts", "research.md", "Title", "Find facts.", "body"));
    try std.testing.expect(matchesQuery("scalar", "x.md", "T", "D", "command-to-scalar"));
    try std.testing.expect(!matchesQuery("missing", "x.md", "T", "D", "body"));
}

test "clipTo does not split a UTF-8 sequence" {
    const s = "abc\u{00e9}xyz";
    try std.testing.expectEqualStrings("abc", clipTo(s, 4));
    try std.testing.expectEqualStrings(s, clipTo(s, 64));
}
