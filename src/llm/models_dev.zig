//! On-disk models.dev snapshot: the store, plus lookup and specs.
//!
//! models.dev is a public, unauthenticated directory of provider/model specs
//! (context window, pricing, capabilities) maintained outside this repo, so a
//! model's metadata need not be hand-typed into config.toml and kept in sync.
//! The snapshot is downloaded once (first catalog use, or `providers refresh`
//! / `POST /api/catalog/refresh`) and then read forever: serve start and
//! catalog search never touch the network while it is present. The older 24h
//! cache path is still read so an existing download survives an upgrade.
//!
//! The file lives at `state/models-dev.json` (legacy `state/cache/`). Where it
//! lives and how it is read and written is this module's, so no caller spells
//! either path again. The *download* stays in `cli.zig` (`loadModelsDev`) so
//! config load never hits the network; `api_url` is here because the store and
//! the address it is populated from are one fact.

const std = @import("std");
const atomic_write = @import("../util/atomic_write.zig");
const ensure_dir = @import("../util/ensure_dir.zig");

pub const store_path = "state/models-dev.json";
pub const legacy_path = "state/cache/models-dev.json";
pub const api_url = "https://models.dev/api.json";

pub const Specs = struct {
    context_window: ?u32 = null,
    max_tokens: ?u32 = null,
    cost_per_1m_input: ?f64 = null,
    cost_per_1m_output: ?f64 = null,
    display: ?[]const u8 = null,
    capabilities: []const []const u8 = &.{},
};

fn readFile(io: std.Io, dir: std.Io.Dir, arena: std.mem.Allocator, path: []const u8) ?[]const u8 {
    const body = dir.readFileAlloc(io, path, arena, .limited(64 * 1024 * 1024)) catch return null;
    if (body.len == 0) return null;
    return body;
}

/// Snapshot body from `dir`, or null when neither path exists.
pub fn readLocal(io: std.Io, dir: std.Io.Dir, arena: std.mem.Allocator) ?[]const u8 {
    if (readFile(io, dir, arena, store_path)) |body| return body;
    return readFile(io, dir, arena, legacy_path);
}

/// Replace the snapshot with `body`, creating `state/` if this is the first
/// populate. Atomic: a torn write would leave every later read parsing half a
/// file.
pub fn writeLocal(io: std.Io, dir: std.Io.Dir, body: []const u8) !void {
    try ensure_dir.ensureDir(dir, io, "state");
    try atomic_write.writeFile(io, dir, store_path, body);
}

fn hostOf(url: []const u8) ?[]const u8 {
    const scheme_end = std.mem.find(u8, url, "://") orelse return null;
    const rest = url[scheme_end + 3 ..];
    const end = std.mem.findAny(u8, rest, "/?#") orelse rest.len;
    var host = rest[0..end];
    if (std.mem.findScalar(u8, host, '@')) |at| host = host[at + 1 ..];
    if (host.len == 0) return null;
    if (host[0] == '[') {
        const close = std.mem.findScalar(u8, host, ']') orelse return null;
        host = host[1..close];
    } else if (std.mem.findScalar(u8, host, ':')) |colon| {
        host = host[0..colon];
    }
    return if (host.len == 0) null else host;
}

fn jsonNum(obj: std.json.ObjectMap, key: []const u8) ?f64 {
    const v = obj.get(key) orelse return null;
    return switch (v) {
        .integer => |i| @floatFromInt(i),
        .float => |f| f,
        .number_string => |s| std.fmt.parseFloat(f64, s) catch null,
        .string => |s| std.fmt.parseFloat(f64, s) catch null,
        else => null,
    };
}

fn jsonU32(obj: std.json.ObjectMap, key: []const u8) ?u32 {
    const n = jsonNum(obj, key) orelse return null;
    if (n <= 0 or n > @as(f64, @floatFromInt(std.math.maxInt(u32)))) return null;
    return @as(u32, @trunc(n));
}

