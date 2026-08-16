//! Pure listing shape for the `providers` guest.
//! Host-tested; `GET /api/providers` relays `action:"list"` so the picker
//! and `clanker` share one object. Live `/models` fill for an empty map
//! stays native (credentials).

const std = @import("std");

pub const Model = struct {
    id: []const u8 = "",
    display: []const u8 = "",
    context_window: u32 = 0,
    max_tokens: u32 = 0,
    temperature: ?f64 = null,
    top_p: ?f64 = null,
    cost_per_1m_input: ?f64 = null,
    cost_per_1m_output: ?f64 = null,
    reasoning_effort: []const u8 = "",
    capabilities: []const []const u8 = &.{},
    category: []const u8 = "",
    rpm: ?u32 = null,
};

pub const Provider = struct {
    kind: []const u8 = "openai_compat",
    base_url: []const u8 = "",
    default_model: []const u8 = "",
    rpm: ?u32 = null,
    models: std.json.ArrayHashMap(Model) = .{},
};

pub const ConfigFile = struct {
    default_provider: []const u8 = "",
    providers: std.json.ArrayHashMap(Provider) = .{},
};

/// The model id the picker and `providers check` show for this row:
/// configured default, else the only declared model.
pub fn activeModelName(p: Provider) []const u8 {
    if (p.default_model.len > 0) return p.default_model;
    if (p.models.map.count() == 1) return p.models.map.keys()[0];
    return "";
}

pub fn writeModel(s: *std.json.Stringify, name: []const u8, m: Model) !void {
    try s.beginObject();
    try s.objectField("name");
    try s.write(name);
    if (m.id.len > 0) {
        try s.objectField("id");
        try s.write(m.id);
    }
    if (m.display.len > 0) {
        try s.objectField("display");
        try s.write(m.display);
    }
    try s.objectField("context_window");
    try s.write(m.context_window);
    try s.objectField("max_tokens");
    try s.write(m.max_tokens);
    if (m.temperature) |t| {
        try s.objectField("temperature");
        try s.write(t);
    }
    if (m.top_p) |t| {
        try s.objectField("top_p");
        try s.write(t);
    }
    if (m.cost_per_1m_input) |c| {
        try s.objectField("cost_per_1m_input");
        try s.write(c);
    }
    if (m.cost_per_1m_output) |c| {
        try s.objectField("cost_per_1m_output");
        try s.write(c);
    }
    if (m.reasoning_effort.len > 0) {
        try s.objectField("reasoning_effort");
        try s.write(m.reasoning_effort);
    }
    if (m.capabilities.len > 0) {
        try s.objectField("capabilities");
        try s.write(m.capabilities);
    }
    if (m.category.len > 0) {
        try s.objectField("category");
        try s.write(m.category);
    }
    if (m.rpm) |r| {
        try s.objectField("rpm");
        try s.write(r);
    }
    try s.endObject();
}

/// `{ok, default, default_provider, providers:[{name, default_model, model,
/// kind, base_url, rpm?, models:[...]}]}`. `default` is the picker field;
/// `default_provider` / `model` stay so `action:check` consumers still parse.
pub fn writeList(s: *std.json.Stringify, cfg: ConfigFile, filter: []const u8) !bool {
    try s.beginObject();
    try s.objectField("ok");
    try s.write(true);
    try s.objectField("default");
    try s.write(cfg.default_provider);
    try s.objectField("default_provider");
    try s.write(cfg.default_provider);
    try s.objectField("providers");
    try s.beginArray();

    var matched = false;
    var it = cfg.providers.map.iterator();
    while (it.next()) |kv| {
        const name = kv.key_ptr.*;
        if (filter.len > 0 and !std.mem.eql(u8, name, filter)) continue;
        matched = true;
        const p = kv.value_ptr.*;
        const model = activeModelName(p);

        try s.beginObject();
        try s.objectField("name");
        try s.write(name);
        try s.objectField("default_model");
        try s.write(p.default_model);
        try s.objectField("model");
        try s.write(model);
        try s.objectField("base_url");
        try s.write(p.base_url);
        try s.objectField("kind");
        try s.write(p.kind);
        if (p.rpm) |r| {
            try s.objectField("rpm");
            try s.write(r);
        }
        try s.objectField("models");
        try s.beginArray();
        var mit = p.models.map.iterator();
        while (mit.next()) |mkv| {
            try writeModel(s, mkv.key_ptr.*, mkv.value_ptr.*);
        }
        try s.endArray();
        try s.endObject();
    }
    try s.endArray();
    try s.endObject();
    return matched;
}

