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
const strip_xml = @import("strip_xml.zig");

const stripXmlTags = strip_xml.stripXmlTags;

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
