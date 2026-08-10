//! Guest-side helpers for clanker tools (wasm32-freestanding).
//! Implements the clanker tool ABI and thin wrappers over the ck_* host
//! functions. Each tool's root file must provide a `tool_main` handler and a
//! `run` export:
//!
//!     const lib = @import("lib.zig");
//!     export fn run(ptr: u32, len: u32) callconv(.c) u64 { return lib.run(ptr, len, tool_main); }
//!
//! The `scratch` and `host_arena` exports come from this file.

const std = @import("std");

// ---- host function imports (provided by the harness) ------------------------
extern fn ck_log(level: u32, ptr: u32, len: u32) void;
extern fn ck_now() u64;
extern fn ck_random() u64;
extern fn ck_http(method: u32, url_ptr: u32, url_len: u32, body_ptr: u32, body_len: u32, hdr_ptr: u32, hdr_len: u32) u32;
extern fn ck_fs_read(path_ptr: u32, path_len: u32) u32;
extern fn ck_fs_write(path_ptr: u32, path_len: u32, data_ptr: u32, data_len: u32) u32;
extern fn ck_getenv(name_ptr: u32, name_len: u32) u32;
extern fn ck_result() u64;

const scratch_cap = 64 * 1024;
const host_arena_cap = 64 * 1024;
const out_cap = 64 * 1024;

var scratch_buf: [scratch_cap]u8 align(16) = undefined;
var host_arena_buf: [host_arena_cap]u8 align(16) = undefined;
var out_buf: [out_cap]u8 align(16) = undefined;

/// Pointer to the module's input scratch buffer (host writes the input JSON
/// here before calling `run`).
export fn scratch(need: u32) callconv(.c) u32 {
    if (need > scratch_buf.len) return 0;
    return @intFromPtr(&scratch_buf);
}

/// Pointer to the module's host arena (host functions write results here).
export fn host_arena() callconv(.c) u32 {
    return @intFromPtr(&host_arena_buf);
}

/// Output buffer the tool handler fills.
pub const Out = struct {
    buf: []u8,
    len: usize = 0,

    pub fn writeAll(self: *Out, bytes: []const u8) !void {
        if (self.len + bytes.len > self.buf.len) return error.OutputTooLarge;
        @memcpy(self.buf[self.len..][0..bytes.len], bytes);
        self.len += bytes.len;
    }

    pub fn reset(self: *Out) void {
        self.len = 0;
    }
};

fn pack(out: *const Out) u64 {
    return (@as(u64, @intFromPtr(out.buf.ptr)) << 32) | @as(u64, out.len);
}

fn memSlice(ptr: u32, len: u32) ?[]const u8 {
    const base: usize = ptr;
    if (base + len > @as(usize, @intFromPtr(&scratch_buf)) + scratch_buf.len) return null;
    // Input is only guaranteed valid inside the scratch region.
    if (base < @intFromPtr(&scratch_buf) or base + len > @intFromPtr(&scratch_buf) + scratch_buf.len) return null;
    return @as([*]const u8, @ptrFromInt(base))[0..len];
}

fn writeErr(out: *Out, name: []const u8) void {
    out.reset();
    out.writeAll("{\"ok\":false,\"error\":\"") catch return;
    out.writeAll(name) catch return;
    out.writeAll("\"}") catch return;
}

/// Entry point shared by all tools: slices the input, runs `handler`, and
/// packs the output (ptr, len). Errors are serialized as `{"ok":false,...}`.
pub fn run(ptr: u32, len: u32, comptime handler: anytype) u64 {
    var out = Out{ .buf = &out_buf };
    const input = memSlice(ptr, len) orelse {
        writeErr(&out, "input out of bounds");
        return pack(&out);
    };
    handler(input, &out) catch |err| {
        writeErr(&out, @errorName(err));
    };
    return pack(&out);
}

// ----------------------------------------------------------- host wrappers --

fn sliceToMem(s: []const u8) struct { ptr: u32, len: u32 } {
    return .{ .ptr = @intCast(@intFromPtr(s.ptr)), .len = @intCast(s.len) };
}

fn readResult() ?[]const u8 {
    const packed_ = ck_result();
    const ptr: u32 = @intCast(packed_ >> 32);
    const len: u32 = @intCast(packed_ & 0xFFFF_FFFF);
    return memSlice(ptr, len);
}

pub fn log(comptime level: u32, msg: []const u8) void {
    const m = sliceToMem(msg);
    ck_log(level, m.ptr, m.len);
}

pub fn logInfo(msg: []const u8) void {
    log(1, msg);
}

/// Seconds since the Unix epoch.
pub fn nowSeconds() f64 {
    return @as(f64, @floatFromInt(ck_now())) / 1e9;
}

/// Uniform float in [0, 1).
pub fn randomFloat() f64 {
    return @as(f64, @floatFromInt(ck_random())) / @as(f64, @floatFromInt(std.math.maxInt(u64)));
}

pub const HttpError = error{ SandboxDenied, TooLarge, NetworkError, InvalidArg };

pub fn httpGet(url: []const u8) HttpError![]const u8 {
    const u = sliceToMem(url);
    const rc = ck_http(0, u.ptr, u.len, 0, 0, 0, 0);
    return switch (rc) {
        0 => readResult() orelse error.InvalidArg,
        1 => error.SandboxDenied,
        3 => error.TooLarge,
        4 => error.NetworkError,
        else => error.InvalidArg,
    };
}

pub fn httpPost(url: []const u8, body: []const u8) HttpError![]const u8 {
    const u = sliceToMem(url);
    const b = sliceToMem(body);
    const rc = ck_http(1, u.ptr, u.len, b.ptr, b.len, 0, 0);
    return switch (rc) {
        0 => readResult() orelse error.InvalidArg,
        1 => error.SandboxDenied,
        3 => error.TooLarge,
        4 => error.NetworkError,
        else => error.InvalidArg,
    };
}

pub const FsError = error{ SandboxDenied, NotFound, TooLarge, IoError };

/// Reads a file relative to the sandbox root.
pub fn fsRead(path: []const u8) FsError![]const u8 {
    const p = sliceToMem(path);
    const rc = ck_fs_read(p.ptr, p.len);
    return switch (rc) {
        0 => readResult() orelse error.IoError,
        1 => error.SandboxDenied,
        2 => error.NotFound,
        3 => error.TooLarge,
        else => error.IoError,
    };
}

/// Writes a file relative to the sandbox root.
pub fn fsWrite(path: []const u8, data: []const u8) FsError!void {
    const p = sliceToMem(path);
    const d = sliceToMem(data);
    const rc = ck_fs_write(p.ptr, p.len, d.ptr, d.len);
    return switch (rc) {
        0 => {},
        1 => error.SandboxDenied,
        3 => error.TooLarge,
        else => error.IoError,
    };
}

/// Reads an environment variable (from the harness process env).
pub fn getenv(name: []const u8) ?[]const u8 {
    const n = sliceToMem(name);
    const rc = ck_getenv(n.ptr, n.len);
    if (rc != 0) return null;
    return readResult();
}
