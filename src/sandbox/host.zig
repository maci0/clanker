//! Host functions exposed to WASM tool modules (`ck_*`), plus the sandbox
//! policy that constrains them: filesystem confined to a sandbox root,
//! network only to an explicit allowlist, and size caps on all I/O.
//!
//! ABI: each op returns a u32 error code (0 = ok); bulk data is written into
//! the module's host arena and read back via `ck_result()` -> u64 (ptr, len).
//! Runs on zwasm: host fns receive `*zwasm.Caller` and recover the sandbox
//! context via `caller.data(Host)`.

const std = @import("std");
const log = @import("../util/log.zig");
const protocol = @import("protocol.zig");
const zwasm = @import("zwasm");

/// The guest reserves this many bytes for the host arena (must match
/// tools-src/lib.zig).
pub const host_arena_cap = 64 * 1024;
pub const scratch_cap = 64 * 1024;

/// Error codes returned by ck_* host functions.
pub const Err = struct {
    pub const ok: u32 = 0;
    pub const denied: u32 = 1;
    pub const not_found: u32 = 2;
    pub const too_large: u32 = 3;
    pub const network: u32 = 4;
    pub const invalid: u32 = 5;
};

/// Per-tool sandbox policy, owned by the harness.
pub const Sandbox = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    /// Absolute path of the directory tool filesystem access is confined to.
    root_dir: []const u8,
    /// Exact host matches allowed for ck_http (e.g. "api.example.com").
    network_allow: []const []const u8,
    /// Directory prefixes (relative to root_dir) the tool may read/write.
    /// Empty means filesystem access is denied entirely.
    fs_prefixes: []const []const u8 = &.{},
    max_http_bytes: usize = 1 << 20,
    max_fs_bytes: usize = 1 << 20,
    environ_map: *std.process.Environ.Map,
};

/// Per-module execution context; passed to host functions via
/// `defineFuncCtx` and recovered with `Caller.data(Host)`.
pub const Host = struct {
    sandbox: *Sandbox,
    arena_base: u32 = 0,
    arena_cur: u32 = 0,
    result_ptr: u32 = 0,
    result_len: u32 = 0,
    rng: std.Random.DefaultPrng,

    pub fn reset(self: *Host) void {
        self.arena_cur = self.arena_base;
        self.result_ptr = 0;
        self.result_len = 0;
    }

    fn writeResult(self: *Host, mem_bytes: []u8, data: []const u8) u32 {
        if (data.len > host_arena_cap) return Err.too_large;
        const off = self.arena_cur;
        if (@as(u64, off) + data.len > mem_bytes.len) return Err.too_large;
        if (self.arena_cur - self.arena_base + data.len > host_arena_cap) return Err.too_large;
        @memcpy(mem_bytes[off .. off + data.len], data);
        self.result_ptr = off;
        self.result_len = @intCast(data.len);
        self.arena_cur += @intCast(data.len);
        return Err.ok;
    }
};

fn memBytes(caller: *zwasm.Caller) ?[]u8 {
    const mem = caller.memory() orelse return null;
    return mem.slice();
}

fn sliceOf(bytes: []u8, ptr: u32, len: u32) ?[]u8 {
    if (@as(u64, ptr) + len > bytes.len) return null;
    return bytes[ptr .. ptr + len];
}

fn getHost(caller: *zwasm.Caller) *Host {
    return caller.data(Host);
}

// --------------------------------------------------------------- ck_* fns --

pub fn ckLog(caller: *zwasm.Caller, level: u32, ptr: u32, len: u32) void {
    if (memBytes(caller)) |bytes| {
        if (sliceOf(bytes, ptr, len)) |msg| {
            const lvl: log.Level = switch (level) {
                0 => .debug,
                1 => .info,
                2 => .warn,
                else => .error_,
            };
            log.log(lvl, "[tool] {s}", .{msg});
        }
    }
}

pub fn ckNow(caller: *zwasm.Caller) u64 {
    // Returns nanoseconds since the Unix epoch (bit-pattern-clean; zwasm's f64
    // host-result marshalling has a bug, so guests reinterpret this).
    const h = getHost(caller);
    return @intCast(std.Io.Timestamp.now(h.sandbox.io, .real).nanoseconds);
}

