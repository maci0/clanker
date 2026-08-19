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
const hashline = @import("hashline.zig");

export fn run(ptr: u32, len: u32) callconv(.c) u64 {
    return lib.run(ptr, len, tool_main);
}

fn tool_main(input: []const u8, out: *lib.Out) !void {
    const alloc = lib.alloc;
    const parsed = std.json.parseFromSliceLeaky(std.json.Value, alloc, input, .{}) catch
        return lib.fail(out, "input must be a JSON object");
    if (parsed != .object) return lib.fail(out, "input must be a JSON object");
    const obj = parsed.object;

    const path = str(obj, "path") orelse return lib.fail(out, "missing required field: path");
    const create = switch (obj.get("create") orelse std.json.Value{ .bool = false }) {
        .bool => |b| b,
        else => false,
    };

    if (str(obj, "op")) |op| {
        if (std.mem.eql(u8, op, "hashline")) return applyHashline(obj, path, out);
        return lib.fail(out, "unknown op; use \"hashline\" or omit op for exact-text replace");
    }

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

fn applyHashline(obj: std.json.ObjectMap, path: []const u8, out: *lib.Out) !void {
    const alloc = lib.alloc;
    const hunks_v = obj.get("hunks") orelse return lib.fail(out, "hashline needs \"hunks\"");
    if (hunks_v != .array or hunks_v.array.items.len == 0)
        return lib.fail(out, "hashline needs a non-empty hunks array");

    var hunks: std.ArrayList(hashline.Hunk) = .empty;
    for (hunks_v.array.items) |item| {
        if (item != .object) return lib.fail(out, "each hunk must be an object");
        const h = item.object;
        const hash_s = str(h, "anchor_hash") orelse
            return lib.fail(out, "hunk needs \"anchor_hash\"");
        const hash = hashline.parseHash(hash_s) orelse
            return lib.fail(out, "anchor_hash must be 4 lowercase hex digits");
        const old_count = switch (h.get("old_count") orelse std.json.Value{ .integer = 1 }) {
            .integer => |n| if (n < 1) 1 else @as(usize, @intCast(n)),
            else => 1,
        };
        const new_text = joinNewLines(alloc, h) catch
            return lib.fail(out, "hunk needs \"new_lines\" (array of strings)");
        const anchor_line: usize = switch (h.get("anchor_line") orelse std.json.Value{ .integer = 1 }) {
            .integer => |n| if (n < 1) 1 else @as(usize, @intCast(n)),
            else => 1,
        };
        try hunks.append(alloc, .{
            .anchor_hash = hash,
            .anchor_line = anchor_line,
            .old_count = old_count,
            .new_text = new_text,
        });
    }

    const current = lib.fsRead(path) catch |err| return lib.failErr(out, err, path);
    const text = try alloc.dupe(u8, current);
    const result = hashline.apply(alloc, text, hunks.items, 10) catch |err| {
        const msg: []const u8 = switch (err) {
            error.AnchorNotFound => "hashline mismatch: anchor hash not found within ±10 lines of the given line (file may have changed since it was read)",
            error.PastEnd => "hashline mismatch: old_count extends past the end of the file",
            error.OverlappingHunks => "hashline mismatch: hunks replace overlapping line ranges",
            error.HashMismatch => "hashline mismatch: a line hash did not match (file may have changed since it was read)",
            error.OutOfMemory => "out of memory",
        };
        return lib.fail(out, msg);
    };

    lib.fsWrite(path, result.text) catch |err| return lib.failErr(out, err, path);

    var w = out.writer();
    var s = std.json.Stringify{ .writer = &w, .options = .{} };
    try s.beginObject();
    try s.objectField("ok");
    try s.write(true);
    try s.objectField("path");
    try s.write(path);
    try s.objectField("bytes");
    try s.write(result.text.len);
    try s.objectField("hunks");
    try s.beginArray();
    for (result.applied) |a| {
        try s.beginObject();
        try s.objectField("start_line");
        try s.write(a.start_line);
        try s.objectField("hashes");
        try s.beginArray();
        for (a.hashes) |hx| try s.write(&hx);
        try s.endArray();
        try s.endObject();
    }
    try s.endArray();
    try s.endObject();
    out.len = w.end;
}

fn joinNewLines(alloc: std.mem.Allocator, h: std.json.ObjectMap) ![]const u8 {
    const v = h.get("new_lines") orelse return error.Missing;
    if (v != .array) return error.Missing;
    var out: std.ArrayList(u8) = .empty;
    for (v.array.items, 0..) |item, i| {
        if (item != .string) return error.Missing;
        try out.appendSlice(alloc, item.string);
        if (i + 1 < v.array.items.len) try out.append(alloc, '\n');
    }
    if (out.items.len > 0 and out.items[out.items.len - 1] != '\n') try out.append(alloc, '\n');
    return out.toOwnedSlice(alloc);
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

const str = lib.strFieldRequired;