/// True when the picker still needs a live `/models` fill (a configured
/// provider declared no static models). Used by the HTTP overlay so a
/// fully-static list is a verbatim guest relay.
pub fn listNeedsLiveModelsAlloc(arena: std.mem.Allocator, raw: []const u8) bool {
    const parsed = std.json.parseFromSliceLeaky(std.json.Value, arena, raw, .{}) catch return false;
    if (parsed != .object) return false;
    const providers = parsed.object.get("providers") orelse return false;
    if (providers != .array) return false;
    for (providers.array.items) |item| {
        if (item != .object) continue;
        const models = item.object.get("models") orelse return true;
        if (models != .array or models.array.items.len == 0) return true;
    }
    return false;
}

test "writeList emits the picker contract and keeps check aliases" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var cfg = ConfigFile{ .default_provider = "zai" };
    var zai = Provider{
        .kind = "openai_compat",
        .base_url = "https://zai.test/v1",
        .default_model = "glm-5",
        .rpm = 30,
    };
    try zai.models.map.put(arena, "glm-5", .{
        .display = "GLM-5",
        .context_window = 128000,
        .max_tokens = 4096,
        .cost_per_1m_input = 0.5,
        .category = "flagship",
        .capabilities = &.{"tool_use"},
    });
    try cfg.providers.map.put(arena, "zai", zai);

    var out: std.Io.Writer.Allocating = .init(arena);
    var s = std.json.Stringify{ .writer = &out.writer, .options = .{ .emit_null_optional_fields = false } };
    try std.testing.expect(try writeList(&s, cfg, ""));

    const raw = out.written();
    try std.testing.expect(std.mem.indexOf(u8, raw, "\"default\":\"zai\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, raw, "\"default_provider\":\"zai\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, raw, "\"default_model\":\"glm-5\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, raw, "\"model\":\"glm-5\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, raw, "\"display\":\"GLM-5\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, raw, "\"context_window\":128000") != null);
    try std.testing.expect(std.mem.indexOf(u8, raw, "\"category\":\"flagship\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, raw, "\"rpm\":30") != null);
    try std.testing.expect(std.mem.indexOf(u8, raw, "\"tool_use\"") != null);
    try std.testing.expect(!listNeedsLiveModelsAlloc(arena, raw));
}

test "writeList filter misses and empty models flag a live fill" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var cfg = ConfigFile{ .default_provider = "ollama" };
    const empty = Provider{ .base_url = "http://127.0.0.1:11434/v1" };
    try cfg.providers.map.put(arena, "ollama", empty);

    var out: std.Io.Writer.Allocating = .init(arena);
    var s = std.json.Stringify{ .writer = &out.writer, .options = .{ .emit_null_optional_fields = false } };
    try std.testing.expect(try writeList(&s, cfg, "ollama"));
    try std.testing.expect(listNeedsLiveModelsAlloc(arena, out.written()));

    var miss: std.Io.Writer.Allocating = .init(arena);
    var s2 = std.json.Stringify{ .writer = &miss.writer, .options = .{ .emit_null_optional_fields = false } };
    try std.testing.expect(!try writeList(&s2, cfg, "nope"));
}

test "activeModelName falls back to the only declared model" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var p = Provider{};
    try p.models.map.put(arena, "only", .{});
    try std.testing.expectEqualStrings("only", activeModelName(p));
    try std.testing.expectEqualStrings("", activeModelName(.{}));
}
