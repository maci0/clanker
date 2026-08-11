//! find_files: locate files by name, anywhere under a directory.
//!
//! list_files answers "what is in this directory" and search_code answers
//! "where does this text appear". Neither answers "where is the file called
//! something like loop", which is the question an agent asks when it has a name
//! from a stack trace, an import, or a half-remembered path.
//!
//! The host has done this since it was written and nothing could call it: the
//! ck_fs_find function was never registered with the runtime.
//!
//! Input:  {"pattern": "loop"}
//!         {"pattern": ".tool.json", "dir": "tools"}
//! Output: {"ok": true, "pattern": "loop", "dir": ".", "paths": [...], "count": 3}

const std = @import("std");
const lib = @import("lib.zig");

export fn run(ptr: u32, len: u32) callconv(.c) u64 {
    return lib.run(ptr, len, tool_main);
}

fn tool_main(input: []const u8, out: *lib.Out) !void {
    const alloc = std.heap.wasm_allocator;
    const parsed = std.json.parseFromSliceLeaky(std.json.Value, alloc, input, .{}) catch
        return lib.fail(out, "input must be a JSON object");
    if (parsed != .object) return lib.fail(out, "input must be a JSON object");
    const obj = parsed.object;

    const pattern = str(obj, "pattern") orelse
        return lib.fail(out, "missing \"pattern\": part of a file name, e.g. \"loop\", or a glob like \"*.tool.json\"");
    // The sandbox rejects "." as a path component, so the root is the empty
    // string. A caller writing "." means the same thing and should not be
    // refused for it.
    const asked_dir = str(obj, "dir") orelse ".";
    const dir = if (std.mem.eql(u8, asked_dir, ".") or std.mem.eql(u8, asked_dir, "./")) "" else asked_dir;

    // The host matches globs, not substrings: "loop" finds a file called
    // exactly "loop" and misses loop.zig, which is never what the caller
    // meant. A pattern with no glob character is taken as "name contains
    // this"; one with * or ? is passed through as written.
    const has_glob = std.mem.indexOfAny(u8, pattern, "*?") != null;
    var glob_buf: [512]u8 = undefined;
    const glob = if (has_glob)
        pattern
    else
        std.fmt.bufPrint(&glob_buf, "*{s}*", .{pattern}) catch pattern;

    const raw = lib.fsFind(dir, glob) catch |err| return lib.failErr(out, err, if (dir.len == 0) "the sandbox root" else dir);
    const found = std.json.parseFromSliceLeaky(std.json.Value, alloc, raw, .{}) catch
        return lib.fail(out, "could not read the search result");

    var w = out.writer();
    var s = std.json.Stringify{ .writer = &w, .options = .{} };
    try s.beginObject();
    try s.objectField("ok");
    try s.write(true);
    try s.objectField("pattern");
    try s.write(pattern);
    try s.objectField("dir");
    try s.write(if (dir.len == 0) "." else dir);
    try s.objectField("paths");
    try s.write(found);
    try s.objectField("count");
    try s.write(if (found == .array) found.array.items.len else 0);
    // Nothing found is an answer, not a failure, but a bare empty list invites
    // a second identical call with the same spelling.
    if (found == .array and found.array.items.len == 0) {
        try s.objectField("note");
        try s.write("nothing matched; the pattern matches file names, and * and ? are the only wildcards");
    }
    try s.endObject();
    out.len = w.end;
}

fn str(obj: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    const v = obj.get(key) orelse return null;
    return if (v == .string and v.string.len > 0) v.string else null;
}
