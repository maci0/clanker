//! read_file guest: reads a file by path through the ck_fs_read host
//! function and returns its text with pagination. Input:
//!   {"path": "src/agent/loop.zig", "offset": 0, "limit": 65536}
//! Output:
//!   {"ok":true,"path":...,"size":N,"offset":O,"limit":L,
//!    "truncated":bool,"next_offset":M,"content":"..."}
//! `size` is the file's total byte size; when the returned slice does not
//! reach EOF, `next_offset` is the byte offset to pass on the next call.
//!
//! Freestanding wasm: no allocator, no std.fs — fixed buffers only, and
//! std.Io.Writer.fixed for output (the same idiom as src/agent/loop.zig).

const std = @import("std");

/// Host import (implemented in src/sandbox/host.zig): reads the file at the
/// given path inside the sandbox root and returns a packed (ptr<<32)|len
/// handle to the contents in guest memory. A zero length with a null path
/// result is reported by the host as an empty/error payload.
extern "env" fn ck_fs_read(path_ptr: u32, path_len: u32) u64;

var path_buf: [4096]u8 = undefined;
var out_buf: [192 * 1024]u8 = undefined;

/// Extracts the string value of a top-level JSON field without an allocator.
/// Handles backslash-escaped characters only to the extent of not terminating
/// the string early; escapes are left intact (paths rarely contain them).
fn jsonStringField(input: []const u8, key: []const u8) ?[]const u8 {
    var needle_buf: [130]u8 = undefined;
    if (key.len + 2 > needle_buf.len) return null;
    needle_buf[0] = '"';
    @memcpy(needle_buf[1 .. 1 + key.len], key);
    needle_buf[1 + key.len] = '"';
    const needle = needle_buf[0 .. key.len + 2];
    var idx = std.mem.indexOf(u8, input, needle) orelse return null;
    idx += needle.len;
    while (idx < input.len and (input[idx] == ' ' or input[idx] == '\t' or input[idx] == '\n' or input[idx] == '\r' or input[idx] == ':')) idx += 1;
    if (idx >= input.len or input[idx] != '"') return null;
    idx += 1;
    const start = idx;
    while (idx < input.len and input[idx] != '"') : (idx += 1) {
        if (input[idx] == '\\' and idx + 1 < input.len) idx += 1;
    }
    return input[start..idx];
}

/// Extracts a non-negative integer value of a top-level JSON field, or
/// `default` when the field is absent or not a plain integer.
fn jsonIntField(input: []const u8, key: []const u8, default: u64) u64 {
    var needle_buf: [130]u8 = undefined;
    if (key.len + 2 > needle_buf.len) return default;
    needle_buf[0] = '"';
    @memcpy(needle_buf[1 .. 1 + key.len], key);
    needle_buf[1 + key.len] = '"';
    const needle = needle_buf[0 .. key.len + 2];
    var idx = std.mem.indexOf(u8, input, needle) orelse return default;
    idx += needle.len;
    while (idx < input.len and (input[idx] == ' ' or input[idx] == '\t' or input[idx] == '\n' or input[idx] == '\r' or input[idx] == ':')) idx += 1;
    var end = idx;
    while (end < input.len and input[end] >= '0' and input[end] <= '9') end += 1;
    if (end == idx) return default;
    return std.fmt.parseInt(u64, input[idx..end], 10) catch default;
}

/// Writes `s` to `w` as a JSON string literal (with surrounding quotes),
/// escaping the characters JSON requires.
fn writeJsonString(w: *std.Io.Writer, s: []const u8) void {
    w.writeByte('"') catch return;
    for (s) |ch| {
        switch (ch) {
            '"' => w.writeAll("\\\"") catch return,
            '\\' => w.writeAll("\\\\") catch return,
            '\n' => w.writeAll("\\n") catch return,
            '\r' => w.writeAll("\\r") catch return,
            '\t' => w.writeAll("\\t") catch return,
            else => {
                if (ch < 0x20) {
                    w.print("\\u{x:0>4}", .{ch}) catch return;
                } else {
                    w.writeByte(ch) catch return;
                }
            },
        }
    }
    w.writeByte('"') catch return;
}

fn packedResult(len: usize) u64 {
    return (@as(u64, @intCast(@intFromPtr(&out_buf))) << 32) | @as(u64, @intCast(len));
}

fn fail(msg: []const u8) u64 {
    var w: std.Io.Writer = .fixed(&out_buf);
    w.writeAll("{\"ok\":false,\"error\":") catch {};
    writeJsonString(&w, msg);
    w.writeByte('}') catch {};
    return packedResult(w.end);
}

/// Entry point invoked by the harness: `input` is the JSON arguments object,
/// the return value is a packed (ptr<<32)|len handle to the JSON result in
/// guest memory.
export fn execute(input_ptr: u32, input_len: u32) u64 {
    const input: []const u8 = @as([*]const u8, @ptrFromInt(input_ptr))[0..input_len];

    const path = jsonStringField(input, "path") orelse return fail("missing required field: path");
    if (path.len == 0) return fail("path must not be empty");
    if (path.len > path_buf.len) return fail("path too long (max 4096 bytes)");
    @memcpy(path_buf[0..path.len], path);

    const offset = jsonIntField(input, "offset", 0);
    const limit = jsonIntField(input, "limit", 65536);

    const packed_read = ck_fs_read(@intCast(@intFromPtr(&path_buf)), @intCast(path.len));
    const data_ptr: u32 = @intCast(packed_read >> 32);
    const data_len: u32 = @truncate(packed_read);
    if (data_ptr == 0) return fail("ck_fs_read failed (file not found, outside the sandbox root, or unreadable)");
    const data: []const u8 = @as([*]const u8, @ptrFromInt(data_ptr))[0..data_len];

    const size: u64 = data.len;
    if (offset > size) return fail("offset is past end of file");
    const start: usize = @intCast(offset);
    const avail = data.len - start;
    const want: usize = @intCast(@min(limit, @as(u64, avail)));
    const slice = data[start .. start + want];
    const end_off = offset + want;
    const truncated = end_off < size;

    var w: std.Io.Writer = .fixed(&out_buf);
    w.writeAll("{\"ok\":true,\"path\":") catch return fail("output buffer overflow");
    writeJsonString(&w, path);
    w.print(",\"size\":{d},\"offset\":{d},\"limit\":{d},\"truncated\":{s}", .{
        size,
        offset,
        limit,
        if (truncated) "true" else "false",
    }) catch return fail("output buffer overflow");
    if (truncated) {
        w.print(",\"next_offset\":{d}", .{end_off}) catch return fail("output buffer overflow");
    }
    w.writeAll(",\"content\":") catch return fail("output buffer overflow");
    writeJsonString(&w, slice);
    w.writeByte('}') catch return fail("output buffer overflow: file slice too large for the result buffer; retry with a smaller limit");
    return packedResult(w.end);
}
