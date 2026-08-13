//! Pure response parsing for the alphaxiv tool: unwraps the alphaXiv MCP
//! server's Streamable-HTTP replies (plain JSON or SSE-framed) into the
//! JSON-RPC payload, then into the text a model can read. Imports nothing
//! from the guest ABI, so `zig build test` runs these tests on the host
//! (build.zig host_tested_helpers).

const std = @import("std");

/// The JSON-RPC message inside an HTTP response body. A Streamable HTTP
/// server answers a POST either with plain `application/json` or with a
/// one-event `text/event-stream`; in the SSE case the message is the payload
/// of the last `data:` line.
// ponytail: single-line data events only — the spec joins consecutive data
// lines with \n, but MCP servers put the whole JSON-RPC message in one line;
// join them here if one ever does not.
pub fn payload(body: []const u8) []const u8 {
    var last: ?[]const u8 = null;
    var it = std.mem.splitScalar(u8, body, '\n');
    while (it.next()) |line| {
        const l = std.mem.trim(u8, line, " \t\r");
        if (std.mem.startsWith(u8, l, "data:")) last = std.mem.trim(u8, l[5..], " \t");
    }
    return last orelse std.mem.trim(u8, body, " \t\r\n");
}

pub const Extracted = struct {
    ok: bool,
    text: []const u8,
};

/// Reduces a JSON-RPC response to what the caller reports: a protocol
/// `error` or a tool result flagged `isError` become failures with the
/// server's own message; a `result.content` array becomes its text items
/// joined with newlines; any other `result` (tools/list) is returned as its
/// raw JSON. Allocates from `alloc`; caller frees by arena.
pub fn extract(alloc: std.mem.Allocator, json_payload: []const u8) !Extracted {
    const parsed = try std.json.parseFromSliceLeaky(std.json.Value, alloc, json_payload, .{});
    if (parsed != .object) return error.InvalidResponse;
    const obj = parsed.object;

    if (obj.get("error")) |e| {
        const msg = if (e == .object)
            if (e.object.get("message")) |m| (if (m == .string) m.string else "server error") else "server error"
        else
            "server error";
        return .{ .ok = false, .text = msg };
    }

    const result = obj.get("result") orelse return error.InvalidResponse;
    if (result != .object) return .{ .ok = true, .text = try stringify(alloc, result) };

    const is_err = if (result.object.get("isError")) |v| v == .bool and v.bool else false;
    if (result.object.get("content")) |content| {
        if (content == .array) {
            var w: std.Io.Writer.Allocating = .init(alloc);
            for (content.array.items) |item| {
                if (item != .object) continue;
                const t = item.object.get("text") orelse continue;
                if (t != .string) continue;
                if (w.writer.end > 0) try w.writer.writeAll("\n");
                try w.writer.writeAll(t.string);
            }
            return .{ .ok = !is_err, .text = w.written() };
        }
    }
    return .{ .ok = !is_err, .text = try stringify(alloc, result) };
}

fn stringify(alloc: std.mem.Allocator, v: std.json.Value) ![]const u8 {
    var w: std.Io.Writer.Allocating = .init(alloc);
    var s = std.json.Stringify{ .writer = &w.writer, .options = .{} };
    try s.write(v);
    return w.written();
}

test "payload passes plain JSON through" {
    try std.testing.expectEqualStrings("{\"a\":1}", payload("  {\"a\":1}\n"));
}

test "payload takes the last data line of an SSE stream" {
    const body = "event: message\ndata: {\"first\":1}\n\nevent: message\ndata: {\"second\":2}\n\n";
    try std.testing.expectEqualStrings("{\"second\":2}", payload(body));
}

test "extract reports a JSON-RPC error" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const r = try extract(arena.allocator(), "{\"jsonrpc\":\"2.0\",\"id\":1,\"error\":{\"code\":-32600,\"message\":\"bad request\"}}");
    try std.testing.expect(!r.ok);
    try std.testing.expectEqualStrings("bad request", r.text);
}

test "extract joins content text items" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const r = try extract(arena.allocator(), "{\"result\":{\"content\":[{\"type\":\"text\",\"text\":\"one\"},{\"type\":\"text\",\"text\":\"two\"}]}}");
    try std.testing.expect(r.ok);
    try std.testing.expectEqualStrings("one\ntwo", r.text);
}

test "extract flags isError tool results" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const r = try extract(arena.allocator(), "{\"result\":{\"isError\":true,\"content\":[{\"type\":\"text\",\"text\":\"no such paper\"}]}}");
    try std.testing.expect(!r.ok);
    try std.testing.expectEqualStrings("no such paper", r.text);
}

test "extract returns raw JSON for results without content" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const r = try extract(arena.allocator(), "{\"result\":{\"tools\":[{\"name\":\"discover_papers\"}]}}");
    try std.testing.expect(r.ok);
    try std.testing.expect(std.mem.indexOf(u8, r.text, "discover_papers") != null);
}

test "extract rejects a body with neither result nor error" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectError(error.InvalidResponse, extract(arena.allocator(), "{\"jsonrpc\":\"2.0\"}"));
}
