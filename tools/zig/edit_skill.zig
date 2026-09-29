//! skill_edit: write or replace a skill file inside skills/ (sandbox fs
//! prefix "skills/", root = project root).
//! Input:  {"path": "skills/<name>.md", "content": "..."}
//! Output: {"ok": true, "path": "..."}

const std = @import("std");
const lib = @import("lib.zig");

export fn run(ptr: u32, len: u32) callconv(.c) u64 {
    return lib.run(ptr, len, tool_main);
}

fn tool_main(input: []const u8, out: *lib.Out) !void {
    const parsed = try std.json.parseFromSliceLeaky(std.json.Value, lib.alloc, input, .{});
    if (parsed != .object) return lib.fail(out, "input must be a JSON object");
    const obj = parsed.object;

    const path = lib.strFieldRequired(obj, "path") orelse return lib.fail(out, "path must be a non-empty string");
    const content = lib.strFieldRequired(obj, "content") orelse return lib.fail(out, "content must be a non-empty string");

    if (content.len > 64 * 1024) return lib.fail(out, "content too large");

    lib.fsWrite(path, content) catch |err| {
        return lib.failErr(out, err, "writing the skill file");
    };

    var w = lib.writer(out);
    var s = lib.json(&w);
    try s.beginObject();
    try s.objectField("ok");
    try s.write(true);
    try s.objectField("path");
    try s.write(path);
    try s.endObject();
    lib.commit(out, &w);
}
