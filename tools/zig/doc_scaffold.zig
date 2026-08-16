//! Pure document-scaffolding logic shared by the `research` and `rfc` guests.
//!
//! This module imports nothing from the guest ABI (lib.zig), so it compiles on
//! the host and its `test` blocks actually run in `zig build test` — the
//! pure-tool list in build.zig is what registers it.
//!
//! What lives here is everything that can be decided without touching the
//! filesystem or the network: the template placeholder substitution, the
//! number a new numbered document gets, the Markdown section arithmetic the
//! status/recommendation edits need, and the inventory insertion both indexes
//! use. Keeping it host-testable is the point — a wrong section boundary
//! silently corrupts a document, and that is exactly the class of bug a
//! wasm-only helper can never be tested for.

const std = @import("std");

// ---------------------------------------------------------------- dates

pub const Civil = struct { year: i64, month: u8, day: u8 };

/// Days since the Unix epoch to a civil date (Howard Hinnant's
/// `civil_from_days`). UTC, not local time: a document dated by whichever
/// machine wrote it is worse than one dated consistently.
pub fn civilFromUnix(unix_seconds: i64) Civil {
    const seconds_per_day: i64 = 86_400;
    var days = @divFloor(unix_seconds, seconds_per_day);

    days += 719_468;
    const era = @divFloor(days, 146_097);
    const doe = days - era * 146_097;
    const yoe = @divTrunc(doe - @divTrunc(doe, 1460) + @divTrunc(doe, 36524) - @divTrunc(doe, 146096), 365);
    const y = yoe + era * 400;
    const doy = doe - (365 * yoe + @divTrunc(yoe, 4) - @divTrunc(yoe, 100));
    const mp = @divTrunc(5 * doy + 2, 153);
    const d = doy - @divTrunc(153 * mp + 2, 5) + 1;
    const m = mp + (if (mp < 10) @as(i64, 3) else @as(i64, -9));

    return .{
        .year = y + @intFromBool(m <= 2),
        .month = @intCast(m),
        .day = @intCast(d),
    };
}

/// `YYYY-MM-DD` into `buf`, which must hold at least 10 bytes.
pub fn isoDate(unix_seconds: i64, buf: []u8) []const u8 {
    const c = civilFromUnix(unix_seconds);
    // Formatted through an unsigned year: a signed integer prints a leading
    // `+` under a width specifier, which would put a `+` in every date.
    const year: u32 = if (c.year < 0) 0 else @intCast(c.year);
    return std.fmt.bufPrint(buf, "{d:0>4}-{d:0>2}-{d:0>2}", .{ year, c.month, c.day }) catch buf[0..0];
}

// ---------------------------------------------------------------- slugs

/// Filename stems are lowercase letters, digits and single hyphens. The
/// alphabet is deliberately narrower than the filesystem's: these names end up
/// in Markdown links, index entries, and shell arguments.
pub fn isSlug(slug: []const u8) bool {
    if (slug.len == 0 or slug.len > 72) return false;
    if (slug[0] == '-' or slug[slug.len - 1] == '-') return false;
    for (slug) |c| {
        if (!(std.ascii.isLower(c) or std.ascii.isDigit(c) or c == '-')) return false;
    }
    return true;
}

/// Derives a slug from a title so `create` can be called with a title alone.
/// Everything outside the slug alphabet collapses to a single hyphen, and the
/// result is cut at `max` bytes on a hyphen boundary rather than mid-word.
pub fn slugify(title: []const u8, buf: []u8, max: usize) []const u8 {
    var n: usize = 0;
    const cap = @min(buf.len, max);
    var pending_sep = false;
    var truncated = false;
    for (title) |raw| {
        const c = std.ascii.toLower(raw);
        const keep = std.ascii.isLower(c) or std.ascii.isDigit(c);
        if (!keep) {
            if (n > 0) pending_sep = true;
            continue;
        }
        if (pending_sep) {
            if (n + 1 >= cap) {
                truncated = true;
                break;
            }
            buf[n] = '-';
            n += 1;
            pending_sep = false;
        }
        if (n >= cap) {
            truncated = true;
            break;
        }
        buf[n] = c;
        n += 1;
    }
    // A slug cut mid-word reads as a different word ("one-two-t"), so drop the
    // partial trailing word rather than keeping a misleading fragment.
    if (truncated) {
        if (std.mem.lastIndexOfScalar(u8, buf[0..n], '-')) |last| n = last;
    }
    while (n > 0 and buf[n - 1] == '-') n -= 1;
    return buf[0..n];
}

