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

pub fn serve(io: std.Io, gpa: std.mem.Allocator, arena: std.mem.Allocator, cfg: *const config.Config, environ_map: *std.process.Environ.Map) !void {
    const reg = try registry.Registry.load(io, arena, std.Io.Dir.cwd(), cfg.agent.tools_dir);
    const tool_defs = try reg.toToolDefs(arena);

    // One line in, one line out, and the read must return as soon as a line
    // arrives. readSliceShort here was a deadlock: it blocks until it fills its
    // buffer or sees EOF, so a client that writes one request and waits for the
    // response (which is every interactive MCP client) hung forever, and the
    // server only worked when fed a large batch or a closed pipe.
    const read_buf = try gpa.alloc(u8, max_line);
    defer gpa.free(read_buf);
    var stdin_file = std.Io.File.stdin();
    var reader = stdin_file.reader(io, read_buf);

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
        log.log(.debug, "mcp handling line: {s}", .{line});
        handleLine(io, gpa, cfg, environ_map, &reg, tool_defs, line) catch |err| {
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

fn handleLine(io: std.Io, gpa: std.mem.Allocator, cfg: *const config.Config, environ_map: *std.process.Environ.Map, reg: *const registry.Registry, tool_defs: []const types.ToolDef, line: []const u8) !void {
    const req = try json.parseFromSliceLeaky(Request, gpa, line, .{ .ignore_unknown_fields = true });
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
            try handleToolCall(&s, io, gpa, cfg, environ_map, reg, req.params);
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

fn handleToolCall(s: *json.Stringify, io: std.Io, gpa: std.mem.Allocator, cfg: *const config.Config, environ_map: *std.process.Environ.Map, reg: *const registry.Registry, params: ?json.Value) !void {
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var name: []const u8 = "";
    var arg_text: []const u8 = "{}";
    var arg_buf: [256 * 1024]u8 = undefined;
    if (params) |p| {
        switch (p) {
            .object => |o| {
                if (o.get("name")) |n| switch (n) {
                    .string => |str| name = str,
                    else => {},
                };
                if (o.get("arguments")) |args| {
                    var w: std.Io.Writer = .fixed(&arg_buf);
                    json.Stringify.value(args, .{}, &w) catch {};
                    arg_text = arg_buf[0..w.end];
                }
            },
            else => {},
        }
    }

    // The real process environment, including anything dotenv loaded: an empty
    // map here means every API key lookup inside a tool silently comes back
    // missing, and the tool reports a misleading "not configured".
    var ctx = client.Ctx{ .io = io, .gpa = gpa, .environ_map = environ_map, .cfg = cfg };
    const mod = runtime.loadNamedTool(gpa, io, arena, environ_map, cfg, reg, name, &ctx) catch |err| {
        const msg: []const u8 = switch (err) {
            error.UnknownTool => "unknown tool",
            error.FileNotFound => "wasm missing (run zig build tools)",
            else => "tool load failed",
        };
        try respondText(s, msg, true);
        return;
    };
    defer mod.deinit();

    const out = mod.executeTool(arg_text) catch |err| {
        try respondText(s, @errorName(err), true);
        return;
    };
    defer gpa.free(out);
    // The agent warns about malformed tool output on its own paths; a tool
    // driven over MCP reaches the caller without passing through any of them,
    // and this is the surface tools are usually probed from.
    toolout.warnIfMalformedAlloc(gpa, name, out);
    try respondText(s, out, false);
}
