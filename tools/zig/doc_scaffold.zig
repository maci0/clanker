//! Pure document-scaffolding logic shared by the record-store guests
//! (`research`, `rfc`, `adr`, `prd`, `reports` and `records_grep`).
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

/// The epoch↔civil conversion lives in one place, the schedule dialect's
/// `schedule_cron.zig` (Howard Hinnant's `civil_from_days`, fuzzed by
/// `zig build test`); a document date is that same conversion read as UTC, so
/// this module holds no second copy that could drift.
const cron = @import("schedule_cron.zig");

pub const Civil = struct { year: i64, month: u8, day: u8 };

/// Days since the Unix epoch to a civil date. UTC, not local time: a document
/// dated by whichever machine wrote it is worse than one dated consistently.
pub fn civilFromUnix(unix_seconds: i64) Civil {
    const c = cron.civilFromEpoch(unix_seconds);
    return .{ .year = c.year, .month = c.month, .day = c.day };
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
        if (std.mem.findScalarLast(u8, buf[0..n], '-')) |last| n = last;
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

/// How much of a record a listing has to read. `documentTitle` wants the `# `
/// line and `statusFrom` the `## Status` section, both of which sit in the
/// first few lines of every record in every store. Reading the whole document
/// instead costs a 1 MiB host-arena read plus a guest copy apiece, which is
/// what makes a listing over a store of long records run the guest arena out
/// and drop its later rows.
pub const header_read_bytes: usize = 4096;

/// README.md and TEMPLATE.md are scaffolding, not documents: they must never
/// appear in a listing, an inventory, or a "which one should I read" answer.
pub fn isDocFile(name: []const u8) bool {
    if (!std.mem.endsWith(u8, name, ".md")) return false;
    if (std.mem.eql(u8, name, "README.md")) return false;
    if (std.mem.eql(u8, name, "TEMPLATE.md")) return false;
    return true;
}

/// `isDocFile` for a whole path rather than a bare name. A grep over a store
/// reports paths, and the index is the worst offender: it names every record
/// it lists, so one real hit arrives with an inventory line stapled to it.
pub fn isDocPath(path: []const u8) bool {
    const slash = std.mem.findScalarLast(u8, path, '/') orelse return isDocFile(path);
    return isDocFile(path[slash + 1 ..]);
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

/// The status of a document whose vocabulary is a fixed set of phrases, some
/// of them more than one word.
///
/// `statusWord` cuts at the first space, so it reads "In progress" as "In" and
/// "**Web UI plugins: Shipped.**" as "**Web". A store with a two-word status
/// therefore needs its vocabulary passed in: the earliest phrase that occurs
/// in the Status line wins, which is what makes a sentence naming two statuses
/// resolve to the one it leads with. An unrecognized wording falls back to
/// `statusWord` rather than to an empty string — a row with a surprising
/// status is still worth listing, a row with none looks unreadable.
pub fn statusFrom(text: []const u8, vocabulary: []const []const u8) []const u8 {
    const line = firstLineOf(text, "## Status");
    if (line.len == 0) return "";
    var best: ?[]const u8 = null;
    var best_at: usize = std.math.maxInt(usize);
    for (vocabulary) |phrase| {
        const at = findIgnoreCase(line, phrase) orelse continue;
        if (at < best_at) {
            best_at = at;
            best = phrase;
        }
    }
    return best orelse statusWord(text);
}

/// The display spelling of a status a caller asked for, or null when it is not
/// in the store's vocabulary.
///
/// Paired with `statusFrom` so a store states its statuses once: the same table
/// decides what `status` will accept and what `list` can read back off a
/// record. Spelling them out twice is how `prd` came to read "Implemented" and
/// "Partial" in a listing while refusing to set either. The wire spelling is
/// matched loosely — case, and `_`/`-` for the space in a two-word phrase — so
/// `in_progress` reaches "In progress" without a second alias row.
pub fn labelFrom(wanted: []const u8, vocabulary: []const []const u8) ?[]const u8 {
    for (vocabulary) |phrase| {
        if (phrase.len != wanted.len) continue;
        var i: usize = 0;
        const same = while (i < phrase.len) : (i += 1) {
            const a = std.ascii.toLower(phrase[i]);
            const b = normalizeStatusByte(wanted[i]);
            if (a != b) break false;
        } else true;
        if (same) return phrase;
    }
    return null;
}

fn normalizeStatusByte(c: u8) u8 {
    return switch (c) {
        '_', '-' => ' ',
        else => std.ascii.toLower(c),
    };
}

fn findIgnoreCase(haystack: []const u8, needle: []const u8) ?usize {
    if (needle.len == 0 or needle.len > haystack.len) return null;
    var i: usize = 0;
    while (i + needle.len <= haystack.len) : (i += 1) {
        if (std.ascii.eqlIgnoreCase(haystack[i .. i + needle.len], needle)) return i;
    }
    return null;
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

/// Rewrites one `- **Field:** ...` bullet of the TL;DR block.
///
/// A record states its state in three places: this bullet, the `## Status`
/// section, and its inventory row. A status change used to write the last two,
/// so a fixed bug still opened with `- **Resolution:** Open.` — and the TL;DR
/// is the line every reader is told to trust first, which makes it the worst
/// of the three to leave stale.
///
/// Scoped to the TL;DR section on purpose: a long record quotes its own
/// bullets while explaining them, and only the summary at the top is the
/// record's state. Returns false when there is no TL;DR or no such bullet, so
/// the caller can report which rather than silently writing nothing.
pub fn replaceTldrField(w: *std.Io.Writer, text: []const u8, field: []const u8, value: []const u8) !bool {
    const found = findTldrField(text, field) orelse return false;
    try w.writeAll(text[0..found.value_start]);
    try w.writeAll(value);
    try w.writeAll(text[found.line_end..]);
    return true;
}

/// The current value of a TL;DR bullet, or null when there is none.
///
/// The caller that needs this is one deciding whether a bullet is still the
/// scaffold's placeholder. An investigation's `- **Finding:**` starts as
/// `Investigating.` and later holds the actual finding, which a status change
/// must never overwrite — so "is it still the placeholder" is the question,
/// not "does it exist".
pub fn tldrField(text: []const u8, field: []const u8) ?[]const u8 {
    const found = findTldrField(text, field) orelse return null;
    return std.mem.trim(u8, text[found.value_start..found.line_end], " \t\r");
}

/// The text of one `**Marker**`-led paragraph inside a section, or null when
/// the section, the marker, or any text after it is absent.
///
/// The caller that needs this is one rewriting a whole section from parts it
/// was only partly given: a field the caller did not pass has to keep what the
/// section already says, or the rewrite silently destroys an
/// operator-written paragraph. The marker must start its line, so a sentence
/// that merely quotes it does not match; the paragraph runs to its first
/// blank line or the section end, because wrapped prose is still one field.
pub fn fieldParagraph(text: []const u8, heading: []const u8, marker: []const u8) ?[]const u8 {
    const sec = findSection(text, heading) orelse return null;
    var scan = sec.body_start;
    while (scan < sec.body_end) {
        const line_end = @min(std.mem.findPos(u8, text, scan, "\n") orelse sec.body_end, sec.body_end);
        if (std.mem.startsWith(u8, text[scan..line_end], marker)) {
            var end = line_end;
            var next = line_end + 1;
            while (next < sec.body_end) {
                const next_end = @min(std.mem.findPos(u8, text, next, "\n") orelse sec.body_end, sec.body_end);
                if (std.mem.trim(u8, text[next..next_end], " \t\r").len == 0) break;
                end = next_end;
                next = next_end + 1;
            }
            const value = std.mem.trim(u8, text[@min(scan + marker.len, end)..end], " \t\r\n");
            return if (value.len == 0) null else value;
        }
        scan = line_end + 1;
    }
    return null;
}

const TldrField = struct { value_start: usize, line_end: usize };

fn findTldrField(text: []const u8, field: []const u8) ?TldrField {
    const sec = findSection(text, "## TL;DR") orelse return null;
    var marker_buf: [64]u8 = undefined;
    const marker = std.fmt.bufPrint(&marker_buf, "- **{s}:**", .{field}) catch return null;

    var scan = sec.body_start;
    while (scan < sec.body_end) {
        const line_end = @min(std.mem.findPos(u8, text, scan, "\n") orelse sec.body_end, sec.body_end);
        const line = text[scan..line_end];
        const indent = line.len - std.mem.trimStart(u8, line, " \t").len;
        if (std.mem.startsWith(u8, line[indent..], marker)) {
            const after = scan + indent + marker.len;
            // The space after the marker belongs to the separator, not the
            // value: a rewrite writes its own.
            //
            // A bullet's value runs to the end of its last continuation line,
            // not the end of the marker's own line: a wrapped bullet's
            // indented continuations are part of the value, and rewriting
            // only the first line leaves the old tail stacked under the new
            // value as two contradictory accounts. Continuation lines are
            // indented deeper than the bullet's marker; a blank line, a line
            // at the marker's own indent (the next bullet), or the section
            // end all stop it.
            var value_end = line_end;
            var next = line_end + 1;
            while (next < sec.body_end) {
                const next_end = @min(std.mem.findPos(u8, text, next, "\n") orelse sec.body_end, sec.body_end);
                const next_line = text[next..next_end];
                if (std.mem.trim(u8, next_line, " \t\r").len == 0) break;
                const next_indent = next_line.len - std.mem.trimStart(u8, next_line, " \t").len;
                if (next_indent <= indent) break;
                value_end = next_end;
                next = next_end + 1;
            }
            return .{ .value_start = @min(after + 1, line_end), .line_end = value_end };
        }
        scan = line_end + 1;
    }
    return null;
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

// -------------------------------------------------------- table inventory

/// Some indexes are Markdown *tables* rather than lists — a PRD row carries a
/// Notes column that a `- [Title](link) — Status` line has nowhere to put. The
/// two functions below are the table equivalents of `insertInventory` and
/// `setInventoryStatus`, and they are separate rather than generalized because
/// the cell arithmetic has no counterpart in a list: rewriting a status means
/// finding the third pipe-delimited cell without touching the fourth.
///
/// The row is appended at the *bottom* of the marker block. A numbered store
/// reads in ascending order, so newest-first — what the RFC list does — would
/// put 0037 above 0001.
pub fn insertInventoryRow(
    w: *std.Io.Writer,
    index: []const u8,
    start_marker: []const u8,
    end_marker: []const u8,
    row: []const u8,
) !bool {
    const start = std.mem.find(u8, index, start_marker) orelse return false;
    const content_start = start + start_marker.len;
    const end = std.mem.findPos(u8, index, content_start, end_marker) orelse return false;
    const previous = std.mem.trim(u8, index[content_start..end], " \t\r\n");

    try w.writeAll(index[0..content_start]);
    try w.writeAll("\n");
    if (previous.len > 0) {
        try w.writeAll(previous);
        try w.writeAll("\n");
    }
    try w.writeAll(row);
    try w.writeAll("\n");
    try w.writeAll(index[end..]);
    return true;
}

/// The pipe-delimited cells of one table row, without the leading and trailing
/// empty fields a `| a | b |` row produces. Returned as offsets into `line` so
/// a rewrite can splice one cell and copy the rest verbatim, notes included.
pub const RowCell = struct { start: usize, end: usize };

pub fn rowCells(line: []const u8, out: *[8]RowCell) []const RowCell {
    const trimmed_end = std.mem.trimEnd(u8, line, " \t\r").len;
    var count: usize = 0;
    var i: usize = 0;
    // A well-formed row opens with a pipe; anything else is not a row.
    while (i < trimmed_end and (line[i] == ' ' or line[i] == '\t')) i += 1;
    if (i >= trimmed_end or line[i] != '|') return out[0..0];
    i += 1;
    while (i <= trimmed_end and count < out.len) {
        const bar = std.mem.findPos(u8, line[0..trimmed_end], i, "|") orelse break;
        out[count] = .{ .start = i, .end = bar };
        count += 1;
        i = bar + 1;
    }
    return out[0..count];
}

/// Rewrites the status cell of the table row whose first Markdown link points
/// at `target`. Column 0 is the link, 1 the title, 2 the status; a row with
/// fewer cells is skipped rather than padded, because widening someone else's
/// table silently is worse than reporting that the row was not updated.
pub fn setInventoryRowStatus(
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
        var cells_buf: [8]RowCell = undefined;
        const cells = rowCells(line, &cells_buf);
        if (cells.len < 3) {
            scan = line_end + 1;
            continue;
        }
        const entry = inventoryEntry(line[cells[0].start..cells[0].end]) orelse {
            scan = line_end + 1;
            continue;
        };
        if (!std.mem.eql(u8, entry.target, target)) {
            scan = line_end + 1;
            continue;
        }
        try w.writeAll(index[0 .. scan + cells[2].start]);
        try w.writeAll(" ");
        try w.writeAll(status);
        try w.writeAll(" ");
        try w.writeAll(index[scan + cells[2].end ..]);
        return true;
    }
    return false;
}

// ------------------------------------------------------- record search

/// The most terms a record search is split into. Each term costs one host
/// grep over the store, so the cap bounds the work a single query can ask for;
/// anything past it is folded into the last term as a phrase.
pub const max_search_terms = 8;

/// Splits a record-store query into the terms every match must contain.
/// Whitespace separates terms and a `"quoted phrase"` is one term, so
/// `concurrent sessions` finds a record that says both words anywhere while
/// `"concurrent sessions"` still asks for the adjacent phrase.
///
/// The store search used to pass the whole query to one substring grep, which
/// is the phrase form with no way to ask for the other one: `reports search
/// "concurrent sessions"` found nothing while
/// `docs/runbooks/concurrent-agent-sessions-on-one-checkout.md` sat in the
/// store saying both words on different lines. A search that misses an
/// existing record is worse than one that returns too much, because the caller
/// concludes the record does not exist and writes a second one.
///
/// Slices into `query`; writes at most `buf.len` terms and returns what it
/// wrote. An unterminated quote runs to the end of the query.
pub fn searchTerms(query: []const u8, buf: [][]const u8) []const []const u8 {
    var n: usize = 0;
    var i: usize = 0;
    while (i < query.len and n < buf.len) {
        while (i < query.len and std.ascii.isWhitespace(query[i])) i += 1;
        if (i >= query.len) break;
        if (query[i] == '"') {
            i += 1;
            const start = i;
            const end = std.mem.findScalarPos(u8, query, i, '"') orelse query.len;
            if (end > start) {
                buf[n] = query[start..end];
                n += 1;
            }
            i = if (end < query.len) end + 1 else end;
            continue;
        }
        const start = i;
        while (i < query.len and !std.ascii.isWhitespace(query[i])) i += 1;
        buf[n] = query[start..i];
        n += 1;
    }
    // A query with nothing but separators still has to search for something.
    if (n == 0 and query.len > 0) {
        buf[0] = query;
        n = 1;
    }
    return buf[0..n];
}

/// The file named by one `{"file":...,"line":...,"text":...}` grep hit.
fn hitFile(hit: std.json.Value) ?[]const u8 {
    const obj = switch (hit) {
        .object => |o| o,
        else => return null,
    };
    return switch (obj.get("file") orelse return null) {
        .string => |s| s,
        else => null,
    };
}

/// Folds one grep result per term into the hits of the records that matched
/// *every* term: a record is a file, so the AND is over file names and the
/// surviving hits are the union of the lines each term matched in them. Lines
/// keep the order the first term that matched them reported, which is file
/// order within a term, so the result still reads store-order.
///
/// `per_term` must already be parsed — each host grep reuses the shared host
/// arena, so a caller has to parse one result before issuing the next.
pub fn intersectHits(alloc: std.mem.Allocator, per_term: []const std.json.Value) !std.json.Value {
    var out = std.json.Array.init(alloc);
    if (per_term.len == 0) return .{ .array = out };

    // Files the first term matched, then narrowed by each later term. An empty
    // term result empties the intersection, which is the honest answer: no
    // record contains all the terms.
    var keep: std.StringHashMapUnmanaged(void) = .empty;
    for (arrayItems(per_term[0])) |hit| {
        if (hitFile(hit)) |f| try keep.put(alloc, f, {});
    }
    for (per_term[1..]) |term| {
        var next: std.StringHashMapUnmanaged(void) = .empty;
        for (arrayItems(term)) |hit| {
            const f = hitFile(hit) orelse continue;
            if (keep.contains(f)) try next.put(alloc, f, {});
        }
        keep = next;
    }

    var seen: std.StringHashMapUnmanaged(void) = .empty;
    for (per_term) |term| {
        for (arrayItems(term)) |hit| {
            const f = hitFile(hit) orelse continue;
            if (!keep.contains(f)) continue;
            const line = switch (hit.object.get("line") orelse std.json.Value.null) {
                .integer => |n| n,
                else => 0,
            };
            const key = try std.fmt.allocPrint(alloc, "{s}:{d}", .{ f, line });
            if (seen.contains(key)) continue;
            try seen.put(alloc, key, {});
            try out.append(hit);
        }
    }
    return .{ .array = out };
}

fn arrayItems(v: std.json.Value) []const std.json.Value {
    return switch (v) {
        .array => |a| a.items,
        else => &.{},
    };
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

test "isDocPath excludes the index and the template a grep would otherwise hit" {
    // A search over docs/adrs/ hits README.md's own inventory line for every
    // record it lists, so one real hit arrives with an index line stapled to
    // it. The store's grep filters on this.
    try std.testing.expect(isDocPath("docs/adrs/0008-scheduler.md"));
    try std.testing.expect(!isDocPath("docs/adrs/README.md"));
    try std.testing.expect(!isDocPath("docs/prds/TEMPLATE.md"));
    try std.testing.expect(!isDocPath("README.md"));
    try std.testing.expect(!isDocPath("docs/adrs/notes.txt"));
}

test "isPathIn accepts a direct child and refuses traversal" {
    try std.testing.expect(isPathIn("docs/rfcs", "docs/rfcs/0001-a.md"));
    try std.testing.expect(!isPathIn("docs/rfcs", "docs/rfcs/sub/0001-a.md"));
    try std.testing.expect(!isPathIn("docs/rfcs", "docs/rfcs/../adrs/0001-a.md"));
    try std.testing.expect(!isPathIn("docs/rfcs", "docs/research/a.md"));
    try std.testing.expect(!isPathIn("docs/rfcs", "docs/rfcs/a.txt"));
    try std.testing.expect(!isPathIn("docs/rfcs", "docs/rfcs/"));
}

test "statusFrom reads a two-word status that statusWord would cut at the space" {
    const vocabulary = [_][]const u8{ "In progress", "Shipped", "Draft" };
    // The real shapes in docs/prds/: statusWord stops at the first space,
    // comma, colon or period, so only a one-word status survives it.
    try std.testing.expectEqualStrings("In progress", statusFrom("## Status\n\nIn progress: the offline path ships.\n", &vocabulary));
    try std.testing.expectEqualStrings("Shipped", statusFrom("## Status\n\nShipped. Source of truth: `ui/app/*`\n", &vocabulary));
    try std.testing.expectEqualStrings("Shipped", statusFrom("## Status\n\n**Web UI plugins: Shipped.** TUI is draft.\n", &vocabulary));
    try std.testing.expectEqualStrings("Draft", statusFrom("## Status\n\nDraft. No source files yet.\n", &vocabulary));
}

test "labelFrom reads the wire spelling of a status against the same vocabulary" {
    const vocabulary = [_][]const u8{ "In progress", "Shipped", "Draft" };
    try std.testing.expectEqualStrings("Draft", labelFrom("draft", &vocabulary).?);
    try std.testing.expectEqualStrings("Shipped", labelFrom("SHIPPED", &vocabulary).?);
    // The two-word phrase arrives with an underscore or a hyphen on the wire.
    try std.testing.expectEqualStrings("In progress", labelFrom("in_progress", &vocabulary).?);
    try std.testing.expectEqualStrings("In progress", labelFrom("in-progress", &vocabulary).?);
    try std.testing.expectEqualStrings("In progress", labelFrom("In progress", &vocabulary).?);
    try std.testing.expect(labelFrom("implemented", &vocabulary) == null);
    try std.testing.expect(labelFrom("", &vocabulary) == null);
    // A prefix is not a status: "ship" must not reach "Shipped".
    try std.testing.expect(labelFrom("ship", &vocabulary) == null);
}

test "labelFrom and statusFrom agree on one vocabulary" {
    // The point of the pair: every status `status` accepts is one `list` can
    // read back, which is what a second hand-written table kept breaking.
    const vocabulary = [_][]const u8{ "In progress", "Shipped", "Draft" };
    for ([_][]const u8{ "draft", "in_progress", "shipped" }) |wanted| {
        const label = labelFrom(wanted, &vocabulary).?;
        var buf: [64]u8 = undefined;
        const text = std.fmt.bufPrint(&buf, "## Status\n\n{s}. Written by the status action.\n", .{label}) catch unreachable;
        try std.testing.expectEqualStrings(label, statusFrom(text, &vocabulary));
    }
}

test "statusFrom falls back to the first word when no known status matches" {
    const vocabulary = [_][]const u8{ "In progress", "Shipped", "Draft" };
    // Rather than report an empty status and hide the row, an unrecognized
    // wording degrades to what statusWord can read off it.
    try std.testing.expectEqualStrings("Implemented", statusFrom("## Status\n\nImplemented, except the manual matrix.\n", &vocabulary));
    try std.testing.expectEqualStrings("", statusFrom("# No status section\n", &vocabulary));
}

test "statusFrom prefers the earliest phrase in the line, not the first listed" {
    const vocabulary = [_][]const u8{ "Shipped", "Draft" };
    try std.testing.expectEqualStrings("Draft", statusFrom("## Status\n\nDraft; supersedes a Shipped design.\n", &vocabulary));
}

test "insertInventoryRow appends a table row below the last one" {
    const index =
        \\| PRD | Title | Status | Notes |
        \\|---|---|---|---|
        \\<!-- inventory:prd:start -->
        \\| [0001](0001-a.md) | A | Shipped | |
        \\| [0002](0002-b.md) | B | Draft | |
        \\<!-- inventory:prd:end -->
        \\
    ;
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    try std.testing.expect(try insertInventoryRow(
        &out.writer,
        index,
        "<!-- inventory:prd:start -->",
        "<!-- inventory:prd:end -->",
        "| [0003](0003-c.md) | C | Draft | |",
    ));
    const text = out.written();
    const b = std.mem.find(u8, text, "0002-b.md").?;
    const c = std.mem.find(u8, text, "0003-c.md").?;
    // Numbered documents read in ascending order, so a new row lands at the
    // bottom — the opposite of the newest-first RFC list.
    try std.testing.expect(b < c);
    try std.testing.expect(std.mem.find(u8, text, "| [0001](0001-a.md) | A | Shipped | |") != null);
}

test "insertInventoryRow refuses an index with no markers" {
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    try std.testing.expect(!try insertInventoryRow(&out.writer, "| a |\n", "<!-- s -->", "<!-- e -->", "| b |"));
}

test "setInventoryRowStatus rewrites only the status cell of the matching row" {
    const index =
        \\<!-- inventory:prd:start -->
        \\| [0001](0001-a.md) | A | Draft | keeps its note |
        \\| [0002](0002-b.md) | B | Draft | |
        \\<!-- inventory:prd:end -->
        \\
    ;
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    try std.testing.expect(try setInventoryRowStatus(
        &out.writer,
        index,
        "<!-- inventory:prd:start -->",
        "<!-- inventory:prd:end -->",
        "0001-a.md",
        "Shipped",
    ));
    const text = out.written();
    try std.testing.expect(std.mem.find(u8, text, "| [0001](0001-a.md) | A | Shipped | keeps its note |") != null);
    // The other row is untouched, notes column included.
    try std.testing.expect(std.mem.find(u8, text, "| [0002](0002-b.md) | B | Draft | |") != null);
}

test "setInventoryRowStatus reports a row it cannot find rather than guessing" {
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    const index = "<!-- s -->\n| [0001](0001-a.md) | A | Draft | |\n<!-- e -->\n";
    try std.testing.expect(!try setInventoryRowStatus(&out.writer, index, "<!-- s -->", "<!-- e -->", "0009-z.md", "Shipped"));
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

test "replaceTldrField rewrites the bullet and leaves the others alone" {
    const record =
        "# Bug — x\n\n## TL;DR\n\n- **What failed:** it broke.\n- **Impact:** none.\n" ++
        "- **Resolution:** Open.\n\n## Status\n\nOpen.\n";
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    try std.testing.expect(try replaceTldrField(&out.writer, record, "Resolution", "Resolved on 2026-08-16. fixed in abc1234."));
    try std.testing.expectEqualStrings(
        "# Bug — x\n\n## TL;DR\n\n- **What failed:** it broke.\n- **Impact:** none.\n" ++
            "- **Resolution:** Resolved on 2026-08-16. fixed in abc1234.\n\n## Status\n\nOpen.\n",
        out.written(),
    );
}

test "replaceTldrField reports a missing bullet or a missing TL;DR" {
    const no_bullet = "# Bug — x\n\n## TL;DR\n\n- **What failed:** it broke.\n\n## Status\n\nOpen.\n";
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    try std.testing.expect(!try replaceTldrField(&out.writer, no_bullet, "Resolution", "Resolved."));
    try std.testing.expect(!try replaceTldrField(&out.writer, "# Bug\n\n## Status\n\nOpen.\n", "Resolution", "Resolved."));
}

test "replaceTldrField drops a wrapped bullet's continuation lines" {
    // A wrapped Resolution bullet's indented continuations are part of the
    // value; rewriting only the first line used to leave the old tail stacked
    // under the new value as two contradictory accounts.
    const record =
        "# Bug — x\n\n## TL;DR\n\n- **What failed:** it broke.\n- **Impact:** none.\n" ++
        "- **Resolution:** Resolved on 2026-08-16. fixed in abc1234.\n" ++
        "  link target and renames onto *that*, so the linked path keeps its\n" ++
        "  link and the write lands where every reader looks.\n\n## Status\n\nOpen.\n";
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    try std.testing.expect(try replaceTldrField(&out.writer, record, "Resolution", "Resolved on 2026-08-17. re-diagnosed."));
    try std.testing.expectEqualStrings(
        "# Bug — x\n\n## TL;DR\n\n- **What failed:** it broke.\n- **Impact:** none.\n" ++
            "- **Resolution:** Resolved on 2026-08-17. re-diagnosed.\n\n## Status\n\nOpen.\n",
        out.written(),
    );
    // A wrapped bullet's value reads whole, not as its first line.
    try std.testing.expectEqualStrings(
        "Resolved on 2026-08-16. fixed in abc1234.\n" ++
            "  link target and renames onto *that*, so the linked path keeps its\n" ++
            "  link and the write lands where every reader looks.",
        tldrField(record, "Resolution").?,
    );
}

test "fieldParagraph reads a wrapped bold-led paragraph and reports an absent one" {
    const rfc =
        "# RFC 0004 — x\n\n## Recommendation\n\n**Recommended option:** A\n\n" ++
        "**Confidence:** 7/10\n\n" ++
        "**Why this confidence.** The eval corpus covers the hot path,\n" ++
        "and a failed soak would sink it.\n\n" ++
        "**Rationale.** Beats B on cost.\n\n## Open questions\n\nNone.\n";
    // A wrapped paragraph reads whole, not as its first line.
    try std.testing.expectEqualStrings(
        "The eval corpus covers the hot path,\nand a failed soak would sink it.",
        fieldParagraph(rfc, "## Recommendation", "**Why this confidence.**").?,
    );
    try std.testing.expectEqualStrings(
        "Beats B on cost.",
        fieldParagraph(rfc, "## Recommendation", "**Rationale.**").?,
    );
    // Absent marker, absent section, and a marker with nothing after it are
    // all "no existing text", not an empty string to preserve.
    try std.testing.expect(fieldParagraph(rfc, "## Recommendation", "**Reversibility.**") == null);
    try std.testing.expect(fieldParagraph(rfc, "## Decision", "**Rationale.**") == null);
    try std.testing.expect(fieldParagraph("## R\n\n**Empty.**\n\nnext\n", "## R", "**Empty.**") == null);
    // A sentence quoting the marker mid-line does not match it.
    try std.testing.expect(fieldParagraph(
        "## R\n\nsee **Reversibility.** below\n",
        "## R",
        "**Reversibility.**",
    ) == null);
}

test "replaceTldrField stops a wrapped bullet at the next bullet" {
    const record =
        "# Bug — x\n\n## TL;DR\n\n- **Resolution:** Resolved on 2026-08-16. fixed in abc1234.\n" ++
        "  a wrapped continuation\n- **Impact:** none.\n\n## Status\n\nOpen.\n";
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    try std.testing.expect(try replaceTldrField(&out.writer, record, "Resolution", "Resolved."));
    // The next bullet survives; only the continuation is consumed.
    try std.testing.expectEqualStrings(
        "# Bug — x\n\n## TL;DR\n\n- **Resolution:** Resolved.\n- **Impact:** none.\n\n## Status\n\nOpen.\n",
        out.written(),
    );
}

test "tldrField reads a bullet's value and reports an absent one" {
    const record = "# Bug\n\n## TL;DR\n\n- **Finding:** Investigating.\n- **Resolution:** Open.\n\n## Status\n\nOpen.\n";
    try std.testing.expectEqualStrings("Investigating.", tldrField(record, "Finding").?);
    try std.testing.expectEqualStrings("Open.", tldrField(record, "Resolution").?);
    try std.testing.expect(tldrField(record, "Impact") == null);
    try std.testing.expect(tldrField("# Bug\n\n## Status\n\nOpen.\n", "Finding") == null);
}

test "replaceTldrField ignores a matching bullet outside the TL;DR" {
    // The body of a long record can quote the bullet it is describing; only
    // the summary at the top is the record's own state.
    const record =
        "# Bug — x\n\n## TL;DR\n\n- **Resolution:** Open.\n\n## Root cause\n\n" ++
        "- **Resolution:** Open. is what the TL;DR still says\n";
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    try std.testing.expect(try replaceTldrField(&out.writer, record, "Resolution", "Resolved."));
    try std.testing.expectEqualStrings(
        "# Bug — x\n\n## TL;DR\n\n- **Resolution:** Resolved.\n\n## Root cause\n\n" ++
            "- **Resolution:** Open. is what the TL;DR still says\n",
        out.written(),
    );
}

/// The enforced filename marker for missing-tooling records: a record of a
/// basic verb clanker lacks must be findable by name alone, so the reports
/// tool inserts this into the slug itself rather than trusting the caller
/// to have named it.
pub const missing_tool_marker = "missing-clanker-tool-";

/// Insert `missing_tool_marker` after a dated slug's `YYYY-MM-DD-` prefix,
/// unless the caller already wrote it there. The input must have passed the
/// dated-slug check (11-byte prefix ending in '-').
pub fn markMissingToolSlug(alloc: std.mem.Allocator, slug: []const u8) ![]const u8 {
    const rest = slug[11..];
    if (std.mem.startsWith(u8, rest, missing_tool_marker)) return slug;
    return std.fmt.allocPrint(alloc, "{s}" ++ missing_tool_marker ++ "{s}", .{ slug[0..11], rest });
}

test "markMissingToolSlug enforces the marker exactly once, after the date" {
    const alloc = std.testing.allocator;
    const marked = try markMissingToolSlug(alloc, "2026-08-17-no-verb-prints-a-runs-final-answer");
    defer alloc.free(marked);
    try std.testing.expectEqualStrings("2026-08-17-missing-clanker-tool-no-verb-prints-a-runs-final-answer", marked);
    // Already marked: returned as-is, never doubled.
    const kept = try markMissingToolSlug(alloc, "2026-08-17-missing-clanker-tool-no-rename-verb");
    try std.testing.expectEqualStrings("2026-08-17-missing-clanker-tool-no-rename-verb", kept);
}

test "searchTerms splits on whitespace and keeps a quoted phrase whole" {
    var buf: [max_search_terms][]const u8 = undefined;

    const two = searchTerms("concurrent sessions", &buf);
    try std.testing.expectEqual(@as(usize, 2), two.len);
    try std.testing.expectEqualStrings("concurrent", two[0]);
    try std.testing.expectEqualStrings("sessions", two[1]);

    const phrase = searchTerms("\"concurrent sessions\"", &buf);
    try std.testing.expectEqual(@as(usize, 1), phrase.len);
    try std.testing.expectEqualStrings("concurrent sessions", phrase[0]);

    const mixed = searchTerms("  commit \"smart commit\"  plan ", &buf);
    try std.testing.expectEqual(@as(usize, 3), mixed.len);
    try std.testing.expectEqualStrings("smart commit", mixed[1]);

    // A single word is one term, so a one-word query searches exactly as it
    // always did.
    try std.testing.expectEqual(@as(usize, 1), searchTerms("concurrent", &buf).len);
    // Whitespace only: the query is still what gets searched for.
    try std.testing.expectEqual(@as(usize, 1), searchTerms("   ", &buf).len);
    try std.testing.expectEqual(@as(usize, 0), searchTerms("", &buf).len);
    // An unterminated quote runs to the end rather than dropping the rest.
    const open_quote = searchTerms("\"never closed", &buf);
    try std.testing.expectEqual(@as(usize, 1), open_quote.len);
    try std.testing.expectEqualStrings("never closed", open_quote[0]);
}

test "searchTerms stops at the term cap" {
    var buf: [max_search_terms][]const u8 = undefined;
    const many = searchTerms("a b c d e f g h i j k", &buf);
    try std.testing.expectEqual(@as(usize, max_search_terms), many.len);
}

test "intersectHits keeps only records every term matched" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();

    // The reported miss: 'concurrent' and 'sessions' both hit the runbook, on
    // different lines, and each also hits a record the other does not.
    const concurrent = try std.json.parseFromSliceLeaky(std.json.Value, alloc,
        \\[{"file":"runbooks/concurrent.md","line":3,"text":"concurrent agent sessions"},
        \\ {"file":"bugs/other.md","line":9,"text":"concurrent writes"}]
    , .{});
    const sessions = try std.json.parseFromSliceLeaky(std.json.Value, alloc,
        \\[{"file":"runbooks/concurrent.md","line":12,"text":"five sessions"},
        \\ {"file":"bugs/unrelated.md","line":2,"text":"sessions list"}]
    , .{});

    const hits = try intersectHits(alloc, &.{ concurrent, sessions });
    const items = hits.array.items;
    try std.testing.expectEqual(@as(usize, 2), items.len);
    for (items) |h| try std.testing.expectEqualStrings("runbooks/concurrent.md", h.object.get("file").?.string);
    // Both matching lines survive, not just the first term's.
    try std.testing.expectEqual(@as(i64, 3), items[0].object.get("line").?.integer);
    try std.testing.expectEqual(@as(i64, 12), items[1].object.get("line").?.integer);

    // One term is the old behaviour, unchanged.
    const single = try intersectHits(alloc, &.{concurrent});
    try std.testing.expectEqual(@as(usize, 2), single.array.items.len);

    // A term nothing matched empties the result rather than widening it.
    const none = try std.json.parseFromSliceLeaky(std.json.Value, alloc, "[]", .{});
    const empty = try intersectHits(alloc, &.{ concurrent, none });
    try std.testing.expectEqual(@as(usize, 0), empty.array.items.len);
}

test "intersectHits reports a line matched by two terms once" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();
    const both = try std.json.parseFromSliceLeaky(std.json.Value, alloc,
        \\[{"file":"a.md","line":1,"text":"smart commit groups the diff"}]
    , .{});
    const hits = try intersectHits(alloc, &.{ both, both });
    try std.testing.expectEqual(@as(usize, 1), hits.array.items.len);
}

test "a header-length prefix answers title and status for a template-shaped record" {
    // What `header_read_bytes` buys: a listing reads this much of a record
    // instead of all of it, so the store's arena cost is bounded by the row
    // count rather than by how long the records happen to be. The prefix is
    // only sound while the `# ` line and the `## Status` section stay inside
    // it, which is what a template-shaped record puts there and what this
    // pins.
    const body = "Body paragraph that runs well past the header window.\n" ** 400;
    const full = "# 0001: A decision\n\n## Status\n\nAccepted — 2026-08-18.\n\n## Context\n\n" ++ body;
    try std.testing.expect(full.len > header_read_bytes);

    const prefix = full[0..header_read_bytes];
    const vocabulary = [_][]const u8{ "Accepted", "Superseded", "Deprecated", "Proposed" };
    try std.testing.expectEqualStrings(documentTitle(full), documentTitle(prefix));
    try std.testing.expectEqualStrings(statusFrom(full, &vocabulary), statusFrom(prefix, &vocabulary));
    try std.testing.expectEqualStrings("0001: A decision", documentTitle(prefix));
    try std.testing.expectEqualStrings("Accepted", statusFrom(prefix, &vocabulary));
}
