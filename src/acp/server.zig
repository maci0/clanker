//! ACP v1 stdio transport. One JSON-RPC 2.0 message per line, matching the
//! official stdio SDKs and clanker's MCP server framing.

const std = @import("std");
const json = std.json;
const build_options = @import("build_options");
const log = @import("../util/log.zig");

pub const protocol_version: u32 = 1;
const max_line = 1 << 20;

const Request = struct {
    jsonrpc: ?[]const u8 = null,
    id: ?json.Value = null,
    method: ?[]const u8 = null,
    params: ?json.Value = null,
};

pub const Connection = struct {
    initialized: bool = false,
    session_counter: u64 = 0,
    sessions: std.StringArrayHashMapUnmanaged(void) = .empty,
    prompt_busy: std.StringArrayHashMapUnmanaged(bool) = .empty,

    pub fn deinit(self: *Connection, gpa: std.mem.Allocator) void {
        var it = self.sessions.iterator();
        while (it.next()) |kv| gpa.free(kv.key_ptr.*);
        self.sessions.deinit(gpa);
        self.prompt_busy.deinit(gpa);
    }

    pub fn handleLine(self: *Connection, alloc: std.mem.Allocator, line: []const u8) ![]u8 {
        var parse_arena = std.heap.ArenaAllocator.init(alloc);
        defer parse_arena.deinit();
        const arena = parse_arena.allocator();
        const req = json.parseFromSliceLeaky(Request, arena, line, .{ .ignore_unknown_fields = true }) catch
            return responseError(alloc, .null, -32700, "Parse error");

        if (req.jsonrpc == null or !std.mem.eql(u8, req.jsonrpc.?, "2.0") or req.method == null) {
            return responseError(alloc, req.id orelse .null, -32600, "Invalid Request");
        }

        // Notifications intentionally have no response. Cancellation becomes
        // stateful when sessions are wired; accepting an unknown id is a no-op
        // per ACP v1.
        if (req.id == null) {
            if (std.mem.eql(u8, req.method.?, "session/cancel")) {
                if (req.params) |p| if (p == .object) if (p.object.get("sessionId")) |sid| if (sid == .string) {
                    if (self.prompt_busy.getPtr(sid.string)) |busy| busy.* = false;
                };
                return alloc.dupe(u8, "");
            }
            return alloc.dupe(u8, "");
        }

        if (std.mem.eql(u8, req.method.?, "initialize")) {
            const requested = protocolVersion(req.params) orelse
                return responseError(alloc, req.id.?, -32602, "initialize requires integer protocolVersion");
            self.initialized = true;
            return initializeResponse(alloc, req.id.?, requested);
        }
        if (!self.initialized) {
            return responseError(alloc, req.id.?, -32002, "initialize must be the first request");
        }
        if (std.mem.eql(u8, req.method.?, "authenticate")) {
            // No methods are advertised. Some clients still probe this method;
            // an empty success is harmless and matches ACP's response shape.
            return responseObject(alloc, req.id.?, "{}");
        }
        if (std.mem.eql(u8, req.method.?, "session/new")) {
            return handleSessionNew(self, alloc, arena, req.id.?, req.params);
        }
        if (std.mem.eql(u8, req.method.?, "session/prompt")) {
            return handleSessionPrompt(self, alloc, arena, req.id.?, req.params);
        }
        if (std.mem.eql(u8, req.method.?, "session/cancel")) {
            if (req.params) |p| if (p == .object) if (p.object.get("sessionId")) |sid| if (sid == .string) {
                if (self.prompt_busy.getPtr(sid.string)) |busy| busy.* = false;
            };
            return responseObject(alloc, req.id.?, "{\"stopReason\":\"cancelled\"}");
        }
        return responseError(alloc, req.id.?, -32601, "Method not found");
    }
};

fn handleSessionNew(conn: *Connection, alloc: std.mem.Allocator, arena: std.mem.Allocator, id: json.Value, params: ?json.Value) ![]u8 {
    const p = params orelse return responseError(alloc, id, -32602, "session/new requires params");
    const obj = switch (p) {
        .object => |o| o,
        else => return responseError(alloc, id, -32602, "session/new requires params"),
    };
    const cwd_val = obj.get("cwd") orelse return responseError(alloc, id, -32602, "session/new requires string cwd");
    const cwd = switch (cwd_val) {
        .string => |s| s,
        else => return responseError(alloc, id, -32602, "session/new requires string cwd"),
    };
    if (cwd.len == 0 or cwd[0] != '/') {
        return responseError(alloc, id, -32602, "cwd must be an absolute path");
    }
    if (std.mem.findScalar(u8, cwd, 0) != null) {
        return responseError(alloc, id, -32602, "cwd does not exist");
    }
    conn.session_counter += 1;
    const sid = try std.fmt.allocPrint(arena, "acp-{d}", .{conn.session_counter});
    const owned = try alloc.dupe(u8, sid);
    try conn.sessions.put(alloc, owned, {});
    try conn.prompt_busy.put(alloc, owned, false);
    var out: std.Io.Writer.Allocating = .init(alloc);
    errdefer out.deinit();
    var s = json.Stringify{ .writer = &out.writer, .options = .{} };
    try responseStart(&s, id);
    try s.objectField("result");
    try s.beginObject();
    try s.objectField("sessionId");
    try s.write(sid);
    try s.endObject();
    try s.endObject();
    return out.toOwnedSlice();
}

