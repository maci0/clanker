//! Pure helpers for mirroring agency-agents (github.com/msitarzewski/
//! agency-agents) persona files and their catalog: pulling the `name:` out
//! of a persona's frontmatter, listing a division's markdown files from a
//! GitHub contents-API response, and building/merging agency/index.json, a
//! flat catalog (division, path, name, description per persona) a future
//! picker tool can browse without reading every file. No host I/O, so
//! `zig build test` runs it; the `agency_sync` guest does the HTTP fetches
//! and file writes around these functions.

const std = @import("std");

/// The `name:` value from a leading `---` frontmatter block, or "" if there
/// is none. Mirrors skills_logic.splitFrontmatter's key-scanning loop but
/// looks for `name` instead of `title` -- agency-agents files use `name`;
/// clanker's own skill files (unrelated to this catalog) use `title`.
pub fn extractName(raw: []const u8) []const u8 {
    if (!std.mem.startsWith(u8, raw, "---")) return "";
    const first_nl = std.mem.findScalar(u8, raw, '\n') orelse return "";
    if (!std.mem.eql(u8, std.mem.trim(u8, raw[0..first_nl], " \t\r"), "---")) return "";
    const rest = raw[first_nl + 1 ..];
    const rel = std.mem.find(u8, rest, "\n---") orelse return "";
    const fm = rest[0..rel];
    var lines = std.mem.splitScalar(u8, fm, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (trimmed.len == 0 or trimmed[0] == '#') continue;
        const colon = std.mem.findScalar(u8, trimmed, ':') orelse continue;
        const key = std.mem.trim(u8, trimmed[0..colon], " \t");
        if (!std.ascii.eqlIgnoreCase(key, "name")) continue;
        var val = std.mem.trim(u8, trimmed[colon + 1 ..], " \t");
        if (val.len >= 2 and ((val[0] == '"' and val[val.len - 1] == '"') or (val[0] == '\'' and val[val.len - 1] == '\''))) {
            val = val[1 .. val.len - 1];
        }
        return val;
    }
    return "";
}

/// Keys of the top-level `divisions` object in agency-agents' divisions.json
/// (its own source of truth for which top-level directories are agent
/// divisions, as opposed to integrations/strategy/examples/scripts).
pub fn divisionNames(arena: std.mem.Allocator, divisions_json: []const u8) ![]const []const u8 {
    const parsed = std.json.parseFromSliceLeaky(std.json.Value, arena, divisions_json, .{}) catch
        return &.{};
    if (parsed != .object) return &.{};
    const divisions = parsed.object.get("divisions") orelse return &.{};
    if (divisions != .object) return &.{};
    var out: std.ArrayList([]const u8) = .empty;
    var it = divisions.object.iterator();
    while (it.next()) |kv| try out.append(arena, kv.key_ptr.*);
    return out.toOwnedSlice(arena);
}

/// `.md` file names from a GitHub contents-API directory listing (an array
/// of `{"name": "...", "type": "file", ...}` objects). Anything not a file
/// ending in `.md` is skipped, since a division's directory has been asked to
/// hold nothing else, but a divergence there should be silently ignored
/// rather than synced as a bogus entry.
pub fn mdFileNames(arena: std.mem.Allocator, contents_json: []const u8) ![]const []const u8 {
    const parsed = std.json.parseFromSliceLeaky(std.json.Value, arena, contents_json, .{}) catch
        return &.{};
    if (parsed != .array) return &.{};
    var out: std.ArrayList([]const u8) = .empty;
    for (parsed.array.items) |item| {
        if (item != .object) continue;
        const kind = item.object.get("type") orelse continue;
        if (kind != .string or !std.mem.eql(u8, kind.string, "file")) continue;
        const name = item.object.get("name") orelse continue;
        if (name != .string or !std.mem.endsWith(u8, name.string, ".md")) continue;
        try out.append(arena, name.string);
    }
    return out.toOwnedSlice(arena);
}

pub const IndexEntry = struct {
    division: []const u8,
    path: []const u8,
    name: []const u8,
    description: []const u8,
};

/// Renders agency/index.json: a JSON array of {division, path, name,
/// description}, one per persona, so a future picker can browse the
/// catalog without reading every mirrored file.
pub fn buildIndex(arena: std.mem.Allocator, entries: []const IndexEntry) ![]const u8 {
    var w: std.Io.Writer.Allocating = .init(arena);
    var s: std.json.Stringify = .{ .writer = &w.writer, .options = .{ .whitespace = .indent_2 } };
    try s.beginArray();
    for (entries) |e| {
        try s.beginObject();
        try s.objectField("division");
        try s.write(e.division);
        try s.objectField("path");
        try s.write(e.path);
        try s.objectField("name");
        try s.write(e.name);
        try s.objectField("description");
        try s.write(e.description);
        try s.endObject();
    }
    try s.endArray();
    return w.written();
}

