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
    const description = lib.optStr(parsed, "description");
    const steps = lib.optStr(parsed, "steps_to_reproduce");
    const expected = lib.optStr(parsed, "expected");
    const actual = lib.optStr(parsed, "actual");
    const severity = lib.optStr(parsed, "severity") orelse "normal";
    const environment = lib.optStr(parsed, "environment");
    const component = lib.optStr(parsed, "component");
    const room = lib.optStr(parsed, "room");

    // Validate severity → board priority mapping
    const priority = mapSeverity(severity) orelse
        return lib.fail(out, "severity must be one of: critical, high, normal, low");

    // Build the formatted body
    var body_buf: std.ArrayList(u8) = .empty;
    defer body_buf.deinit(lib.alloc);

    try body_buf.appendSlice(lib.alloc, "## Bug Report\n\n");

    try body_buf.appendSlice(lib.alloc, "**Severity:** ");
    try body_buf.appendSlice(lib.alloc, severity);
    try body_buf.appendSlice(lib.alloc, "\n");

    if (component) |c| {
        try body_buf.appendSlice(lib.alloc, "**Component:** ");
        try body_buf.appendSlice(lib.alloc, c);
        try body_buf.appendSlice(lib.alloc, "\n");
    }

    if (environment) |e| {
        try body_buf.appendSlice(lib.alloc, "**Environment:** ");
        try body_buf.appendSlice(lib.alloc, e);
        try body_buf.appendSlice(lib.alloc, "\n");
    }

    if (description) |d| {
        try body_buf.appendSlice(lib.alloc, "\n### Description\n");
        try body_buf.appendSlice(lib.alloc, d);
        try body_buf.appendSlice(lib.alloc, "\n");
    }

    if (steps) |s| {
        try body_buf.appendSlice(lib.alloc, "\n### Steps to Reproduce\n");
        try body_buf.appendSlice(lib.alloc, s);
        try body_buf.appendSlice(lib.alloc, "\n");
    }

    if (expected) |e| {
        try body_buf.appendSlice(lib.alloc, "\n### Expected Behaviour\n");
        try body_buf.appendSlice(lib.alloc, e);
        try body_buf.appendSlice(lib.alloc, "\n");
    }

    if (actual) |a| {
        try body_buf.appendSlice(lib.alloc, "\n### Actual Behaviour\n");
        try body_buf.appendSlice(lib.alloc, a);
        try body_buf.appendSlice(lib.alloc, "\n");
    }

    // Prefix title with [BUG] if it doesn't already have it
    var title_buf: [600]u8 = undefined;
    const title = blk: {
        if (std.ascii.startsWithIgnoreCase(title_raw, "[bug]")) {
            break :blk title_raw;
        }
        const n = std.fmt.bufPrint(&title_buf, "[BUG] {s}", .{title_raw}) catch title_raw;
        break :blk n;
    };

    // Build the kanban_add args as JSON
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

    // Call kanban_add via ck_tool
    const result = lib.toolCall("kanban_add", args_buf.items) catch |err| {
        return lib.failErr(out, err, "posting the bug to the board");
    };

    // Forward the kanban_add response — it contains ok, board, and the new card id
    try out.writeAll(result);
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
