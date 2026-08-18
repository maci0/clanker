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

/// Tolerant number field: integer, float, or a numeric string all read as
/// f64; anything else (and an unparseable string) reads as null. models.dev
/// spells prices and window sizes inconsistently across providers.
pub fn jsonNum(obj: std.json.ObjectMap, key: []const u8) ?f64 {
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

// ------------------------------------------------------- raw member scanning --

// The snapshot is ~4 MB and a `Config.load` needs the handful of members that
// name configured providers. A full `std.json.Value` parse of the whole file
// cost ~350 ms of pure CPU on *every* CLI invocation, because `Config.load`
// runs `applyCatalogSpecs` unconditionally: `clanker --help` (no config) is
// 13 ms, any config-loading verb was 360 ms. So the file is walked once as
// bytes here, and only the spans that matched a provider are handed to
// `std.json`. Same shape as `tools/zig/manifest_scan.zig`, which exists for
// the same reason on the guest side.

/// One member of a JSON object: the raw key bytes (escapes unresolved) and
/// the raw span of its value (a string span includes its quotes, an
/// object/array span its braces/brackets).
pub const Member = struct { key: []const u8, value: []const u8 };

/// Walks a JSON object's members without building a value tree. Stops at the
/// first malformed byte rather than reporting it: a corrupt snapshot must
/// degrade to "no catalog specs", never fail a config load.
pub const MemberIterator = struct {
    raw: []const u8,
    i: usize,
    done: bool = false,

    /// Null when `raw` does not open an object.
    pub fn init(raw: []const u8) ?MemberIterator {
        const open = skipWs(raw, 0);
        if (open >= raw.len or raw[open] != '{') return null;
        return .{ .raw = raw, .i = open + 1 };
    }

    pub fn next(self: *MemberIterator) ?Member {
        if (self.done) return null;
        const raw = self.raw;
        var i = skipWs(raw, self.i);
        while (i < raw.len and raw[i] == ',') i = skipWs(raw, i + 1);
        if (i >= raw.len or raw[i] == '}' or raw[i] != '"') {
            self.done = true;
            return null;
        }
        const key_end = stringEnd(raw, i) orelse {
            self.done = true;
            return null;
        };
        const key = raw[i + 1 .. key_end];
        i = skipWs(raw, key_end + 1);
        if (i >= raw.len or raw[i] != ':') {
            self.done = true;
            return null;
        }
        i = skipWs(raw, i + 1);
        const val_end = valueEnd(raw, i) orelse {
            self.done = true;
            return null;
        };
        self.i = val_end;
        return .{ .key = key, .value = raw[i..val_end] };
    }
};

fn skipWs(raw: []const u8, from: usize) usize {
    var i = from;
    while (i < raw.len and (raw[i] == ' ' or raw[i] == '\t' or raw[i] == '\r' or raw[i] == '\n')) i += 1;
    return i;
}

/// Index of the closing quote of the string opening at `start`.
fn stringEnd(raw: []const u8, start: usize) ?usize {
    var i = start + 1;
    var escaped = false;
    while (i < raw.len) : (i += 1) {
        if (escaped) {
            escaped = false;
            continue;
        }
        switch (raw[i]) {
            '\\' => escaped = true,
            '"' => return i,
            else => {},
        }
    }
    return null;
}

/// One past the end of the JSON value starting at `start`. Honours strings so
/// a brace inside `"a}b"` cannot close a span early.
///
/// Byte at a time on purpose. This walk reads every one of the snapshot's
/// ~4 MB, so it looks like the place to hand-vectorise, and a Debug profile
/// agrees loudly: it is 44% of `clanker stats` there. It is not. LLVM already
/// turns this loop into ~1.5 GB/s of straight-line code in ReleaseFast (~2.5 ms
/// for the whole file), and a hand-written 32-lane "skip to the next structural
/// byte" scan measured 10% *slower* on the real snapshot, whose short dense
/// strings never let a lane run pay for its setup. Profile a release build
/// before touching this.
fn valueEnd(raw: []const u8, start: usize) ?usize {
    if (start >= raw.len) return null;
    switch (raw[start]) {
        '"' => return (stringEnd(raw, start) orelse return null) + 1,
        '{', '[' => {
            var depth: usize = 0;
            var in_string = false;
            var escaped = false;
            var i = start;
            while (i < raw.len) : (i += 1) {
                const c = raw[i];
                if (escaped) {
                    escaped = false;
                    continue;
                }
                if (in_string) {
                    switch (c) {
                        '\\' => escaped = true,
                        '"' => in_string = false,
                        else => {},
                    }
                    continue;
                }
                switch (c) {
                    '"' => in_string = true,
                    '{', '[' => depth += 1,
                    '}', ']' => {
                        depth -= 1;
                        if (depth == 0) return i + 1;
                    },
                    else => {},
                }
            }
            return null;
        },
        // Bare scalar: number / true / false / null.
        else => {
            var i = start;
            while (i < raw.len and raw[i] != ',' and raw[i] != '}' and raw[i] != ']' and
                raw[i] != ' ' and raw[i] != '\t' and raw[i] != '\r' and raw[i] != '\n') i += 1;
            return i;
        },
    }
}

/// Every top-level member of the snapshot, in document order. Empty when the
/// body is not an object, which is what a truncated download reads as.
pub fn topLevelMembers(arena: std.mem.Allocator, body: []const u8) []const Member {
    var out: std.ArrayList(Member) = .empty;
    var it = MemberIterator.init(body) orelse return &.{};
    while (it.next()) |m| out.append(arena, m) catch return out.items;
    return out.items;
}

/// The raw span of `key` inside the object `obj_raw`, or null.
fn memberSpan(obj_raw: []const u8, key: []const u8) ?[]const u8 {
    var it = MemberIterator.init(obj_raw) orelse return null;
    while (it.next()) |m| if (std.mem.eql(u8, m.key, key)) return m.value;
    return null;
}

/// A JSON string span's contents. Borrows when there is nothing to unescape,
/// which is every `api` URL the catalog has ever carried; anything else goes
/// through `std.json` for just that one small token.
fn spanString(arena: std.mem.Allocator, span: []const u8) ?[]const u8 {
    if (span.len < 2 or span[0] != '"' or span[span.len - 1] != '"') return null;
    const inner = span[1 .. span.len - 1];
    if (std.mem.findScalar(u8, inner, '\\') == null) return inner;
    return std.json.parseFromSliceLeaky([]const u8, arena, span, .{}) catch null;
}

/// `findProvider`'s rule over raw spans: exact name, then exact `api` URL,
/// then same host, then a shared `api_key_env`, each taking the first hit in
/// document order. Returns the matched provider's raw JSON span, so the
/// caller parses one provider instead of the whole snapshot.
///
/// An exact name hit stops the walk: it outranks every fallback, so nothing
/// later in the document can change the answer. That is the ordinary case —
/// `anthropic`, `openai`, `deepseek` are all models.dev ids — and it means a
/// configured provider costs a key comparison, not a scan of its models.
pub fn findProviderSpan(
    arena: std.mem.Allocator,
    members: []const Member,
    name: []const u8,
    base_url: []const u8,
    api_key_env: ?[]const u8,
) ?[]const u8 {
    const want_base = std.mem.trimEnd(u8, base_url, "/");
    const want_host = hostOf(base_url);
    var api_match: ?[]const u8 = null;
    var host_fallback: ?[]const u8 = null;
    var env_fallback: ?[]const u8 = null;
    for (members) |m| {
        if (name.len > 0 and std.mem.eql(u8, m.key, name)) return m.value;
        if (m.value.len == 0 or m.value[0] != '{') continue;
        // Nothing below can beat a hit already recorded, so skip the field
        // scans once all three fallbacks are decided.
        if (api_match != null and host_fallback != null and env_fallback != null) continue;
        const api: []const u8 = blk: {
            const span = memberSpan(m.value, "api") orelse break :blk "";
            break :blk spanString(arena, span) orelse "";
        };
        if (api_match == null and api.len > 0 and want_base.len > 0 and
            std.mem.eql(u8, std.mem.trimEnd(u8, api, "/"), want_base)) api_match = m.value;
        if (host_fallback == null) if (want_host) |wh| {
            if (hostOf(api)) |eh| {
                if (std.mem.eql(u8, eh, wh)) host_fallback = m.value;
            }
        };
        if (env_fallback == null) if (api_key_env) |want_env| {
            if (memberSpan(m.value, "env")) |envs| {
                // `env` is a small array of names; parsing just that span is
                // cheaper than a second raw-array walker for one field.
                const parsed = std.json.parseFromSliceLeaky([]const []const u8, arena, envs, .{}) catch &[_][]const u8{};
                for (parsed) |e| {
                    if (std.mem.eql(u8, e, want_env)) {
                        env_fallback = m.value;
                        break;
                    }
                }
            }
        };
    }
    return api_match orelse host_fallback orelse env_fallback;
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

const multi_sample =
    \\{
    \\  "alpha": {"api": "https://alpha.test/v1", "env": ["ALPHA_KEY"], "models": {"a1": {}}},
    \\  "beta":  {"api": "https://beta.test/v1",  "env": ["BETA_KEY"],  "models": {"b1": {}}},
    \\  "gamma": {"api": "https://beta.test/v2",  "env": ["SHARED_KEY"],"models": {"g1": {}}}
    \\}
;

/// The span scanner is what `Config.load` uses, so its answer must be the one
/// `findProvider` would have given on the same bytes -- every rung of the
/// rule, not just the exact-name case that covers the configured providers.
fn expectSameMatch(arena: std.mem.Allocator, body: []const u8, name: []const u8, base_url: []const u8, env: ?[]const u8) !void {
    const catalog = try std.json.parseFromSliceLeaky(std.json.Value, arena, body, .{});
    const want = findProvider(catalog, name, base_url, env);
    const members = topLevelMembers(arena, body);
    const got_span = findProviderSpan(arena, members, name, base_url, env);
    if (want == null) {
        try std.testing.expect(got_span == null);
        return;
    }
    const got = try std.json.parseFromSliceLeaky(std.json.Value, arena, got_span.?, .{});
    // Providers are distinguishable by `api`, so that field identifies which
    // one each route landed on.
    try std.testing.expectEqualStrings(want.?.object.get("api").?.string, got.object.get("api").?.string);
}

test "findProviderSpan matches findProvider on name, api, host, and env" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // Exact name wins over an api URL that names a different provider.
    try expectSameMatch(arena, multi_sample, "alpha", "https://beta.test/v1", null);
    // Exact api URL, no name.
    try expectSameMatch(arena, multi_sample, "nope", "https://beta.test/v1", null);
    // Same host, different path: falls back to the first host match.
    try expectSameMatch(arena, multi_sample, "nope", "https://beta.test/v9", null);
    // Only the env name is shared.
    try expectSameMatch(arena, multi_sample, "nope", "https://unrelated.test/v1", "SHARED_KEY");
    // Nothing matches.
    try expectSameMatch(arena, multi_sample, "nope", "https://unrelated.test/v1", "NO_SUCH_KEY");
    // Trailing slash is trimmed on both sides, as findProvider does.
    try expectSameMatch(arena, multi_sample, "", "https://alpha.test/v1/", null);
    // The single-provider fixture with a real models tree.
    try expectSameMatch(arena, sample, "xai", "", null);
    try expectSameMatch(arena, sample, "nope", "https://api.x.ai/v1", null);
    try expectSameMatch(arena, sample, "nope", "https://other.test/v1", null);
}

test "topLevelMembers spans values without parsing them" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const members = topLevelMembers(arena, multi_sample);
    try std.testing.expectEqual(@as(usize, 3), members.len);
    try std.testing.expectEqualStrings("alpha", members[0].key);
    try std.testing.expectEqualStrings("gamma", members[2].key);
    // The span is the whole object, so it re-parses on its own.
    const gamma = try std.json.parseFromSliceLeaky(std.json.Value, arena, members[2].value, .{});
    try std.testing.expectEqualStrings("https://beta.test/v2", gamma.object.get("api").?.string);

    // A brace inside a string must not close a span early, and a truncated
    // body must degrade to "no members" rather than a bogus one.
    const braced =
        \\{"a": {"note": "}{"}, "b": {"api": "https://b.test"}}
    ;
    const m2 = topLevelMembers(arena, braced);
    try std.testing.expectEqual(@as(usize, 2), m2.len);
    try std.testing.expectEqualStrings("b", m2[1].key);
    try std.testing.expectEqual(@as(usize, 0), topLevelMembers(arena, "[1,2]").len);
    try std.testing.expectEqual(@as(usize, 0), topLevelMembers(arena, "not json").len);
    try std.testing.expectEqual(@as(usize, 0), topLevelMembers(arena, "{\"a\": {\"unterminated").len);
}

