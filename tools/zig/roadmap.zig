//! roadmap: read the project roadmap (docs/ROADMAP.md), list the planned
//! items so tasks can pick the next one to implement.
//! The roadmap keeps items as plain "- " bullets grouped under "## " section
//! headings ("Done", "Planned", "Autolearn"); everything outside "## Done" is
//! open work. Checkbox bullets ("- [ ]" / "- [x]") are also understood, and
//! their mark wins over the section they sit in.
//! Input:  {"list": "planned" | "all"}
//! Output: {"ok": true, "text": "<roadmap items>"}

const std = @import("std");
const lib = @import("lib.zig");

export fn run(ptr: u32, len: u32) callconv(.c) u64 {
    return lib.run(ptr, len, tool_main);
}

fn tool_main(input: []const u8, out: *lib.Out) !void {
    const parsed = try std.json.parseFromSliceLeaky(std.json.Value, lib.alloc, input, .{});
    var want_all = false;
    if (parsed == .object) {
        if (parsed.object.get("list")) |l| {
            if (l == .string and std.mem.eql(u8, l.string, "planned")) {
                want_all = false;
            } else if (l == .string and std.mem.eql(u8, l.string, "all")) {
                want_all = true;
            } else {
                return lib.fail(out, "list must be \"planned\" or \"all\"");
            }
        }
    }
    const md = lib.fsRead("docs/ROADMAP.md") catch return lib.fail(out, "ROADMAP.md unreadable");

    var text: std.ArrayList(u8) = .empty;
    defer text.deinit(lib.alloc);
    // Only end-trimmed: a bullet counts when "- " starts at column 0, so the
    // indented sub-bullets under a multi-line item stay part of their parent
    // instead of showing up as items of their own.
    var in_done = false;
    var it = std.mem.splitScalar(u8, md, '\n');
    while (it.next()) |line| {
        const trimmed = std.mem.trimEnd(u8, line, " \t\r");
        if (std.mem.startsWith(u8, trimmed, "## ")) {
            in_done = std.mem.eql(u8, trimmed[3..], "Done");
            // In "all" mode the headings are what tells done and planned
            // apart, since plain bullets carry no mark of their own.
            if (want_all) {
                if (text.items.len > 0) try text.append(lib.alloc, '\n');
                try text.appendSlice(lib.alloc, trimmed);
            }
            continue;
        }
        if (!std.mem.startsWith(u8, trimmed, "- ")) continue;
        const done = if (std.mem.startsWith(u8, trimmed, "- [x]"))
            true
        else if (std.mem.startsWith(u8, trimmed, "- [ ]"))
            false
        else
            in_done;
        if (done and !want_all) continue;
        if (text.items.len > 0) try text.append(lib.alloc, '\n');
        try text.appendSlice(lib.alloc, trimmed);
    }
    if (text.items.len == 0) try text.appendSlice(lib.alloc, "(no planned items)");

    return lib.okText(out, text.items);
}
