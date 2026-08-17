//! thinking: fail-open effort classifier. One prompt, one of four words.
//!
//! Input:  {"text":"...","provider":"<optional>"}
//! Output: {"ok":true,"level":"low|medium|high|xhigh","effort":"low|medium|high"}
//!
//! The native loop still owns provider resolution and the timeout
//! `client.chat` call (credentials). This guest owns the same classify
//! via `ck_llm` so a CLI or hook runs the same fence and four-word dialect.

const std = @import("std");
const lib = @import("lib.zig");
const logic = @import("thinking_logic.zig");

const Request = struct {
    text: []const u8 = "",
    provider: []const u8 = "",
};

export fn run(ptr: u32, len: u32) callconv(.c) u64 {
    return lib.run(ptr, len, tool_main);
}

fn tool_main(input: []const u8, out: *lib.Out) !void {
    const req = std.json.parseFromSliceLeaky(Request, lib.alloc, input, .{ .ignore_unknown_fields = true }) catch Request{};
    const text = std.mem.trim(u8, req.text, " \t\r\n");
    if (text.len == 0) return lib.fail(out, "text is empty");

    const prompt = logic.classifyPrompt(lib.alloc, text) catch return lib.fail(out, "could not build classifier prompt");
    const provider: ?[]const u8 = if (req.provider.len > 0) req.provider else null;
    // 0 keeps the descriptor's grant, which is where this budget is sized
    // (`tools/manifests/thinking.tool.json`). It used to ask for 5 — one word
    // and nothing else — which is a correct content budget and an unusable
    // total: a reasoning model spends the grant on its trace first, so the
    // classifier returned an empty string on every call and `parseLevel` fell
    // through to `medium` for every turn of every run.
    const raw = lib.llmWith(prompt, provider, 0) catch |err| {
        return lib.fail(out, switch (err) {
            error.SandboxDenied => "refused by sandbox policy",
            error.NetworkError => "classifier request did not complete",
            error.InvalidArg => "arguments rejected",
            else => "classifier did not respond",
        });
    };
    const level = logic.parseLevel(raw);

    var buf: [512]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    var s = std.json.Stringify{ .writer = &w, .options = .{ .emit_null_optional_fields = false } };
    try s.beginObject();
    try s.objectField("ok");
    try s.write(true);
    try s.objectField("level");
    try s.write(@tagName(level));
    try s.objectField("effort");
    try s.write(logic.effortFor(level));
    try s.endObject();
    try out.writeAll(buf[0..w.end]);
}
