//! mutate: generic mutator transform plugin. Wraps tool results (`after`)
//! and asks the model to rewrite them according to a configurable
//! `instruction` template. Generalizes `translate`.
//!
//! Input:  {"tool": "...", "phase": "after", "payload": "<json>", "prior": [...]}
//! Output: {"ok": true, "payload": "<rewritten>"}  or {"ok":false} to decline.
//!
//! Settings come from `config` in tools/manifests/mutate.tool.json:
//!   instruction  LLM instruction template (may contain {{lang}} and {{tool}})
//!   lang         shorthand for the common translate case (default "en")
//!   mode         "json" (default) | "text" — json validates the reply is JSON
//!   max_tokens   forwarded to ck_llm via the harness

const std = @import("std");
const lib = @import("lib.zig");

const Settings = struct {
    instruction: []const u8 = "",
    lang: []const u8 = "en",
    mode: []const u8 = "json",
};

const Request = struct {
    tool: []const u8 = "",
    phase: []const u8 = "",
    payload: []const u8 = "",
    prior: []const []const u8 = &.{},
};

export fn run(ptr: u32, len: u32) callconv(.c) u64 {
    return lib.run(ptr, len, tool_main);
}

fn tool_main(input: []const u8, out: *lib.Out) !void {
    const alloc = lib.alloc;
    const req = std.json.parseFromSliceLeaky(Request, alloc, input, .{ .ignore_unknown_fields = true }) catch
        return declineJson(out, "input is not a transform request");
    if (req.payload.len == 0) return declineJson(out, "empty payload");

    const settings = std.json.parseFromSliceLeaky(Settings, alloc, lib.config(), .{ .ignore_unknown_fields = true }) catch Settings{};
    const mode_is_json = !std.mem.eql(u8, settings.mode, "text");

    const instruction_template = if (settings.instruction.len > 0) settings.instruction else "Translate the human-readable text in this JSON tool result into {{lang}}.\n\nRules:\n- Return only the JSON, no fences and no commentary.\n- Keep the exact same structure, keys, and value types.\n- Leave identifiers, URLs, file paths, code, and numbers untouched.\n- If nothing needs translating, return the input unchanged.";

    const instruction = try interpolate(alloc, instruction_template, settings.lang, req.tool);

    const prompt = try std.fmt.allocPrint(alloc,
        \\{s}
        \\
        \\Tool: {s}
        \\
        \\{s}
    , .{ instruction, req.tool, req.payload });

    const answer = lib.llm(prompt) catch |err| {
        lib.log(2, @errorName(err));
        return declineJson(out, "llm call failed");
    };

    const cleaned = stripFences(std.mem.trim(u8, answer, " \t\r\n"));
    if (mode_is_json) {
        const is_json = std.json.validate(alloc, cleaned) catch false;
        if (!is_json) return declineJson(out, "model returned text that is not JSON");
    }

    try okJson(out, cleaned);
}

fn interpolate(alloc: std.mem.Allocator, tmpl: []const u8, lang: []const u8, tool: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < tmpl.len) {
        if (std.mem.startsWith(u8, tmpl[i..], "{{lang}}")) {
            try out.appendSlice(alloc, lang);
            i += "{{lang}}".len;
        } else if (std.mem.startsWith(u8, tmpl[i..], "{{tool}}")) {
            try out.appendSlice(alloc, tool);
            i += "{{tool}}".len;
        } else {
            try out.append(alloc, tmpl[i]);
            i += 1;
        }
    }
    return out.toOwnedSlice(alloc);
}

fn stripFences(s: []const u8) []const u8 {
    if (!std.mem.startsWith(u8, s, "```")) return s;
    const first_nl = std.mem.indexOfScalar(u8, s, '\n') orelse return s;
    const body = s[first_nl + 1 ..];
    const close = std.mem.lastIndexOf(u8, body, "```") orelse return body;
    return std.mem.trim(u8, body[0..close], " \t\r\n");
}

fn okJson(out: *lib.Out, payload: []const u8) !void {
    var buf: [64 * 1024]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    var s2 = std.json.Stringify{ .writer = &w, .options = .{} };
    try s2.beginObject();
    try s2.objectField("ok");
    try s2.write(true);
    try s2.objectField("payload");
    try s2.write(payload);
    try s2.endObject();
    try out.writeAll(buf[0..w.end]);
}

fn declineJson(out: *lib.Out, reason: []const u8) !void {
    var buf: [512]u8 = undefined;
    const body = try std.fmt.bufPrint(&buf, "{{\"ok\":false,\"error\":\"{s}\"}}", .{reason});
    try out.writeAll(body);
}
