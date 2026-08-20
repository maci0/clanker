//! lsp: answer symbol questions about Zig source through zls.
//!
//! ast-grep has no Zig grammar and semcode indexes only C/C++/Rust, so every
//! question about this project's own source otherwise falls back to ripgrep —
//! and a regex cannot tell a definition from the same word in a comment. zls
//! resolves it against the real semantic model.
//!
//! One zls process per call: the whole LSP conversation (initialize, didOpen,
//! the request, shutdown) is written to its stdin in one go and the answer is
//! read off stdout. That costs a process launch per question and keeps the
//! tool stateless, which is the right trade while questions are occasional.
//!
//! Input:  {"action": "definition", "file": "src/agent/loop.zig", "line": 120, "character": 8}
//!         {"action": "references", ...}  same shape
//!         line and character are 0-based, as LSP counts them.
//! Output: {"ok": true, "action": "definition", "locations": ["src/x.zig:44:12"]}
//!         {"ok": false, "error": "..."}

const std = @import("std");
const lib = @import("lib.zig");

export fn run(ptr: u32, len: u32) callconv(.c) u64 {
    return lib.run(ptr, len, tool_main);
}

fn tool_main(input: []const u8, out: *lib.Out) !void {
    const alloc = lib.alloc;
    const parsed = std.json.parseFromSliceLeaky(std.json.Value, alloc, input, .{}) catch
        return lib.fail(out, "input must be a JSON object");
    if (parsed != .object) return lib.fail(out, "input must be a JSON object");

    const action = str(parsed.object, "action") orelse "definition";
    const method = if (std.mem.eql(u8, action, "definition"))
        "textDocument/definition"
    else if (std.mem.eql(u8, action, "references"))
        "textDocument/references"
    else if (std.mem.eql(u8, action, "diagnose"))
        "textDocument/documentSymbol"
    else
        return lib.fail(out, "action must be \"definition\", \"references\", or \"diagnose\"");

    const file = str(parsed.object, "file") orelse return lib.fail(out, "missing required field: file");
    if (file.len == 0) return lib.fail(out, "file must be a non-empty relative path within the project root");
    if (std.mem.startsWith(u8, file, "/")) return lib.fail(out, "file must be a relative path within the project root");
    if (std.mem.indexOf(u8, file, "..")) |_| return lib.fail(out, "file must not contain '..' components");
    const line = uint(parsed.object, "line") orelse return lib.fail(out, "missing required field: line (0-based)");
    const character = uint(parsed.object, "character") orelse 0;

    // zls answers against the text it is given, not against what is on disk,
    // so the whole file has to come across.
    const source = lib.fsRead(file) catch |err| return lib.fail(out, switch (err) {
        error.SandboxDenied => "file is outside the sandbox",
        error.NotFound => "no such file",
        error.TooLarge => "file is too large to send to zls",
        else => "could not read the file",
    });

    // zls resolves imports and declarations against the real project, so it
    // needs a rootUri and a file URI it can map to disk.
    // zls needs absolute URIs. The harness runs from the project root, so its
    // PWD is that root; there is no separate host call for it.
    const cwd = lib.getenv("PWD") orelse return lib.fail(out, "cannot resolve the project root (PWD unset)");
    const session = buildSession(alloc, cwd, file, source, method, line, character) catch
        return lib.fail(out, "could not build the LSP session");

    const raw = lib.execStdin("zls", &.{}, session) catch |err| return lib.fail(out, switch (err) {
        error.SandboxDenied => "zls is not in this tool's exec allowlist",
        error.NotFound => "zls is not installed or not on PATH",
        else => "zls did not answer",
    });

    const reply = std.json.parseFromSliceLeaky(std.json.Value, alloc, raw, .{ .ignore_unknown_fields = true }) catch
        return lib.fail(out, "could not read the exec result");
    const stdout = if (reply == .object) blk: {
        const v = reply.object.get("stdout") orelse break :blk "";
        break :blk if (v == .string) v.string else "";
    } else "";
    if (stdout.len == 0) return lib.fail(out, "zls produced no output; is it the right version for this Zig?");

    if (std.mem.eql(u8, action, "diagnose")) {
        var symbols: std.ArrayList([]const u8) = .empty;
        defer symbols.deinit(alloc);
        try collectSymbols(alloc, stdout, &symbols);

        var buf: [16384]u8 = undefined;
        var w: std.Io.Writer = .fixed(&buf);
        var s = std.json.Stringify{ .writer = &w, .options = .{} };
        try s.beginObject();
        try s.objectField("ok");
        try s.write(true);
        try s.objectField("action");
        try s.write(action);
        try s.objectField("symbols");
        try s.beginArray();
        for (symbols.items) |sym| try s.write(sym);
        try s.endArray();
        if (symbols.items.len == 0) {
            try s.objectField("note");
            try s.write("zls returned no symbols; the file may be empty or zls could not parse it");
        }
        try s.endObject();
        try out.writeAll(buf[0..w.end]);
        return;
    }

    var locations: std.ArrayList([]const u8) = .empty;
    defer locations.deinit(alloc);
    try collectLocations(alloc, stdout, &locations);

    var buf: [16384]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    var s = std.json.Stringify{ .writer = &w, .options = .{} };
    try s.beginObject();
    try s.objectField("ok");
    try s.write(true);
    try s.objectField("action");
    try s.write(action);
    try s.objectField("locations");
    try s.beginArray();
    for (locations.items) |l| try s.write(l);
    try s.endArray();
    if (locations.items.len == 0) {
        // An empty result is an answer ("nothing resolves here"), not a
        // failure, but saying so beats returning a bare empty list.
        try s.objectField("note");
        try s.write("zls resolved nothing at that position; check that line/character are 0-based and point at the symbol");
    }
    try s.endObject();
    try out.writeAll(buf[0..w.end]);
}

