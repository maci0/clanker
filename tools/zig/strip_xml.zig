//! Pure XML-to-text stripping for tools/zig/youtube_transcript.zig (timedtext
//! caption format). The guest is a sandboxed wasm module, where a `test` block
//! can never run, so the pure function its tests pin lives here and
//! `zig build test` runs them on the host.

const std = @import("std");

/// Strips XML tags and decodes basic XML entities, producing plain text.
/// Only a closing `</p>` breaks the line: the timedtext format wraps every
/// word in its own `<s>` element, and breaking on those made one word per
/// line.
pub fn stripXmlTags(alloc: std.mem.Allocator, xml: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    var in_tag = false;
    while (i < xml.len) {
        if (xml[i] == '<') {
            if (!in_tag and i + 3 < xml.len and xml[i + 1] == '/' and xml[i + 2] == 'p' and xml[i + 3] == '>') {
                if (out.items.len > 0 and out.items[out.items.len - 1] != '\n') {
                    try out.append(alloc, '\n');
                }
            }
            in_tag = true;
            i += 1;
        } else if (xml[i] == '>') {
            in_tag = false;
            i += 1;
        } else if (in_tag) {
            i += 1;
        } else if (xml[i] == '&') {
            if (i + 4 <= xml.len and std.mem.eql(u8, xml[i .. i + 4], "&lt;")) {
                try out.append(alloc, '<');
                i += 4;
            } else if (i + 4 <= xml.len and std.mem.eql(u8, xml[i .. i + 4], "&gt;")) {
                try out.append(alloc, '>');
                i += 4;
            } else if (i + 5 <= xml.len and std.mem.eql(u8, xml[i .. i + 5], "&amp;")) {
                try out.append(alloc, '&');
                i += 5;
            } else if (i + 6 <= xml.len and std.mem.eql(u8, xml[i .. i + 6], "&apos;")) {
                try out.append(alloc, '\'');
                i += 6;
            } else if (i + 6 <= xml.len and std.mem.eql(u8, xml[i .. i + 6], "&quot;")) {
                try out.append(alloc, '"');
                i += 6;
            } else if (i + 2 < xml.len and xml[i + 1] == '#') {
                // Numeric entity: captions use &#39; for every apostrophe.
                const semi = std.mem.findScalarPos(u8, xml, i + 2, ';') orelse {
                    try out.append(alloc, xml[i]);
                    i += 1;
                    continue;
                };
                const digits = xml[i + 2 .. semi];
                const cp = std.fmt.parseInt(u21, digits, 10) catch 0;
                if (cp > 0 and cp < 128) {
                    try out.append(alloc, @intCast(cp));
                } else if (cp >= 128) {
                    var buf: [4]u8 = undefined;
                    const n = std.unicode.utf8Encode(cp, &buf) catch 0;
                    try out.appendSlice(alloc, buf[0..n]);
                }
                i = semi + 1;
            } else if (std.mem.findScalarPos(u8, xml, i + 1, ';')) |semi| {
                // Skip unknown entity.
                i = semi + 1;
            } else {
                try out.append(alloc, xml[i]);
                i += 1;
            }
        } else {
            try out.append(alloc, xml[i]);
            i += 1;
        }
    }
    return out.toOwnedSlice(alloc);
}

test "stripXmlTags joins words and breaks on paragraph ends" {
    const xml = "<p t=\"80\"><s>In</s><s t=\"320\"> 1993,</s></p><p t=\"5440\"><s>hello</s></p>";
    const text = try stripXmlTags(std.testing.allocator, xml);
    defer std.testing.allocator.free(text);
    // The closing `</p>` of the final paragraph breaks the line too, so the
    // result ends with one newline rather than a dangling paragraph marker.
    try std.testing.expectEqualStrings("In 1993,\nhello\n", text);
}

test "stripXmlTags decodes entities" {
    const xml = "<p>a &amp; b &lt;c&gt; &#39;d</p>";
    const text = try stripXmlTags(std.testing.allocator, xml);
    defer std.testing.allocator.free(text);
    try std.testing.expectEqualStrings("a & b <c> 'd\n", text);
}

test "fuzz: no transcript bytes crash the stripper or amplify the text" {
    // Timedtext captions arrive off the network, so any byte sequence must
    // strip without crashing or hanging. Two invariants the fuzzer must keep:
    // stripping never *grows* the text (tags are dropped whole, a `</p>` line
    // break consumes four bytes to add one, and every entity decodes to fewer
    // bytes than it occupies), and valid UTF-8 stays valid UTF-8 — the entity
    // decoder is the only byte producer, and a swallowed utf8Encode failure
    // would surface here as a garbled transcript.
    const Ctx = struct {
        fn one(_: void, smith: *std.testing.Smith) anyerror!void {
            var buf: [4096]u8 = undefined;
            const len = smith.slice(&buf);
            const xml = buf[0..len];
            const text = stripXmlTags(std.testing.allocator, xml) catch return;
            defer std.testing.allocator.free(text);
            try std.testing.expect(text.len <= xml.len);
            if (std.unicode.utf8ValidateSlice(xml)) {
                try std.testing.expect(std.unicode.utf8ValidateSlice(text));
            }
        }
    };
    try std.testing.fuzz({}, Ctx.one, .{});
}
