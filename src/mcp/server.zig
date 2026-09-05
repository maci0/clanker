//! MCP (Model Context Protocol) stdio JSON-RPC 2.0 server: exposes clanker's
//! WASM tools to external MCP clients (Claude, Cursor, IDE agents, ...).
//! Each line on stdin is one JSON-RPC request; each response is one line.

const std = @import("std");
const json = std.json;
const build_options = @import("build_options");
const config = @import("../config.zig");
const registry = @import("../toolhost/registry.zig");
const runtime = @import("../sandbox/runtime.zig");
const client = @import("../llm/client.zig");
const types = @import("../llm/types.zig");
const log = @import("../util/log.zig");
const tool_out = @import("../util/tool_out.zig");

const protocol_version = "2024-11-05";
const max_line = 1 << 20;
var mcp_sequence = std.atomic.Value(u64).init(1);

/// Wire names include slashes (`tools/list`), so stringToEnum cannot be the
/// table. Same closed-set map as `log.Level.fromStr`.
const Method = enum { initialize, ping, tools_list, tools_call };
const methods = std.StaticStringMap(Method).initComptime(.{
    .{ "initialize", .initialize },
    .{ "ping", .ping },
    .{ "tools/list", .tools_list },
    .{ "tools/call", .tools_call },
});

/// Compiled tool modules, keyed by tool name and kept for the life of the
/// stdio session. Without this, every `tools/call` re-read the .wasm file and
/// re-parsed/re-linked/re-instantiated it from scratch, the agent loop
/// avoids exactly this cost with its own `wasm_cache`/`self.modules`, and an
/// MCP client issuing many calls in a session deserves the same reuse.
///
/// Each entry is stamped with the wasm file it was compiled from. A
/// `zig build tools` mid-session used to keep executing the first build for
/// the rest of the stdio connection: `runtime.cachedWasm` picked up the new
/// bytes, but a hit here never consulted them. Same shape as `Agent.moduleFor`.
const ModuleCacheEntry = struct { stamp: u64, mod: *runtime.ToolModule };
const ModuleCache = std.StringHashMapUnmanaged(ModuleCacheEntry);

fn deinitModuleCache(gpa: std.mem.Allocator, cache: *ModuleCache) void {
    var it = cache.valueIterator();
    while (it.next()) |e| e.mod.deinit();
    cache.deinit(gpa);
}

pub fn serve(io: std.Io, gpa: std.mem.Allocator, arena: std.mem.Allocator, cfg: *const config.Config, environ_map: *std.process.Environ.Map) !void {
    const reg = try registry.Registry.load(io, arena, std.Io.Dir.cwd(), cfg.agent.tools_dir);
    const tool_defs = try reg.toToolDefs(arena);

    // Stdout is the JSON-RPC channel, so the operator-facing banner goes to
    // stderr. Without it a human typing `clanker mcp` sees a silent hang and
    // cannot tell a working server from a wedged one.
    log.log(.info, "mcp: serving {d} tool(s) over stdio (JSON-RPC, one line per message); waiting for a client on stdin, Ctrl-C to stop", .{tool_defs.len});

    // One line in, one line out, and the read must return as soon as a line
    // arrives. readSliceShort here was a deadlock: it blocks until it fills its
    // buffer or sees EOF, so a client that writes one request and waits for the
    // response (which is every interactive MCP client) hung forever, and the
    // server only worked when fed a large batch or a closed pipe.
    const read_buf = try gpa.alloc(u8, max_line);
    defer gpa.free(read_buf);
    var stdin_file = std.Io.File.stdin();
    var reader = stdin_file.reader(io, read_buf);

    // Long-lived: every cached module's sandbox is built once against this
    // context and this arena, so both must outlive every call that might
    // still be reusing a module they were built with (io/gpa/environ_map/cfg
    // never change across a session, so sharing them is safe).
    var llm_ctx = client.Ctx{ .io = io, .gpa = gpa, .environ_map = environ_map, .cfg = cfg };
    var cache_arena_state = std.heap.ArenaAllocator.init(gpa);
    defer cache_arena_state.deinit();
    var module_cache: ModuleCache = .empty;
    defer deinitModuleCache(gpa, &module_cache);
    const cache_arena = cache_arena_state.allocator();

    while (true) {
        const raw = reader.interface.takeDelimiter('\n') catch |e| switch (e) {
            // A line longer than the buffer cannot be parsed, so drop what is
            // held and resync on the next newline rather than spinning on a
            // stream state the reader deliberately left unmodified.
            error.StreamTooLong => {
                reader.interface.toss(reader.interface.buffered().len);
                continue;
            },
            error.ReadFailed => {
                log.log(.error_, "mcp stdin read error: {s}", .{@errorName(e)});
                break;
            },
        } orelse break; // stdin EOF
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0) continue;
        // JSON-RPC params routinely contain prompts, file content, and tool
        // arguments. Logging even a prefix leaks data without adding much
        // diagnostic value; the byte count still identifies framing issues.
        log.log(.debug, "mcp handling line bytes={d}", .{line.len});
        var mcp_id_buf: [24]u8 = undefined;
        const mcp_id = std.fmt.bufPrint(&mcp_id_buf, "mcp-{d}", .{mcp_sequence.fetchAdd(1, .monotonic)}) catch "mcp-unknown";
        log.setContext(mcp_id);
        defer log.clearContext();
        handleLine(io, gpa, cache_arena, cfg, environ_map, &reg, tool_defs, &module_cache, &llm_ctx, line) catch |err| {
            log.log(.error_, "mcp line error: {s}", .{@errorName(err)});
        };
    }
}

