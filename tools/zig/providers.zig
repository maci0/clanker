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

const Model = struct {
    context_window: u32 = 0,
    max_tokens: u32 = 0,
};

const Provider = struct {
    kind: []const u8 = "openai_compat",
    base_url: []const u8 = "",
    api_key_env: ?[]const u8 = null,
    default_model: []const u8 = "",
    models: std.json.ArrayHashMap(Model) = .{},
};

const ConfigFile = struct {
    default_provider: []const u8 = "",
    providers: std.json.ArrayHashMap(Provider) = .{},
};

const Request = struct {
    action: []const u8 = "check",
    provider: []const u8 = "",
};

export fn run(ptr: u32, len: u32) callconv(.c) u64 {
    return lib.run(ptr, len, tool_main);
}

fn tool_main(input: []const u8, out: *lib.Out) !void {
    const alloc = std.heap.wasm_allocator;
    const req = std.json.parseFromSliceLeaky(Request, alloc, input, .{ .ignore_unknown_fields = true }) catch Request{};

    // Merged the way the harness merges: config.local.json overrides individual
    // providers, it does not replace the whole set.
    var providers: std.StringArrayHashMapUnmanaged(Provider) = .empty;
    var default_provider: []const u8 = "";
    for ([_][]const u8{ "config.json", "config.local.json" }) |path| {
        const raw = lib.fsRead(path) catch continue;
        const parsed = std.json.parseFromSliceLeaky(ConfigFile, alloc, raw, .{ .ignore_unknown_fields = true }) catch continue;
        if (parsed.default_provider.len > 0) default_provider = parsed.default_provider;
        var pit = parsed.providers.map.iterator();
        while (pit.next()) |kv| try providers.put(alloc, kv.key_ptr.*, kv.value_ptr.*);
    }
    if (providers.count() == 0) return errJson(out, "no providers configured");

    const check = std.mem.eql(u8, req.action, "check");
    if (!check and !std.mem.eql(u8, req.action, "list"))
        return errJson(out, "action must be \"check\" or \"list\"");

    var buf: [48 * 1024]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    var s = std.json.Stringify{ .writer = &w, .options = .{ .emit_null_optional_fields = false } };
    try s.beginObject();
    try s.objectField("ok");
    try s.write(true);
    try s.objectField("default_provider");
    try s.write(default_provider);
    try s.objectField("providers");
    try s.beginArray();

    var matched = false;
    var it = providers.iterator();
    while (it.next()) |kv| {
        const name = kv.key_ptr.*;
        if (req.provider.len > 0 and !std.mem.eql(u8, name, req.provider)) continue;
        matched = true;
        const p = kv.value_ptr.*;
        // Config carries one shape: models{} plus an optional default_model,
        // which the harness fills in when a provider declares a single model.
        var model = p.default_model;
        if (model.len == 0 and p.models.map.count() == 1) model = p.models.map.keys()[0];

        try s.beginObject();
        try s.objectField("name");
        try s.write(name);
        try s.objectField("model");
        try s.write(model);
        try s.objectField("base_url");
        try s.write(p.base_url);
        try s.objectField("kind");
        try s.write(p.kind);

        if (!check) {
            try s.endObject();
            continue;
        }

        // A provider whose key is absent is reported as skipped rather than
        // failed: nothing is wrong with it, it just is not usable here.
        if (p.api_key_env) |env_name| {
            const key = lib.getenv(env_name) orelse "";
            if (key.len == 0) {
                try s.objectField("status");
                try s.write("skipped");
                try s.objectField("error");
                try s.write(try std.fmt.allocPrint(alloc, "{s} is not set", .{env_name}));
                try s.endObject();
                continue;
            }
        }

        const t0 = lib.nowSeconds();
        if (lib.llmWith("ping", name, 1)) |_| {
            const ms: u64 = @intFromFloat(@max(0.0, (lib.nowSeconds() - t0) * 1000.0));
            try s.objectField("status");
            try s.write("ok");
            try s.objectField("ms");
            try s.write(ms);
        } else |err| {
            try s.objectField("status");
            try s.write("failed");
            try s.objectField("error");
            try s.write(@errorName(err));
        }
        try s.endObject();
    }
    try s.endArray();
    try s.endObject();

    if (req.provider.len > 0 and !matched) return errJson(out, "no such provider");
    try out.writeAll(buf[0..w.end]);
}

fn errJson(out: *lib.Out, msg: []const u8) !void {
    var buf: [512]u8 = undefined;
    const body = try std.fmt.bufPrint(&buf, "{{\"ok\":false,\"error\":\"{s}\"}}", .{msg});
    try out.writeAll(body);
}