// ------------------------------------------------------------- numbering

/// The `NNNN` prefix of a numbered document name, or null when it has none.
/// Requires at least four digits followed by a hyphen, so `0001-x.md` counts
/// and `2026-08-14-x.md` (a dated report slug) does not become RFC 2026.
pub fn leadingNumber(name: []const u8) ?u32 {
    if (name.len < 5) return null;
    var digits: usize = 0;
    while (digits < name.len and std.ascii.isDigit(name[digits])) digits += 1;
    if (digits < 4 or digits > 6) return null;
    if (name[digits] != '-') return null;
    // A second date-shaped group means this is a date, not a document number.
    if (digits == 4 and name.len >= 8 and std.ascii.isDigit(name[5]) and std.ascii.isDigit(name[6]) and name[7] == '-') return null;
    return std.fmt.parseInt(u32, name[0..digits], 10) catch null;
}

/// One past the highest number already taken, so a deleted document never
/// hands its number to a different one.
pub fn nextNumber(names: []const []const u8) u32 {
    var highest: u32 = 0;
    for (names) |name| {
        if (!std.mem.endsWith(u8, name, ".md")) continue;
        const n = leadingNumber(name) orelse continue;
        if (n > highest) highest = n;
    }
    return highest + 1;
}

/// README.md and TEMPLATE.md are scaffolding, not documents: they must never
/// appear in a listing, an inventory, or a "which one should I read" answer.
pub fn isDocFile(name: []const u8) bool {
    if (!std.mem.endsWith(u8, name, ".md")) return false;
    if (std.mem.eql(u8, name, "README.md")) return false;
    if (std.mem.eql(u8, name, "TEMPLATE.md")) return false;
    return true;
}

/// A path is acceptable when it sits directly below `dir`, ends in `.md`, and
/// contains no traversal. The sandbox enforces its own prefix policy; this is
/// the tool refusing to write somewhere its own conventions do not describe.
pub fn isPathIn(dir: []const u8, path: []const u8) bool {
    if (!std.mem.endsWith(u8, path, ".md")) return false;
    if (!std.mem.startsWith(u8, path, dir)) return false;
    if (path.len <= dir.len or path[dir.len] != '/') return false;
    const rest = path[dir.len + 1 ..];
    if (rest.len == 0) return false;
    if (std.mem.find(u8, rest, "/") != null) return false;
    if (std.mem.find(u8, rest, "..") != null) return false;
    return true;
}

// -------------------------------------------------------------- templates

pub const Var = struct { name: []const u8, value: []const u8 };

/// Substitutes `{{name}}` occurrences from `vars`. A placeholder with no
/// matching variable is left verbatim: a typo in the template should be
/// visible in the rendered document, not silently swallowed.
pub fn fillTemplate(w: *std.Io.Writer, template: []const u8, vars: []const Var) !void {
    var i: usize = 0;
    while (i < template.len) {
        const open = std.mem.findPos(u8, template, i, "{{") orelse {
            try w.writeAll(template[i..]);
            return;
        };
        try w.writeAll(template[i..open]);
        const close = std.mem.findPos(u8, template, open + 2, "}}") orelse {
            try w.writeAll(template[open..]);
            return;
        };
        const name = template[open + 2 .. close];
        const found = for (vars) |v| {
            if (std.mem.eql(u8, v.name, name)) break v.value;
        } else null;
        if (found) |value| {
            try w.writeAll(value);
        } else {
            try w.writeAll(template[open .. close + 2]);
        }
        i = close + 2;
    }
}

// ------------------------------------------------------- markdown sections

pub const Section = struct {
    /// Byte offset of the heading line itself.
    heading: usize,
    /// Byte offset just past the heading line's newline.
    body_start: usize,
    /// Byte offset of the next heading of the same or higher level (or EOF).
    body_end: usize,
};

