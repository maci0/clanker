//! webui: serves the clanker web UI from the sandbox — markup, styles and
//! behaviour, each its own file under webui/ and embedded at comptime.
//! Third-party JS the page needs (graph layout, code highlighting) is vendored
//! and served separately by the native HTTP server from webui/vendor/ — see
//! handleWebui/handleWebuiVendor in cli.zig — rather than routed through this
//! tool, because those files are not ours to edit and never change.
//! Internal tool: it is never offered to the LLM; the `clanker serve` HTTP
//! server calls it to render GET /, /webui, /webui/app.css and /webui/app.js.
//! Input:  {"path": "/" | "/webui/app.css" | "/webui/app.js"}
//! Output: {"ok": true, "content_type": "text/html", "body": "..."}

const std = @import("std");
const lib = @import("lib.zig");

/// One file per language, so each can be edited, searched and reviewed as
/// what it is. They were a single 5,500-line index.html until the page needed
/// three different kinds of change at once.
const page = @embedFile("webui/index.html");
const styles = @embedFile("webui/app.css");
const script = @embedFile("webui/app.js");
/// Bridges VanJS's ES module into the global the classic scripts expect. Its
/// own file because the policy forbids inline script.
const van_boot = @embedFile("webui/van-boot.js");
const fleet = @embedFile("webui/features/fleet.js");
const icons = @embedFile("webui/core/icons.js");
const utils = @embedFile("webui/core/utils.js");
const vendor = @embedFile("webui/core/vendor.js");
const theme = @embedFile("webui/core/theme.js");
const markdown = @embedFile("webui/lib/markdown.js");
const graph = @embedFile("webui/lib/graph.js");
const board = @embedFile("webui/lib/board.js");

/// Bytes this asset occupies once JSON-encoded into the response envelope.
/// Matches std.json's default (escape_unicode = false): bytes 0x20-0x21,
/// 0x23-0x5B and 0x5D-0xFF pass through, `"` `\` and the seven short control
/// escapes take two bytes, every other control byte becomes \u00xx.
fn encodedLen(comptime asset: []const u8) usize {
    @setEvalBranchQuota(4 * asset.len);
    var encoded: usize = 2; // the enclosing quotes
    for (asset) |c| encoded += switch (c) {
        '"', '\\', 0x08, 0x0C, '\n', '\r', '\t' => 2,
        0x00...0x07, 0x0B, 0x0E...0x1F => 6,
        else => 1,
    };
    return encoded;
}

// Each asset reaches the browser JSON-encoded through lib.zig's shared output
// buffer, so the buffer — not the raw file size — is the real ceiling on how
// big any of them may get. Checked at build time: outgrowing it silently would
// otherwise surface as a 500 from `clanker serve` at request time. Each is
// checked on its own, because each is sent in its own response.
comptime {
    const overhead = "{\"ok\":true,\"content_type\":\"text/javascript; charset=utf-8\",\"body\":}".len;
    for ([_][]const u8{ page, styles, script, van_boot, fleet, icons, utils, vendor, theme, markdown, graph, board }, [_][]const u8{ "index.html", "app.css", "app.js", "van-boot.js", "features/fleet.js", "core/icons.js", "core/utils.js", "core/vendor.js", "core/theme.js", "lib/markdown.js", "lib/graph.js", "lib/board.js" }) |asset, name| {
        const envelope = overhead + encodedLen(asset);
        if (envelope > lib.out_cap) @compileError(std.fmt.comptimePrint(
            "webui/{s} JSON-encodes to {d} bytes, over lib.zig's out_cap of {d}. Shrink it or raise out_cap.",
            .{ name, envelope, lib.out_cap },
        ));
    }
}

export fn run(ptr: u32, len: u32) callconv(.c) u64 {
    return lib.run(ptr, len, tool_main);
}

const Asset = struct { body: []const u8, content_type: []const u8 };

/// Which file a request wants. Anything else is the page, because the app
/// routes its own paths client-side and a deep link must still load it.
fn assetFor(path: []const u8) Asset {
    if (std.mem.endsWith(u8, path, "/app.css")) return .{ .body = styles, .content_type = "text/css; charset=utf-8" };
    if (std.mem.endsWith(u8, path, "/app.js")) return .{ .body = script, .content_type = "text/javascript; charset=utf-8" };
    if (std.mem.endsWith(u8, path, "/van-boot.js")) return .{ .body = van_boot, .content_type = "text/javascript; charset=utf-8" };
    if (std.mem.endsWith(u8, path, "/core/utils.js")) return .{ .body = utils, .content_type = "text/javascript; charset=utf-8" };
    if (std.mem.endsWith(u8, path, "/core/icons.js")) return .{ .body = icons, .content_type = "text/javascript; charset=utf-8" };
    if (std.mem.endsWith(u8, path, "/core/vendor.js")) return .{ .body = vendor, .content_type = "text/javascript; charset=utf-8" };
    if (std.mem.endsWith(u8, path, "/core/theme.js")) return .{ .body = theme, .content_type = "text/javascript; charset=utf-8" };
    if (std.mem.endsWith(u8, path, "/lib/markdown.js")) return .{ .body = markdown, .content_type = "text/javascript; charset=utf-8" };
    if (std.mem.endsWith(u8, path, "/lib/graph.js")) return .{ .body = graph, .content_type = "text/javascript; charset=utf-8" };
    if (std.mem.endsWith(u8, path, "/lib/board.js")) return .{ .body = board, .content_type = "text/javascript; charset=utf-8" };
    if (std.mem.endsWith(u8, path, "/features/fleet.js")) return .{ .body = fleet, .content_type = "text/javascript; charset=utf-8" };
    return .{ .body = page, .content_type = "text/html; charset=utf-8" };
}

fn tool_main(input: []const u8, out: *lib.Out) !void {
    const parsed = try std.json.parseFromSliceLeaky(std.json.Value, lib.alloc, input, .{});
    var path: []const u8 = "/";
    if (parsed == .object) {
        if (parsed.object.get("path")) |v| {
            if (v == .string) path = v.string;
        }
    }
    const asset = assetFor(path);
    // Encoded straight into the shared output buffer: an intermediate stack
    // copy would duplicate the whole asset and cap it at its own size rather
    // than at out_cap.
    var w: std.Io.Writer = .fixed(out.buf);
    var s = std.json.Stringify{ .writer = &w, .options = .{ .emit_null_optional_fields = false } };
    try s.beginObject();
    try s.objectField("ok");
    try s.write(true);
    try s.objectField("content_type");
    try s.write(asset.content_type);
    try s.objectField("body");
    try s.write(asset.body);
    try s.endObject();
    out.len = w.end;
}