/// The catalog provider for this clanker provider: exact name, then exact
/// `api` URL, then same host, then a shared `api_key_env`.
pub fn findProvider(
    catalog: std.json.Value,
    name: []const u8,
    base_url: []const u8,
    api_key_env: ?[]const u8,
) ?std.json.Value {
    if (catalog != .object) return null;
    if (name.len > 0) {
        if (catalog.object.get(name)) |e| return e;
    }
    const want_base = std.mem.trimEnd(u8, base_url, "/");
    const want_host = hostOf(base_url);
    var host_fallback: ?std.json.Value = null;
    var env_fallback: ?std.json.Value = null;
    var it = catalog.object.iterator();
    while (it.next()) |kv| {
        const entry = kv.value_ptr.*;
        if (entry != .object) continue;
        const api: []const u8 = if (entry.object.get("api")) |v| switch (v) {
            .string => |s| s,
            else => "",
        } else "";
        if (api.len > 0 and want_base.len > 0 and std.mem.eql(u8, std.mem.trimEnd(u8, api, "/"), want_base))
            return entry;
        if (host_fallback == null) if (want_host) |wh| {
            if (hostOf(api)) |eh| {
                if (std.mem.eql(u8, eh, wh)) host_fallback = entry;
            }
        };
        if (env_fallback == null) {
            if (api_key_env) |want_env| {
                if (entry.object.get("env")) |envs| {
                    if (envs == .array) {
                        for (envs.array.items) |e| {
                            if (e == .string and std.mem.eql(u8, e.string, want_env)) {
                                env_fallback = entry;
                                break;
                            }
                        }
                    }
                }
            }
        }
    }
    return host_fallback orelse env_fallback;
}

/// A catalog model matching `model_name`: exact key, then the part after the
/// last `/` (OpenRouter-style ids against a vendor's own table).
pub fn findModel(provider_entry: std.json.Value, model_name: []const u8) ?std.json.Value {
    if (provider_entry != .object) return null;
    const models_v = provider_entry.object.get("models") orelse return null;
    if (models_v != .object) return null;
    if (models_v.object.get(model_name)) |m| return m;
    if (std.mem.findScalarLast(u8, model_name, '/')) |slash| {
        return models_v.object.get(model_name[slash + 1 ..]);
    }
    return null;
}

/// models.dev `reasoning` / `tool_call` / `modalities.input` as the tags
/// `config.Model.capabilities` accepts.
pub fn capabilities(arena: std.mem.Allocator, m: std.json.Value) ![]const []const u8 {
    var caps: std.ArrayList([]const u8) = .empty;
    if (m != .object) return caps.toOwnedSlice(arena);
    if (m.object.get("reasoning")) |r| if (r == .bool and r.bool) try caps.append(arena, "thinking");
    if (m.object.get("tool_call")) |t| if (t == .bool and t.bool) try caps.append(arena, "tool_use");
    if (m.object.get("modalities")) |mo| if (mo == .object) {
        if (mo.object.get("input")) |in| if (in == .array) {
            for (in.array.items) |item| {
                if (item != .string) continue;
                if (std.mem.eql(u8, item.string, "image")) try caps.append(arena, "image_in");
                if (std.mem.eql(u8, item.string, "video")) try caps.append(arena, "video_in");
                if (std.mem.eql(u8, item.string, "audio")) try caps.append(arena, "audio_in");
            }
        };
    };
    return caps.toOwnedSlice(arena);
}

pub fn specs(arena: std.mem.Allocator, m: std.json.Value) !Specs {
    var out = Specs{};
    if (m != .object) return out;
    if (m.object.get("limit")) |l| if (l == .object) {
        out.context_window = jsonU32(l.object, "context");
        out.max_tokens = jsonU32(l.object, "output");
    };
    if (m.object.get("cost")) |c| if (c == .object) {
        out.cost_per_1m_input = jsonNum(c.object, "input");
        out.cost_per_1m_output = jsonNum(c.object, "output");
    };
    if (m.object.get("name")) |n| {
        if (n == .string and n.string.len > 0) out.display = n.string;
    }
    out.capabilities = try capabilities(arena, m);
    return out;
}

// ------------------------------------------------------------------- tests --

