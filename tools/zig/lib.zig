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
extern fn ck_http(method: u32, url_ptr: u32, url_len: u32, body_ptr: u32, body_len: u32, hdr_ptr: u32, hdr_len: u32) u32;
extern fn ck_fs_read(path_ptr: u32, path_len: u32) u32;
extern fn ck_fs_read_range(path_ptr: u32, path_len: u32, offset: u32, length: u32) u32;
extern fn ck_fs_append(path_ptr: u32, path_len: u32, data_ptr: u32, data_len: u32) u32;
extern fn ck_fs_copy(src_ptr: u32, src_len: u32, dst_ptr: u32, dst_len: u32) u32;
extern fn ck_fs_rename(old_ptr: u32, old_len: u32, new_ptr: u32, new_len: u32) u32;
extern fn ck_fs_delete(path_ptr: u32, path_len: u32) u32;
extern fn ck_fs_mkdir(path_ptr: u32, path_len: u32) u32;
extern fn ck_fs_stat(path_ptr: u32, path_len: u32) u32;
extern fn ck_fs_find(dir_ptr: u32, dir_len: u32, pat_ptr: u32, pat_len: u32) u32;
extern fn ck_fs_grep(dir_ptr: u32, dir_len: u32, pat_ptr: u32, pat_len: u32) u32;
extern fn ck_hash(ptr: u32, len: u32) u32;
extern fn ck_fs_write(path_ptr: u32, path_len: u32, data_ptr: u32, data_len: u32) u32;
extern fn ck_fs_write_if(path_ptr: u32, path_len: u32, expect_ptr: u32, expect_len: u32, data_ptr: u32, data_len: u32) u32;
extern fn ck_fs_list(path_ptr: u32, path_len: u32) u32;
extern fn ck_getenv(name_ptr: u32, name_len: u32) u32;
extern fn ck_exec(argv_ptr: u32, argv_len: u32) u32;
extern fn ck_docker(req_ptr: u32, req_len: u32) u32;
extern fn ck_kernel(req_ptr: u32, req_len: u32) u32;
extern fn ck_debug(req_ptr: u32, req_len: u32) u32;
extern fn ck_llm(prompt_ptr: u32, prompt_len: u32) u32;
extern fn ck_session(req_ptr: u32, req_len: u32) u32;
extern fn ck_llm_many(req_ptr: u32, req_len: u32) u32;
extern fn ck_chat(op_ptr: u32, op_len: u32) u32;
extern fn ck_publish(ptr: u32, len: u32) u32;
extern fn ck_stats() u32;
extern fn ck_improve_history() u32;
extern fn ck_config() u32;
extern fn ck_harness_config() u32;
extern fn ck_result() u64;
extern fn ck_std_api(sym_ptr: u32, sym_len: u32) u32;
extern fn ck_tool(ptr: u32, len: u32) u32;
extern fn ck_subagent(json_ptr: u32, json_len: u32) u32;
extern fn ck_job(json_ptr: u32, json_len: u32) u32;
extern fn ck_swarm(json_ptr: u32, json_len: u32) u32;
extern fn ck_ask(json_ptr: u32, json_len: u32) u32;
extern fn ck_random() u64;

const root = @import("root");
/// Most tools only need a small request buffer. A tool that transports one
/// complete artifact (the run graph is the current example) can opt into a
/// larger buffer in its root source without making every guest reserve it.
const scratch_cap = if (@hasDecl(root, "input_scratch_cap")) root.input_scratch_cap else 64 * 1024;
/// Every host result lands here, and the host bump-allocates through it for
/// the whole tool call without resetting, so this is the total a tool can pull
/// in from the host per invocation. 64 KiB made this project's own source files
/// unreadable. It is .bss, so it costs linear-memory pages and nothing on disk.
/// A tool that makes many host calls in one invocation (a research sweep is a
/// dozen HTTP fetches) can raise it in its root source; the whole module still
/// has to fit in the runtime's 16 MiB of linear memory, out_cap included.
const host_arena_cap = if (@hasDecl(root, "host_arena_cap")) root.host_arena_cap else 1024 * 1024;
/// Bigger than the input and host-result buffers because a tool's output is
/// the one thing that can legitimately be large: webui.zig JSON-encodes the
/// whole embedded page through here. All three are `undefined`, so they cost
/// .bss pages in linear memory (capped at 16 MiB, see runtime.zig) and add
/// nothing to the .wasm on disk. The host reads the result straight out of
/// linear memory and imposes no size limit of its own.
pub const out_cap = 2 * 1024 * 1024;

var scratch_buf: [scratch_cap]u8 align(16) = undefined;
var host_arena_buf: [host_arena_cap]u8 align(16) = undefined;
var out_buf: [out_cap]u8 align(16) = undefined;

/// How many bytes the host may bump-allocate at `host_arena()`. The host
/// defaults to 64 KiB for modules that do not export this.
export fn host_arena_size() callconv(.c) u32 {
    return host_arena_cap;
}

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

    /// A writer straight onto the output buffer. Building a response in a
    /// local array first costs a second copy of it on the wasm stack, which
    /// is a megabyte at most: a tool that returns a whole file traps on the
    /// stack long before it fills its output.
    pub fn writer(self: *Out) std.Io.Writer {
        return .{
            .buffer = self.buf,
            .end = self.len,
            .vtable = &.{ .drain = drainFull },
        };
    }

    /// The buffer is the destination, so there is nowhere to drain to:
    /// reaching here means the response outgrew out_cap.
    fn drainFull(_: *std.Io.Writer, _: []const []const u8, _: usize) std.Io.Writer.Error!usize {
        return error.WriteFailed;
    }
};

fn pack(out: *const Out) u64 {
    return (@as(u64, @intFromPtr(out.buf.ptr)) << 32) | @as(u64, out.len);
}

fn memSlice(ptr: u32, len: u32) ?[]const u8 {
    const base: usize = ptr;
    if (base < @intFromPtr(&scratch_buf) or base + len > @intFromPtr(&scratch_buf) + scratch_buf.len) return null;
    return @as([*]const u8, @ptrFromInt(base))[0..len];
}