const Request = struct {
    jsonrpc: ?[]const u8 = null,
    id: ?json.Value = null,
    method: ?[]const u8 = null,
    params: ?json.Value = null,
};

/// JSON-RPC requires exactly "jsonrpc": "2.0"; a missing or wrong version is
/// an Invalid Request, not something to dispatch leniently.
fn hasValidJsonRpc(jsonrpc: ?[]const u8) bool {
    const v = jsonrpc orelse return false;
    return std.mem.eql(u8, v, "2.0");
}

fn respondError(s: *json.Stringify, code: i64, message: []const u8) !void {
    try s.objectField("error");
    try s.beginObject();
    try s.objectField("code");
    try s.print("{d}", .{code});
    try s.objectField("message");
    try s.write(message);
    try s.endObject();
}

/// Emits the fields of a tools/call result object. The caller has already
/// opened the top-level "result" object, so write the payload fields
/// directly (previously this nested a second "result" object inside it,
/// producing {"result":{"result":{...}}} that MCP clients cannot parse).
fn respondText(s: *json.Stringify, text: []const u8, is_error: bool) !void {
    if (is_error) {
        try s.objectField("isError");
        try s.write(true);
    }
    try s.objectField("content");
    try s.beginArray();
    try s.beginObject();
    try s.objectField("type");
    try s.write("text");
    try s.objectField("text");
    try s.write(text);
    try s.endObject();
    try s.endArray();
}