pub fn ckRandom(caller: *zwasm.Caller) u64 {
    const h = getHost(caller);
    return h.rng.random().int(u64);
}

pub fn ckResult(caller: *zwasm.Caller) u64 {
    const h = getHost(caller);
    return protocol.packPtrLen(h.result_ptr, h.result_len);
}

pub fn ckHttp(
    caller: *zwasm.Caller,
    method: u32,
    url_ptr: u32,
    url_len: u32,
    body_ptr: u32,
    body_len: u32,
    hdr_ptr: u32,
    hdr_len: u32,
) u32 {
    _ = hdr_ptr;
    _ = hdr_len;
    const h = getHost(caller);
    const bytes = memBytes(caller) orelse return Err.invalid;
    const url = sliceOf(bytes, url_ptr, url_len) orelse return Err.invalid;
    const body = sliceOf(bytes, body_ptr, body_len) orelse &.{};
    return httpImpl(h, bytes, method, url, body);
}

fn httpImpl(h: *Host, mem_bytes: []u8, method: u32, url: []const u8, body: []const u8) u32 {
    const uri = std.Uri.parse(url) catch return Err.invalid;
    const hostname = switch (uri.host orelse return Err.invalid) {
        .raw => |hh| hh,
        .percent_encoded => |hh| hh,
    };

    var allowed = false;
    for (h.sandbox.network_allow) |a| {
        if (std.mem.eql(u8, hostname, a)) {
            allowed = true;
            break;
        }
    }
    if (!allowed) {
        log.log(.warn, "[sandbox] tool denied network access to '{s}'", .{hostname});
        return Err.denied;
    }

    var client: std.http.Client = .{ .allocator = h.sandbox.gpa, .io = h.sandbox.io };
    defer client.deinit();

    const resp_buf = h.sandbox.gpa.alloc(u8, h.sandbox.max_http_bytes) catch return Err.too_large;
    defer h.sandbox.gpa.free(resp_buf);
    var w: std.Io.Writer = .fixed(resp_buf);

    const req_method: std.http.Method = switch (method) {
        0 => .GET,
        else => .POST,
    };
    const result = client.fetch(.{
        .location = .{ .url = url },
        .method = req_method,
        .payload = if (req_method == .POST) body else null,
        .headers = .{ .user_agent = .{ .override = "clanker-tool/0.1.0" } },
        .response_writer = &w,
    }) catch return Err.network;

    const response = resp_buf[0..w.end];
    if (@intFromEnum(result.status) >= 400) return Err.network;
    return h.writeResult(mem_bytes, response);
}

pub fn ckFsRead(caller: *zwasm.Caller, path_ptr: u32, path_len: u32) u32 {
    const h = getHost(caller);
    const bytes = memBytes(caller) orelse return Err.invalid;
    const path = sliceOf(bytes, path_ptr, path_len) orelse return Err.invalid;
    return fsReadImpl(h, bytes, path);
}

fn fsReadImpl(h: *Host, mem_bytes: []u8, sub_path: []const u8) u32 {
    const full = safeJoin(h.sandbox, sub_path) catch return Err.denied;
    defer h.sandbox.gpa.free(full);
    const data = std.Io.Dir.cwd().readFileAlloc(h.sandbox.io, full, h.sandbox.gpa, .limited(h.sandbox.max_fs_bytes)) catch |err| switch (err) {
        error.FileNotFound => return Err.not_found,
        error.StreamTooLong => return Err.too_large,
        else => return Err.invalid,
    };
    defer h.sandbox.gpa.free(data);
    return h.writeResult(mem_bytes, data);
}

pub fn ckFsWrite(caller: *zwasm.Caller, path_ptr: u32, path_len: u32, data_ptr: u32, data_len: u32) u32 {
    const h = getHost(caller);
    const bytes = memBytes(caller) orelse return Err.invalid;
    const path = sliceOf(bytes, path_ptr, path_len) orelse return Err.invalid;
    const data = sliceOf(bytes, data_ptr, data_len) orelse &.{};
    return fsWriteImpl(h, path, data);
}