fn writeErr(out: *Out, name: []const u8) void {
    fail(out, name) catch return;
}

// ------------------------------------------------------------- responding --

/// The guest allocator. Named here so a tool never has to know which one it
/// is; `std.heap.wasm_allocator` was spelled out in nearly every tool.
pub const alloc = std.heap.wasm_allocator;

/// A writer over the remaining output buffer. Tools used to declare a
/// second, hand-sized buffer (77 of them, in 12 different sizes) and copy it
/// into `out` afterwards; writing here directly removes both the guess and
/// the copy. The real ceiling is `out_cap`, which is the only one that was
/// ever true.
pub fn writer(out: *Out) std.Io.Writer {
    return .fixed(out.buf[out.len..]);
}

/// Commits bytes written through `writer`. Kept separate from `writer` so a
/// tool that fails halfway through simply never commits, leaving the buffer
/// untouched for `fail` to overwrite.
pub fn commit(out: *Out, w: *const std.Io.Writer) void {
    out.len += w.end;
}

/// A `Stringify` positioned on this tool's output. The caller writes the
/// value, then calls `commit`.
pub fn json(w: *std.Io.Writer) std.json.Stringify {
    return .{ .writer = w, .options = .{ .emit_null_optional_fields = false } };
}

/// Reports a host-call failure in terms of what the caller can do about it.
///
/// `@errorName` was going straight to the model at 28 call sites: "NotFound",
/// "SandboxDenied", "InvalidArg". None of those say which path, which command,
/// or which policy, and a model handed one has nothing to act on. `what`
/// names the thing that failed, e.g. "reading state/sessions" or "running rg".
pub fn failErr(out: *Out, err: anyerror, what: []const u8) !void {
    var buf: [512]u8 = undefined;
    const msg = switch (err) {
        error.SandboxDenied => std.fmt.bufPrint(&buf, "{s}: refused by this tool's sandbox policy — its manifest has to allow the path (fs_prefixes), the command (exec_allow) or the host (network_allow)", .{what}),
        error.NotFound => std.fmt.bufPrint(&buf, "{s}: not found", .{what}),
        error.TooLarge => std.fmt.bufPrint(&buf, "{s}: too large for one call — ask for a smaller range or narrow the query", .{what}),
        error.NetworkError => std.fmt.bufPrint(&buf, "{s}: the request did not complete", .{what}),
        error.InvalidArg => std.fmt.bufPrint(&buf, "{s}: the arguments were rejected", .{what}),
        error.OutOfMemory => std.fmt.bufPrint(&buf, "{s}: out of memory in the sandbox", .{what}),
        else => std.fmt.bufPrint(&buf, "{s}: {s}", .{ what, @errorName(err) }),
    } catch what;
    return fail(out, msg);
}

/// `{"ok":false,"error":"<msg>"}`, with `msg` escaped as a JSON string.
///
/// Every tool used to carry its own copy of this that interpolated the
/// message raw, so any message containing a quote, backslash, or newline
/// produced output the host could not parse — turning a useful error into a
/// parse failure. Escaping it once here makes that unrepresentable.
pub fn fail(out: *Out, msg: []const u8) !void {
    out.reset();
    var w = writer(out);
    var s = json(&w);
    try s.beginObject();
    try s.objectField("ok");
    try s.write(false);
    try s.objectField("error");
    try s.write(msg);
    try s.endObject();
    commit(out, &w);
}

/// `{"ok":true,"text":"<text>"}` — the entire successful reply of 14 tools.
pub fn okText(out: *Out, text: []const u8) !void {
    var w = writer(out);
    var s = json(&w);
    try s.beginObject();
    try s.objectField("ok");
    try s.write(true);
    try s.objectField("text");
    try s.write(text);
    try s.endObject();
    commit(out, &w);
}

/// `{"ok":true,"payload":"<payload>"}` — the successful reply of a transform
/// plugin, whose payload replaces the wrapped tool's result.
pub fn okPayload(out: *Out, payload: []const u8) !void {
    var w = writer(out);
    var s = json(&w);
    try s.beginObject();
    try s.objectField("ok");
    try s.write(true);
    try s.objectField("payload");
    try s.write(payload);
    try s.endObject();
    commit(out, &w);
}

// ----------------------------------------------------------------- input --

/// Parses the tool input and requires it to be a JSON object. Tools that want
/// the raw text, or that scan for one key without paying for a parse (see
/// read_file.zig), can keep ignoring this.
pub fn object(input: []const u8) !std.json.Value {
    const parsed = try std.json.parseFromSliceLeaky(std.json.Value, alloc, input, .{});
    if (parsed != .object) return error.InputNotAnObject;
    return parsed;
}

/// A string field, or null when absent or not a string. `obj` is the value
/// returned by `object`.
pub fn optStr(obj: std.json.Value, name: []const u8) ?[]const u8 {
    if (obj != .object) return null;
    const v = obj.object.get(name) orelse return null;
    return switch (v) {
        .string => |s| s,
        else => null,
    };
}

/// A string field that must be present and non-empty.
pub fn str(obj: std.json.Value, name: []const u8) ![]const u8 {
    const s = optStr(obj, name) orelse return error.MissingField;
    if (s.len == 0) return error.MissingField;
    return s;
}

/// A numeric field as f64, accepting both JSON number spellings.
pub fn optNum(obj: std.json.Value, name: []const u8) ?f64 {
    if (obj != .object) return null;
    const v = obj.object.get(name) orelse return null;
    return switch (v) {
        .float => |f| f,
        .integer => |i| @floatFromInt(i),
        else => null,
    };
}

/// A boolean field, or `default` when absent or not a boolean.
pub fn optBool(obj: std.json.Value, name: []const u8, default: bool) bool {
    if (obj != .object) return default;
    const v = obj.object.get(name) orelse return default;
    return switch (v) {
        .bool => |b| b,
        else => default,
    };
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
        failErr(&out, err, "tool execution") catch writeErr(&out, "tool execution failed while encoding the error response");
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
    // Host functions (ck_http, ck_exec, ck_fs_read, ck_getenv, ck_docker)
    // write their results into the host arena, not the scratch buffer.
    const base: usize = ptr;
    if (base < @intFromPtr(&host_arena_buf) or
        base + len > @intFromPtr(&host_arena_buf) + host_arena_buf.len) return null;
    return @as([*]const u8, @ptrFromInt(base))[0..len];
}

