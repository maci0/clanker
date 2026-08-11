//! read_file: read a file's text by path, with byte-range pagination so a
//! large file can be walked without blowing the context window.
//!
//! Windows are snapped to line boundaries: offset and limit are byte counts,
//! but a fragment of a line at either end reads as corrupted source, so the
//! partial first line is dropped and the last is cut at its newline.
//! next_offset points at the first byte not returned, so paging with it loses
//! nothing.
//!
//! Input:  {"path": "src/agent/loop.zig", "offset": 0, "limit": 65536}
//!         {"path": "src/agent/loop.zig", "start_line": 603, "line_count": 40}
//! Output: {"ok": true, "text": "...", "next_offset": 49152}
//!         next_offset is present only when the read stopped short of the end.

const std = @import("std");
const lib = @import("lib.zig");

/// The harness looks up `run` with this exact signature, and `lib` supplies
/// the rest of the guest ABI (scratch, host_arena, the output buffer). A guest
/// that hand-rolls its own entry point links fine and then fails every call
/// with SignatureMismatch.
export fn run(ptr: u32, len: u32) callconv(.c) u64 {
    return lib.run(ptr, len, tool_main);
}

// A whole file in one call for anything normal-sized; pagination is for the
// genuinely huge, not for ordinary source. Bounded by the host arena a read
// comes through, with room left for the JSON envelope around the text.
const default_limit: usize = 768 * 1024;

fn tool_main(input: []const u8, out: *lib.Out) !void {
    const path = jsonString(input, "path") orelse return lib.fail(out, "missing required field: path");
    if (path.len == 0) return lib.fail(out, "path must not be empty");

    // Callers think in lines: every diagnostic in this project points at
    // file:line, and an agent handed a byte offset for "line 603" cannot get
    // there. When start_line is given the file is addressed by line instead.
    if (jsonUintOpt(input, "start_line")) |start_line| {
        // Zero lines is never what the caller wanted, and answering with an
        // empty string looks like an empty file.
        const want = jsonUint(input, "line_count", 200);
        return readByLine(out, path, start_line, if (want == 0) 200 else want);
    }

    // Read only the requested window. Reading the whole file first capped this
    // tool at the host arena size, which made every large source file in this
    // very repository unreadable.
    const offset = jsonUint(input, "offset", 0);
    const limit = @min(jsonUint(input, "limit", default_limit), default_limit);
    const raw = lib.fsReadRange(path, offset, limit) catch |err| return lib.fail(out, switch (err) {
        error.SandboxDenied => "path is outside the sandbox",
        error.NotFound => "no such file",
        error.TooLarge => "file is too large to read",
        else => "read failed",
    });

    // Whole lines only. A byte window lands mid-line at both ends, and source
    // that begins with the tail of one statement and stops in the middle of
    // another reads as corruption: an agent reviewing this project reported the
    // output "truncated/garbled" and spent its remaining turns trying smaller
    // reads, which land mid-line just the same.
    var start: usize = 0;
    if (offset > 0) {
        // The caller resumed inside a line; drop that fragment.
        if (std.mem.indexOfScalar(u8, raw, '\n')) |nl| start = nl + 1;
    }
    var end: usize = raw.len;
    if (raw.len == limit) {
        // More to come, so end on a line boundary rather than mid-statement.
        if (std.mem.lastIndexOfScalar(u8, raw[start..], '\n')) |nl| end = start + nl + 1;
    }
    // A line longer than the whole window has no boundary to snap to. Returning
    // it unsnapped is the only way the caller makes progress.
    const slice = if (end > start) raw[start..end] else raw;
    const consumed = if (end > start) end else raw.len;

    // Straight into the output buffer: a local array of this size would be a
    // megabyte-plus on the wasm stack, which traps.
    var w = out.writer();
    var s = std.json.Stringify{ .writer = &w, .options = .{ .emit_null_optional_fields = false } };
    try s.beginObject();
    try s.objectField("ok");
    try s.write(true);
    try s.objectField("text");
    try s.write(slice);
    // Byte mode reads a window and never learns how big the file is, so an
    // offset past the end came back as an empty string with nothing else at
    // all: indistinguishable from an empty file.
    if (slice.len == 0) {
        try s.objectField("note");
        try s.write("no bytes at that offset; the file is shorter than that, or empty");
    }
    // Only when there is more to come: a caller that sees no next_offset knows
    // it has the whole file, without comparing byte counts itself. A short read
    // means end of file.
    if (raw.len == limit) {
        try s.objectField("next_offset");
        try s.write(offset + consumed);
    }
    try s.endObject();
    out.len = w.end;
}

