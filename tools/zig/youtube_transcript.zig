//! youtube_transcript: fetch YouTube video captions as plain text.
//! Input:  {"video_id": "dQw4w9WgXcQ"}
//! Output: {"ok": true, "text": "<transcript>"}
//!
//! Scraping the watch page for the caption URL stopped working twice over:
//! the first `"baseUrl"` in that HTML is a stats ping, not a caption track,
//! and the web client's timedtext URLs now return an empty 200 without a
//! proof-of-origin token. The innertube player API asked as the ANDROID
//! client hands back caption URLs that still work with a plain GET, which
//! is the same route youtube-transcript-api and yt-dlp take.

const std = @import("std");
const lib = @import("lib.zig");

export fn run(ptr: u32, len: u32) callconv(.c) u64 {
    return lib.run(ptr, len, tool_main);
}

fn tool_main(input: []const u8, out: *lib.Out) !void {
    const obj = lib.object(input) catch return lib.fail(out, "expected a JSON object");
    const video_id = lib.str(obj, "video_id") catch return lib.fail(out, "\"video_id\" is required");

    if (video_id.len == 0 or video_id.len > 64)
        return lib.fail(out, "video_id looks invalid");
    for (video_id) |c| {
        if (!std.ascii.isAlphanumeric(c) and c != '-' and c != '_')
            return lib.fail(out, "video_id looks invalid");
    }

    const body = std.fmt.allocPrint(
        lib.alloc,
        "{{\"context\":{{\"client\":{{\"clientName\":\"ANDROID\",\"clientVersion\":\"20.10.38\",\"androidSdkVersion\":31}}}},\"videoId\":\"{s}\"}}",
        .{video_id},
    ) catch return lib.fail(out, "out of memory");
    defer lib.alloc.free(body);

    const player_raw = lib.httpPostHdr(
        "https://www.youtube.com/youtubei/v1/player",
        body,
        "{\"Content-Type\":\"application/json\"}",
    ) catch |err| return lib.failErr(out, err, "asking the YouTube player API");

    const player = std.json.parseFromSliceLeaky(std.json.Value, lib.alloc, player_raw, .{}) catch
        return lib.fail(out, "player API returned something that is not JSON");
    if (player != .object) return lib.fail(out, "player API returned something that is not JSON");

    if (player.object.get("playabilityStatus")) |ps| {
        if (ps == .object) {
            if (ps.object.get("status")) |st| {
                if (st == .string and !std.mem.eql(u8, st.string, "OK")) {
                    const reply = std.fmt.allocPrint(lib.alloc, "video is not playable: {s}", .{st.string}) catch
                        return lib.fail(out, "video is not playable");
                    return lib.fail(out, reply);
                }
            }
        }
    }

    const captions_url = captionTrackUrl(player) orelse
        return lib.fail(out, "no captions on this video (not even auto-generated ones)");

    const xml = lib.httpGet(captions_url) catch |err|
        return lib.failErr(out, err, "fetching captions");
    if (xml.len == 0)
        return lib.fail(out, "captions URL returned an empty reply");

    const text = stripXmlTags(lib.alloc, xml) catch
        return lib.fail(out, "failed to parse captions XML");
    if (std.mem.trim(u8, text, " \t\r\n").len == 0)
        return lib.fail(out, "captions parsed to empty text");

    return lib.okText(out, text);
}

/// The first manually-written caption track's URL, or the first track of any
/// kind when every track is auto-generated (`"kind":"asr"`).
fn captionTrackUrl(player: std.json.Value) ?[]const u8 {
    const captions = player.object.get("captions") orelse return null;
    if (captions != .object) return null;
    const renderer = captions.object.get("playerCaptionsTracklistRenderer") orelse return null;
    if (renderer != .object) return null;
    const tracks = renderer.object.get("captionTracks") orelse return null;
    if (tracks != .array or tracks.array.items.len == 0) return null;

    var fallback: ?[]const u8 = null;
    for (tracks.array.items) |t| {
        if (t != .object) continue;
        const base = t.object.get("baseUrl") orelse continue;
        if (base != .string) continue;
        if (fallback == null) fallback = base.string;
        const kind = t.object.get("kind") orelse {
            return base.string; // no kind field: a human-uploaded track
        };
        if (kind != .string or !std.mem.eql(u8, kind.string, "asr")) return base.string;
    }
    return fallback;
}

/// Strips XML tags and decodes basic XML entities, producing plain text.
/// Only a closing `</p>` breaks the line: the timedtext format wraps every
/// word in its own `<s>` element, and breaking on those made one word per
/// line.
fn stripXmlTags(alloc: std.mem.Allocator, xml: []const u8) ![]const u8 {
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
    try std.testing.expectEqualStrings("In 1993,\nhello", text);
}

test "stripXmlTags decodes entities" {
    const xml = "<p>a &amp; b &lt;c&gt; &#39;d</p>";
    const text = try stripXmlTags(std.testing.allocator, xml);
    defer std.testing.allocator.free(text);
    try std.testing.expectEqualStrings("a & b <c> 'd", text);
}