pub fn log(comptime level: u32, msg: []const u8) void {
    const m = sliceToMem(msg);
    ck_log(level, m.ptr, m.len);
}

pub fn logInfo(msg: []const u8) void {
    log(1, msg);
}

/// Delegates a task to a nested sub-agent run (host-side).
pub fn subagent(task: []const u8, provider: ?[]const u8) FsError![]const u8 {
    var buf: [8192]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    var s = std.json.Stringify{ .writer = &w, .options = .{} };
    s.beginObject() catch return error.IoError;
    s.objectField("task") catch return error.IoError;
    s.write(task) catch return error.IoError;
    if (provider) |p| {
        s.objectField("provider") catch return error.IoError;
        s.write(p) catch return error.IoError;
    }
    s.endObject() catch return error.IoError;
    const req = sliceToMem(buf[0..w.end]);
    const rc = ck_subagent(req.ptr, req.len);
    return switch (rc) {
        0 => readResult() orelse error.IoError,
        2 => error.NotFound,
        else => error.IoError,
    };
}

/// Delegates to a sub-agent, forwarding the caller's whole input object so the
/// brief ("context", "files") reaches the host untouched.
pub fn subagentBriefed(input: []const u8, task: []const u8, provider: ?[]const u8) FsError![]const u8 {
    // The host already parses task/provider/context/files out of this object;
    // re-encoding here would only be a chance to drop a field.
    _ = task;
    _ = provider;
    const req = sliceToMem(input);
    const rc = ck_subagent(req.ptr, req.len);
    return switch (rc) {
        0 => readResult() orelse error.IoError,
        2 => error.NotFound,
        else => error.IoError,
    };
}

/// Background job control (ck_job). Privileged: the jobs and subagent guests.
pub fn job(req: []const u8) FsError![]const u8 {
    const p = sliceToMem(req);
    const rc = ck_job(p.ptr, p.len);
    return switch (rc) {
        0 => readResult() orelse error.IoError,
        1 => error.SandboxDenied,
        2 => error.NotFound,
        else => error.IoError,
    };
}

/// Fans a batch of tasks out to concurrent sub-agents, forwarding the
/// caller's whole input object ("tasks", "provider") untouched — the host
/// parses it directly, so re-encoding here would only be a chance to drop a
/// field. Returns a JSON array of {task, ok, text|error}, one entry per task.
pub fn swarm(input: []const u8) FsError![]const u8 {
    const req = sliceToMem(input);
    const rc = ck_swarm(req.ptr, req.len);
    return switch (rc) {
        0 => readResult() orelse error.IoError,
        2 => error.NotFound,
        3 => error.TooLarge,
        else => error.IoError,
    };
}

/// Puts a multiple-choice question to the human and returns the option they
/// chose. `error.NotFound` means nobody is attached to answer (a scripted run),
/// which the caller should treat as "decide it yourself", not as a failure.
pub fn ask(question: []const u8, options: []const []const u8) FsError![]const u8 {
    return askTarget(question, options, null);
}

/// Like `ask`, aimed at a specific host-side answerer: `to` = "parent" routes
/// the question to the agent that spawned this sub-agent (null asks the
/// human). NotFound means the requested answerer is not attached.
pub fn askTarget(question: []const u8, options: []const []const u8, to: ?[]const u8) FsError![]const u8 {
    var buf: [8192]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    var s = std.json.Stringify{ .writer = &w, .options = .{} };
    s.beginObject() catch return error.IoError;
    s.objectField("question") catch return error.IoError;
    s.write(question) catch return error.IoError;
    s.objectField("options") catch return error.IoError;
    s.beginArray() catch return error.IoError;
    for (options) |o| s.write(o) catch return error.IoError;
    s.endArray() catch return error.IoError;
    if (to) |t| {
        s.objectField("to") catch return error.IoError;
        s.write(t) catch return error.IoError;
    }
    s.endObject() catch return error.IoError;

    const req = sliceToMem(buf[0..w.end]);
    const rc = ck_ask(req.ptr, req.len);
    return switch (rc) {
        0 => readResult() orelse error.IoError,
        2 => error.NotFound,
        else => error.IoError,
    };
}

/// Looks up a symbol in the Zig standard library source (host-side rg).
pub fn stdApi(symbol: []const u8) FsError![]const u8 {
    const p = sliceToMem(symbol);
    const rc = ck_std_api(p.ptr, p.len);
    return switch (rc) {
        0 => readResult() orelse error.IoError,
        2 => error.NotFound,
        else => error.IoError,
    };
}

/// Seconds since the Unix epoch.
pub fn nowSeconds() f64 {
    return @as(f64, @floatFromInt(ck_now())) / 1e9;
}

/// Nanoseconds since the Unix epoch, raw. The entropy source for anything
/// that must be unique across invocations: with agent.seed pinned (the
/// default is 0, for reproducible runs), `random()` draws the same sequence
/// in every fresh instantiation of the same tool, so an id built from
/// randomness alone collides with the id the previous call generated.
pub fn nowNanos() u64 {
    return ck_now();
}

pub const HostError = error{ SandboxDenied, NoAccess, TooLarge, NetworkError, InvalidArg };

fn hostResult(rc: u32) HostError![]const u8 {
    return switch (rc) {
        0 => readResult() orelse error.InvalidArg,
        1 => error.SandboxDenied,
        7 => error.NoAccess,
        3 => error.TooLarge,
        4 => error.NetworkError,
        else => error.InvalidArg,
    };
}

/// Reads the session store through ck_session (list/get/search). Gate:
/// the tool descriptor must set `session: true`.
pub fn sessionCall(input: []const u8) HostError![]const u8 {
    const m = sliceToMem(input);
    return hostResult(ck_session(m.ptr, m.len));
}