/// Reads `count` lines starting at `start_line` (1-based). The file is pulled
/// in whole, which the host arena bounds; a file too large for that still has
/// the byte-offset path.
fn readByLine(out: *lib.Out, path: []const u8, start_line: usize, count: usize) !void {
    const data = lib.fsRead(path) catch |err| return lib.fail(out, switch (err) {
        error.SandboxDenied => "path is outside the sandbox",
        error.NotFound => "no such file",
        error.TooLarge => "file is too large to address by line; use offset and limit instead",
        else => "read failed",
    });

    const first = if (start_line == 0) 1 else start_line;
    var line: usize = 1;
    var idx: usize = 0;
    var start: usize = data.len;
    var end: usize = data.len;
    while (idx <= data.len) : (idx += 1) {
        if (line == first and start == data.len) start = idx;
        if (line == first + count and end == data.len) {
            end = idx;
            break;
        }
        if (idx == data.len) break;
        if (data[idx] == '\n') line += 1;
    }
    if (start > end) start = end;
    const slice = data[start..end];
    const last_line = first + countLines(slice) -| 1;
    const total = countLines(data);

    var w = out.writer();
    var s = std.json.Stringify{ .writer = &w, .options = .{ .emit_null_optional_fields = false } };
    try s.beginObject();
    try s.objectField("ok");
    try s.write(true);
    try s.objectField("text");
    try s.write(slice);
    try s.objectField("start_line");
    try s.write(first);
    try s.objectField("end_line");
    try s.write(last_line);
    try s.objectField("lines");
    try s.write(total);
    if (end < data.len) {
        try s.objectField("next_line");
        try s.write(last_line + 1);
    }
    // An empty result reads the same whether the file is empty, the line does
    // not exist, or something went wrong. Say which.
    if (slice.len == 0) {
        try s.objectField("note");
        if (first > total) {
            // Built as a string first: print writes raw text, which is right
            // for a number and produces an unquoted value for a message.
            var nbuf: [160]u8 = undefined;
            const msg = std.fmt.bufPrint(&nbuf, "the file has {d} line(s), so line {d} is past its end", .{ total, first }) catch
                "that line is past the end of the file";
            try s.write(msg);
        } else {
            try s.write("that range is empty");
        }
    }
    try s.endObject();
    out.len = w.end;
}

fn countLines(text: []const u8) usize {
    if (text.len == 0) return 0;
    var n: usize = 1;
    for (text) |c| {
        if (c == '\n') n += 1;
    }
    // A trailing newline ends the last line rather than starting another.
    return if (text[text.len - 1] == '\n') n - 1 else n;
}

/// Minimal field readers: the guest has no allocator, and the arguments object
/// is small and flat, so a full JSON parse would cost more than it returns.
fn fieldValue(input: []const u8, name: []const u8) ?[]const u8 {
    var key_buf: [64]u8 = undefined;
    if (name.len + 2 > key_buf.len) return null;
    key_buf[0] = '"';
    @memcpy(key_buf[1 .. 1 + name.len], name);
    key_buf[1 + name.len] = '"';
    const key = key_buf[0 .. name.len + 2];

    const at = std.mem.indexOf(u8, input, key) orelse return null;
    var i = at + key.len;
    while (i < input.len and (input[i] == ' ' or input[i] == ':')) i += 1;
    if (i >= input.len) return null;
    return input[i..];
}

fn jsonString(input: []const u8, name: []const u8) ?[]const u8 {
    const rest = fieldValue(input, name) orelse return null;
    if (rest.len == 0 or rest[0] != '"') return null;
    const end = std.mem.indexOfScalar(u8, rest[1..], '"') orelse return null;
    return rest[1 .. 1 + end];
}

fn jsonUintOpt(input: []const u8, name: []const u8) ?usize {
    const rest = fieldValue(input, name) orelse return null;
    var n: usize = 0;
    var digits: usize = 0;
    for (rest) |c| {
        if (c < '0' or c > '9') break;
        n = n *| 10 +| (c - '0');
        digits += 1;
    }
    return if (digits == 0) null else n;
}

fn jsonUint(input: []const u8, name: []const u8, fallback: usize) usize {
    const rest = fieldValue(input, name) orelse return fallback;
    var n: usize = 0;
    var digits: usize = 0;
    for (rest) |c| {
        if (c < '0' or c > '9') break;
        n = n *| 10 +| (c - '0');
        digits += 1;
    }
    return if (digits == 0) fallback else n;
}