/// The whole conversation as one stdin blob. zls reads framed messages in
/// order, so batching them costs nothing and keeps this tool stateless.
fn buildSession(
    alloc: std.mem.Allocator,
    cwd: []const u8,
    file: []const u8,
    source: []const u8,
    method: []const u8,
    line: usize,
    character: usize,
) ![]const u8 {
    var body: std.ArrayList(u8) = .empty;
    defer body.deinit(alloc);
    var msg: std.ArrayList(u8) = .empty;
    defer msg.deinit(alloc);

    const root_uri = try std.fmt.allocPrint(alloc, "file://{s}", .{cwd});
    const file_uri = try std.fmt.allocPrint(alloc, "file://{s}/{s}", .{ cwd, file });

    msg.clearRetainingCapacity();
    try writeJson(alloc, &msg,
        \\{{"jsonrpc":"2.0","id":1,"method":"initialize","params":{{"processId":null,"rootUri":{f},"capabilities":{{}}}}}}
    , .{std.json.fmt(root_uri, .{})});
    try frame(alloc, &body, msg.items);

    msg.clearRetainingCapacity();
    try msg.appendSlice(alloc,
        \\{"jsonrpc":"2.0","method":"initialized","params":{}}
    );
    try frame(alloc, &body, msg.items);

    // didOpen with the file's actual text: zls answers against what it was
    // given, not against what is on disk.
    msg.clearRetainingCapacity();
    try writeJson(alloc, &msg,
        \\{{"jsonrpc":"2.0","method":"textDocument/didOpen","params":{{"textDocument":{{"uri":{f},"languageId":"zig","version":1,"text":{f}}}}}}}
    , .{ std.json.fmt(file_uri, .{}), std.json.fmt(source, .{}) });
    try frame(alloc, &body, msg.items);

    msg.clearRetainingCapacity();
    try writeJson(alloc, &msg,
        \\{{"jsonrpc":"2.0","id":2,"method":{f},"params":{{"textDocument":{{"uri":{f}}},"position":{{"line":{d},"character":{d}}},"context":{{"includeDeclaration":true}}}}}}
    , .{ std.json.fmt(method, .{}), std.json.fmt(file_uri, .{}), line, character });
    try frame(alloc, &body, msg.items);

    // shutdown + exit, so zls closes stdout instead of waiting forever.
    msg.clearRetainingCapacity();
    try msg.appendSlice(alloc,
        \\{"jsonrpc":"2.0","id":3,"method":"shutdown","params":null}
    );
    try frame(alloc, &body, msg.items);
    msg.clearRetainingCapacity();
    try msg.appendSlice(alloc,
        \\{"jsonrpc":"2.0","method":"exit","params":null}
    );
    try frame(alloc, &body, msg.items);

    return body.toOwnedSlice(alloc);
}