fn handleLine(io: std.Io, gpa: std.mem.Allocator, cache_arena: std.mem.Allocator, cfg: *const config.Config, environ_map: *std.process.Environ.Map, reg: *const registry.Registry, tool_defs: []const types.ToolDef, module_cache: *ModuleCache, llm_ctx: *client.Ctx, line: []const u8) !void {
    // Request-scoped: parseFromSliceLeaky on the process gpa leaked the
    // JSON tree on every line of a long-lived stdio session.
    var req_arena_state = std.heap.ArenaAllocator.init(gpa);
    defer req_arena_state.deinit();
    const req_arena = req_arena_state.allocator();
    // A client that sends one request and blocks on the reply (every
    // interactive MCP client) must get a response even to garbage input, or
    // it hangs forever: JSON-RPC 2.0 requires an id-less error response when
    // the id itself could not be parsed, rather than silence.
    const req = json.parseFromSliceLeaky(Request, req_arena, line, .{ .ignore_unknown_fields = true }) catch {
        var out_buf: [512]u8 = undefined;
        var w: std.Io.Writer = .fixed(&out_buf);
        var s = json.Stringify{ .writer = &w, .options = .{ .emit_null_optional_fields = false } };
        try s.beginObject();
        try s.objectField("jsonrpc");
        try s.write("2.0");
        try s.objectField("id");
        try s.write(.null);
        try respondError(&s, -32700, "Parse error");
        try s.endObject();
        writeResponse(io, out_buf[0..w.end]);
        return;
    };
    const method_name = (if (hasValidJsonRpc(req.jsonrpc)) req.method else null) orelse {
        var err_buf: [512]u8 = undefined;
        var err_w: std.Io.Writer = .fixed(&err_buf);
        var err_s = json.Stringify{ .writer = &err_w, .options = .{ .emit_null_optional_fields = false } };
        try err_s.beginObject();
        try err_s.objectField("jsonrpc");
        try err_s.write("2.0");
        try err_s.objectField("id");
        try err_s.write(req.id orelse .null);
        try respondError(&err_s, -32600, "Invalid Request");
        try err_s.endObject();
        writeResponse(io, err_buf[0..err_w.end]);
        return;
    };
    // Notifications (initialized, cancelled, ...) never get a response.
    if (std.mem.startsWith(u8, method_name, "notifications/")) return;

    var out_buf: [max_line]u8 = undefined;
    var w: std.Io.Writer = .fixed(&out_buf);
    var s = json.Stringify{ .writer = &w, .options = .{ .emit_null_optional_fields = false } };
    try s.beginObject();
    try s.objectField("jsonrpc");
    try s.write("2.0");
    try s.objectField("id");
    try s.write(req.id orelse .null);
    try s.objectField("result");
    try s.beginObject();

    {
        const method = methods.get(method_name) orelse {
            // Unknown method: a JSON-RPC response must not contain both
            // "result" and "error". Discard the half-written result object
            // and restart the buffer with a proper error response.
            w = .fixed(&out_buf);
            s = json.Stringify{ .writer = &w, .options = .{ .emit_null_optional_fields = false } };
            try s.beginObject();
            try s.objectField("jsonrpc");
            try s.write("2.0");
            try s.objectField("id");
            try s.write(req.id orelse .null);
            try respondError(&s, -32601, "MethodNotFound");
            try s.endObject();
            writeResponse(io, out_buf[0..w.end]);
            return;
        };
        switch (method) {
            .initialize => {
                try s.objectField("protocolVersion");
                try s.write(protocol_version);
                try s.objectField("capabilities");
                try s.beginObject();
                try s.objectField("tools");
                try s.beginObject();
                try s.objectField("listChanged");
                try s.write(false);
                try s.endObject();
                try s.endObject();
                try s.objectField("serverInfo");
                try s.beginObject();
                try s.objectField("name");
                try s.write("clanker");
                try s.objectField("version");
                try s.write(build_options.version);
                try s.endObject();
            },
            .ping => {},
            .tools_list => {
                try s.objectField("tools");
                try s.beginArray();
                for (tool_defs) |t| {
                    try s.beginObject();
                    try s.objectField("name");
                    try s.write(t.name);
                    try s.objectField("description");
                    try s.write(t.description);
                    try s.objectField("inputSchema");
                    try s.write(t.input_schema);
                    try s.endObject();
                }
                try s.endArray();
            },
            .tools_call => {
                try handleToolCall(&s, io, gpa, cache_arena, cfg, environ_map, reg, module_cache, llm_ctx, req.params);
            },
        }
    }
    try s.endObject();
    try s.endObject();

    writeResponse(io, out_buf[0..w.end]);
}

/// One response per line on stdout.
///
/// Streaming, not positional: a positional writer starts at offset 0 every
/// time it is created, and this creates one per response. Over a pipe the
/// offset is ignored and nothing looks wrong, but with stdout redirected to a
/// file each response overwrote the one before it. A 45-request session left a
/// file holding the last reply followed by the middle of another.
fn writeResponse(io: std.Io, bytes: []const u8) void {
    var stdout_file = std.Io.File.stdout();
    var wbuf: [65536]u8 = undefined;
    var out_w = stdout_file.writerStreaming(io, &wbuf);
    out_w.interface.writeAll(bytes) catch {};
    out_w.interface.writeAll("\n") catch {};
    out_w.interface.flush() catch {};
}

/// Pulls the "name" and "arguments" fields a tools/call request carries out of
/// whatever `params` the client sent, re-serializing arguments into `arg_buf`.
/// Split out from handleToolCall so the untrusted-input parsing can be fuzzed
/// without touching the sandbox, the registry, or stdout.
fn extractToolCall(params: ?json.Value, arg_buf: []u8) struct { name: []const u8, arg_text: []const u8, too_large: bool = false } {
    var name: []const u8 = "";
    var arg_text: []const u8 = "{}";
    if (params) |p| {
        switch (p) {
            .object => |o| {
                if (o.get("name")) |n| switch (n) {
                    .string => |str| name = str,
                    else => {},
                };
                if (o.get("arguments")) |args| {
                    var w: std.Io.Writer = .fixed(arg_buf);
                    json.Stringify.value(args, .{}, &w) catch {
                        // The fixed buffer overflowed: arg_buf now holds a
                        // partial, invalid-JSON prefix. Handing that to a
                        // tool as its arguments is worse than rejecting the
                        // call outright, since the truncation is invisible
                        // to both the tool and the caller.
                        return .{ .name = name, .arg_text = "{}", .too_large = true };
                    };
                    arg_text = arg_buf[0..w.end];
                }
            },
            else => {},
        }
    }
    return .{ .name = name, .arg_text = arg_text };
}