/// Locates a `## Heading` section. `heading` is matched in full including its
/// hashes, at the start of a line, and the body runs to the next line that
/// starts with `#` at the same or a higher level.
pub fn findSection(text: []const u8, heading: []const u8) ?Section {
    var level: usize = 0;
    while (level < heading.len and heading[level] == '#') level += 1;
    if (level == 0) return null;

    var at: usize = 0;
    const start = while (true) {
        const hit = std.mem.findPos(u8, text, at, heading) orelse return null;
        const line_start = hit == 0 or text[hit - 1] == '\n';
        const rest = text[hit + heading.len ..];
        const line_end = rest.len == 0 or rest[0] == '\n' or rest[0] == '\r';
        if (line_start and line_end) break hit;
        at = hit + 1;
    };

    const nl = std.mem.findPos(u8, text, start, "\n") orelse text.len;
    const body_start = @min(nl + 1, text.len);

    var scan = body_start;
    const body_end = while (scan < text.len) {
        const line_end = std.mem.findPos(u8, text, scan, "\n") orelse text.len;
        const line = text[scan..line_end];
        var hashes: usize = 0;
        while (hashes < line.len and line[hashes] == '#') hashes += 1;
        if (hashes > 0 and hashes <= level and hashes < line.len and line[hashes] == ' ') break scan;
        scan = @min(line_end + 1, text.len);
        if (line_end >= text.len) break text.len;
    } else text.len;

    return .{ .heading = start, .body_start = body_start, .body_end = body_end };
}

/// The first non-blank line of a section's body, trimmed. Empty when the
/// section is missing or blank.
pub fn firstLineOf(text: []const u8, heading: []const u8) []const u8 {
    const sec = findSection(text, heading) orelse return "";
    var scan = sec.body_start;
    while (scan < sec.body_end) {
        const line_end = std.mem.findPos(u8, text, scan, "\n") orelse sec.body_end;
        const line = std.mem.trim(u8, text[scan..@min(line_end, sec.body_end)], " \t\r");
        if (line.len > 0) return line;
        scan = line_end + 1;
    }
    return "";
}

/// The document's `# ` title, without the hashes. Empty when there is none.
pub fn documentTitle(text: []const u8) []const u8 {
    var scan: usize = 0;
    while (scan < text.len) {
        const line_end = std.mem.findPos(u8, text, scan, "\n") orelse text.len;
        const line = std.mem.trim(u8, text[scan..line_end], " \t\r");
        if (std.mem.startsWith(u8, line, "# ")) return std.mem.trim(u8, line[2..], " \t");
        scan = line_end + 1;
    }
    return "";
}

/// The status word of a document whose Status section starts with one, e.g.
/// `Draft — opened 2026-08-15.` → `Draft`. Used for index entries, so it stops
/// at the first separator rather than carrying a whole sentence into a table.
pub fn statusWord(text: []const u8) []const u8 {
    const line = firstLineOf(text, "## Status");
    if (line.len == 0) return "";
    var end: usize = 0;
    while (end < line.len) {
        const c = line[end];
        if (c == ' ' or c == '\t' or c == ',' or c == '.' or c == ':') break;
        // Stop at the em dash (a three-byte UTF-8 sequence) too.
        if (c == 0xE2 and end + 2 < line.len and line[end + 1] == 0x80 and line[end + 2] == 0x94) break;
        end += 1;
    }
    return line[0..end];
}

/// Replaces a section's body wholesale. Returns false when the heading is
/// absent, so the caller can say which heading it wanted rather than writing
/// the replacement into the wrong place.
pub fn replaceSection(w: *std.Io.Writer, text: []const u8, heading: []const u8, body: []const u8) !bool {
    const sec = findSection(text, heading) orelse return false;
    try w.writeAll(text[0..sec.body_start]);
    try w.writeAll(body);
    try w.writeAll(text[sec.body_end..]);
    return true;
}

