//! youtube_transcript: fetch YouTube video captions as plain text.
//! Input:  {"video_id": "dQw4w9WgXcQ"}
//! Output: {"ok": true, "text": "<transcript>"}

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

    // Fetch the watch page to find a timedtext captions URL.
    const watch_url = std.fmt.allocPrint(lib.alloc, "https://www.youtube.com/watch?v={s}", .{video_id}) catch
        return lib.fail(out, "out of memory");
    defer lib.alloc.free(watch_url);

    const page = lib.httpGet(watch_url) catch |err|
        return lib.failErr(out, err, "fetching YouTube watch page");

    // Look for a timedtext URL in the page source.
    const captions_url = extractCaptionsUrl(page) orelse
        return lib.fail(out, "no captions found for this video (it may not have subtitles)");

    // Fetch the captions XML.
    const xml = lib.httpGet(captions_url) catch |err|
        return lib.failErr(out, err, "fetching captions XML");

    // Parse XML: strip tags, decode basic entities, join lines.
    const text = stripXmlTags(lib.alloc, xml) catch
        return lib.fail(out, "failed to parse captions XML");

    return lib.okText(out, text);
}

/// Extracts a timedtext/captions URL from the YouTube watch page HTML.
fn extractCaptionsUrl(page: []const u8) ?[]const u8 {
    // YouTube embeds captions URLs in the playerCaptionsTracklistRenderer.
    // Look for "baseUrl":"https://www.youtube.com/api/timedtext..."
    const needle = "\"baseUrl\":\"";
    const start = std.mem.find(u8, page, needle) orelse return null;
    const url_start = start + needle.len;
    const url_end_rel = std.mem.findScalar(u8, page[url_start..], '"') orelse return null;
    const raw_url = page[url_start .. url_start + url_end_rel];

    // The URL contains \u0026 for &; decode those.
    const decoded = decodeUrl(lib.alloc, raw_url) catch return null;
    return decoded;
}

/// Replaces \u0026 with & in a URL string.
fn decodeUrl(alloc: std.mem.Allocator, raw: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < raw.len) {
        if (i + 6 <= raw.len and std.mem.eql(u8, raw[i .. i + 6], "\\u0026")) {
            try out.append(alloc, '&');
            i += 6;
        } else {
            try out.append(alloc, raw[i]);
            i += 1;
        }
    }
    return out.toOwnedSlice(alloc);
}

/// Strips XML tags and decodes basic XML entities, producing plain text.
fn stripXmlTags(alloc: std.mem.Allocator, xml: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    var in_tag = false;
    while (i < xml.len) {
        if (xml[i] == '<') {
            // Check if this is a closing </text> — insert newline between segments.
            if (i + 2 < xml.len and xml[i + 1] == '/' and !in_tag) {
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
