//! fetch_web: HTTP GET a URL (host must be in the tool's network allowlist).
//! Input:  {"url": "https://..."}
//! Output: {"ok": true, "bytes": <num>, "body": "<up to N chars>"} or error.

const std = @import("std");
const lib = @import("lib.zig");

export fn run(ptr: u32, len: u32) callconv(.c) u64 {
    return lib.run(ptr, len, tool_main);
}

fn tool_main(input: []const u8, out: *lib.Out) !void {
    const parsed = try std.json.parseFromSliceLeaky(std.json.Value, lib.alloc, input, .{});
    if (parsed != .object) return lib.fail(out, "input must be a JSON object");
    const obj = parsed.object;
    const url = switch (obj.get("url") orelse return lib.fail(out, "missing url")) {
        .string => |s| s,
        else => return lib.fail(out, "url must be a string"),
    };

    const body = lib.httpGet(url) catch |err| {
        return lib.failErr(out, err, "fetching the page");
    };

    // 8000 bytes, not characters: a mid-sequence cut used to land invalid
    // UTF-8 in a hand-built JSON string and break every .ok parser.
    const truncated = lib.utf8Prefix(body, 8000);
    var w = lib.writer(out);
    var s = lib.json(&w);
    try s.beginObject();
    try s.objectField("ok");
    try s.write(true);
    try s.objectField("bytes");
    try s.write(body.len);
    try s.objectField("body");
    try s.write(truncated);
    try s.endObject();
    lib.commit(out, &w);
}