/// Replaces only the first non-blank line of a section, keeping the prose that
/// explains the section underneath it. This is what a status change wants: the
/// state changes, the explanation of what the state means does not.
pub fn replaceFirstLine(w: *std.Io.Writer, text: []const u8, heading: []const u8, line: []const u8) !bool {
    const sec = findSection(text, heading) orelse return false;
    var scan = sec.body_start;
    while (scan < sec.body_end) {
        const line_end = std.mem.findPos(u8, text, scan, "\n") orelse sec.body_end;
        const trimmed = std.mem.trim(u8, text[scan..@min(line_end, sec.body_end)], " \t\r");
        if (trimmed.len > 0) {
            try w.writeAll(text[0..scan]);
            try w.writeAll(line);
            try w.writeAll(text[@min(line_end, sec.body_end)..]);
            return true;
        }
        scan = line_end + 1;
    }
    // A blank section: the new line becomes its whole body.
    try w.writeAll(text[0..sec.body_start]);
    try w.writeAll(line);
    try w.writeAll("\n");
    try w.writeAll(text[sec.body_start..]);
    return true;
}

/// Walks the sub-headings inside one section, e.g. every `### ` option under
/// `## Options found`. Used to carry a research note's candidate list into an
/// RFC as stubs, which is why it yields the heading text only: the body is the
/// note's claim, and it has to be re-checked before it becomes an RFC's.
pub const SubHeadings = struct {
    text: []const u8,
    pos: usize,
    end: usize,
    prefix: []const u8,

    pub fn next(self: *SubHeadings) ?[]const u8 {
        while (self.pos < self.end) {
            const line_end = std.mem.findPos(u8, self.text, self.pos, "\n") orelse self.end;
            const line = std.mem.trim(u8, self.text[self.pos..@min(line_end, self.end)], " \t\r");
            self.pos = line_end + 1;
            if (std.mem.startsWith(u8, line, self.prefix)) {
                const title = std.mem.trim(u8, line[self.prefix.len..], " \t");
                if (title.len > 0) return title;
            }
        }
        return null;
    }
};

pub fn subHeadings(text: []const u8, heading: []const u8, prefix: []const u8) SubHeadings {
    const sec = findSection(text, heading) orelse return .{ .text = text, .pos = 0, .end = 0, .prefix = prefix };
    return .{ .text = text, .pos = sec.body_start, .end = sec.body_end, .prefix = prefix };
}

// ------------------------------------------------------------- edit splices

pub const SpliceError = error{
    /// `old` does not occur in the document.
    NotFound,
    /// `old` occurs more than once, so replacing "it" would be a guess.
    Ambiguous,
};

/// Replaces the single occurrence of `old` with `new`. Requiring uniqueness is
/// the point: a document is full of repeated headings and status lines, and an
/// agent that means the third one has no way to say so except by including
/// enough surrounding text to be unambiguous.
pub fn spliceReplace(w: *std.Io.Writer, text: []const u8, old: []const u8, new: []const u8) !void {
    if (old.len == 0) return SpliceError.NotFound;
    const start = std.mem.find(u8, text, old) orelse return SpliceError.NotFound;
    if (std.mem.findPos(u8, text, start + old.len, old) != null) return SpliceError.Ambiguous;
    try w.writeAll(text[0..start]);
    try w.writeAll(new);
    try w.writeAll(text[start + old.len ..]);
}

/// Appends a block to a document, guaranteeing the newline between them that a
/// hand-built concatenation forgets exactly once and then silently welds two
/// Markdown blocks into one paragraph.
pub fn appendBlock(w: *std.Io.Writer, text: []const u8, content: []const u8) !void {
    try w.writeAll(text);
    if (text.len > 0 and text[text.len - 1] != '\n') try w.writeByte('\n');
    try w.writeAll(content);
}

// -------------------------------------------------------------- inventory

/// Inserts `entry` at the top of the `<!-- inventory:kind:start -->` block of
/// an index file, dropping the "none yet" placeholder if that is all that is
/// there. Returns false when the markers are missing, which the caller reports
/// rather than guessing where the list belongs.
pub fn insertInventory(
    w: *std.Io.Writer,
    index: []const u8,
    start_marker: []const u8,
    end_marker: []const u8,
    entry: []const u8,
) !bool {
    const start = std.mem.find(u8, index, start_marker) orelse return false;
    const content_start = start + start_marker.len;
    const end = std.mem.findPos(u8, index, content_start, end_marker) orelse return false;
    const previous = std.mem.trim(u8, index[content_start..end], " \t\r\n");

    try w.writeAll(index[0..content_start]);
    try w.writeAll("\n");
    try w.writeAll(entry);
    try w.writeAll("\n");
    if (previous.len > 0 and !isEmptyPlaceholder(previous)) {
        try w.writeAll(previous);
        try w.writeAll("\n");
    }
    try w.writeAll(index[end..]);
    return true;
}