const sample =
    \\{
    \\  "xai": {
    \\    "api": "https://api.x.ai/v1",
    \\    "env": ["XAI_API_KEY"],
    \\    "models": {
    \\      "grok-4.6": {
    \\        "name": "Grok 4.6",
    \\        "limit": {"context": 500000, "output": 250000},
    \\        "cost": {"input": 2, "output": 6},
    \\        "reasoning": true,
    \\        "tool_call": true,
    \\        "modalities": {"input": ["text", "image"]}
    \\      }
    \\    }
    \\  }
    \\}
;

test "findProvider prefers the catalog name, then the api URL" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const catalog = try std.json.parseFromSliceLeaky(std.json.Value, arena, sample, .{});

    try std.testing.expect(findProvider(catalog, "xai", "", null) != null);
    try std.testing.expect(findProvider(catalog, "nope", "https://api.x.ai/v1", null) != null);
    try std.testing.expect(findProvider(catalog, "nope", "https://other.test/v1", null) == null);
}

test "findModel matches a wire SKU and a slashed alias tail" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const catalog = try std.json.parseFromSliceLeaky(std.json.Value, arena, sample, .{});
    const p = findProvider(catalog, "xai", "", null).?;
    try std.testing.expect(findModel(p, "grok-4.6") != null);
    try std.testing.expect(findModel(p, "xai/grok-4.6") != null);
    try std.testing.expect(findModel(p, "grok4.6-coding") == null);
}

test "specs reads context, output, cost, display, and capabilities" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const catalog = try std.json.parseFromSliceLeaky(std.json.Value, arena, sample, .{});
    const m = findModel(findProvider(catalog, "xai", "", null).?, "grok-4.6").?;
    const s = try specs(arena, m);
    try std.testing.expectEqual(@as(u32, 500000), s.context_window.?);
    try std.testing.expectEqual(@as(u32, 250000), s.max_tokens.?);
    try std.testing.expectEqual(@as(f64, 2), s.cost_per_1m_input.?);
    try std.testing.expectEqual(@as(f64, 6), s.cost_per_1m_output.?);
    try std.testing.expectEqualStrings("Grok 4.6", s.display.?);
    try std.testing.expectEqual(@as(usize, 3), s.capabilities.len);
    try std.testing.expectEqualStrings("thinking", s.capabilities[0]);
    try std.testing.expectEqualStrings("tool_use", s.capabilities[1]);
    try std.testing.expectEqualStrings("image_in", s.capabilities[2]);
}

test "specs skips a zero context or output rather than treating it as a cap" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const m = try std.json.parseFromSliceLeaky(std.json.Value, arena,
        \\{"limit":{"context":0,"output":0}}
    , .{});
    const s = try specs(arena, m);
    try std.testing.expect(s.context_window == null);
    try std.testing.expect(s.max_tokens == null);
}

test "readLocal prefers state/models-dev.json over the legacy cache path" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    try tmp.dir.createDirPath(io, "state/cache");
    try tmp.dir.writeFile(io, .{ .sub_path = legacy_path, .data = "legacy" });
    try tmp.dir.writeFile(io, .{ .sub_path = store_path, .data = "current" });
    const body = readLocal(io, tmp.dir, arena) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("current", body);
}

test "readLocal falls back to the legacy 24h cache path" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    try tmp.dir.createDirPath(io, "state/cache");
    try tmp.dir.writeFile(io, .{ .sub_path = legacy_path, .data = "legacy" });
    const body = readLocal(io, tmp.dir, arena) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("legacy", body);
}

test "readLocal treats a missing or empty file as absent" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    try std.testing.expect(readLocal(io, tmp.dir, arena) == null);
    try tmp.dir.createDirPath(io, "state");
    try tmp.dir.writeFile(io, .{ .sub_path = store_path, .data = "" });
    try std.testing.expect(readLocal(io, tmp.dir, arena) == null);
}

test "writeLocal creates state/ on the first populate and replaces the snapshot" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    try writeLocal(io, tmp.dir, "first");
    try std.testing.expectEqualStrings("first", readLocal(io, tmp.dir, arena) orelse return error.TestUnexpectedResult);
    try writeLocal(io, tmp.dir, "second");
    try std.testing.expectEqualStrings("second", readLocal(io, tmp.dir, arena) orelse return error.TestUnexpectedResult);
}
