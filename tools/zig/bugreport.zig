//! bugreport: structured bug report → Kanban board card.
//!
//! Accepts a bug report with a template (title, description, steps to
//! reproduce, expected/actual behaviour, severity, environment), formats it
//! into a readable body, and posts it to the board as a high-priority backlog
//! card via ck_tool → kanban_add.
//!
//! Input:  {"title":"...", "description":"...", ...}
//! Output: {"ok":true, "card_id":"...", "board":{...}}

const std = @import("std");
const lib = @import("lib.zig");

export fn run(ptr: u32, len: u32) callconv(.c) u64 {
    return lib.run(ptr, len, tool_main);
}

fn tool_main(input: []const u8, out: *lib.Out) !void {
    const parsed = lib.object(input) catch
        return lib.fail(out, "expected a JSON object");

    const title_raw = lib.str(parsed, "title") catch
        return lib.fail(out, "missing required field: title");
    if (std.mem.trim(u8, title_raw, " \t\r\n").len == 0)
        return lib.fail(out, "title must be a non-empty string");
    const description = lib.optStr(parsed, "description");
    const steps = lib.optStr(parsed, "steps_to_reproduce");
    const expected = lib.optStr(parsed, "expected");
    const actual = lib.optStr(parsed, "actual");
    const severity = lib.optStr(parsed, "severity") orelse "normal";
    const environment = lib.optStr(parsed, "environment");
    const component = lib.optStr(parsed, "component") orelse inferComponent(title_raw);
    const room = lib.optStr(parsed, "room");
    const repro = lib.optStr(parsed, "repro");
    const fix_hint = lib.optStr(parsed, "fix_hint");

    const priority = mapSeverity(severity) orelse {
        var buf: [128]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "severity must be one of: critical, high, normal, medium, low, minor (got \"{s}\")", .{severity}) catch return lib.fail(out, "invalid severity");
        return lib.fail(out, msg);
    };

    var body_buf: std.ArrayList(u8) = .empty;
    defer body_buf.deinit(lib.alloc);

    try body_buf.appendSlice(lib.alloc, "## Bug Report\n\n");
    try appendField(&body_buf, "Severity", severity);
    try appendField(&body_buf, "Component", component);
    try appendField(&body_buf, "Environment", environment);
    try appendSection(&body_buf, "Description", description, null);
    try appendSection(&body_buf, "Steps to Reproduce", steps, null);
    try appendSection(&body_buf, "Expected Behaviour", expected, null);
    try appendSection(&body_buf, "Actual Behaviour", actual, null);
    try appendSection(&body_buf, "Reproduce", repro, "sh");
    try appendSection(&body_buf, "Fix hint", fix_hint, "");

    const prefix = "[BUG] ";
    var title_buf: [600]u8 = undefined;
    const title = blk: {
        if (std.ascii.startsWithIgnoreCase(title_raw, "[bug]")) break :blk title_raw;
        const max_title = title_buf.len - prefix.len;
        const t = if (title_raw.len > max_title) title_raw[0..max_title] else title_raw;
        break :blk std.fmt.bufPrint(&title_buf, prefix ++ "{s}", .{t}) catch title_raw;
    };

    var args_buf: std.ArrayList(u8) = .empty;
    defer args_buf.deinit(lib.alloc);
    {
        var w: std.Io.Writer.Allocating = .init(lib.alloc);
        defer w.deinit();
        var s = std.json.Stringify{ .writer = &w.writer, .options = .{ .emit_null_optional_fields = false } };
        try s.beginObject();
        try s.objectField("title");
        try s.write(title);
        try s.objectField("body");
        try s.write(body_buf.items);
        try s.objectField("column");
        try s.write("backlog");
        try s.objectField("priority");
        try s.write(priority);
        if (room) |r| {
            try s.objectField("room");
            try s.write(r);
        }
        try s.endObject();
        try args_buf.appendSlice(lib.alloc, w.written());
    }

    const result = lib.toolCall("kanban_add", args_buf.items) catch |err| {
        return lib.failErr(out, err, "posting the bug to the board");
    };

    // kanban_add's own reply carries ok, board and the new card id.
    try out.writeAll(result);
}

/// `**Name:** value` on its own line. An absent value writes nothing.
fn appendField(buf: *std.ArrayList(u8), name: []const u8, value: ?[]const u8) !void {
    const v = value orelse return;
    try buf.appendSlice(lib.alloc, "**");
    try buf.appendSlice(lib.alloc, name);
    try buf.appendSlice(lib.alloc, ":** ");
    try buf.appendSlice(lib.alloc, v);
    try buf.appendSlice(lib.alloc, "\n");
}

/// A `### heading` block, its body optionally in a fenced code block of the
/// named language. An absent or empty value writes nothing, heading included.
fn appendSection(buf: *std.ArrayList(u8), heading: []const u8, value: ?[]const u8, fence: ?[]const u8) !void {
    const v = value orelse return;
    if (v.len == 0) return;
    try buf.appendSlice(lib.alloc, "\n### ");
    try buf.appendSlice(lib.alloc, heading);
    try buf.appendSlice(lib.alloc, "\n");
    if (fence) |lang| {
        try buf.appendSlice(lib.alloc, "```");
        try buf.appendSlice(lib.alloc, lang);
        try buf.appendSlice(lib.alloc, "\n");
    }
    try buf.appendSlice(lib.alloc, v);
    try buf.appendSlice(lib.alloc, "\n");
    if (fence != null) try buf.appendSlice(lib.alloc, "```\n");
}

fn mapSeverity(sev: []const u8) ?[]const u8 {
    if (std.ascii.eqlIgnoreCase(sev, "critical") or
        std.ascii.eqlIgnoreCase(sev, "high"))
        return "high";
    if (std.ascii.eqlIgnoreCase(sev, "normal") or
        std.ascii.eqlIgnoreCase(sev, "medium"))
        return "normal";
    if (std.ascii.eqlIgnoreCase(sev, "low") or
        std.ascii.eqlIgnoreCase(sev, "minor"))
        return "low";
    return null;
}

fn inferComponent(title: []const u8) ?[]const u8 {
    const tokens = [_][]const u8{ "llm", "tui", "sandbox", "schedule", "serve", "tools", "webui", "chat", "memory", "auth", "config" };
    for (tokens) |tok| {
        if (std.ascii.indexOfIgnoreCase(title, tok)) |_| return tok;
    }
    return null;
}
