//! Self-contained HTML transcript for a saved session (`clanker session
//! export <id>`).
//!
//! Local-first by design: this writes one file to disk and never talks to the
//! network. The shareable-link half of the idea (a paste-service upload that
//! hands back a public URL) is deliberately not built here; a file that opens
//! from `file://` and can be attached to a mail or a ticket is the version
//! that does not need a server to keep running for the link to survive.
//!
//! Everything in a session is untrusted text. The message bodies are model
//! output, the tool messages are whatever a tool printed, and the title is
//! whatever a user or an agent typed, so every byte that reaches the page
//! goes through `escape` below and nothing in this file interpolates a
//! session field into markup any other way. There is one escaper on purpose:
//! the webui's own raw-string export had a second, partial one (a lone
//! `.replace(/</g, "&lt;")`) and that is exactly how the gap in it stayed
//! invisible.
//!
//! The page carries no script and no external reference: no stylesheet, no
//! font, no image, no analytics. That is what "self-contained" has to mean
//! for a transcript that will be opened from a downloads folder, and it also
//! means there is no place for injected markup to fetch anything from even if
//! the escaping were wrong.

const std = @import("std");
const types = @import("../llm/types.zig");
const session = @import("session.zig");

/// Writes `text` to `w` with every character that can change the meaning of
/// the surrounding markup replaced by its entity.
///
/// `&`, `<` and `>` cover element context; `"` and `'` cover an unquoted or
/// single-quoted attribute value. The exporter only ever emits element
/// content, but escaping the quotes too costs nothing and means a caller
/// that later interpolates into an attribute is not silently unprotected.
/// `&` must be replaced first, which is why this is a single pass over the
/// input rather than a chain of replacements.
pub fn escape(w: *std.Io.Writer, text: []const u8) !void {
    var start: usize = 0;
    for (text, 0..) |c, i| {
        const entity: []const u8 = switch (c) {
            '&' => "&amp;",
            '<' => "&lt;",
            '>' => "&gt;",
            '"' => "&quot;",
            '\'' => "&#39;",
            else => continue,
        };
        if (i > start) try w.writeAll(text[start..i]);
        try w.writeAll(entity);
        start = i + 1;
    }
    if (start < text.len) try w.writeAll(text[start..]);
}

/// `escape` into a fresh allocation. Used by the tests and by callers that
/// need the escaped form as a value rather than as part of a stream.
pub fn escapeAlloc(gpa: std.mem.Allocator, text: []const u8) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(gpa);
    errdefer out.deinit();
    try escape(&out.writer, text);
    return out.toOwnedSlice();
}

/// Days since the Unix epoch to a civil (year, month, day), and the seconds
/// within the day to a wall clock. Howard Hinnant's `civil_from_days`, valid
/// for any date this will ever see. Rendered as UTC rather than local time:
/// an exported transcript is read somewhere other than where it was made, so
/// a bare timestamp with no zone is worse than one that names its own.
const Civil = struct {
    year: i64,
    month: u8,
    day: u8,
    hour: u8,
    minute: u8,
    second: u8,
};

fn civilFromUnix(unix_seconds: i64) Civil {
    const seconds_per_day: i64 = 86_400;
    // Floor division, so a pre-1970 timestamp does not round toward zero and
    // land a day late.
    var days = @divFloor(unix_seconds, seconds_per_day);
    const rem = unix_seconds - days * seconds_per_day;

    days += 719_468;
    const era = @divFloor(days, 146_097);
    const doe = days - era * 146_097; // [0, 146096]
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
        .hour = @intCast(@divTrunc(rem, 3600)),
        .minute = @intCast(@divTrunc(@rem(rem, 3600), 60)),
        .second = @intCast(@rem(rem, 60)),
    };
}

fn writeTimestamp(w: *std.Io.Writer, unix_seconds: i64) !void {
    // Not escaped, and does not need to be: every byte here comes from a
    // format of integers this function computed itself.
    const c = civilFromUnix(unix_seconds);
    try w.print("{d:0>4}-{d:0>2}-{d:0>2} {d:0>2}:{d:0>2}:{d:0>2} UTC", .{
        c.year,
        c.month,
        c.day,
        c.hour,
        c.minute,
        c.second,
    });
}

fn roleLabel(role: types.Role) []const u8 {
    return switch (role) {
        .system => "System",
        .user => "You",
        .assistant => "Assistant",
        .tool => "Tool result",
    };
}