/// Returns the cached module for `name`, loading and caching it on first use.
/// `cache_arena` never resets for the life of the session, matching the
/// module's lifetime: its sandbox must outlive every later call that reuses
/// the module from the cache.
///
/// The old module is freed only after the new one compiled successfully, so
/// a failed recompile leaves the previous entry in place (retried on the
/// next call) rather than a dangling pointer. MCP is single-threaded stdio,
/// so freeing a superseded module cannot race an in-flight use.
fn getOrLoadModule(gpa: std.mem.Allocator, io: std.Io, cache_arena: std.mem.Allocator, environ_map: *std.process.Environ.Map, cfg: *const config.Config, reg: *const registry.Registry, module_cache: *ModuleCache, llm_ctx: *client.Ctx, name: []const u8) !*runtime.ToolModule {
    const tool = reg.get(name) orelse return error.UnknownTool;
    const stamp = runtime.wasmStamp(io, tool.wasm) catch 0;
    if (module_cache.get(name)) |e| {
        if (e.stamp == stamp) return e.mod;
    }
    const mod = try runtime.loadNamedTool(gpa, io, cache_arena, environ_map, cfg, reg, name, llm_ctx);
    errdefer mod.deinit();
    if (module_cache.getPtr(name)) |e| {
        if (e.mod != mod) e.mod.deinit();
        e.* = .{ .stamp = stamp, .mod = mod };
        return mod;
    }
    const key = try cache_arena.dupe(u8, name);
    try module_cache.put(gpa, key, .{ .stamp = stamp, .mod = mod });
    return mod;
}

fn handleToolCall(s: *json.Stringify, io: std.Io, gpa: std.mem.Allocator, cache_arena: std.mem.Allocator, cfg: *const config.Config, environ_map: *std.process.Environ.Map, reg: *const registry.Registry, module_cache: *ModuleCache, llm_ctx: *client.Ctx, params: ?json.Value) !void {
    var arg_buf: [256 * 1024]u8 = undefined;
    const call = extractToolCall(params, &arg_buf);
    if (call.too_large) {
        try respondText(s, "arguments too large", true);
        return;
    }
    const name = call.name;
    const arg_text = call.arg_text;

    const mod = getOrLoadModule(gpa, io, cache_arena, environ_map, cfg, reg, module_cache, llm_ctx, name) catch |err| {
        const msg: []const u8 = switch (err) {
            error.UnknownTool => "unknown tool",
            error.FileNotFound => "wasm missing (run zig build tools)",
            else => "tool load failed",
        };
        try respondText(s, msg, true);
        return;
    };

    const out = mod.executeTool(arg_text) catch |err| {
        try respondText(s, @errorName(err), true);
        return;
    };
    defer gpa.free(out);
    // The agent warns about malformed tool output on its own paths; a tool
    // driven over MCP reaches the caller without passing through any of them,
    // and this is the surface tools are usually probed from.
    tool_out.warnIfMalformed(gpa, name, out);
    try respondText(s, out, false);
}

test "fuzz: a JSON-RPC line from stdin never crashes the parse/dispatch path" {
    // handleLine and extractToolCall see whatever bytes an MCP client writes
    // to stdin, unauthenticated and outside any sandbox: the property under
    // test is that no line, however malformed or adversarially structured,
    // panics or overflows arg_buf.
    const Ctx = struct {
        fn one(_: void, smith: *std.testing.Smith) anyerror!void {
            var buf: [4096]u8 = undefined;
            const len = smith.slice(&buf);
            const line = buf[0..len];

            var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
            defer arena_state.deinit();
            const arena = arena_state.allocator();

            const req = json.parseFromSliceLeaky(Request, arena, line, .{ .ignore_unknown_fields = true }) catch return;
            var arg_buf: [4096]u8 = undefined;
            _ = extractToolCall(req.params, &arg_buf);
        }
    };
    try std.testing.fuzz({}, Ctx.one, .{});
}