pub fn httpGet(url: []const u8) HostError![]const u8 {
    const u = sliceToMem(url);
    const rc = ck_http(0, u.ptr, u.len, 0, 0, 0, 0);
    return hostResult(rc);
}

pub fn httpGetHdr(url: []const u8, headers_json: []const u8) HostError![]const u8 {
    const u = sliceToMem(url);
    const h = sliceToMem(headers_json);
    const rc = ck_http(0, u.ptr, u.len, 0, 0, h.ptr, h.len);
    return hostResult(rc);
}

/// What the server said when it refused: an HTTP status and as much of the
/// error body as the host kept (2 KiB).
pub const HttpFailure = struct { status: u16, body: []const u8 };

/// The status behind the *immediately preceding* `error.NetworkError` from a
/// `http*` call, or null when there was no status (DNS failure, refused
/// connection, timeout -- all of which report the same error).
///
/// `ck_http` collapses every >= 400 response into `error.NetworkError`, so on
/// its own a 404 is indistinguishable from an unreachable host. The host parks
/// a `{"ck_http_status":N,"body":"..."}` envelope in the result slot on the
/// status path only, and this reads it. Call it before any other host call: the
/// result slot is shared and nothing clears it.
pub fn httpLastFailure(gpa: std.mem.Allocator) ?HttpFailure {
    const raw = readResult() orelse return null;
    const parsed = std.json.parseFromSliceLeaky(std.json.Value, gpa, raw, .{}) catch return null;
    if (parsed != .object) return null;
    const status = switch (parsed.object.get("ck_http_status") orelse return null) {
        .integer => |n| if (n >= 0 and n <= 599) @as(u16, @intCast(n)) else return null,
        else => return null,
    };
    const body = switch (parsed.object.get("body") orelse std.json.Value{ .string = "" }) {
        .string => |s| s,
        else => "",
    };
    return .{ .status = status, .body = body };
}

pub fn httpPost(url: []const u8, body: []const u8) HostError![]const u8 {
    const u = sliceToMem(url);
    const b = sliceToMem(body);
    const rc = ck_http(1, u.ptr, u.len, b.ptr, b.len, 0, 0);
    return hostResult(rc);
}

/// POST with custom headers, passed as a JSON object of name -> value
/// (parsed host-side; see src/sandbox/host.zig parseCustomHeaders). Needed
/// by any API that rejects a body without its Content-Type.
pub fn httpPostHdr(url: []const u8, body: []const u8, headers_json: []const u8) HostError![]const u8 {
    const u = sliceToMem(url);
    const b = sliceToMem(body);
    const h = sliceToMem(headers_json);
    const rc = ck_http(1, u.ptr, u.len, b.ptr, b.len, h.ptr, h.len);
    return hostResult(rc);
}

/// Runs a chatroom operation (send / history / rooms / subscribe) host-side.
/// The op lives in the request JSON; the guest fills in the argument fields.
pub fn chat(req: []const u8) HostError![]const u8 {
    const p = sliceToMem(req);
    const rc = ck_chat(p.ptr, p.len);
    return hostResult(rc);
}

/// Post `payload` (a JSON value) onto the serve live bus as a plugin event.
/// Requires `"live_publish": true` in this tool's descriptor; denied otherwise.
/// The host stamps `t` and `from`; the guest cannot pick chat/run/metrics.
pub fn publish(payload: []const u8) HostError!void {
    const p = sliceToMem(payload);
    const rc = ck_publish(p.ptr, p.len);
    switch (rc) {
        0 => {},
        1 => return error.SandboxDenied,
        3 => return error.TooLarge,
        else => return error.InvalidArg,
    }
}

/// Aggregated global token usage per provider/model (host-side aggregation
/// over state/token_stats.jsonl). Requires the token_stats module.
pub fn stats() HostError![]const u8 {
    const rc = ck_stats();
    return hostResult(rc);
}

/// The improve ledger (`state/improvements.jsonl`), newest records last, capped
/// host-side on a line boundary. Name-gated to the `improve_history` tool.
///
/// A host channel rather than a filesystem read on purpose: inside a
/// `clanker improve-self` worktree that path is a symlink to the checkout's
/// file, and the sandbox's no-follow walk refuses a symlinked leaf even when
/// the prefix is granted.
///
/// An absent ledger comes back as `""`, which is the honest answer for a
/// checkout that has never run improve-self. Every other failure is returned as
/// an error and must NOT be rendered as an empty history: reporting a refused
/// or unreadable ledger as "nothing yet" is the exact defect this channel
/// exists to remove.
pub fn improveHistory() HostError![]const u8 {
    const rc = ck_improve_history();
    if (rc == 2) return "";
    return hostResult(rc);
}

/// One-shot model call on the harness's active provider. Requires `"llm": true`
/// in this tool's descriptor; denied otherwise. No tools, no history: a prompt
/// in, completion text out.
pub fn llm(prompt: []const u8) HostError![]const u8 {
    return llmWith(prompt, null, 0);
}

/// Same, but aimed at a named provider and/or a different output cap. Both are
/// optional: null provider and 0 max_tokens keep the descriptor's settings.
pub fn llmWith(prompt: []const u8, provider: ?[]const u8, max_tokens: u32) HostError![]const u8 {
    var buf: [32 * 1024]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    var s = std.json.Stringify{ .writer = &w, .options = .{ .emit_null_optional_fields = false } };
    s.beginObject() catch return error.InvalidArg;
    s.objectField("prompt") catch return error.InvalidArg;
    s.write(prompt) catch return error.TooLarge;
    if (provider) |p| {
        s.objectField("provider") catch return error.InvalidArg;
        s.write(p) catch return error.InvalidArg;
    }
    if (max_tokens > 0) {
        s.objectField("max_tokens") catch return error.InvalidArg;
        s.write(max_tokens) catch return error.InvalidArg;
    }
    s.endObject() catch return error.InvalidArg;

    const req = sliceToMem(buf[0..w.end]);
    const rc = ck_llm(req.ptr, req.len);
    return hostResult(rc);
}