fn fsWriteImpl(h: *Host, sub_path: []const u8, data: []const u8) u32 {
    if (data.len > h.sandbox.max_fs_bytes) return Err.too_large;
    const full = safeJoin(h.sandbox, sub_path) catch return Err.denied;
    defer h.sandbox.gpa.free(full);
    std.Io.Dir.cwd().writeFile(h.sandbox.io, .{ .sub_path = full, .data = data }) catch |err| switch (err) {
        error.NoSpaceLeft, error.DiskQuota => return Err.too_large,
        else => return Err.invalid,
    };
    return Err.ok;
}

pub fn ckGetenv(caller: *zwasm.Caller, name_ptr: u32, name_len: u32) u32 {
    const h = getHost(caller);
    const bytes = memBytes(caller) orelse return Err.invalid;
    const name = sliceOf(bytes, name_ptr, name_len) orelse return Err.invalid;
    if (h.sandbox.environ_map.get(name)) |value| {
        return h.writeResult(bytes, value);
    }
    return Err.not_found;
}

// ------------------------------------------------------- ck_exec (shell-ish) --

const exec_cmds = [_][]const u8{ "git", "rg", "ast-grep", "semcode" };

fn isWordChar(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_' or c == '-';
}

/// Returns true if `arg` should be denied because it contains deny token `t`.
/// Bare subcommand words ("rm", "gc", "push", ...) are only matched as whole
/// words; dash flags ("-f", "--force", ...) match as exact/prefix flags;
/// shell-operator tokens match anywhere (defense in depth).
fn argDenied(arg: []const u8, t: []const u8) bool {
    if (t.len == 0) return false;
    if (std.mem.eql(u8, arg, t)) return true;
    if (t[0] == '-') return std.mem.startsWith(u8, arg, t);
    var op = true;
    for (t) |c| {
        if (isWordChar(c)) {
            op = false;
            break;
        }
    }
    if (op) return std.mem.indexOf(u8, arg, t) != null;
    var i: usize = 0;
    while (std.mem.indexOfPos(u8, arg, i, t)) |p| {
        const before = p == 0 or !isWordChar(arg[p - 1]);
        const after = p + t.len >= arg.len or !isWordChar(arg[p + t.len]);
        if (before and after) return true;
        i = p + 1;
    }
    return false;
}

/// Arguments that are never allowed for sandboxed commands.
const exec_deny_tokens = [_][]const u8{
    "push",  "reset",   "rebase", "checkout", "clean", "rm",       "fetch",
    "merge", "revert",  "stash",  "remote",   "tag",   "filter-branch",
    "gc",    "repack",  "prune",  "submodule", "-f",   "--force",  "--exec",
    "&&",    "||",      ";",      "|",        ">",     "<",        "`",
};

pub fn ckExec(caller: *zwasm.Caller, argv_ptr: u32, argv_len: u32) u32 {
    const h = getHost(caller);
    const bytes = memBytes(caller) orelse return Err.invalid;
    const argv_json = sliceOf(bytes, argv_ptr, argv_len) orelse return Err.invalid;

    // parse {cmd, args}
    const parsed = std.json.parseFromSliceLeaky(std.json.Value, h.sandbox.gpa, argv_json, .{}) catch return Err.invalid;
    const obj = switch (parsed) {
        .object => |o| o,
        else => return Err.invalid,
    };
    const cmd = switch (obj.get("cmd") orelse return Err.invalid) {
        .string => |s| s,
        else => return Err.invalid,
    };
    var allowed_cmd = false;
    for (exec_cmds) |c| {
        if (std.mem.eql(u8, cmd, c)) {
            allowed_cmd = true;
            break;
        }
    }
    if (!allowed_cmd) return Err.denied;

    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(h.sandbox.gpa);
    argv.append(h.sandbox.gpa, cmd) catch return Err.invalid;
    if (obj.get("args")) |a| {
        switch (a) {
            .array => |arr| {
                for (arr.items) |item| {
                    const arg = switch (item) {
                        .string => |s| s,
                        else => return Err.invalid,
                    };
                    // deny-list check: match whole arguments / flag prefixes /
                    // word boundaries so single-char tokens like "-f", "rm",
                    // "gc" don't false-positive on innocent arguments.
                    for (exec_deny_tokens) |t| {
                        if (argDenied(arg, t)) {
                            log.log(.warn, "[sandbox] ck_exec denied token '{s}' in arg '{s}'", .{ t, arg });
                            return Err.denied;
                        }
                    }
                    argv.append(h.sandbox.gpa, arg) catch return Err.invalid;
                }
            },
            else => {},
        }
    }

    const result = std.process.run(h.sandbox.gpa, h.sandbox.io, .{
        .argv = argv.items,
        .cwd = .{ .dir = std.Io.Dir.cwd() },
        .stdout_limit = .limited(64 * 1024),
        .stderr_limit = .limited(8 * 1024),
    }) catch return Err.network;
    defer h.sandbox.gpa.free(result.stdout);
    defer h.sandbox.gpa.free(result.stderr);

    const code: u32 = switch (result.term) {
        .exited => |c| c,
        else => 1,
    };

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(h.sandbox.gpa);
    const wbuf = h.sandbox.gpa.alloc(u8, 96 * 1024) catch return Err.too_large;
    defer h.sandbox.gpa.free(wbuf);
    var w: std.Io.Writer = .fixed(wbuf);
    writeExecResult(h, &out, &w, code, result.stdout, result.stderr) catch return Err.invalid;
    return h.writeResult(bytes, out.items);
}