/// A single line that is not a list item is the "nothing here yet" text a
/// fresh index ships with; replacing it is the point of the first insert.
fn isEmptyPlaceholder(previous: []const u8) bool {
    if (std.mem.startsWith(u8, previous, "- ")) return false;
    return std.mem.find(u8, previous, "\n") == null;
}

/// The separator between an inventory entry's title and its status field.
const em_dash = "\u{2014}";

pub const InventoryEntry = struct {
    /// Link target of the entry's first Markdown link, e.g. `bugs/foo.md`.
    target: []const u8,
    /// Offset of the em dash that introduces the status field, or null when
    /// the entry carries no status yet.
    status_start: ?usize,
};

/// Splits one `- [Title](link) — Status` inventory line. The status separator
/// is looked for *after* the link rather than at the first em dash, so a title
/// that contains one is not mistaken for it.
pub fn inventoryEntry(line: []const u8) ?InventoryEntry {
    const open = std.mem.find(u8, line, "](") orelse return null;
    const close = std.mem.findPos(u8, line, open + 2, ")") orelse return null;
    const target = line[open + 2 .. close];
    if (target.len == 0) return null;
    return .{ .target = target, .status_start = std.mem.findPos(u8, line, close + 1, em_dash) };
}

/// Rewrites the status field of the inventory entry linking to `target`.
///
/// An index status is a second copy of the record's own `## Status` line, and
/// a second copy that only `create` ever writes is a copy that is wrong from
/// the first status change onwards. Every writer of the record's status calls
/// this so the two move together. Returns false when the markers or the entry
/// are absent — the caller reports that rather than guessing which row it
/// meant, since rewriting the wrong row is worse than leaving the index stale.
pub fn setInventoryStatus(
    w: *std.Io.Writer,
    index: []const u8,
    start_marker: []const u8,
    end_marker: []const u8,
    target: []const u8,
    status: []const u8,
) !bool {
    const start = std.mem.find(u8, index, start_marker) orelse return false;
    const content_start = start + start_marker.len;
    const end = std.mem.findPos(u8, index, content_start, end_marker) orelse return false;

    var scan = content_start;
    while (scan < end) {
        const line_end = @min(std.mem.findPos(u8, index, scan, "\n") orelse end, end);
        const line = index[scan..line_end];
        const entry = inventoryEntry(line) orelse {
            scan = line_end + 1;
            continue;
        };
        if (!std.mem.eql(u8, entry.target, target)) {
            scan = line_end + 1;
            continue;
        }
        try w.writeAll(index[0..scan]);
        if (entry.status_start) |at| {
            try w.writeAll(line[0..at]);
        } else {
            try w.writeAll(std.mem.trimEnd(u8, line, " \t\r"));
            try w.writeAll(" ");
        }
        try w.writeAll(em_dash);
        try w.writeAll(" ");
        try w.writeAll(status);
        try w.writeAll(index[line_end..]);
        return true;
    }
    return false;
}

// ------------------------------------------------------------------ tests

test "isoDate renders the epoch, a leap day, and a late date" {
    var buf: [16]u8 = undefined;
    try std.testing.expectEqualStrings("1970-01-01", isoDate(0, &buf));
    try std.testing.expectEqualStrings("2024-02-29", isoDate(1_709_164_800, &buf));
    try std.testing.expectEqualStrings("2026-08-16", isoDate(1_786_838_400, &buf));
}

test "isSlug accepts the documented alphabet and nothing else" {
    try std.testing.expect(isSlug("embedded-kv-stores"));
    try std.testing.expect(isSlug("zig016"));
    try std.testing.expect(!isSlug(""));
    try std.testing.expect(!isSlug("-leading"));
    try std.testing.expect(!isSlug("trailing-"));
    try std.testing.expect(!isSlug("Has-Caps"));
    try std.testing.expect(!isSlug("has space"));
    try std.testing.expect(!isSlug("has/slash"));
}