test "value spans survive escapes and structural bytes at every offset" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // A quote, a backslash or a brace has to behave the same wherever it
    // lands, including past any block a future block-at-a-time walk would
    // read. Padding shifts every following structural byte one place per
    // iteration.
    var pad: usize = 0;
    while (pad < 40) : (pad += 1) {
        const filler = try arena.alloc(u8, pad);
        @memset(filler, 'x');
        const body = try std.fmt.allocPrint(
            arena,
            "{{\"a\": {{\"note\": \"{s}\\\"}}{{[\\\\\", \"n\": 1}}, \"b\": {{\"api\": \"https://b.test\"}}}}",
            .{filler},
        );
        const m = topLevelMembers(arena, body);
        try std.testing.expectEqual(@as(usize, 2), m.len);
        try std.testing.expectEqualStrings("b", m[1].key);
        // Each span must still be valid JSON on its own.
        const a = try std.json.parseFromSliceLeaky(std.json.Value, arena, m[0].value, .{});
        try std.testing.expectEqual(@as(i64, 1), a.object.get("n").?.integer);
        const b = try std.json.parseFromSliceLeaky(std.json.Value, arena, m[1].value, .{});
        try std.testing.expectEqualStrings("https://b.test", b.object.get("api").?.string);
    }

    // A string ending in a lone backslash never terminates: the member walk
    // must stop rather than run off the end or report a bogus span.
    try std.testing.expectEqual(@as(usize, 0), topLevelMembers(arena, "{\"a\": \"tail\\").len);
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