/// Parses an existing agency/index.json back into entries. Malformed or
/// missing input yields an empty slice rather than an error: a first sync
/// has no prior index to read, and a corrupt one should not block a re-sync
/// that would fix it.
pub fn parseIndex(arena: std.mem.Allocator, index_json: []const u8) []const IndexEntry {
    const parsed = std.json.parseFromSliceLeaky(std.json.Value, arena, index_json, .{}) catch
        return &.{};
    if (parsed != .array) return &.{};
    var out: std.ArrayList(IndexEntry) = .empty;
    for (parsed.array.items) |item| {
        if (item != .object) continue;
        const division = item.object.get("division") orelse continue;
        const path = item.object.get("path") orelse continue;
        const name = item.object.get("name") orelse continue;
        const description = item.object.get("description") orelse continue;
        if (division != .string or path != .string or name != .string or description != .string) continue;
        out.append(arena, .{ .division = division.string, .path = path.string, .name = name.string, .description = description.string }) catch continue;
    }
    return out.toOwnedSlice(arena) catch &.{};
}

/// `existing` with every entry whose division is in `resynced_divisions`
/// dropped, so a scoped {"division": "..."} sync replaces only that
/// division's slice of the catalog instead of wiping the rest of it.
pub fn dropDivisions(arena: std.mem.Allocator, existing: []const IndexEntry, resynced_divisions: []const []const u8) []const IndexEntry {
    var out: std.ArrayList(IndexEntry) = .empty;
    for (existing) |e| {
        var stale = false;
        for (resynced_divisions) |d| {
            if (std.mem.eql(u8, e.division, d)) {
                stale = true;
                break;
            }
        }
        if (!stale) out.append(arena, e) catch continue;
    }
    return out.toOwnedSlice(arena) catch &.{};
}

test "extractName reads the name key and ignores decorative ones" {
    const raw =
        \\---
        \\name: Code Reviewer
        \\description: Reviews code.
        \\color: purple
        \\emoji: 👁️
        \\---
        \\
        \\# Code Reviewer Agent
    ;
    try std.testing.expectEqualStrings("Code Reviewer", extractName(raw));
}

test "extractName returns empty for a body with no frontmatter" {
    try std.testing.expectEqualStrings("", extractName("# Just a heading\n\nbody"));
}

test "extractName strips matching quotes" {
    const raw = "---\nname: \"Quoted Name\"\n---\nbody";
    try std.testing.expectEqualStrings("Quoted Name", extractName(raw));
}

test "divisionNames reads the divisions object keys" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const json =
        \\{"divisions": {"engineering": {"label": "Engineering"}, "design": {"label": "Design"}}}
    ;
    const names = try divisionNames(arena, json);
    try std.testing.expectEqual(@as(usize, 2), names.len);
    var saw_engineering = false;
    var saw_design = false;
    for (names) |n| {
        if (std.mem.eql(u8, n, "engineering")) saw_engineering = true;
        if (std.mem.eql(u8, n, "design")) saw_design = true;
    }
    try std.testing.expect(saw_engineering and saw_design);
}

test "divisionNames tolerates malformed input" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const names = try divisionNames(arena_state.allocator(), "not json");
    try std.testing.expectEqual(@as(usize, 0), names.len);
}

test "mdFileNames keeps only .md files, skips directories and non-md files" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const json =
        \\[
        \\  {"name": "engineering-code-reviewer.md", "type": "file"},
        \\  {"name": "README.md", "type": "file"},
        \\  {"name": "subdir", "type": "dir"},
        \\  {"name": "notes.txt", "type": "file"}
        \\]
    ;
    const files = try mdFileNames(arena, json);
    try std.testing.expectEqual(@as(usize, 2), files.len);
    try std.testing.expectEqualStrings("engineering-code-reviewer.md", files[0]);
    try std.testing.expectEqualStrings("README.md", files[1]);
}

test "buildIndex then parseIndex round-trips" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const entries = [_]IndexEntry{
        .{ .division = "engineering", .path = "agency/engineering/engineering-code-reviewer.md", .name = "Code Reviewer", .description = "Reviews code." },
    };
    const json = try buildIndex(arena, &entries);
    const back = parseIndex(arena, json);
    try std.testing.expectEqual(@as(usize, 1), back.len);
    try std.testing.expectEqualStrings("engineering", back[0].division);
    try std.testing.expectEqualStrings("Code Reviewer", back[0].name);
}

test "dropDivisions removes only the named divisions' entries" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const entries = [_]IndexEntry{
        .{ .division = "engineering", .path = "a", .name = "A", .description = "d" },
        .{ .division = "design", .path = "b", .name = "B", .description = "d" },
        .{ .division = "engineering", .path = "c", .name = "C", .description = "d" },
    };
    const kept = dropDivisions(arena, &entries, &.{"engineering"});
    try std.testing.expectEqual(@as(usize, 1), kept.len);
    try std.testing.expectEqualStrings("design", kept[0].division);
}