test "slugify derives a slug and cuts on a hyphen boundary" {
    var buf: [64]u8 = undefined;
    try std.testing.expectEqualStrings("http-client-for-the-proxy", slugify("HTTP client for the proxy", &buf, 64));
    try std.testing.expectEqualStrings("a-b", slugify("  a -- b!! ", &buf, 64));
    try std.testing.expectEqualStrings("one-two", slugify("one two three", &buf, 9));
    try std.testing.expect(isSlug(slugify("Zig 0.16: std.Io — what changed?", &buf, 64)));
}

test "leadingNumber reads a document number but not a date" {
    try std.testing.expectEqual(@as(?u32, 1), leadingNumber("0001-thing.md"));
    try std.testing.expectEqual(@as(?u32, 42), leadingNumber("0042-thing.md"));
    try std.testing.expectEqual(@as(?u32, null), leadingNumber("2026-08-14-thing.md"));
    try std.testing.expectEqual(@as(?u32, null), leadingNumber("thing.md"));
    try std.testing.expectEqual(@as(?u32, null), leadingNumber("README.md"));
}

test "nextNumber skips non-documents and never reuses a number" {
    const names = [_][]const u8{ "0001-a.md", "0003-c.md", "README.md", "TEMPLATE.md", "notes.txt" };
    try std.testing.expectEqual(@as(u32, 4), nextNumber(&names));
    try std.testing.expectEqual(@as(u32, 1), nextNumber(&.{}));
}

test "isDocFile excludes the index and the template" {
    try std.testing.expect(isDocFile("0001-a.md"));
    try std.testing.expect(!isDocFile("README.md"));
    try std.testing.expect(!isDocFile("TEMPLATE.md"));
    try std.testing.expect(!isDocFile("a.txt"));
}

test "isPathIn accepts a direct child and refuses traversal" {
    try std.testing.expect(isPathIn("docs/rfcs", "docs/rfcs/0001-a.md"));
    try std.testing.expect(!isPathIn("docs/rfcs", "docs/rfcs/sub/0001-a.md"));
    try std.testing.expect(!isPathIn("docs/rfcs", "docs/rfcs/../adrs/0001-a.md"));
    try std.testing.expect(!isPathIn("docs/rfcs", "docs/research/a.md"));
    try std.testing.expect(!isPathIn("docs/rfcs", "docs/rfcs/a.txt"));
    try std.testing.expect(!isPathIn("docs/rfcs", "docs/rfcs/"));
}

test "fillTemplate substitutes known names and leaves unknown ones visible" {
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    try fillTemplate(&out.writer, "# RFC {{number}} — {{title}}\n{{mystery}}\n", &.{
        .{ .name = "number", .value = "0007" },
        .{ .name = "title", .value = "Pick a client" },
    });
    try std.testing.expectEqualStrings("# RFC 0007 — Pick a client\n{{mystery}}\n", out.written());
}

test "fillTemplate tolerates an unterminated placeholder" {
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    try fillTemplate(&out.writer, "a {{b", &.{.{ .name = "b", .value = "x" }});
    try std.testing.expectEqualStrings("a {{b", out.written());
}

const sample_doc =
    \\# RFC 0001 — Thing
    \\
    \\## Status
    \\
    \\Draft — opened 2026-08-15.
    \\
    \\An RFC is a request for comment.
    \\
    \\## Overview
    \\
    \\Body text.
    \\
    \\### Nested
    \\
    \\Still overview.
    \\
    \\## Recommendation
    \\
    \\Placeholder.
    \\
    \\## References
    \\
    \\- none
    \\
;

test "findSection stops at the next same-level heading, not a nested one" {
    const sec = findSection(sample_doc, "## Overview").?;
    const body = sample_doc[sec.body_start..sec.body_end];
    try std.testing.expect(std.mem.find(u8, body, "Still overview.") != null);
    try std.testing.expect(std.mem.find(u8, body, "Placeholder.") == null);
}

test "findSection does not match a heading that is only a prefix" {
    try std.testing.expect(findSection(sample_doc, "## Ref") == null);
    try std.testing.expect(findSection(sample_doc, "## Missing") == null);
}