fn handleSessionPrompt(conn: *Connection, alloc: std.mem.Allocator, arena: std.mem.Allocator, id: json.Value, params: ?json.Value) ![]u8 {
    const p = params orelse return responseError(alloc, id, -32602, "session/prompt requires params");
    const obj = switch (p) {
        .object => |o| o,
        else => return responseError(alloc, id, -32602, "session/prompt requires params"),
    };
    const sid_val = obj.get("sessionId") orelse return responseError(alloc, id, -32602, "session/prompt requires sessionId");
    const sid = switch (sid_val) {
        .string => |s| s,
        else => return responseError(alloc, id, -32602, "session/prompt requires sessionId"),
    };
    if (conn.sessions.get(sid) == null) {
        return responseError(alloc, id, -32602, "unknown sessionId");
    }
    const busy = conn.prompt_busy.getPtr(sid) orelse return responseError(alloc, id, -32602, "unknown sessionId");
    if (busy.*) {
        return responseError(alloc, id, -32603, "session already has an in-flight prompt");
    }
    const prompt_val = obj.get("prompt") orelse return responseError(alloc, id, -32602, "session/prompt requires prompt");
    const prompt_text: []const u8 = switch (prompt_val) {
        .string => |s| s,
        .array => |arr| blk: {
            var buf: std.ArrayList(u8) = .empty;
            for (arr.items) |item| {
                if (item == .object) if (item.object.get("text")) |t| if (t == .string) {
                    if (buf.items.len > 0) try buf.append(arena, '\n');
                    try buf.appendSlice(arena, t.string);
                };
            }
            break :blk buf.items;
        },
        else => return responseError(alloc, id, -32602, "session/prompt requires prompt"),
    };
    _ = prompt_text;
    // v1 stub: report end_turn without running the model; real Agent wiring lands next
    // turn once sessions own an Agent + cwd. This already satisfies the ACP shape
    // (sessionId must exist, no concurrent prompt) and is testable without a provider.
    busy.* = true;
    defer busy.* = false;
    var out: std.Io.Writer.Allocating = .init(alloc);
    errdefer out.deinit();
    var s = json.Stringify{ .writer = &out.writer, .options = .{} };
    try responseStart(&s, id);
    try s.objectField("result");
    try s.beginObject();
    try s.objectField("stopReason");
    try s.write("end_turn");
    try s.endObject();
    try s.endObject();
    return out.toOwnedSlice();
}

fn protocolVersion(params: ?json.Value) ?u32 {
    const p = params orelse return null;
    const obj = switch (p) {
        .object => |o| o,
        else => return null,
    };
    const v = obj.get("protocolVersion") orelse return null;
    return switch (v) {
        .integer => |n| if (n >= 0 and n <= std.math.maxInt(u32)) @intCast(n) else null,
        else => null,
    };
}

fn initializeResponse(alloc: std.mem.Allocator, id: json.Value, requested: u32) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(alloc);
    errdefer out.deinit();
    var s = json.Stringify{ .writer = &out.writer, .options = .{ .emit_null_optional_fields = false } };
    try responseStart(&s, id);
    try s.objectField("result");
    try s.beginObject();
    try s.objectField("protocolVersion");
    try s.write(if (requested == protocol_version) requested else protocol_version);
    try s.objectField("agentCapabilities");
    try s.beginObject();
    try s.objectField("loadSession");
    try s.write(false);
    try s.objectField("promptCapabilities");
    try s.write(.{ .image = false, .audio = false, .embeddedContext = false });
    try s.objectField("mcpCapabilities");
    try s.write(.{ .http = false, .sse = false });
    try s.objectField("sessionCapabilities");
    try s.beginObject();
    try s.endObject();
    try s.objectField("auth");
    try s.beginObject();
    try s.endObject();
    try s.endObject();
    try s.objectField("authMethods");
    try s.beginArray();
    try s.endArray();
    try s.objectField("agentInfo");
    try s.write(.{ .name = "clanker", .version = build_options.version });
    try s.endObject();
    try s.endObject();
    return out.toOwnedSlice();
}

fn responseObject(alloc: std.mem.Allocator, id: json.Value, comptime object: []const u8) ![]u8 {
    var id_buf: [256]u8 = undefined;
    var id_w: std.Io.Writer = .fixed(&id_buf);
    try json.Stringify.value(id, .{}, &id_w);
    return std.fmt.allocPrint(alloc, "{{\"jsonrpc\":\"2.0\",\"id\":{s},\"result\":{s}}}", .{ id_buf[0..id_w.end], object });
}

fn responseError(alloc: std.mem.Allocator, id: json.Value, code: i64, message: []const u8) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(alloc);
    errdefer out.deinit();
    var s = json.Stringify{ .writer = &out.writer, .options = .{} };
    try responseStart(&s, id);
    try s.objectField("error");
    try s.beginObject();
    try s.objectField("code");
    try s.write(code);
    try s.objectField("message");
    try s.write(message);
    try s.endObject();
    try s.endObject();
    return out.toOwnedSlice();
}

