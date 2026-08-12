//! edit_file: change a file by replacing an exact piece of its text.
//!
//! Reading and searching were the only things an agent could do to this
//! project's source: the one write tool covered skills/, so a run asked to fix
//! something it had just diagnosed had no way to do it.
//!
//! Replacement is by exact match, never by line number, and the match must be
//! unique. A line number is stale the moment anything above it changes, and a
//! pattern occurring twice means the caller is guessing about which one it
//! meant; both are how an edit silently lands in the wrong place.
//!
//! Input:  {"path": "src/x.zig", "old": "exact text", "new": "replacement"}
//!         {"path": "src/new.zig", "content": "whole file", "create": true}
//!         create refuses a path that already exists unless overwrite is set.
//! Output: {"ok": true, "path": "src/x.zig", "replaced": 1, "bytes": 12043}
//!         {"ok": false, "error": "..."}

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

    const path = str(obj, "path") orelse return lib.fail(out, "missing required field: path");
    const create = switch (obj.get("create") orelse std.json.Value{ .bool = false }) {
        .bool => |b| b,
        else => false,
    };

    if (create) {
        const content = str(obj, "content") orelse
            return lib.fail(out, "create needs \"content\": the whole text of the new file");
        const overwrite = switch (obj.get("overwrite") orelse std.json.Value{ .bool = false }) {
            .bool => |b| b,
            else => false,
        };
        // Writing truncates, so creating over a path that already exists
        // destroys it and answers ok, with nothing in the result to say
        // anything was lost. Replacing text goes through an exact match for
        // exactly this reason; the create flag must not be the way around it.
        if (!overwrite) {
            if (existingSize(alloc, path)) |size| {
                var buf: [220]u8 = undefined;
                const msg = std.fmt.bufPrint(&buf, "{s} already exists ({d} bytes). Use old/new to change part of it, or pass overwrite: true to replace the whole file deliberately", .{ path, size }) catch
                    "that file already exists; use old/new, or pass overwrite: true";
                return lib.fail(out, msg);
            }
        }
        lib.fsWrite(path, content) catch |err| return lib.failErr(out, err, path);
        return report(out, path, 0, content.len);
    }

    const old = str(obj, "old") orelse
        return lib.fail(out, "needs \"old\" (exact text to replace) and \"new\", or \"create\": true with \"content\"");
    const new = switch (obj.get("new") orelse std.json.Value{ .string = "" }) {
        .string => |v| v,
        else => return lib.fail(out, "new must be a string"),
    };

    const current = lib.fsRead(path) catch |err| return lib.failErr(out, err, path);
    // Copied before the write below: fsRead hands back a slice of the host
    // arena, and the next host call moves it.
    const text = try alloc.dupe(u8, current);

    const hits = std.mem.count(u8, text, old);
    if (hits == 0) {
        // Which is more useful than "not found": the usual cause is whitespace
        // or a line the caller reconstructed from memory rather than read.
        return lib.fail(out, "the \"old\" text does not appear in the file; read it again and copy the exact bytes, including indentation");
    }
    if (hits > 1) {
        var buf: [160]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "the \"old\" text appears {d} times; include enough surrounding lines to make it unique", .{hits}) catch
            "the \"old\" text is not unique; include more surrounding lines";
        return lib.fail(out, msg);
    }

    const at = std.mem.find(u8, text, old).?;
    var result: std.ArrayList(u8) = .empty;
    defer result.deinit(alloc);
    try result.appendSlice(alloc, text[0..at]);
    try result.appendSlice(alloc, new);
    try result.appendSlice(alloc, text[at + old.len ..]);

    lib.fsWrite(path, result.items) catch |err| return lib.failErr(out, err, path);
    return report(out, path, 1, result.items.len);
}

/// The size of `path` if it is an existing file, else null.
fn existingSize(alloc: std.mem.Allocator, path: []const u8) ?u64 {
    const raw = lib.fsStat(path) catch return null;
    const st = std.json.parseFromSliceLeaky(std.json.Value, alloc, raw, .{}) catch return null;
    if (st != .object) return null;
    const kind = st.object.get("kind") orelse return null;
    if (kind != .string or !std.mem.eql(u8, kind.string, "file")) return null;
    const size = st.object.get("size") orelse return null;
    return switch (size) {
        .integer => |i| if (i < 0) null else @as(u64, @intCast(i)),
        else => null,
    };
}

fn report(out: *lib.Out, path: []const u8, replaced: usize, bytes: usize) !void {
    var w = out.writer();
    var s = std.json.Stringify{ .writer = &w, .options = .{} };
    try s.beginObject();
    try s.objectField("ok");
    try s.write(true);
    try s.objectField("path");
    try s.write(path);
    try s.objectField("replaced");
    try s.write(replaced);
    try s.objectField("bytes");
    try s.write(bytes);
    try s.endObject();
    out.len = w.end;
}

fn str(obj: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    const v = obj.get(key) orelse return null;
    return if (v == .string and v.string.len > 0) v.string else null;
}