fn writeJson(alloc: std.mem.Allocator, buf: *std.ArrayList(u8), comptime fmt: []const u8, args: anytype) !void {
    const text = try std.fmt.allocPrint(alloc, fmt, args);
    defer alloc.free(text);
    try buf.appendSlice(alloc, text);
}

/// LSP framing: every message carries its byte length.
fn frame(alloc: std.mem.Allocator, body: *std.ArrayList(u8), payload: []const u8) !void {
    const header = try std.fmt.allocPrint(alloc, "Content-Length: {d}\r\n\r\n", .{payload.len});
    defer alloc.free(header);
    try body.appendSlice(alloc, header);
    try body.appendSlice(alloc, payload);
}

/// Pulls every {"uri": ..., "range": {"start": {"line": L, "character": C}}}
/// out of zls's replies and renders it as path:line:character (1-based, the
/// way an editor and every other tool here report positions).
fn collectLocations(alloc: std.mem.Allocator, stdout: []const u8, out: *std.ArrayList([]const u8)) !void {
    var rest = stdout;
    while (std.mem.find(u8, rest, "\"file://")) |at| {
        rest = rest[at + "\"file://".len ..];
        const uri_end = std.mem.findScalar(u8, rest, '"') orelse break;
        const path = rest[0..uri_end];
        // Advance past this URI so a malformed entry cannot poison later ones.
        rest = rest[uri_end + 1 ..];

        const line_key = "\"line\":";
        const line_at = std.mem.find(u8, rest, line_key) orelse continue;
        const line = parseUint(rest[line_at + line_key.len ..]);
        const char_key = "\"character\":";
        const char_at = std.mem.find(u8, rest, char_key) orelse continue;
        const character = parseUint(rest[char_at + char_key.len ..]);

        const entry = try std.fmt.allocPrint(alloc, "{s}:{d}:{d}", .{ path, line + 1, character + 1 });
        try out.append(alloc, entry);
        if (out.items.len >= 50) break;
    }
}

/// Extracts symbol names and their start lines from a documentSymbol response.
fn collectSymbols(alloc: std.mem.Allocator, stdout: []const u8, out: *std.ArrayList([]const u8)) !void {
    var rest = stdout;
    while (std.mem.find(u8, rest, "\"name\":\"")) |at| {
        rest = rest[at + "\"name\":\"".len ..];
        const name_end = std.mem.findScalar(u8, rest, '"') orelse break;
        const name = rest[0..name_end];

        const line_key = "\"line\":";
        const line_at = std.mem.find(u8, rest, line_key) orelse break;
        const start_line = parseUint(rest[line_at + line_key.len ..]);

        const entry = try std.fmt.allocPrint(alloc, "{s}:{d}", .{ name, start_line + 1 });
        try out.append(alloc, entry);
        if (out.items.len >= 50) break;
    }
}

fn parseUint(s: []const u8) usize {
    var n: usize = 0;
    for (s) |c| {
        if (c < '0' or c > '9') break;
        n = n *| 10 +| (c - '0');
    }
    return n;
}

const str = lib.strFieldRequired;

fn uint(obj: std.json.ObjectMap, key: []const u8) ?usize {
    const v = obj.get(key) orelse return null;
    return switch (v) {
        .integer => |i| if (i < 0) null else @intCast(i),
        else => null,
    };
}
