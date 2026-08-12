//! MCP (Model Context Protocol) stdio JSON-RPC 2.0 server: exposes clanker's
//! WASM tools to external MCP clients (Claude, Cursor, IDE agents, ...).
//! Each line on stdin is one JSON-RPC request; each response is one line.

const std = @import("std");
const json = std.json;
const config = @import("../config.zig");
const registry = @import("../tools/registry.zig");
const runtime = @import("../sandbox/runtime.zig");
const client = @import("../llm/client.zig");
const types = @import("../llm/types.zig");
const log = @import("../util/log.zig");
const toolout = @import("../util/toolout.zig");

const protocol_version = "2024-11-05";
const max_line = 1 << 20;

/// Compiled tool modules, keyed by tool name and kept for the life of the
/// stdio session. Without this, every `tools/call` re-read the .wasm file and
/// re-parsed/re-linked/re-instantiated it from scratch — the agent loop
/// avoids exactly this cost with its own `wasm_cache`/`self.modules`, and an
/// MCP client issuing many calls in a session deserves the same reuse.
const ModuleCache = std.StringHashMapUnmanaged(*runtime.ToolModule);

fn deinitModuleCache(gpa: std.mem.Allocator, cache: *ModuleCache) void {
    var it = cache.valueIterator();
    while (it.next()) |m| m.*.deinit();
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
    var module_cache: ModuleCache = .empty;
    defer deinitModuleCache(gpa, &module_cache);
    var cache_arena_state = std.heap.ArenaAllocator.init(gpa);
    defer cache_arena_state.deinit();
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
        handleLine(io, gpa, cache_arena, cfg, environ_map, &reg, tool_defs, &module_cache, &llm_ctx, line) catch |err| {
            log.log(.error_, "mcp line error: {s}", .{@errorName(err)});
        };
    }
}

const Request = struct {
    id: ?json.Value = null,
    method: ?[]const u8 = null,
    params: ?json.Value = null,
};

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
    // A client that sends one request and blocks on the reply (every
    // interactive MCP client) must get a response even to garbage input, or
    // it hangs forever: JSON-RPC 2.0 requires an id-less error response when
    // the id itself could not be parsed, rather than silence.
    const req = json.parseFromSliceLeaky(Request, gpa, line, .{ .ignore_unknown_fields = true }) catch {
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
    if (req.method) |m| {
        // Notifications (initialized, cancelled, ...) never get a response.
        if (std.mem.startsWith(u8, m, "notifications/")) return;
    }

    var out_buf: [1 << 20]u8 = undefined;
    var w: std.Io.Writer = .fixed(&out_buf);
    var s = json.Stringify{ .writer = &w, .options = .{ .emit_null_optional_fields = false } };
    try s.beginObject();
    try s.objectField("jsonrpc");
    try s.write("2.0");
    try s.objectField("id");
    try s.write(req.id orelse .null);
    try s.objectField("result");
    try s.beginObject();

    if (req.method) |m| {
        if (std.mem.eql(u8, m, "initialize")) {
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
            try s.write("0.1.0");
            try s.endObject();
        } else if (std.mem.eql(u8, m, "ping")) {
            // empty result object
        } else if (std.mem.eql(u8, m, "tools/list")) {
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
        } else if (std.mem.eql(u8, m, "tools/call")) {
            try handleToolCall(&s, io, gpa, cache_arena, cfg, environ_map, reg, module_cache, llm_ctx, req.params);
        } else {
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
fn getOrLoadModule(gpa: std.mem.Allocator, io: std.Io, cache_arena: std.mem.Allocator, environ_map: *std.process.Environ.Map, cfg: *const config.Config, reg: *const registry.Registry, module_cache: *ModuleCache, llm_ctx: *client.Ctx, name: []const u8) !*runtime.ToolModule {
    if (module_cache.get(name)) |m| return m;
    const mod = try runtime.loadNamedTool(gpa, io, cache_arena, environ_map, cfg, reg, name, llm_ctx);
    errdefer mod.deinit();
    const key = try cache_arena.dupe(u8, name);
    try module_cache.put(gpa, key, mod);
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
    toolout.warnIfMalformed(gpa, name, out);
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
