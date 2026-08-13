//! Surgical edits to an existing TOML file. Replaces one table span or one
//! top-level key and copies every other byte through unchanged. Used by the
//! web UI Models view to write `config.local.toml` without a TOML round-trip
//! that would drop comments and hand-placed structure.

const std = @import("std");

/// First line of `block` must be the table header (`[models."x/y"]` or
/// `[providers.name]`). Replaces that table's span if the header is present
/// as a literal line; otherwise appends the block.
pub fn replaceTable(arena: std.mem.Allocator, src: []const u8, block: []const u8) ![]const u8 {
    const header = tableHeaderLine(block) orelse return error.MissingTableHeader;
    if (findTableSpan(src, header)) |span| {
        return splice(arena, src, span.start, span.end, ensureTrailingNewline(block));
    }
    return appendBlock(arena, src, ensureTrailingNewline(block));
}

/// Replace or insert a top-level `key = "value"` line. A new key is inserted
/// immediately before the first table header so it stays at the root.
pub fn setTopLevelString(arena: std.mem.Allocator, src: []const u8, key: []const u8, value: []const u8) ![]const u8 {
    const line = try std.fmt.allocPrint(arena, "{s} = \"{s}\"\n", .{ key, escapeTomlString(arena, value) });
    if (findTopLevelKey(src, key)) |span| {
        return splice(arena, src, span.start, span.end, line);
    }
    const insert_at = firstTableOffset(src) orelse src.len;
    if (src.len == 0) return line;
    if (insert_at == 0) return std.fmt.allocPrint(arena, "{s}{s}", .{ line, src });
    const before = src[0..insert_at];
    const after = src[insert_at..];
    if (before.len > 0 and before[before.len - 1] != '\n') {
        return std.fmt.allocPrint(arena, "{s}\n{s}{s}", .{ before, line, after });
    }
    return std.fmt.allocPrint(arena, "{s}{s}{s}", .{ before, line, after });
}

const Span = struct { start: usize, end: usize };

fn tableHeaderLine(block: []const u8) ?[]const u8 {
    var it = std.mem.splitScalar(u8, block, '\n');
    const first = it.next() orelse return null;
    const line = std.mem.trimRight(u8, first, "\r");
    if (line.len < 3 or line[0] != '[') return null;
    return line;
}

fn findTableSpan(src: []const u8, header: []const u8) ?Span {
    var i: usize = 0;
    var found: ?Span = null;
    while (i < src.len) {
        const nl = std.mem.indexOfScalarPos(u8, src, i, '\n') orelse src.len;
        const line = std.mem.trimRight(u8, src[i..nl], "\r");
        if (std.mem.eql(u8, line, header)) {
            const end = nextTableOffset(src, if (nl < src.len) nl + 1 else src.len);
            found = .{ .start = i, .end = end };
        }
        if (nl == src.len) break;
        i = nl + 1;
    }
    return found;
}

fn nextTableOffset(src: []const u8, from: usize) usize {
    var i = from;
    while (i < src.len) {
        const nl = std.mem.indexOfScalarPos(u8, src, i, '\n') orelse src.len;
        const line = std.mem.trimRight(u8, src[i..nl], "\r");
        if (line.len > 0 and line[0] == '[') return i;
        if (nl == src.len) return src.len;
        i = nl + 1;
    }
    return src.len;
}

fn firstTableOffset(src: []const u8) ?usize {
    var i: usize = 0;
    while (i < src.len) {
        const nl = std.mem.indexOfScalarPos(u8, src, i, '\n') orelse src.len;
        const line = std.mem.trimRight(u8, src[i..nl], "\r");
        if (line.len > 0 and line[0] == '[') return i;
        if (nl == src.len) return null;
        i = nl + 1;
    }
    return null;
}

fn findTopLevelKey(src: []const u8, key: []const u8) ?Span {
    var i: usize = 0;
    var in_table = false;
    var found: ?Span = null;
    while (i < src.len) {
        const nl = std.mem.indexOfScalarPos(u8, src, i, '\n') orelse src.len;
        const line = std.mem.trimRight(u8, src[i..nl], "\r");
        if (line.len > 0 and line[0] == '[') {
            in_table = true;
        } else if (!in_table and lineStartsWithKey(line, key)) {
            const end = if (nl < src.len) nl + 1 else src.len;
            found = .{ .start = i, .end = end };
        }
        if (nl == src.len) break;
        i = nl + 1;
    }
    return found;
}

