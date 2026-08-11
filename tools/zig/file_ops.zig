//! file_ops: the file operations that are not reading or editing text.
//!
//! move, copy, delete, mkdir, stat and append were all implemented in the host
//! and unreachable: nothing registered them with the runtime, so no guest could
//! call them and no tool exposed them. An agent could therefore create a file
//! and rewrite it, but never rename one, remove one, or ask how big it is.
//!
//! One tool rather than six, because these are the same question — "do this to
//! that path" — and six near-identical entries in every tool list costs more
//! attention than it saves.
//!
//! Input:  {"op": "move",   "path": "a.zig", "to": "b.zig"}
//!         {"op": "copy",   "path": "a.zig", "to": "b.zig"}
//!         {"op": "delete", "path": "old.zig"}
//!         {"op": "mkdir",  "path": "src/new"}
//!         {"op": "stat",   "path": "src/main.zig"}
//!         {"op": "append", "path": "notes.md", "content": "one more line\n"}
//! Output: {"ok": true, "op": "move", "path": "a.zig", "to": "b.zig"}
//!         {"ok": true, "op": "stat", "path": "...", "kind": "file", "size": 1234}

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

    const op = str(obj, "op") orelse
        return lib.fail(out, "missing \"op\": one of move, copy, delete, mkdir, stat, append, hash");
    const path = str(obj, "path") orelse
        return lib.fail(out, "missing required field: path");

    if (std.mem.eql(u8, op, "stat")) {
        const raw = lib.fsStat(path) catch |err| return lib.failErr(out, err, path);
        // Re-emitted rather than spliced in: writing the host's JSON straight
        // into the middle of a Stringify object produced "stat",{...} — a
        // comma where the colon belonged, and invalid JSON for the caller.
        const stat = std.json.parseFromSliceLeaky(std.json.Value, alloc, raw, .{}) catch
            return lib.fail(out, "could not read the stat result");
        var w = out.writer();
        var s = std.json.Stringify{ .writer = &w, .options = .{} };
        try s.beginObject();
        try s.objectField("ok");
        try s.write(true);
        try s.objectField("op");
        try s.write(op);
        try s.objectField("path");
        try s.write(path);
        if (stat == .object) {
            var it = stat.object.iterator();
            while (it.next()) |kv| {
                try s.objectField(kv.key_ptr.*);
                try s.write(kv.value_ptr.*);
            }
        }
        try s.endObject();
        out.len = w.end;
        return;
    }

    if (std.mem.eql(u8, op, "hash")) {
        const data = lib.fsRead(path) catch |err| return lib.failErr(out, err, path);
        const digest = lib.hash(data) catch |err| return lib.failErr(out, err, path);
        var w = out.writer();
        var s = std.json.Stringify{ .writer = &w, .options = .{} };
        try s.beginObject();
        try s.objectField("ok");
        try s.write(true);
        try s.objectField("op");
        try s.write(op);
        try s.objectField("path");
        try s.write(path);
        try s.objectField("sha256");
        try s.write(digest);
        try s.endObject();
        out.len = w.end;
        return;
    }

    if (std.mem.eql(u8, op, "append")) {
        const content = str(obj, "content") orelse
            return lib.fail(out, "append needs \"content\"");
        lib.fsAppend(path, content) catch |err| return lib.failErr(out, err, path);
        return done(out, op, path, null);
    }

    if (std.mem.eql(u8, op, "delete")) {
        lib.fsDelete(path) catch |err| return lib.failErr(out, err, path);
        return done(out, op, path, null);
    }

    if (std.mem.eql(u8, op, "mkdir")) {
        lib.fsMkdir(path) catch |err| return lib.failErr(out, err, path);
        return done(out, op, path, null);
    }

    const to = str(obj, "to") orelse
        return lib.fail(out, "move and copy need \"to\": the destination path");
    if (std.mem.eql(u8, op, "move")) {
        lib.fsRename(path, to) catch |err| return lib.failErr(out, err, path);
        return done(out, op, path, to);
    }
    if (std.mem.eql(u8, op, "copy")) {
        lib.fsCopy(path, to) catch |err| return lib.failErr(out, err, path);
        return done(out, op, path, to);
    }

    return lib.fail(out, "unknown op; use move, copy, delete, mkdir, stat, append or hash");
}

fn done(out: *lib.Out, op: []const u8, path: []const u8, to: ?[]const u8) !void {
    var w = out.writer();
    var s = std.json.Stringify{ .writer = &w, .options = .{ .emit_null_optional_fields = false } };
    try s.beginObject();
    try s.objectField("ok");
    try s.write(true);
    try s.objectField("op");
    try s.write(op);
    try s.objectField("path");
    try s.write(path);
    if (to) |dst| {
        try s.objectField("to");
        try s.write(dst);
    }
    try s.endObject();
    out.len = w.end;
}

fn str(obj: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    const v = obj.get(key) orelse return null;
    return if (v == .string and v.string.len > 0) v.string else null;
}