test "documentTitle and statusWord read the header" {
    try std.testing.expectEqualStrings("RFC 0001 — Thing", documentTitle(sample_doc));
    try std.testing.expectEqualStrings("Draft", statusWord(sample_doc));
    try std.testing.expectEqualStrings("", statusWord("# No status here\n"));
}

test "replaceSection swaps a whole body and leaves neighbours intact" {
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    try std.testing.expect(try replaceSection(&out.writer, sample_doc, "## Recommendation", "\nOption A, confidence 7/10.\n\n"));
    const text = out.written();
    try std.testing.expect(std.mem.find(u8, text, "Option A, confidence 7/10.") != null);
    try std.testing.expect(std.mem.find(u8, text, "Placeholder.") == null);
    try std.testing.expect(std.mem.find(u8, text, "## References") != null);
    try std.testing.expect(std.mem.find(u8, text, "Draft — opened 2026-08-15.") != null);
}

test "replaceSection reports a missing heading instead of writing blind" {
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    try std.testing.expect(!try replaceSection(&out.writer, sample_doc, "## Nowhere", "x"));
}

test "replaceFirstLine changes the status but keeps its explanation" {
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    try std.testing.expect(try replaceFirstLine(&out.writer, sample_doc, "## Status", "Decided — 2026-09-01."));
    const text = out.written();
    try std.testing.expect(std.mem.find(u8, text, "Decided — 2026-09-01.") != null);
    try std.testing.expect(std.mem.find(u8, text, "Draft — opened") == null);
    try std.testing.expect(std.mem.find(u8, text, "An RFC is a request for comment.") != null);
    try std.testing.expectEqualStrings("Decided", statusWord(text));
}

test "subHeadings yields only the named section's sub-headings" {
    const note =
        \\# Research — Thing
        \\
        \\## Options found
        \\
        \\### sled — embedded KV
        \\
        \\text
        \\
        \\### redb
        \\
        \\text
        \\
        \\## Out-of-the-box options
        \\
        \\### do nothing
        \\
    ;
    var it = subHeadings(note, "## Options found", "### ");
    try std.testing.expectEqualStrings("sled — embedded KV", it.next().?);
    try std.testing.expectEqualStrings("redb", it.next().?);
    try std.testing.expect(it.next() == null);
}

test "subHeadings on a missing section yields nothing" {
    var it = subHeadings("# Doc\n", "## Options found", "### ");
    try std.testing.expect(it.next() == null);
}

test "spliceReplace refuses a missing or repeated target" {
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    try std.testing.expectError(SpliceError.NotFound, spliceReplace(&out.writer, "abc", "z", "y"));
    try std.testing.expectError(SpliceError.Ambiguous, spliceReplace(&out.writer, "a b a", "a", "c"));
    try std.testing.expectError(SpliceError.NotFound, spliceReplace(&out.writer, "abc", "", "y"));
}

test "spliceReplace swaps the one occurrence and can delete it" {
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    try spliceReplace(&out.writer, "status: draft\n", "draft", "decided");
    try std.testing.expectEqualStrings("status: decided\n", out.written());

    var gone: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer gone.deinit();
    try spliceReplace(&gone.writer, "keep  drop", "  drop", "");
    try std.testing.expectEqualStrings("keep", gone.written());
}

test "appendBlock inserts the separating newline only when it is missing" {
    var with: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer with.deinit();
    try appendBlock(&with.writer, "# Doc\n", "## New\n");
    try std.testing.expectEqualStrings("# Doc\n## New\n", with.written());

    var without: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer without.deinit();
    try appendBlock(&without.writer, "# Doc", "## New\n");
    try std.testing.expectEqualStrings("# Doc\n## New\n", without.written());
}

test "insertInventory prepends an entry and drops the placeholder" {
    const index = "## Inventory\n\n<!-- inventory:rfc:start -->\nNo RFCs yet.\n<!-- inventory:rfc:end -->\n";
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    try std.testing.expect(try insertInventory(&out.writer, index, "<!-- inventory:rfc:start -->", "<!-- inventory:rfc:end -->", "- [A](0001-a.md) — Draft"));
    try std.testing.expectEqualStrings(
        "## Inventory\n\n<!-- inventory:rfc:start -->\n- [A](0001-a.md) — Draft\n<!-- inventory:rfc:end -->\n",
        out.written(),
    );
}