fn lineStartsWithKey(line: []const u8, key: []const u8) bool {
    if (!std.mem.startsWith(u8, line, key)) return false;
    const rest = line[key.len..];
    return rest.len >= 3 and rest[0] == ' ' and rest[1] == '=' and rest[2] == ' ';
}

fn appendBlock(arena: std.mem.Allocator, src: []const u8, block: []const u8) ![]const u8 {
    if (src.len == 0) return arena.dupe(u8, block);
    if (src[src.len - 1] == '\n') {
        if (src.len > 1 and src[src.len - 2] == '\n') {
            return std.fmt.allocPrint(arena, "{s}{s}", .{ src, block });
        }
        return std.fmt.allocPrint(arena, "{s}\n{s}", .{ src, block });
    }
    return std.fmt.allocPrint(arena, "{s}\n\n{s}", .{ src, block });
}

fn splice(arena: std.mem.Allocator, src: []const u8, start: usize, end: usize, mid: []const u8) ![]const u8 {
    return std.fmt.allocPrint(arena, "{s}{s}{s}", .{ src[0..start], mid, src[end..] });
}

fn ensureTrailingNewline(block: []const u8) []const u8 {
    if (block.len > 0 and block[block.len - 1] == '\n') return block;
    // Callers always pass a trailing newline from renderModelSnippet; keep
    // this as a last-resort no-op rather than allocating here.
    return block;
}

fn escapeTomlString(arena: std.mem.Allocator, value: []const u8) []const u8 {
    var need: usize = 0;
    for (value) |c| {
        need += if (c == '"' or c == '\\') @as(usize, 2) else 1;
    }
    if (need == value.len) return value;
    var out = arena.alloc(u8, need) catch return value;
    var i: usize = 0;
    for (value) |c| {
        if (c == '"' or c == '\\') {
            out[i] = '\\';
            i += 1;
        }
        out[i] = c;
        i += 1;
    }
    return out;
}

test "replaceTable replaces an existing table and leaves comments" {
    const src =
        \\# keep me
        \\[models."a/x"]
        \\provider = "a"
        \\max_tokens = 1
        \\
        \\[agent]
        \\max_iterations = 4
        \\
    ;
    const block =
        \\[models."a/x"]
        \\provider = "a"
        \\max_tokens = 99
        \\
    ;
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const out = try replaceTable(arena_state.allocator(), src, block);
    try std.testing.expect(std.mem.startsWith(u8, out, "# keep me\n"));
    try std.testing.expect(std.mem.indexOf(u8, out, "max_tokens = 99") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "max_tokens = 1") == null);
    try std.testing.expect(std.mem.indexOf(u8, out, "[agent]\nmax_iterations = 4") != null);
}

test "replaceTable appends a missing table" {
    const src =
        \\[agent]
        \\max_iterations = 4
        \\
    ;
    const block =
        \\[models."a/x"]
        \\provider = "a"
        \\
    ;
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const out = try replaceTable(arena_state.allocator(), src, block);
    try std.testing.expect(std.mem.indexOf(u8, out, "[agent]\nmax_iterations = 4") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "[models.\"a/x\"]") != null);
}

test "setTopLevelString inserts before the first table" {
    const src =
        \\# comment
        \\[agent]
        \\max_iterations = 4
        \\
    ;
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const out = try setTopLevelString(arena_state.allocator(), src, "default_provider", "ollama");
    try std.testing.expect(std.mem.indexOf(u8, out, "default_provider = \"ollama\"\n[agent]") != null);
    try std.testing.expect(std.mem.startsWith(u8, out, "# comment\n"));
}

test "setTopLevelString replaces an existing key in place" {
    const src =
        \\default_provider = "old"
        \\[agent]
        \\
    ;
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const out = try setTopLevelString(arena_state.allocator(), src, "default_provider", "new");
    try std.testing.expectEqualStrings("default_provider = \"new\"\n[agent]\n", out);
}

test "replaceTable last matching header wins" {
    const src =
        \\[models."a/x"]
        \\provider = "first"
        \\
        \\[models."a/x"]
        \\provider = "second"
        \\
    ;
    const block =
        \\[models."a/x"]
        \\provider = "third"
        \\
    ;
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const out = try replaceTable(arena_state.allocator(), src, block);
    try std.testing.expect(std.mem.indexOf(u8, out, "provider = \"first\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "provider = \"second\"") == null);
    try std.testing.expect(std.mem.indexOf(u8, out, "provider = \"third\"") != null);
}
