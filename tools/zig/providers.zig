//! providers: check which configured LLM backends actually answer.
//!
//! Input:  {"action": "check", "provider": "<optional name>"}
//!         {"action": "list"}
//! Output: {"ok": true, "providers": [{name, model, status, ms, error}]}
//!
//! The check sends a one-token "ping" through `ck_llm` with an explicit
//! provider, so the harness's own client handles auth and the openai_compat vs
//! anthropic difference. Reimplementing either in the guest would be a second
//! copy of `src/llm/` that could drift.

const std = @import("std");
const lib = @import("lib.zig");
const logic = @import("providers_logic.zig");

const Request = struct {
    action: []const u8 = "check",
    provider: []const u8 = "",
};

export fn run(ptr: u32, len: u32) callconv(.c) u64 {
    return lib.run(ptr, len, tool_main);
}

fn tool_main(input: []const u8, out: *lib.Out) !void {
    const alloc = lib.alloc;
    const req = std.json.parseFromSliceLeaky(Request, alloc, input, .{ .ignore_unknown_fields = true }) catch Request{};

    // The harness already merges config.toml with config.local.toml before
    // handing this back, so there is exactly one source to read here.
    const parsed = std.json.parseFromSliceLeaky(logic.ConfigFile, alloc, lib.harnessConfig(), .{ .ignore_unknown_fields = true }) catch logic.ConfigFile{};
    if (parsed.providers.map.count() == 0) return lib.fail(out, "no providers configured");

    const check = std.mem.eql(u8, req.action, "check");
    if (!check and !std.mem.eql(u8, req.action, "list"))
        return lib.fail(out, "action must be \"check\" or \"list\"");

    if (!check) {
        var w: std.Io.Writer.Allocating = .init(alloc);
        var s = std.json.Stringify{ .writer = &w.writer, .options = .{ .emit_null_optional_fields = false } };
        const matched = try logic.writeList(&s, parsed, req.provider);
        if (req.provider.len > 0 and !matched) return lib.fail(out, "no such provider");
        try out.writeAll(w.written());
        return;
    }

    var buf: [48 * 1024]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    var s = std.json.Stringify{ .writer = &w, .options = .{ .emit_null_optional_fields = false } };

    try s.beginObject();
    try s.objectField("ok");
    try s.write(true);
    try s.objectField("default_provider");
    try s.write(parsed.default_provider);
    try s.objectField("providers");
    try s.beginArray();

    var matched = false;
    var it = parsed.providers.map.iterator();
    while (it.next()) |kv| {
        const name = kv.key_ptr.*;
        if (req.provider.len > 0 and !std.mem.eql(u8, name, req.provider)) continue;
        matched = true;
        const p = kv.value_ptr.*;
        const model = logic.activeModelName(p);

        try s.beginObject();
        try s.objectField("name");
        try s.write(name);
        try s.objectField("model");
        try s.write(model);
        try s.objectField("base_url");
        try s.write(p.base_url);
        try s.objectField("kind");
        try s.write(p.kind);

        const t0 = lib.nowSeconds();
        if (lib.llmWith("ping", name, 1)) |_| {
            const ms: u64 = @trunc(@max(0.0, (lib.nowSeconds() - t0) * 1000.0));
            try s.objectField("status");
            try s.write("ok");
            try s.objectField("ms");
            try s.write(ms);
        } else |err| {
            try s.objectField("status");
            try s.write("failed");
            try s.objectField("error");
            try s.write(switch (err) {
                error.SandboxDenied => "refused by sandbox policy",
                error.NetworkError => "request did not complete",
                error.InvalidArg => "arguments rejected",
                else => "provider did not respond",
            });
        }
        try s.endObject();
    }
    try s.endArray();
    try s.endObject();

    if (req.provider.len > 0 and !matched) return lib.fail(out, "no such provider");
    try out.writeAll(buf[0..w.end]);
}