/// Optional fields for `llmCall`. A null provider/model keeps the
/// descriptor's defaults; 0 max_tokens does the same.
pub const LlmCall = struct {
    system: ?[]const u8 = null,
    prompt: []const u8,
    provider: ?[]const u8 = null,
    model: ?[]const u8 = null,
    max_tokens: u32 = 0,
};

/// Like `llmWith`, plus a system message prepended to the call — the shape a
/// role-played call needs (`arena`'s combatants layer a persona there, not into
/// the user turn, so the position under debate stays the only thing in it).
///
/// Allocates the request rather than using `llmWith`'s fixed 32 KiB stack
/// buffer: a prompt carrying a whole match transcript outgrows that, and
/// `error.TooLarge` on a prompt the provider would have accepted is the kind of
/// failure that reads as a provider problem.
pub fn llmSystem(system: ?[]const u8, prompt: []const u8, provider: ?[]const u8, max_tokens: u32) HostError![]const u8 {
    return llmCall(.{ .system = system, .prompt = prompt, .provider = provider, .max_tokens = max_tokens });
}

/// Same request as `llmSystem`, plus an optional model override. `ck_llm`
/// already accepts `"model"`; this is the guest helper that sends it.
pub fn llmCall(opts: LlmCall) HostError![]const u8 {
    var w: std.Io.Writer.Allocating = .init(alloc);
    defer w.deinit();
    var s = std.json.Stringify{ .writer = &w.writer, .options = .{ .emit_null_optional_fields = false } };
    s.beginObject() catch return error.TooLarge;
    s.objectField("prompt") catch return error.TooLarge;
    s.write(opts.prompt) catch return error.TooLarge;
    if (opts.system) |sys| if (sys.len > 0) {
        s.objectField("system") catch return error.TooLarge;
        s.write(sys) catch return error.TooLarge;
    };
    if (opts.provider) |p| if (p.len > 0) {
        s.objectField("provider") catch return error.TooLarge;
        s.write(p) catch return error.TooLarge;
    };
    if (opts.model) |m| if (m.len > 0) {
        s.objectField("model") catch return error.TooLarge;
        s.write(m) catch return error.TooLarge;
    };
    if (opts.max_tokens > 0) {
        s.objectField("max_tokens") catch return error.TooLarge;
        s.write(opts.max_tokens) catch return error.TooLarge;
    }
    s.endObject() catch return error.TooLarge;

    const req = sliceToMem(w.written());
    const rc = ck_llm(req.ptr, req.len);
    return hostResult(rc);
}

/// One prompt to several models at once. `request` is the whole `ck_llm_many`
/// object, built by the caller:
/// `{"prompt": "...", "system": "...", "max_tokens": N,
///   "targets": [{"provider": "<name>", "model": "<name>"}, ...]}`.
/// Returns a JSON array with one element per target, in target order:
/// `[{"provider":..,"model":..,"ok":true,"text":..,"ms":N,"tokens":N}, ...]`,
/// a failing target being `{"ok":false,"error":..,"detail":..}` rather than a
/// failure of the whole call.
///
/// A guest is single-threaded, so a loop of `llmWith` costs the sum of the
/// models' latencies; the host runs these side by side and the call costs the
/// slowest one. Requires `"llm": true` in the descriptor, exactly like `llm`.
pub fn llmMany(request: []const u8) HostError![]const u8 {
    const req = sliceToMem(request);
    const rc = ck_llm_many(req.ptr, req.len);
    return hostResult(rc);
}

/// This tool's own `config` object from its descriptor, as a JSON string
/// ("{}" when the descriptor has none).
pub fn config() []const u8 {
    if (ck_config() != 0) return "{}";
    return readResult() orelse "{}";
}

/// The harness's own effective config (default_provider, providers, models,
/// instance, peers), as a JSON string ("{}" if denied or on error). Distinct
/// from `config()`, which returns this plugin's own descriptor settings.
/// This is the merged config.toml/config.local.toml as the host parsed it —
/// use it instead of reading "config.toml" directly: a wasm32-freestanding
/// guest carries no TOML parser.
pub fn harnessConfig() []const u8 {
    if (ck_harness_config() != 0) return "{}";
    return readResult() orelse "{}";
}

pub const FsError = error{ SandboxDenied, NotFound, TooLarge, IoError, Mismatch };

/// Reads a file relative to the sandbox root.
pub fn fsRead(path: []const u8) FsError![]const u8 {
    const p = sliceToMem(path);
    const rc = ck_fs_read(p.ptr, p.len);
    return fsPathQuery(rc);
}

pub const ConfigSource = struct { name: []const u8, text: []const u8 };

/// Reads `<stem>.toml`. TOML is canonical; there is no `.json` fallback,
/// matching src/config.zig. Returns null when the file doesn't exist, so a
/// config layer that simply isn't there (e.g. no local override) is a normal
/// skip, not an error. For structured fields prefer `harnessConfig()`; this
/// is for tools that need the raw file bytes (config's dump).
pub fn readConfigFile(comptime stem: []const u8) ?ConfigSource {
    if (fsRead(stem ++ ".toml") catch null) |t| return .{ .name = stem ++ ".toml", .text = t };
    return null;
}

/// Lists file names under an allowed directory (JSON string array).
pub fn fsList(path: []const u8) FsError![]const u8 {
    const p = sliceToMem(path);
    const rc = ck_fs_list(p.ptr, p.len);
    return fsPathQuery(rc);
}

/// Reads [offset, offset+len) of a file. The host writes results into the
/// guest arena (1 MiB here), so this is the only way to see a file bigger
/// than that: ask for it a window at a time.
pub fn fsReadRange(path: []const u8, offset: usize, len: usize) FsError![]const u8 {
    const p = sliceToMem(path);
    const rc = ck_fs_read_range(p.ptr, p.len, @intCast(offset), @intCast(len));
    return fsPathQuery(rc);
}

