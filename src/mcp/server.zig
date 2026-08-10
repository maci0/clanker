//! MCP (Model Context Protocol) stdio JSON-RPC 2.0 server: exposes clanker's
//! WASM tools to external MCP clients (Claude, Cursor, IDE agents, ...).
//! Each line on stdin is one JSON-RPC request; each response is one line.

const std = @import("std");
const json = std.json;
const config = @import("../config.zig");
const registry = @import("../tools/registry.zig");
const runtime = @import("../sandbox/runtime.zig");
const host = @import("../sandbox/host.zig");
const types = @import("../llm/types.zig");
const log = @import("../util/log.zig");

const protocol_version = "2024-11-05";
const max_line = 1 << 20;

pub fn serve(io: std.Io, gpa: std.mem.Allocator, arena: std.mem.Allocator, cfg: *const config.Config) !void {
    const reg = try registry.Registry.load(io, arena, std.Io.Dir.cwd(), cfg.agent.tools_dir);
    const tool_defs = try reg.toToolDefs(arena);

    var stdin_file = std.Io.File.stdin();
    var read_buf: [65536]u8 = undefined;
    var reader = stdin_file.reader(io, &read_buf);

    var acc: std.ArrayList(u8) = .empty;
    defer acc.deinit(gpa);
    var tmp: [8192]u8 = undefined;

    while (true) {
        const n = reader.interface.readSliceShort(&tmp) catch |e| {
            log.log(.error_, "mcp stdin read error: {s}", .{@errorName(e)});
            break;
        };
        log.log(.debug, "mcp read {d} bytes", .{n});
        if (n == 0) break; // stdin EOF
        acc.appendSlice(gpa, tmp[0..n]) catch break;
        if (acc.items.len > max_line) {
            acc.clearRetainingCapacity();
            continue;
        }
        while (std.mem.indexOfScalar(u8, acc.items, '\n')) |nl| {
            const line = std.mem.trim(u8, acc.items[0..nl], " \t\r");
            const rest = acc.items[nl + 1 ..];
            std.mem.copyForwards(u8, acc.items[0..rest.len], rest);
            acc.items.len = rest.len;
            if (line.len > 0) {
                log.log(.debug, "mcp handling line: {s}", .{line});
                handleLine(io, gpa, &reg, tool_defs, line) catch |err| {
                    log.log(.error_, "mcp line error: {s}", .{@errorName(err)});
                };
            }
        }
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

fn handleLine(io: std.Io, gpa: std.mem.Allocator, reg: *const registry.Registry, tool_defs: []const types.ToolDef, line: []const u8) !void {
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
            try handleToolCall(&s, io, gpa, reg, req.params);
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

fn writeResponse(io: std.Io, bytes: []const u8) void {
    var stdout_file = std.Io.File.stdout();
    var wbuf: [65536]u8 = undefined;
    var out_w = stdout_file.writer(io, &wbuf);
    out_w.interface.writeAll(bytes) catch {};
    out_w.interface.writeAll("\n") catch {};
    out_w.interface.flush() catch {};
}

fn handleToolCall(s: *json.Stringify, io: std.Io, gpa: std.mem.Allocator, reg: *const registry.Registry, params: ?json.Value) !void {
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

    const tool = reg.get(name);
    if (tool == null) {
        try respondText(s, "unknown tool", true);
        return;
    }

    const wasm_path = std.fmt.allocPrint(gpa, "{s}", .{tool.?.wasm}) catch {
        try respondText(s, "OOM", true);
        return;
    };
    defer gpa.free(wasm_path);
    const wasm_bytes = std.Io.Dir.cwd().readFileAlloc(io, wasm_path, gpa, .limited(1 << 20)) catch {
        try respondText(s, "wasm missing (run zig build tools)", true);
        return;
    };
    defer gpa.free(wasm_bytes);

    var env_map = std.process.Environ.Map.init(gpa);
    defer env_map.deinit();
    var sb = host.Sandbox{
        .gpa = gpa,
        .io = io,
        .root_dir = ".",
        .network_allow = tool.?.network_allow,
        .fs_prefixes = tool.?.fs_prefixes,
        .environ_map = &env_map,
    };

    var mod = runtime.ToolModule.load(gpa, io, &sb, wasm_bytes) catch {
        try respondText(s, "tool load failed", true);
        return;
    };
    defer mod.deinit();

    const out = mod.executeTool(arg_text) catch |err| {
        try respondText(s, @errorName(err), true);
        return;
    };
    defer gpa.free(out);
    try respondText(s, out, false);
}
