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
/// Bridges the vendored Preact/htm/signals ES modules onto window for the plugin API. Its
/// own file because the policy forbids inline script.
const preact_boot = @embedFile("webui/preact-boot.js");
const fleet = @embedFile("webui/features/fleet.js");
const arena_view = @embedFile("webui/features/arena.js");
const arena3d_view = @embedFile("webui/features/arena3d.js");
const board_view = @embedFile("webui/features/board.js");
const compare_view = @embedFile("webui/features/compare.js");
const goals_view = @embedFile("webui/features/goals.js");
const knowledge_view = @embedFile("webui/features/knowledge.js");
const prompts_view = @embedFile("webui/features/prompts.js");
const todos_view = @embedFile("webui/features/todos.js");
const models_view = @embedFile("webui/features/models.js");
const schedule_view = @embedFile("webui/features/schedule.js");
const search_view = @embedFile("webui/features/search.js");
const icons = @embedFile("webui/core/icons.js");
const ui = @embedFile("webui/core/ui.js");
const utils = @embedFile("webui/core/utils.js");
const vendor = @embedFile("webui/core/vendor.js");
const chat = @embedFile("webui/core/chat.js");
const labels = @embedFile("webui/core/labels.js");
const goals = @embedFile("webui/core/goals.js");
const stream = @embedFile("webui/core/stream.js");
const theme = @embedFile("webui/core/theme.js");
const overlay = @embedFile("webui/core/overlay.js");
const search = @embedFile("webui/core/search.js");
const composer = @embedFile("webui/core/composer.js");
const scroll = @embedFile("webui/core/scroll.js");
const dialog = @embedFile("webui/core/dialog.js");
const usage = @embedFile("webui/core/usage.js");
const status = @embedFile("webui/core/status.js");
const attachments = @embedFile("webui/core/attachments.js");
const logs = @embedFile("webui/core/logs.js");
const plugins = @embedFile("webui/core/plugins.js");
const palette = @embedFile("webui/core/palette.js");
const modelpicker = @embedFile("webui/core/modelpicker.js");
const tools = @embedFile("webui/core/tools.js");
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
    for ([_][]const u8{ page, styles, script, preact_boot, fleet, arena_view, arena3d_view, board_view, compare_view, goals_view, knowledge_view, prompts_view, todos_view, models_view, schedule_view, search_view, icons, ui, utils, vendor, chat, labels, goals, stream, theme, overlay, search, composer, scroll, dialog, usage, status, attachments, logs, plugins, palette, modelpicker, tools, markdown, graph, board }, [_][]const u8{ "index.html", "app.css", "app.js", "preact-boot.js", "features/fleet.js", "features/arena.js", "features/arena3d.js", "features/board.js", "features/compare.js", "features/goals.js", "features/knowledge.js", "features/prompts.js", "features/todos.js", "features/models.js", "features/schedule.js", "features/search.js", "core/icons.js", "core/ui.js", "core/utils.js", "core/vendor.js", "core/chat.js", "core/labels.js", "core/goals.js", "core/stream.js", "core/theme.js", "core/overlay.js", "core/search.js", "core/composer.js", "core/scroll.js", "core/dialog.js", "core/usage.js", "core/status.js", "core/attachments.js", "core/logs.js", "core/plugins.js", "core/palette.js", "core/modelpicker.js", "core/tools.js", "lib/markdown.js", "lib/graph.js", "lib/board.js" }) |asset, name| {
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
    if (std.mem.endsWith(u8, path, "/preact-boot.js")) return .{ .body = preact_boot, .content_type = "text/javascript; charset=utf-8" };
    if (std.mem.endsWith(u8, path, "/core/utils.js")) return .{ .body = utils, .content_type = "text/javascript; charset=utf-8" };
    if (std.mem.endsWith(u8, path, "/core/icons.js")) return .{ .body = icons, .content_type = "text/javascript; charset=utf-8" };
    if (std.mem.endsWith(u8, path, "/core/ui.js")) return .{ .body = ui, .content_type = "text/javascript; charset=utf-8" };
    if (std.mem.endsWith(u8, path, "/core/vendor.js")) return .{ .body = vendor, .content_type = "text/javascript; charset=utf-8" };
    if (std.mem.endsWith(u8, path, "/core/chat.js")) return .{ .body = chat, .content_type = "text/javascript; charset=utf-8" };
    if (std.mem.endsWith(u8, path, "/core/labels.js")) return .{ .body = labels, .content_type = "text/javascript; charset=utf-8" };
    if (std.mem.endsWith(u8, path, "/core/goals.js")) return .{ .body = goals, .content_type = "text/javascript; charset=utf-8" };
    if (std.mem.endsWith(u8, path, "/core/stream.js")) return .{ .body = stream, .content_type = "text/javascript; charset=utf-8" };
    if (std.mem.endsWith(u8, path, "/core/theme.js")) return .{ .body = theme, .content_type = "text/javascript; charset=utf-8" };
    if (std.mem.endsWith(u8, path, "/core/overlay.js")) return .{ .body = overlay, .content_type = "text/javascript; charset=utf-8" };
    if (std.mem.endsWith(u8, path, "/core/search.js")) return .{ .body = search, .content_type = "text/javascript; charset=utf-8" };
    if (std.mem.endsWith(u8, path, "/core/composer.js")) return .{ .body = composer, .content_type = "text/javascript; charset=utf-8" };
    if (std.mem.endsWith(u8, path, "/core/scroll.js")) return .{ .body = scroll, .content_type = "text/javascript; charset=utf-8" };
    if (std.mem.endsWith(u8, path, "/core/dialog.js")) return .{ .body = dialog, .content_type = "text/javascript; charset=utf-8" };
    if (std.mem.endsWith(u8, path, "/core/usage.js")) return .{ .body = usage, .content_type = "text/javascript; charset=utf-8" };
    if (std.mem.endsWith(u8, path, "/core/status.js")) return .{ .body = status, .content_type = "text/javascript; charset=utf-8" };
    if (std.mem.endsWith(u8, path, "/core/attachments.js")) return .{ .body = attachments, .content_type = "text/javascript; charset=utf-8" };
    if (std.mem.endsWith(u8, path, "/core/logs.js")) return .{ .body = logs, .content_type = "text/javascript; charset=utf-8" };
    if (std.mem.endsWith(u8, path, "/core/plugins.js")) return .{ .body = plugins, .content_type = "text/javascript; charset=utf-8" };
    if (std.mem.endsWith(u8, path, "/core/palette.js")) return .{ .body = palette, .content_type = "text/javascript; charset=utf-8" };
    if (std.mem.endsWith(u8, path, "/core/modelpicker.js")) return .{ .body = modelpicker, .content_type = "text/javascript; charset=utf-8" };
    if (std.mem.endsWith(u8, path, "/core/tools.js")) return .{ .body = tools, .content_type = "text/javascript; charset=utf-8" };
    if (std.mem.endsWith(u8, path, "/lib/markdown.js")) return .{ .body = markdown, .content_type = "text/javascript; charset=utf-8" };
    if (std.mem.endsWith(u8, path, "/lib/graph.js")) return .{ .body = graph, .content_type = "text/javascript; charset=utf-8" };
    if (std.mem.endsWith(u8, path, "/lib/board.js")) return .{ .body = board, .content_type = "text/javascript; charset=utf-8" };
    if (std.mem.endsWith(u8, path, "/features/fleet.js")) return .{ .body = fleet, .content_type = "text/javascript; charset=utf-8" };
    if (std.mem.endsWith(u8, path, "/features/arena.js")) return .{ .body = arena_view, .content_type = "text/javascript; charset=utf-8" };
    if (std.mem.endsWith(u8, path, "/features/arena3d.js")) return .{ .body = arena3d_view, .content_type = "text/javascript; charset=utf-8" };
    if (std.mem.endsWith(u8, path, "/features/board.js")) return .{ .body = board_view, .content_type = "text/javascript; charset=utf-8" };
    if (std.mem.endsWith(u8, path, "/features/compare.js")) return .{ .body = compare_view, .content_type = "text/javascript; charset=utf-8" };
    if (std.mem.endsWith(u8, path, "/features/goals.js")) return .{ .body = goals_view, .content_type = "text/javascript; charset=utf-8" };
    if (std.mem.endsWith(u8, path, "/features/knowledge.js")) return .{ .body = knowledge_view, .content_type = "text/javascript; charset=utf-8" };
    if (std.mem.endsWith(u8, path, "/features/prompts.js")) return .{ .body = prompts_view, .content_type = "text/javascript; charset=utf-8" };
    if (std.mem.endsWith(u8, path, "/features/todos.js")) return .{ .body = todos_view, .content_type = "text/javascript; charset=utf-8" };
    if (std.mem.endsWith(u8, path, "/features/models.js")) return .{ .body = models_view, .content_type = "text/javascript; charset=utf-8" };
    if (std.mem.endsWith(u8, path, "/features/schedule.js")) return .{ .body = schedule_view, .content_type = "text/javascript; charset=utf-8" };
    if (std.mem.endsWith(u8, path, "/features/search.js")) return .{ .body = search_view, .content_type = "text/javascript; charset=utf-8" };
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
