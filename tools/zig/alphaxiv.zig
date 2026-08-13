//! alphaxiv: query the alphaXiv research API (paper search, paper content,
//! PDF Q&A, paper codebases) through its MCP endpoint.
//! Input:  {"tool": "discover_papers", "args": {"query": "..."}, "max_chars": 16000}
//!         {"tool": "list"} enumerates the server's tools and their schemas.
//! Output: {"ok": true, "text": "..."}
//!
//! Auth is an API key in the ALPHAXIV_API_KEY environment variable
//! (alphaxiv.org, Settings > API Keys). One stateless JSON-RPC POST per call;
//! no MCP initialize handshake, because ck_http exposes neither response
//! headers nor a session to carry across calls — if the server ever starts
//! requiring one, its own error message is returned verbatim.

const std = @import("std");
const lib = @import("lib.zig");
const mcp = @import("alphaxiv_mcp.zig");

const endpoint = "https://api.alphaxiv.org/mcp/v1";
const default_max_chars: usize = 16000;

export fn run(ptr: u32, len: u32) callconv(.c) u64 {
    return lib.run(ptr, len, tool_main);
}

fn tool_main(input: []const u8, out: *lib.Out) !void {
    const obj = try lib.object(input);
    const tool = lib.str(obj, "tool") catch return lib.fail(out, "missing tool — a server tool name, or \"list\" to enumerate them");
    var max_chars = default_max_chars;
    if (lib.optNum(obj, "max_chars")) |m| {
        if (m >= 1) max_chars = @trunc(m);
    }

    const key = lib.getenv("ALPHAXIV_API_KEY") orelse
        return lib.fail(out, "ALPHAXIV_API_KEY is not set — create an API key at alphaxiv.org under Settings > API Keys");

    // JSON-RPC request: tools/list for discovery, tools/call for everything else.
    var req: std.Io.Writer.Allocating = .init(lib.alloc);
    var s = std.json.Stringify{ .writer = &req.writer, .options = .{} };
    try s.beginObject();
    try s.objectField("jsonrpc");
    try s.write("2.0");
    try s.objectField("id");
    try s.write(1);
    try s.objectField("method");
    if (std.mem.eql(u8, tool, "list")) {
        try s.write("tools/list");
    } else {
        try s.write("tools/call");
        try s.objectField("params");
        try s.beginObject();
        try s.objectField("name");
        try s.write(tool);
        try s.objectField("arguments");
        if (obj.object.get("args")) |args| {
            try s.write(args);
        } else {
            try s.beginObject();
            try s.endObject();
        }
        try s.endObject();
    }
    try s.endObject();

    const headers = try std.fmt.allocPrint(lib.alloc,
        \\{{"Authorization":"Bearer {s}","Content-Type":"application/json","Accept":"application/json, text/event-stream"}}
    , .{key});

    const body = lib.httpPostHdr(endpoint, req.written(), headers) catch |err|
        return lib.failErr(out, err, "querying alphaXiv (an auth failure also lands here — check ALPHAXIV_API_KEY)");

    const extracted = mcp.extract(lib.alloc, mcp.payload(body)) catch
        return lib.fail(out, "alphaXiv returned a response that is not a JSON-RPC message");
    if (!extracted.ok) return lib.fail(out, extracted.text);

    const text = if (extracted.text.len > max_chars) extracted.text[0..max_chars] else extracted.text;
    return lib.okText(out, text);
}