/// One `<style>` block, no external reference of any kind. System font stacks
/// only: a webfont would be a network fetch on open, which is the property
/// this export exists to avoid.
const style =
    \\:root{color-scheme:light dark;--bg:#fbfbfa;--fg:#1a1a1a;--muted:#5c5c5c;--line:#e0e0dd;--card:#fff;--code:#f4f4f2}
    \\@media (prefers-color-scheme:dark){:root{--bg:#16171a;--fg:#e6e6e6;--muted:#9a9a9a;--line:#2c2e33;--card:#1d1e22;--code:#101114}}
    \\*{box-sizing:border-box}
    \\body{margin:0;padding:2rem 1rem 4rem;background:var(--bg);color:var(--fg);font:16px/1.55 ui-sans-serif,system-ui,-apple-system,"Segoe UI",Roboto,Helvetica,Arial,sans-serif}
    \\main{max-width:52rem;margin:0 auto}
    \\h1{font-size:1.4rem;margin:0 0 .35rem;word-break:break-word}
    \\dl.meta{display:grid;grid-template-columns:max-content 1fr;gap:.15rem .8rem;margin:0 0 2rem;color:var(--muted);font-size:.85rem}
    \\dl.meta dt{font-weight:600}
    \\dl.meta dd{margin:0;word-break:break-word}
    \\section.msg{background:var(--card);border:1px solid var(--line);border-radius:10px;padding:.85rem 1rem;margin:0 0 .85rem}
    \\section.msg > h2{font-size:.78rem;letter-spacing:.06em;text-transform:uppercase;color:var(--muted);margin:0 0 .5rem;font-weight:700}
    \\section.msg.user{border-left:3px solid #4a7dbd}
    \\section.msg.assistant{border-left:3px solid #4c9a72}
    \\section.msg.system{border-left:3px solid #8a7fbb}
    \\section.msg.tool{border-left:3px solid #b08442}
    \\pre{margin:0;white-space:pre-wrap;overflow-wrap:anywhere;font:13px/1.5 ui-monospace,SFMono-Regular,Menlo,Consolas,monospace}
    \\.call{margin-top:.7rem;border-top:1px dashed var(--line);padding-top:.6rem}
    \\.call h3{font-size:.8rem;margin:0 0 .35rem;font-family:ui-monospace,SFMono-Regular,Menlo,Consolas,monospace}
    \\.call pre{background:var(--code);border-radius:6px;padding:.5rem .6rem}
    \\.empty{color:var(--muted);font-style:italic}
    \\footer{margin-top:2.5rem;padding-top:.8rem;border-top:1px solid var(--line);color:var(--muted);font-size:.8rem}
;

/// Renders `s` as one complete HTML document. Caller owns the result.
pub fn render(gpa: std.mem.Allocator, s: session.Session) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(gpa);
    errdefer out.deinit();
    const w = &out.writer;

    try w.writeAll("<!doctype html>\n<html lang=\"en\">\n<head>\n<meta charset=\"utf-8\">\n");
    try w.writeAll("<meta name=\"viewport\" content=\"width=device-width, initial-scale=1\">\n");
    try w.writeAll("<title>");
    if (s.title.len > 0) {
        try escape(w, s.title);
        try w.writeAll(" - ");
    }
    try escape(w, s.id);
    try w.writeAll("</title>\n<style>\n");
    try w.writeAll(style);
    try w.writeAll("\n</style>\n</head>\n<body>\n<main>\n");

    try w.writeAll("<h1>");
    try escape(w, if (s.title.len > 0) s.title else s.id);
    try w.writeAll("</h1>\n<dl class=\"meta\">\n");
    try w.writeAll("<dt>Session</dt><dd>");
    try escape(w, s.id);
    try w.writeAll("</dd>\n<dt>Started</dt><dd>");
    try writeTimestamp(w, s.created);
    try w.writeAll("</dd>\n<dt>Updated</dt><dd>");
    try writeTimestamp(w, s.updated);
    try w.writeAll("</dd>\n<dt>Messages</dt><dd>");
    try w.print("{d}", .{s.messages.len});
    try w.writeAll("</dd>\n");
    if (s.workspace.len > 0) {
        try w.writeAll("<dt>Workspace</dt><dd>");
        try escape(w, s.workspace);
        try w.writeAll("</dd>\n");
    }
    if (s.archived) try w.writeAll("<dt>State</dt><dd>archived</dd>\n");
    try w.writeAll("</dl>\n");

    if (s.messages.len == 0) {
        try w.writeAll("<p class=\"empty\">This conversation has no messages.</p>\n");
    }

    for (s.messages) |m| {
        try w.writeAll("<section class=\"msg ");
        // From a closed enum this process owns, never from the file: an
        // unknown role is rejected by loadSession long before here.
        try w.writeAll(m.role.asStr());
        try w.writeAll("\">\n<h2>");
        try escape(w, roleLabel(m.role));
        try w.writeAll("</h2>\n");

        const content = m.content orelse "";
        if (content.len > 0) {
            // A whole message body in one <pre>: the transcript is shown as
            // the text it is, not re-rendered as markdown. Rendering markdown
            // would mean emitting markup derived from model output, which is
            // the one thing an export of untrusted text should not do, and a
            // code fence would then have to be un-rendered again anyway.
            try w.writeAll("<pre>");
            try escape(w, content);
            try w.writeAll("</pre>\n");
        } else if (m.tool_calls == null) {
            try w.writeAll("<p class=\"empty\">(no text)</p>\n");
        }

        if (m.images) |imgs| {
            if (imgs.len > 0) {
                try w.writeAll("<p class=\"empty\">");
                try w.print("{d}", .{imgs.len});
                try w.writeAll(if (imgs.len == 1) " image attachment omitted" else " image attachments omitted");
                try w.writeAll("</p>\n");
            }
        }

        if (m.tool_calls) |calls| {
            for (calls) |tc| {
                try w.writeAll("<div class=\"call\">\n<h3>");
                try escape(w, tc.name);
                try w.writeAll("</h3>\n<pre>");
                try escape(w, tc.arguments);
                try w.writeAll("</pre>\n</div>\n");
            }
        }
        try w.writeAll("</section>\n");
    }

    try w.writeAll("<footer>Exported by clanker. Self-contained: no scripts, no network requests, safe to open offline.</footer>\n");
    try w.writeAll("</main>\n</body>\n</html>\n");
    return out.toOwnedSlice();
}

/// Default destination for `clanker session export <id>` when no path is
/// given. Beside the other exportable artifacts under `state/`, not in the
/// session store: a rewritten export must never be mistaken for the session.
pub fn defaultPath(gpa: std.mem.Allocator, id: []const u8) ![]u8 {
    return std.fmt.allocPrint(gpa, "state/exports/{s}.html", .{id});
}

// ---------------------------------------------------------------------------
// tests
// ---------------------------------------------------------------------------

test "escape replaces every character that can change the surrounding markup" {
    const got = try escapeAlloc(std.testing.allocator, "<a href='x' title=\"y\">a & b</a>");
    defer std.testing.allocator.free(got);
    try std.testing.expectEqualStrings(
        "&lt;a href=&#39;x&#39; title=&quot;y&quot;&gt;a &amp; b&lt;/a&gt;",
        got,
    );
}

test "escape encodes the ampersand first so an entity is not double-decoded" {
    // The bug a chained replace makes: `&` after `<` turns "&lt;" typed by a
    // user into a literal "<" when the page is read back.
    const got = try escapeAlloc(std.testing.allocator, "&lt;script&gt;");
    defer std.testing.allocator.free(got);
    try std.testing.expectEqualStrings("&amp;lt;script&amp;gt;", got);
}

test "escape leaves text with nothing to escape byte-identical" {
    const plain = "plain ascii, and \xc3\xa9 \xe2\x9c\x93 utf-8 passing straight through";
    const got = try escapeAlloc(std.testing.allocator, plain);
    defer std.testing.allocator.free(got);
    try std.testing.expectEqualStrings(plain, got);
}

test "civilFromUnix converts the epoch, a leap day and a pre-epoch time" {
    const a = civilFromUnix(0);
    try std.testing.expectEqual(@as(i64, 1970), a.year);
    try std.testing.expectEqual(@as(u8, 1), a.month);
    try std.testing.expectEqual(@as(u8, 1), a.day);
    try std.testing.expectEqual(@as(u8, 0), a.hour);

    // 2024-02-29T12:34:56Z
    const b = civilFromUnix(1_709_209_496);
    try std.testing.expectEqual(@as(i64, 2024), b.year);
    try std.testing.expectEqual(@as(u8, 2), b.month);
    try std.testing.expectEqual(@as(u8, 29), b.day);
    try std.testing.expectEqual(@as(u8, 12), b.hour);
    try std.testing.expectEqual(@as(u8, 34), b.minute);
    try std.testing.expectEqual(@as(u8, 56), b.second);

    // Floor division, not truncation: one second before the epoch is the
    // last second of 1969, not the first of 1970.
    const c = civilFromUnix(-1);
    try std.testing.expectEqual(@as(i64, 1969), c.year);
    try std.testing.expectEqual(@as(u8, 12), c.month);
    try std.testing.expectEqual(@as(u8, 31), c.day);
    try std.testing.expectEqual(@as(u8, 23), c.hour);
    try std.testing.expectEqual(@as(u8, 59), c.minute);
    try std.testing.expectEqual(@as(u8, 59), c.second);
}

test "render escapes a hostile transcript instead of emitting it as markup" {
    const gpa = std.testing.allocator;
    const calls = [_]types.ToolCall{.{
        .id = "call_1",
        .name = "exec<img src=x onerror=alert(1)>",
        .arguments = "{\"cmd\":\"echo \\\"a & b\\\" > out\"}",
    }};
    const messages = [_]types.Message{
        .{ .role = .user, .content = "render this: <script>alert(\"xss\")</script>" },
        .{ .role = .assistant, .content = "sure:\n```html\n<div class=\"x\">a & b</div>\n```", .tool_calls = &calls },
        .{ .role = .tool, .content = "</pre><script>alert(1)</script><pre>", .tool_call_id = "call_1" },
    };
    const html = try render(gpa, .{
        .id = "sess-hostile",
        .title = "a \"quoted\" & <b>bold</b> title",
        .messages = &messages,
        .created = 1_700_000_000,
        .updated = 1_700_003_600,
    });
    defer gpa.free(html);

    // Nothing the session carried may appear as a tag. The only `<script`
    // and `<pre` sequences left in the document are the ones this module
    // writes itself, and it writes no script at all.
    try std.testing.expect(std.mem.find(u8, html, "<script") == null);
    try std.testing.expect(std.mem.find(u8, html, "onerror=") == null);
    try std.testing.expect(std.mem.find(u8, html, "<b>bold</b>") == null);
    try std.testing.expect(std.mem.find(u8, html, "</pre><script>") == null);
    try std.testing.expect(std.mem.find(u8, html, "<img src=x") == null);
    try std.testing.expect(std.mem.find(u8, html, "<div class=\"x\">") == null);

    // And all of it must still be *there*, as text.
    try std.testing.expect(std.mem.find(u8, html, "&lt;script&gt;alert(&quot;xss&quot;)&lt;/script&gt;") != null);
    try std.testing.expect(std.mem.find(u8, html, "&lt;div class=&quot;x&quot;&gt;a &amp; b&lt;/div&gt;") != null);
    try std.testing.expect(std.mem.find(u8, html, "a &quot;quoted&quot; &amp; &lt;b&gt;bold&lt;/b&gt; title") != null);
    try std.testing.expect(std.mem.find(u8, html, "exec&lt;img src=x onerror=alert(1)&gt;") != null);
    // The code fence survives as literal text, backticks and all.
    try std.testing.expect(std.mem.find(u8, html, "```html") != null);
}

test "render produces a self-contained document with no external references" {
    const gpa = std.testing.allocator;
    const messages = [_]types.Message{
        .{ .role = .user, .content = "hello" },
        .{ .role = .assistant, .content = "hi" },
    };
    const html = try render(gpa, .{
        .id = "sess-plain",
        .title = "plain",
        .messages = &messages,
        .created = 1_700_000_000,
        .updated = 1_700_000_060,
    });
    defer gpa.free(html);

    try std.testing.expect(std.mem.startsWith(u8, html, "<!doctype html>"));
    try std.testing.expect(std.mem.endsWith(u8, html, "</html>\n"));
    // No fetch of any kind: no stylesheet, no font, no image, no script, and
    // nothing that could name a remote origin.
    for ([_][]const u8{ "<link", "<script", "src=", "@import", "url(", "http://", "https://", "//" }) |needle| {
        if (std.mem.find(u8, html, needle)) |at| {
            std.debug.print("self-contained export contains '{s}' at {d}\n", .{ needle, at });
            return error.ExportIsNotSelfContained;
        }
    }
    try std.testing.expect(std.mem.find(u8, html, "2023-11-14 22:13:20 UTC") != null);
}

test "render says so rather than showing nothing for an empty conversation" {
    const gpa = std.testing.allocator;
    const html = try render(gpa, .{
        .id = "sess-empty",
        .title = "",
        .messages = &.{},
        .created = 0,
        .updated = 0,
    });
    defer gpa.free(html);
    try std.testing.expect(std.mem.find(u8, html, "This conversation has no messages.") != null);
    // With no title, the id stands in for it rather than leaving a blank <h1>.
    try std.testing.expect(std.mem.find(u8, html, "<h1>sess-empty</h1>") != null);
}

test "defaultPath lands under state/exports" {
    const p = try defaultPath(std.testing.allocator, "abc-123");
    defer std.testing.allocator.free(p);
    try std.testing.expectEqualStrings("state/exports/abc-123.html", p);
}
