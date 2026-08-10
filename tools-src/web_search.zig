//! web_search tool: DuckDuckGo HTML search.
const std = @import("std");
const lib = @import("lib.zig");

const max_results = 8;

fn writeJsonString(out: *lib.Out, s: []const u8) !void {
    try out.writeAll("\"");
    for (s) |c| {
        switch (c) {
            '"' => try out.writeAll("\\\""),
            '\\' => try out.writeAll("\\\\"),
            '\n' => try out.writeAll("\\n"),
            '\r' => try out.writeAll("\\r"),
            '\t' => try out.writeAll("\\t"),
            else => {
                const buf = [1]u8{c};
                try out.writeAll(&buf);
            },
        }
    }
    try out.writeAll("\"");
}

fn percentEncodeSpaces(s: []const u8, buf: []u8) []const u8 {
    var i: usize = 0;
    var j: usize = 0;
    while (i < s.len and j + 3 <= buf.len) : (i += 1) {
        if (s[i] == ' ') {
            buf[j] = '%';
            buf[j + 1] = '2';
            buf[j + 2] = '0';
            j += 3;
        } else {
            buf[j] = s[i];
            j += 1;
        }
    }
    return buf[0..j];
}

fn tool_main(input: []const u8, out: *lib.Out) !void {
    var arena_state = std.heap.ArenaAllocator.init(std.heap.wasm_allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var query: []const u8 = "";
    if (std.json.parseFromSliceLeaky(std.json.Value, arena, input, .{})) |parsed| {
        if (parsed == .object) {
            if (parsed.object.get("query")) |q| {
                if (q == .string) query = q.string;
            }
        }
    } else |_| {}

    const prefix = "https://html.duckduckgo.com/html/?q=";
    var url_storage: [2048]u8 = undefined;
    @memcpy(url_storage[0..prefix.len], prefix);
    var url_len = prefix.len;
    const enc = percentEncodeSpaces(query, url_storage[url_len..]);
    url_len += enc.len;
    const url = url_storage[0..url_len];

    const html = lib.httpGet(url) catch |err| {
        try out.writeAll("{\"ok\":false,\"error\":");
        try writeJsonString(out, @errorName(err));
        try out.writeAll("}");
        return;
    };

    try out.writeAll("{\"ok\":true,\"results\":[");

    var count: usize = 0;
    var pos: usize = 0;
    while (count < max_results) {
        const a_marker = "result__a";
        const a_start = std.mem.indexOfPos(u8, html, pos, a_marker) orelse break;
        const href_start = std.mem.indexOfPos(u8, html, a_start, "href=\"") orelse break;
        const href_begin = href_start + 6;
        const href_end = std.mem.indexOfPos(u8, html, href_begin, "\"") orelse break;
        const url_str = html[href_begin..href_end];

        const tag_end = std.mem.indexOfPos(u8, html, href_end, ">") orelse break;
        const title_start = tag_end + 1;
        const title_end = std.mem.indexOfPos(u8, html, title_start, "</a>") orelse break;
        const title = html[title_start..title_end];

        const snip_marker = "result__snippet";
        const s_start = std.mem.indexOfPos(u8, html, title_end, snip_marker) orelse break;
        const s_tag_end = std.mem.indexOfPos(u8, html, s_start, ">") orelse break;
        const s_text_start = s_tag_end + 1;
        const s_text_end = std.mem.indexOfPos(u8, html, s_text_start, "<") orelse html.len;
        const snippet = html[s_text_start..s_text_end];

        if (count > 0) try out.writeAll(",");
        try out.writeAll("{\"title\":");
        try writeJsonString(out, title);
        try out.writeAll(",\"url\":");
        try writeJsonString(out, url_str);
        try out.writeAll(",\"snippet\":");
        try writeJsonString(out, snippet);
        try out.writeAll("}");

        count += 1;
        pos = title_end + 1;
    }

    try out.writeAll("]}");
}

export fn run(ptr: u32, len: u32) callconv(.c) u64 {
    return lib.run(ptr, len, tool_main);
}
