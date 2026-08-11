//! format: convert a markdown subset to ANSI escape sequences.
//! Rules: **bold** -> ESC[1m...ESC[0m; *italic* -> ESC[3m...ESC[0m;
//! `inline code` -> ESC[36m...ESC[0m; ```fenced blocks``` -> dim ESC[2m;
//! line-initial "- " list items -> bullet prefix "• ".
//! Input:  {"text": "..."}
//! Output: {"ok": true, "text": "<ansi>"}

const std = @import("std");
const lib = @import("lib.zig");

export fn run(ptr: u32, len: u32) callconv(.c) u64 {
    return lib.run(ptr, len, tool_main);
}

fn tool_main(input: []const u8, out: *lib.Out) !void {
    const parsed = try std.json.parseFromSliceLeaky(std.json.Value, lib.alloc, input, .{});
    const obj = parsed.object;
    const text = switch (obj.get("text") orelse return lib.fail(out, "missing text")) {
        .string => |s| s,
        else => return lib.fail(out, "text must be a string"),
    };

    const ansi = try render(text);
    defer lib.alloc.free(ansi);

    try out.writeAll("{\"ok\":true,\"text\":\"");
    try writeEscaped(out, ansi);
    try out.writeAll("\"}");
}

fn render(input: []const u8) ![]const u8 {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(lib.alloc);

    var in_fence = false;
    var in_bold = false;
    var in_italic = false;
    var in_code = false;

    var i: usize = 0;
    while (i < input.len) {
        // triple backtick (fenced code block)
        if (i + 2 < input.len and std.mem.eql(u8, input[i .. i + 3], "```")) {
            if (!in_fence) {
                try buf.appendSlice(lib.alloc, "\x1b[2m");
                in_fence = true;
            } else {
                try buf.appendSlice(lib.alloc, "\x1b[0m");
                in_fence = false;
            }
            i += 3;
            continue;
        }
        if (in_fence) {
            try buf.append(lib.alloc, input[i]);
            i += 1;
            continue;
        }
        // bold **
        if (i + 1 < input.len and std.mem.eql(u8, input[i .. i + 2], "**")) {
            if (!in_bold) {
                try buf.appendSlice(lib.alloc, "\x1b[1m");
                in_bold = true;
            } else {
                try buf.appendSlice(lib.alloc, "\x1b[0m");
                in_bold = false;
            }
            i += 2;
            continue;
        }
        // inline code `
        if (input[i] == '`') {
            if (!in_code) {
                try buf.appendSlice(lib.alloc, "\x1b[36m");
                in_code = true;
            } else {
                try buf.appendSlice(lib.alloc, "\x1b[0m");
                in_code = false;
            }
            i += 1;
            continue;
        }
        // italic *
        if (input[i] == '*') {
            if (!in_italic) {
                try buf.appendSlice(lib.alloc, "\x1b[3m");
                in_italic = true;
            } else {
                try buf.appendSlice(lib.alloc, "\x1b[0m");
                in_italic = false;
            }
            i += 1;
            continue;
        }
        // bullet prefix: line starting with "- "
        if ((i == 0 or input[i - 1] == '\n') and i + 1 < input.len and input[i] == '-' and input[i + 1] == ' ') {
            try buf.appendSlice(lib.alloc, "\u{2022} ");
            i += 2;
            continue;
        }
        try buf.append(lib.alloc, input[i]);
        i += 1;
    }
    // Close any open formatting (defensive)
    if (in_code) try buf.appendSlice(lib.alloc, "\x1b[0m");
    if (in_italic) try buf.appendSlice(lib.alloc, "\x1b[0m");
    if (in_bold) try buf.appendSlice(lib.alloc, "\x1b[0m");
    if (in_fence) try buf.appendSlice(lib.alloc, "\x1b[0m");

    return buf.toOwnedSlice(lib.alloc);
}

fn writeEscaped(out: *lib.Out, s: []const u8) !void {
    for (s) |ch| {
        switch (ch) {
            '"' => try out.writeAll("\\\""),
            '\\' => try out.writeAll("\\\\"),
            '\n' => try out.writeAll("\\n"),
            '\r' => try out.writeAll("\\r"),
            '\t' => try out.writeAll("\\t"),
            0...8, 11...12, 14...31 => {
                var eb: [8]u8 = undefined;
                const esc = try std.fmt.bufPrint(&eb, "\\u{x:0>4}", .{ch});
                try out.writeAll(esc);
            },
            else => try out.writeAll(&[_]u8{ch}),
        }
    }
}