test "extractToolCall parses name and arguments and refuses an overflowing buffer" {
    // The fuzz test above proves no stdin line crashes extractToolCall, but
    // not that a valid call yields the right name/arguments or that an
    // oversized one is refused rather than silently truncated. Pin the
    // documented contract: defaults for absent fields, compact re-serialized
    // arguments, and too_large discarding the partial JSON prefix.
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const parse = struct {
        fn go(alloc: std.mem.Allocator, raw: []const u8) std.json.Value {
            return std.json.parseFromSliceLeaky(std.json.Value, alloc, raw, .{}) catch @panic("test payload");
        }
    }.go;

    var buf: [64]u8 = undefined;

    // No params at all: defaults, no error.
    const none = extractToolCall(null, &buf);
    try std.testing.expectEqualStrings("", none.name);
    try std.testing.expectEqualStrings("{}", none.arg_text);
    try std.testing.expect(!none.too_large);

    // params that is not an object is ignored, not an error.
    const arr = extractToolCall(parse(arena, "[1,2]"), &buf);
    try std.testing.expectEqualStrings("", arr.name);
    try std.testing.expectEqualStrings("{}", arr.arg_text);

    // Missing name and non-string name both read as empty.
    const no_name = extractToolCall(parse(arena, "{\"arguments\":{\"a\":1}}"), &buf);
    try std.testing.expectEqualStrings("", no_name.name);
    try std.testing.expectEqualStrings("{\"a\":1}", no_name.arg_text);
    const num_name = extractToolCall(parse(arena, "{\"name\":7,\"arguments\":{\"a\":1}}"), &buf);
    try std.testing.expectEqualStrings("", num_name.name);

    // No arguments: the tool sees an empty object, not an error.
    const no_args = extractToolCall(parse(arena, "{\"name\":\"read_file\"}"), &buf);
    try std.testing.expectEqualStrings("read_file", no_args.name);
    try std.testing.expectEqualStrings("{}", no_args.arg_text);

    // A normal call round-trips its arguments as compact JSON.
    const ok = extractToolCall(parse(arena, "{\"name\":\"read_file\",\"arguments\":{\"path\":\"./x\",\"n\":3}}"), &buf);
    try std.testing.expectEqualStrings("read_file", ok.name);
    try std.testing.expectEqualStrings("{\"path\":\"./x\",\"n\":3}", ok.arg_text);
    try std.testing.expect(!ok.too_large);

    // An arguments value that overflows arg_buf is refused wholesale: the
    // truncated JSON prefix is discarded and the tool sees "{}", because a
    // partial object would look like a valid but wrong call.
    const big = try std.fmt.allocPrint(arena, "{{\"name\":\"x\",\"arguments\":{{\"blob\":\"{s}\"}}}}", .{"y" ** 200});
    var tiny: [16]u8 = undefined;
    const overflow = extractToolCall(parse(arena, big), &tiny);
    try std.testing.expectEqualStrings("x", overflow.name);
    try std.testing.expectEqualStrings("{}", overflow.arg_text);
    try std.testing.expect(overflow.too_large);

    // An exact fit is not an overflow.
    var fit: [7]u8 = undefined;
    const exact = extractToolCall(parse(arena, "{\"name\":\"x\",\"arguments\":{\"a\":1}}"), &fit);
    try std.testing.expectEqualStrings("{\"a\":1}", exact.arg_text);
    try std.testing.expect(!exact.too_large);
}

test "respondText emits the MCP content payload without nesting a second result" {
    // Regression: respondText used to emit {"result":{"result":{...}}} by
    // writing its own "result" object, which MCP clients cannot parse. The
    // caller owns the result object; respondText writes only the payload
    // fields, and isError rides alongside content.
    var buf: [256]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    var s = json.Stringify{ .writer = &w, .options = .{ .emit_null_optional_fields = false } };

    try s.beginObject();
    try s.objectField("result");
    try s.beginObject();
    try respondText(&s, "hello", false);
    try s.endObject();
    try s.endObject();
    try std.testing.expectEqualStrings("{\"result\":{\"content\":[{\"type\":\"text\",\"text\":\"hello\"}]}}", buf[0..w.end]);

    w = .fixed(&buf);
    s = json.Stringify{ .writer = &w, .options = .{ .emit_null_optional_fields = false } };
    try s.beginObject();
    try s.objectField("result");
    try s.beginObject();
    try respondText(&s, "boom", true);
    try s.endObject();
    try s.endObject();
    try std.testing.expectEqualStrings("{\"result\":{\"isError\":true,\"content\":[{\"type\":\"text\",\"text\":\"boom\"}]}}", buf[0..w.end]);
}

test "hasValidJsonRpc accepts only the JSON-RPC 2.0 version" {
    try std.testing.expect(hasValidJsonRpc("2.0"));
    try std.testing.expect(!hasValidJsonRpc(null));
    try std.testing.expect(!hasValidJsonRpc("1.0"));
    try std.testing.expect(!hasValidJsonRpc("2024-11-05"));
}