test "insertInventory keeps existing entries below the new one" {
    const index = "<!-- inventory:rfc:start -->\n- [A](0001-a.md) — Draft\n<!-- inventory:rfc:end -->\n";
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    try std.testing.expect(try insertInventory(&out.writer, index, "<!-- inventory:rfc:start -->", "<!-- inventory:rfc:end -->", "- [B](0002-b.md) — Draft"));
    try std.testing.expectEqualStrings(
        "<!-- inventory:rfc:start -->\n- [B](0002-b.md) — Draft\n- [A](0001-a.md) — Draft\n<!-- inventory:rfc:end -->\n",
        out.written(),
    );
}

test "insertInventory reports missing markers" {
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    try std.testing.expect(!try insertInventory(&out.writer, "# Index\n", "<!-- inventory:rfc:start -->", "<!-- inventory:rfc:end -->", "- x"));
}

test "inventoryEntry reads the link and the status separator after it" {
    const entry = inventoryEntry("- [A title — with a dash](bugs/a.md) — Open").?;
    try std.testing.expectEqualStrings("bugs/a.md", entry.target);
    try std.testing.expectEqualStrings("— Open", "- [A title — with a dash](bugs/a.md) — Open"[entry.status_start.?..]);

    const bare = inventoryEntry("- [No status](bugs/b.md)").?;
    try std.testing.expectEqualStrings("bugs/b.md", bare.target);
    try std.testing.expect(bare.status_start == null);

    try std.testing.expect(inventoryEntry("just prose") == null);
}

test "setInventoryStatus rewrites only the matching entry" {
    const index =
        "<!-- inventory:bug:start -->\n" ++
        "- [First](bugs/a.md) — Open\n" ++
        "\n" ++
        "- [Second](bugs/b.md) — Open\n" ++
        "<!-- inventory:bug:end -->\n";
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    try std.testing.expect(try setInventoryStatus(&out.writer, index, "<!-- inventory:bug:start -->", "<!-- inventory:bug:end -->", "bugs/b.md", "Resolved"));
    try std.testing.expectEqualStrings(
        "<!-- inventory:bug:start -->\n" ++
            "- [First](bugs/a.md) — Open\n" ++
            "\n" ++
            "- [Second](bugs/b.md) — Resolved\n" ++
            "<!-- inventory:bug:end -->\n",
        out.written(),
    );
}

test "setInventoryStatus keeps an em dash that belongs to the title" {
    const index = "<!-- s -->\n- [Run — never finishes](investigations/x.md) — Investigating\n<!-- e -->\n";
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    try std.testing.expect(try setInventoryStatus(&out.writer, index, "<!-- s -->", "<!-- e -->", "investigations/x.md", "Resolved"));
    try std.testing.expectEqualStrings(
        "<!-- s -->\n- [Run — never finishes](investigations/x.md) — Resolved\n<!-- e -->\n",
        out.written(),
    );
}

test "setInventoryStatus adds a status field to an entry without one" {
    const index = "<!-- s -->\n- [Bare](a.md)\n<!-- e -->\n";
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    try std.testing.expect(try setInventoryStatus(&out.writer, index, "<!-- s -->", "<!-- e -->", "a.md", "Current"));
    try std.testing.expectEqualStrings("<!-- s -->\n- [Bare](a.md) — Current\n<!-- e -->\n", out.written());
}

test "setInventoryStatus reports an entry or markers it cannot find" {
    const index = "<!-- s -->\n- [A](a.md) — Draft\n<!-- e -->\n";
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    try std.testing.expect(!try setInventoryStatus(&out.writer, index, "<!-- s -->", "<!-- e -->", "missing.md", "Current"));
    try std.testing.expect(!try setInventoryStatus(&out.writer, "# Index\n", "<!-- s -->", "<!-- e -->", "a.md", "Current"));
}

test "setInventoryStatus does not reach past the end marker" {
    const index = "<!-- s -->\n- [A](a.md) — Draft\n<!-- e -->\n- [B](b.md) — Draft\n";
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    try std.testing.expect(!try setInventoryStatus(&out.writer, index, "<!-- s -->", "<!-- e -->", "b.md", "Current"));
}