/// Last `max_bytes` of `path`, cut forward to the first newline so a jsonl
/// consumer never opens mid-line. `fsRead` of a growing log returns TooLarge
/// once the file exceeds the 1 MiB host arena; a picker that only wants the
/// newest lines must not pull the rest.
pub fn fsReadTail(path: []const u8, max_bytes: usize) FsError![]const u8 {
    const want: usize = @min(max_bytes, host_arena_cap);
    if (want == 0) return "";
    const st_raw = fsStat(path) catch |err| switch (err) {
        error.NotFound => return error.NotFound,
        else => return fsRead(path),
    };
    const size = statSize(st_raw) orelse return fsRead(path);
    if (size == 0) return "";
    if (size <= want) return fsRead(path);
    const offset: u64 = size - want;
    if (offset > std.math.maxInt(u32) or want > std.math.maxInt(u32))
        return fsRead(path);
    const raw = try fsReadRange(path, @intCast(offset), @intCast(want));
    if (std.mem.findScalar(u8, raw, '\n')) |nl| return raw[nl + 1 ..];
    return raw;
}

fn statSize(st: []const u8) ?u64 {
    const v = std.json.parseFromSliceLeaky(std.json.Value, alloc, st, .{}) catch return null;
    if (v != .object) return null;
    const s = v.object.get("size") orelse return null;
    return switch (s) {
        .integer => |i| if (i < 0) null else @intCast(i),
        .number_string => |n| std.fmt.parseInt(u64, n, 10) catch null,
        else => null,
    };
}

/// Writes a file relative to the sandbox root.
/// The host writes results into its arena, so anything returned here is only
/// valid until the next host call: copy before calling again.
fn fsPathOp(rc: u32) FsError!void {
    return switch (rc) {
        0 => {},
        1 => error.SandboxDenied,
        2 => error.NotFound,
        3 => error.TooLarge,
        else => error.IoError,
    };
}

fn fsPathQuery(rc: u32) FsError![]const u8 {
    return switch (rc) {
        0 => readResult() orelse error.IoError,
        1 => error.SandboxDenied,
        2 => error.NotFound,
        3 => error.TooLarge,
        else => error.IoError,
    };
}

/// Appends to a file, creating it when absent.
pub fn fsAppend(path: []const u8, data: []const u8) FsError!void {
    const p = sliceToMem(path);
    const d = sliceToMem(data);
    return fsPathOp(ck_fs_append(p.ptr, p.len, d.ptr, d.len));
}

pub fn fsCopy(src: []const u8, dst: []const u8) FsError!void {
    const a = sliceToMem(src);
    const b = sliceToMem(dst);
    return fsPathOp(ck_fs_copy(a.ptr, a.len, b.ptr, b.len));
}

pub fn fsRename(old_path: []const u8, new_path: []const u8) FsError!void {
    const a = sliceToMem(old_path);
    const b = sliceToMem(new_path);
    return fsPathOp(ck_fs_rename(a.ptr, a.len, b.ptr, b.len));
}

pub fn fsDelete(path: []const u8) FsError!void {
    const p = sliceToMem(path);
    return fsPathOp(ck_fs_delete(p.ptr, p.len));
}

pub fn fsMkdir(path: []const u8) FsError!void {
    const p = sliceToMem(path);
    return fsPathOp(ck_fs_mkdir(p.ptr, p.len));
}

/// Bound on list-and-delete passes per directory in `fsDeleteTree`.
/// `ck_fs_list` deliberately truncates a listing whose JSON would overflow
/// the host's buffer and returns a valid-but-partial array (the right
/// contract for a read), so one pass over a large staging tree deletes only
/// the first page and the parent removal then fails with ENOTEMPTY. The
/// loop re-lists until a listing's worth of names has actually gone; the
/// cap stops a directory growing under the sandbox from making that loop
/// unbounded. Each pass deletes at least one full host-buffer page of
/// entries, so 64 passes covers a directory four billion entries deep in
/// pages before giving up.
pub const fs_delete_tree_max_passes: usize = 64;

// Recursively deletes a directory tree. Lists contents, deletes files,
// recurses into subdirectories, then removes the now-empty directory.
// Individual failures are skipped, but the parent removal is retried with
// a fresh listing (see fs_delete_tree_max_passes) so a truncated listing
// page cannot leave most of a large directory alive behind a reported
// success — the janitor staging bug of 2026-08-20.
pub fn fsDeleteTree(a: std.mem.Allocator, path: []const u8) void {
    var pass: usize = 0;
    while (pass < fs_delete_tree_max_passes) : (pass += 1) {
        const raw = fsList(path) catch return;
        const names = std.json.parseFromSliceLeaky(std.json.Value, a, raw, .{}) catch return;
        if (names != .array) return;
        for (names.array.items) |item| {
            if (item != .string) continue;
            const name = item.string;
            if (name.len == 0) continue;
            if (name[name.len - 1] == '/') {
                const dir_path = std.fmt.allocPrint(a, "{s}/{s}", .{ path, name[0 .. name.len - 1] }) catch continue;
                fsDeleteTree(a, dir_path);
            } else {
                const sub = std.fmt.allocPrint(a, "{s}/{s}", .{ path, name }) catch continue;
                fsDelete(sub) catch {};
            }
        }
        // Everything this listing named is gone, so the directory itself
        // can go. Success ends the loop here; ENOTEMPTY — the previous page
        // was truncated — buys exactly one more pass, up to the cap.
        if (fsDelete(path)) return else |_| {}
    }
}

/// JSON: {"kind":"file"|"dir","size":N}
pub fn fsStat(path: []const u8) FsError![]const u8 {
    const p = sliceToMem(path);
    return fsPathQuery(ck_fs_stat(p.ptr, p.len));
}

/// Paths under `dir` whose name contains `pattern`, as a JSON array.
pub fn fsFind(dir: []const u8, pattern: []const u8) FsError![]const u8 {
    const d = sliceToMem(dir);
    const p = sliceToMem(pattern);
    return fsPathQuery(ck_fs_find(d.ptr, d.len, p.ptr, p.len));
}

/// Lines under `dir` containing `pattern`, as a JSON array of "path:line:text".
pub fn fsGrep(dir: []const u8, pattern: []const u8) FsError![]const u8 {
    const d = sliceToMem(dir);
    const p = sliceToMem(pattern);
    return fsPathQuery(ck_fs_grep(d.ptr, d.len, p.ptr, p.len));
}

