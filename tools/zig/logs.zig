//! logs: list and tail harness log files under state/logs/.
//! Input:  {} | {"name": "<filename>"}
//! Output: {"ok": true, "logs": [{"name": "...", "bytes": N}]}
//!         {"ok": true, "name": "...", "bytes": N, "text": "<tail>"}
//!
//! The web UI's log view used to read this directory from src/cli.zig. Same
//! JSON the page already consumes; the guest owns listing, the name check,
//! and the line-aligned tail.

const std = @import("std");
const lib = @import("lib.zig");
const view = @import("log_view.zig");

const logs_dir = "state/logs";

export fn run(ptr: u32, len: u32) callconv(.c) u64 {
    return lib.run(ptr, len, tool_main);
}

fn tool_main(input: []const u8, out: *lib.Out) !void {
    const req = lib.object(input) catch return lib.fail(out, "input must be a JSON object");
    if (lib.optStr(req, "name")) |name| return tailOne(out, name);
    return listAll(out);
}

fn listAll(out: *lib.Out) !void {
    const raw = lib.fsList(logs_dir) catch |err| switch (err) {
        error.NotFound => {
            try out.writeAll("{\"ok\":true,\"logs\":[]}");
            return;
        },
        else => return lib.failErr(out, err, "listing state/logs"),
    };
    const names = try std.json.parseFromSliceLeaky(std.json.Value, lib.alloc, raw, .{});

    var w = lib.writer(out);
    var s = lib.json(&w);
    try s.beginObject();
    try s.objectField("ok");
    try s.write(true);
    try s.objectField("logs");
    try s.beginArray();
    if (names == .array) {
        for (names.array.items) |item| {
            if (item != .string) continue;
            const name = item.string;
            if (name.len == 0 or name[name.len - 1] == '/') continue;
            if (!view.validName(name)) continue;
            const path = try std.fmt.allocPrint(lib.alloc, "{s}/{s}", .{ logs_dir, name });
            const st_raw = lib.fsStat(path) catch continue;
            const st = std.json.parseFromSliceLeaky(std.json.Value, lib.alloc, st_raw, .{}) catch continue;
            const size = statSize(st) orelse continue;
            try s.beginObject();
            try s.objectField("name");
            try s.write(name);
            try s.objectField("bytes");
            try s.write(size);
            try s.endObject();
        }
    }
    try s.endArray();
    try s.endObject();
    lib.commit(out, &w);
}

fn tailOne(out: *lib.Out, name: []const u8) !void {
    if (!view.validName(name)) return lib.fail(out, "no such log");

    const listing = lib.fsList(logs_dir) catch |err| switch (err) {
        error.NotFound => return lib.fail(out, "no such log"),
        else => return lib.failErr(out, err, "listing state/logs"),
    };
    const names = try std.json.parseFromSliceLeaky(std.json.Value, lib.alloc, listing, .{});
    var found = false;
    if (names == .array) {
        for (names.array.items) |item| {
            if (item != .string) continue;
            if (std.mem.eql(u8, item.string, name)) found = true;
        }
    }
    if (!found) return lib.fail(out, "no such log");

    const path = try std.fmt.allocPrint(lib.alloc, "{s}/{s}", .{ logs_dir, name });
    const st_raw = lib.fsStat(path) catch |err| return lib.failErr(out, err, "reading the log");
    const st = std.json.parseFromSliceLeaky(std.json.Value, lib.alloc, st_raw, .{}) catch
        return lib.fail(out, "reading the log");
    const size = statSize(st) orelse return lib.fail(out, "reading the log");

    const raw = try readTailWindow(path, size);
    const text = view.tailOnLineBoundary(raw, view.tail_bytes);

    var w = lib.writer(out);
    var s = lib.json(&w);
    try s.beginObject();
    try s.objectField("ok");
    try s.write(true);
    try s.objectField("name");
    try s.write(name);
    try s.objectField("bytes");
    try s.write(size);
    try s.objectField("text");
    try s.write(text);
    try s.endObject();
    lib.commit(out, &w);
}

fn readTailWindow(path: []const u8, size: u64) ![]const u8 {
    if (size == 0) return "";
    if (size <= view.tail_bytes) return lib.fsRead(path);
    // One extra byte so a window that starts on a newline still drops it.
    const want: u64 = view.tail_bytes + 1;
    const offset: u64 = size - want;
    if (offset > std.math.maxInt(u32) or want > std.math.maxInt(u32))
        return lib.fsRead(path);
    return lib.fsReadRange(path, @intCast(offset), @intCast(want));
}

fn statSize(st: std.json.Value) ?u64 {
    if (st != .object) return null;
    const v = st.object.get("size") orelse return null;
    return switch (v) {
        .integer => |i| if (i < 0) null else @intCast(i),
        else => null,
    };
}