fn writeExecResult(h: *Host, out: *std.ArrayList(u8), w: *std.Io.Writer, code: u32, stdout: []const u8, stderr: []const u8) !void {
    var s = std.json.Stringify{ .writer = w, .options = .{ .emit_null_optional_fields = false } };
    try s.beginObject();
    try s.objectField("ok");
    try s.write(code == 0);
    try s.objectField("code");
    try s.print("{d}", .{code});
    try s.objectField("stdout");
    try s.write(stdout);
    try s.objectField("stderr");
    try s.write(stderr);
    try s.endObject();
    try out.appendSlice(h.sandbox.gpa, w.buffer[0..w.end]);
}

// ------------------------------------------------------------- sandbox core --

/// Resolves a tool-supplied path against the sandbox root, rejecting absolute
/// paths, any `..` / `.` component, and anything outside the tool's allowed
/// prefix list. Returns an allocated joined path.
fn safeJoin(sb: *const Sandbox, sub_path: []const u8) ![]u8 {
    if (sub_path.len == 0) return error.PathOutsideSandbox;
    if (sub_path[0] == '/') return error.PathOutsideSandbox;
    var it = std.mem.splitScalar(u8, sub_path, '/');
    while (it.next()) |comp| {
        if (std.mem.eql(u8, comp, "..") or std.mem.eql(u8, comp, ".")) return error.PathOutsideSandbox;
        if (comp.len == 0) return error.PathOutsideSandbox;
    }
    if (sb.fs_prefixes.len > 0) {
        var allowed = false;
        for (sb.fs_prefixes) |p| {
            if (std.mem.startsWith(u8, sub_path, p)) {
                allowed = true;
                break;
            }
        }
        if (!allowed) return error.PathOutsideSandbox;
    }
    return std.fmt.allocPrint(sb.gpa, "{s}/{s}", .{ std.mem.trimEnd(u8, sb.root_dir, "/"), sub_path });
}

// ------------------------------------------------------------------- tests --

test "safeJoin rejects escapes" {
    var sb = Sandbox{
        .gpa = std.testing.allocator,
        .io = undefined,
        .root_dir = "/tmp/sandbox",
        .network_allow = &.{},
        .fs_prefixes = &.{"notes/"},
        .environ_map = undefined,
    };
    try std.testing.expectError(error.PathOutsideSandbox, safeJoin(&sb, "../etc/passwd"));
    try std.testing.expectError(error.PathOutsideSandbox, safeJoin(&sb, "/etc/passwd"));
    try std.testing.expectError(error.PathOutsideSandbox, safeJoin(&sb, "a/../../b"));
    try std.testing.expectError(error.PathOutsideSandbox, safeJoin(&sb, "a//b"));
    try std.testing.expectError(error.PathOutsideSandbox, safeJoin(&sb, "other/foo.txt"));
    const ok = try safeJoin(&sb, "notes/foo.txt");
    defer std.testing.allocator.free(ok);
    try std.testing.expectEqualStrings("/tmp/sandbox/notes/foo.txt", ok);
}