/// SHA-256 of `data`, hex. Useful for telling whether a file changed between
/// two reads without holding both copies.
pub fn hash(data: []const u8) FsError![]const u8 {
    const d = sliceToMem(data);
    return fsPathQuery(ck_hash(d.ptr, d.len));
}

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

/// Compare-and-swap write: the host locks the file, hashes what is actually
/// there, and writes `data` only when that hash equals `expected_hex`
/// (lowercase SHA-256 hex, as `hash` returns; an empty string matches a file
/// that does not exist yet). error.Mismatch means someone else changed the
/// file between your read and this write — re-read, re-hash, and retry — as
/// opposed to error.SandboxDenied or error.NotFound, which are policy and
/// lookup failures.
pub fn fsWriteIf(path: []const u8, expected_hex: []const u8, data: []const u8) FsError!void {
    const p = sliceToMem(path);
    const e = sliceToMem(expected_hex);
    const d = sliceToMem(data);
    const rc = ck_fs_write_if(p.ptr, p.len, e.ptr, e.len, d.ptr, d.len);
    return switch (rc) {
        0 => {},
        1 => error.SandboxDenied,
        2 => error.NotFound,
        3 => error.TooLarge,
        6 => error.Mismatch,
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

pub const ExecError = error{ SandboxDenied, NotFound, TooLarge, NetworkError, InvalidArg, OutOfMemory, WriteFailed };

fn execResult(rc: u32) ExecError![]const u8 {
    return switch (rc) {
        0 => readResult() orelse error.InvalidArg,
        1 => error.SandboxDenied,
        2 => error.NotFound,
        3 => error.TooLarge,
        4 => error.NetworkError,
        else => error.InvalidArg,
    };
}

/// Runs a command with `input` on its stdin and returns the {code, stdout,
/// stderr} JSON. For processes you talk to rather than just launch — an LSP
/// server reads framed requests and answers on stdout.
pub fn execStdin(cmd: []const u8, args: []const []const u8, input: []const u8) ExecError![]const u8 {
    // stdin is JSON-escaped into this buffer, so it must be sized for the
    // escaped length, not the raw bytes. A fixed 256 KiB cap made the lsp
    // tool answer "zls did not answer" on any source file whose escaped
    // session exceeded it: src/agent/loop.zig is 248 KiB and its didOpen
    // session escaped past 256 KiB before zls was ever spawned. Source text
    // escapes at most ~2x (quotes, backslashes, newlines, tabs); the +4096
    // covers cmd/args and the JSON framing.
    const wcap = input.len * 2 + 4096;
    const wbuf = std.heap.wasm_allocator.alloc(u8, wcap) catch return error.OutOfMemory;
    defer std.heap.wasm_allocator.free(wbuf);
    var w: std.Io.Writer = .fixed(wbuf);
    var s = std.json.Stringify{ .writer = &w, .options = .{ .emit_null_optional_fields = false } };
    s.beginObject() catch return error.InvalidArg;
    s.objectField("cmd") catch return error.InvalidArg;
    s.write(cmd) catch return error.InvalidArg;
    s.objectField("args") catch return error.InvalidArg;
    s.beginArray() catch return error.InvalidArg;
    for (args) |a| s.write(a) catch return error.InvalidArg;
    s.endArray() catch return error.InvalidArg;
    s.objectField("stdin") catch return error.InvalidArg;
    s.write(input) catch return error.InvalidArg;
    s.endObject() catch return error.InvalidArg;

    const req = sliceToMem(wbuf[0..w.end]);
    return execResult(ck_exec(req.ptr, req.len));
}

/// Runs an allowlisted host command (git / rg / ast-grep / semcode) with the
/// given arguments. Returns the raw {"ok","code","stdout","stderr"} JSON.
pub fn exec(cmd: []const u8, args: []const []const u8) ExecError![]const u8 {
    return execCommon(cmd, args, null);
}

/// Same as `exec`, but runs the command with `cwd` as its working directory.
/// The host resolves `cwd` against the sandbox root through `safeJoinSecure`,
/// so it cannot escape the roots the tool's descriptor grants (a `..` or
/// absolute path is refused). Use for running in a subdirectory such as a
/// git worktree.
pub fn execCwd(cmd: []const u8, args: []const []const u8, cwd: []const u8) ExecError![]const u8 {
    return execCommon(cmd, args, cwd);
}

fn execCommon(cmd: []const u8, args: []const []const u8, cwd: ?[]const u8) ExecError![]const u8 {
    const wbuf = std.heap.wasm_allocator.alloc(u8, 8 * 1024) catch return error.OutOfMemory;
    defer std.heap.wasm_allocator.free(wbuf);
    var w: std.Io.Writer = .fixed(wbuf);
    var s = std.json.Stringify{ .writer = &w, .options = .{ .emit_null_optional_fields = false } };
    try s.beginObject();
    try s.objectField("cmd");
    try s.write(cmd);
    try s.objectField("args");
    try s.beginArray();
    for (args) |a| try s.write(a);
    try s.endArray();
    if (cwd) |c| {
        try s.objectField("cwd");
        try s.write(c);
    }
    try s.endObject();

    const b = sliceToMem(wbuf[0..w.end]);
    return execResult(ck_exec(b.ptr, b.len));
}

pub const DockerError = error{ OutOfMemory, WriteFailed, SandboxDenied, InvalidArg, NetworkError };

/// Calls the harness's Docker-socket host function with a JSON request
/// {"method": "...", "path": "..."}; returns the raw response body.
pub fn kernelEval(req: []const u8) FsError![]const u8 {
    const d = sliceToMem(req);
    return fsPathQuery(ck_kernel(d.ptr, d.len));
}

pub fn debugEval(req: []const u8) FsError![]const u8 {
    const d = sliceToMem(req);
    return fsPathQuery(ck_debug(d.ptr, d.len));
}

pub fn dockerRequest(method: []const u8, path: []const u8) DockerError![]const u8 {
    const wbuf = std.heap.wasm_allocator.alloc(u8, 8 * 1024) catch return error.OutOfMemory;
    defer std.heap.wasm_allocator.free(wbuf);
    var w: std.Io.Writer = .fixed(wbuf);
    var s = std.json.Stringify{ .writer = &w, .options = .{ .emit_null_optional_fields = false } };
    try s.beginObject();
    try s.objectField("method");
    try s.write(method);
    try s.objectField("path");
    try s.write(path);
    try s.endObject();

    const req = sliceToMem(wbuf[0..w.end]);
    const rc = ck_docker(req.ptr, req.len);
    return switch (rc) {
        0 => readResult() orelse error.InvalidArg,
        1 => error.SandboxDenied,
        4 => error.NetworkError,
        else => error.InvalidArg,
    };
}

pub const ToolCallError = error{ SandboxDenied, NotFound, TooLarge, InvalidArg, NetworkError };

/// Call another tool via ck_tool (only allowed for `tool_call:true` guests, i.e. chain).
pub fn toolCall(name: []const u8, args_json: []const u8) ToolCallError![]const u8 {
    var buf: [16 * 1024]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    var s = std.json.Stringify{ .writer = &w, .options = .{} };
    s.beginObject() catch return error.InvalidArg;
    s.objectField("tool") catch return error.InvalidArg;
    s.write(name) catch return error.InvalidArg;
    s.objectField("args") catch return error.InvalidArg;
    const v = std.json.parseFromSliceLeaky(std.json.Value, alloc, args_json, .{}) catch null;
    if (v) |val| {
        s.write(val) catch return error.InvalidArg;
    } else {
        s.write(args_json) catch return error.InvalidArg;
    }
    s.endObject() catch return error.InvalidArg;
    const req = sliceToMem(buf[0..w.end]);
    const rc = ck_tool(req.ptr, req.len);
    return switch (rc) {
        0 => readResult() orelse error.InvalidArg,
        1 => error.SandboxDenied,
        2 => error.NotFound,
        3 => error.TooLarge,
        4 => error.NetworkError,
        else => error.InvalidArg,
    };
}

// ------------------------------------------------ shared parsing helpers --

/// A string field from an ObjectMap, trimmed of whitespace. Returns null when
/// absent, wrong type, or blank.
pub fn strFieldTrimmed(obj: std.json.ObjectMap, name: []const u8) ?[]const u8 {
    const v = obj.get(name) orelse return null;
    if (v != .string) return null;
    const s = std.mem.trim(u8, v.string, " \t\r\n");
    return if (s.len == 0) null else s;
}

/// An unsigned integer field from an ObjectMap, accepting JSON integers and
/// floats >= 1. Returns null when absent, wrong type, or <= 0.
pub fn uintFieldMap(obj: std.json.ObjectMap, name: []const u8) ?u32 {
    const v = obj.get(name) orelse return null;
    return switch (v) {
        .integer => |n| if (n > 0) @intCast(@min(n, std.math.maxInt(u32))) else null,
        .float => |f| if (f >= 1.0) @trunc(f) else null,
        else => null,
    };
}

/// A boolean field from an ObjectMap, with a fallback default.
pub fn boolFieldMap(obj: std.json.ObjectMap, name: []const u8, fallback: bool) bool {
    const v = obj.get(name) orelse return fallback;
    return switch (v) {
        .bool => |x| x,
        else => fallback,
    };
}

/// A non-empty string field from an ObjectMap, or null when absent, wrong type,
/// or empty. Does not trim whitespace.
pub fn strFieldRequired(obj: std.json.ObjectMap, name: []const u8) ?[]const u8 {
    const v = obj.get(name) orelse return null;
    return if (v == .string and v.string.len > 0) v.string else null;
}

/// A string field from an ObjectMap, returning "" when absent or not a string.
/// Unlike `strFieldTrimmed`, does not trim whitespace.
pub fn jsonStrField(obj: std.json.ObjectMap, name: []const u8) []const u8 {
    const v = obj.get(name) orelse return "";
    return if (v == .string) v.string else "";
}

/// Harness provider/config structs for tools that need to enumerate configured
/// providers (arena, compare). Parsed from `harnessConfig()` with
/// `ignore_unknown_fields`.
pub const HarnessProvider = struct { default_model: []const u8 = "" };
pub const HarnessAgent = struct {
    tools_dir: []const u8 = "",
    tools_dirs: []const []const u8 = &.{},
};
pub const HarnessKernel = struct { enabled: bool = false, max_output_bytes: u32 = 65536 };
pub const HarnessDebug = struct { enabled: bool = false };
pub const HarnessConfig = struct {
    default_provider: []const u8 = "",
    providers: std.json.ArrayHashMap(HarnessProvider) = .{},
    agent: HarnessAgent = .{},
    kernel: HarnessKernel = .{},
    debug: HarnessDebug = .{},
};

/// Every configured manifest directory, last-listed last. Falls back to the
/// singular `tools_dir` key so a host that only emitted that still works.
pub fn toolsDirs() []const []const u8 {
    const cfg = parseHarnessConfig();
    if (cfg.agent.tools_dirs.len > 0) return cfg.agent.tools_dirs;
    if (cfg.agent.tools_dir.len > 0) {
        const one = alloc.alloc([]const u8, 1) catch return &.{};
        one[0] = cfg.agent.tools_dir;
        return one;
    }
    return &.{"tools/manifests"};
}

/// Generates a time-and-content-seeded id with the given prefix,
/// e.g. "arena-1723456789-a1b2c3d4". Two calls in the same second with
/// different seed text produce different ids.
pub fn prefixedId(prefix: []const u8, seed_text: []const u8) ![]const u8 {
    const secs: u64 = @trunc(@max(0.0, nowSeconds()));
    var hasher = std.hash.Wyhash.init(secs);
    hasher.update(seed_text);
    return std.fmt.allocPrint(alloc, "{s}-{d}-{x}", .{ prefix, secs, hasher.final() & 0xffff_ffff });
}

pub fn parseHarnessConfig() HarnessConfig {
    return std.json.parseFromSliceLeaky(HarnessConfig, alloc, harnessConfig(), .{ .ignore_unknown_fields = true }) catch HarnessConfig{};
}

/// Host-provided random u64.
pub fn random() u64 {
    return ck_random();
}