fn responseStart(s: *json.Stringify, id: json.Value) !void {
    try s.beginObject();
    try s.objectField("jsonrpc");
    try s.write("2.0");
    try s.objectField("id");
    try s.write(id);
}

pub fn serve(io: std.Io, gpa: std.mem.Allocator) !void {
    log.log(.info, "acp: serving protocol v{d} over stdio; waiting for a client on stdin", .{protocol_version});
    const read_buf = try gpa.alloc(u8, max_line);
    defer gpa.free(read_buf);
    var stdin_file = std.Io.File.stdin();
    var reader = stdin_file.reader(io, read_buf);
    var conn = Connection{};
    while (true) {
        const raw = reader.interface.takeDelimiter('\n') catch |err| switch (err) {
            error.StreamTooLong => {
                reader.interface.toss(reader.interface.buffered().len);
                continue;
            },
            error.ReadFailed => return err,
        } orelse break;
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0) continue;
        const response = try conn.handleLine(gpa, line);
        defer gpa.free(response);
        if (response.len == 0) continue;
        var stdout_file = std.Io.File.stdout();
        var out_buf: [64 * 1024]u8 = undefined;
        var writer = stdout_file.writerStreaming(io, &out_buf);
        try writer.interface.writeAll(response);
        try writer.interface.writeByte('\n');
        try writer.interface.flush();
    }
}

test "ACP initialize is schema-shaped and negotiates stable v1" {
    var conn = Connection{};
    const out = try conn.handleLine(std.testing.allocator,
        \\{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":99,"clientCapabilities":{}}}
    );
    defer std.testing.allocator.free(out);
    try std.testing.expect(std.mem.find(u8, out, "\"protocolVersion\":1") != null);
    try std.testing.expect(std.mem.find(u8, out, "\"promptCapabilities\"") != null);
    try std.testing.expect(std.mem.find(u8, out, "\"authMethods\":[]") != null);
}

test "ACP framing returns standard errors and keeps notifications silent" {
    var conn = Connection{};
    defer conn.deinit(std.testing.allocator);
    const parse = try conn.handleLine(std.testing.allocator, "{");
    defer std.testing.allocator.free(parse);
    try std.testing.expect(std.mem.find(u8, parse, "\"code\":-32700") != null);

    const early = try conn.handleLine(std.testing.allocator,
        \\{"jsonrpc":"2.0","id":"x","method":"session/new","params":{}}
    );
    defer std.testing.allocator.free(early);
    try std.testing.expect(std.mem.find(u8, early, "\"code\":-32002") != null);

    const cancel = try conn.handleLine(std.testing.allocator,
        \\{"jsonrpc":"2.0","method":"session/cancel","params":{"sessionId":"missing"}}
    );
    defer std.testing.allocator.free(cancel);
    try std.testing.expectEqual(@as(usize, 0), cancel.len);
}

test "ACP session/new validates cwd and mints a sessionId" {
    var conn = Connection{};
    defer conn.deinit(std.testing.allocator);
    // Must initialize first
    {
        const init = try conn.handleLine(std.testing.allocator,
            \\{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":1}}
        );
        defer std.testing.allocator.free(init);
    }
    const rel = try conn.handleLine(std.testing.allocator,
        \\{"jsonrpc":"2.0","id":2,"method":"session/new","params":{"cwd":"relative/path"}}
    );
    defer std.testing.allocator.free(rel);
    try std.testing.expect(std.mem.find(u8, rel, "\"code\":-32602") != null);

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const abs = "/tmp";
    const params = try std.fmt.allocPrint(std.testing.allocator, "{{\"jsonrpc\":\"2.0\",\"id\":3,\"method\":\"session/new\",\"params\":{{\"cwd\":{f}}}}}", .{std.json.fmt(abs, .{})});
    defer std.testing.allocator.free(params);
    const ok = try conn.handleLine(std.testing.allocator, params);
    defer std.testing.allocator.free(ok);
    try std.testing.expect(std.mem.find(u8, ok, "\"sessionId\":\"acp-1\"") != null);

    const prompt = try std.fmt.allocPrint(std.testing.allocator, "{{\"jsonrpc\":\"2.0\",\"id\":4,\"method\":\"session/prompt\",\"params\":{{\"sessionId\":\"acp-1\",\"prompt\":\"hello\"}}}}", .{});
    defer std.testing.allocator.free(prompt);
    const pres = try conn.handleLine(std.testing.allocator, prompt);
    defer std.testing.allocator.free(pres);
    try std.testing.expect(std.mem.find(u8, pres, "\"stopReason\":\"end_turn\"") != null);

    const bad = try conn.handleLine(std.testing.allocator,
        \\{"jsonrpc":"2.0","id":5,"method":"session/prompt","params":{"sessionId":"nope","prompt":"hi"}}
    );
    defer std.testing.allocator.free(bad);
    try std.testing.expect(std.mem.find(u8, bad, "\"code\":-32602") != null);
}
