//! Shared OpenAI Responses wire codec used by the Codex and Grok plugins.

const std = @import("std");
const api = @import("api.zig");
const common = @import("common.zig");
const types = @import("../types.zig");
const fuzz_corpus = @import("../../util/fuzz_corpus.zig");
const redact = @import("../../util/redact.zig");

pub const BuildOptions = struct {
    /// Send a completion budget. Off for Codex, whose ChatGPT subscription
    /// endpoint rejects it.
    max_output_tokens: bool = true,
    /// Resolve `temperature`/`top_p` and fill the reasoning effort from the
    /// full three-tier chain (per-run override, then model config, then the
    /// PRD 0024 use-case table). Off for Codex, which rejects the sampling
    /// pair; its effort then stays whatever the per-run override pinned, with
    /// no table fill, which is the behaviour its own test asserts.
    sampling: bool = true,
};

pub fn buildRequest(gpa: std.mem.Allocator, params: api.RequestParams) api.BuildError![]u8 {
    return buildWithOptions(gpa, params, .{});
}

pub fn buildWithOptions(gpa: std.mem.Allocator, params: api.RequestParams, options: BuildOptions) api.BuildError![]u8 {
    var out: std.Io.Writer.Allocating = .init(gpa);
    errdefer out.deinit();
    var s: std.json.Stringify = .{ .writer = &out.writer, .options = .{} };
    try s.beginObject();
    try s.objectField("model");
    try s.write(params.provider.wireModelName());
    try s.objectField("store");
    try s.write(false);
    try s.objectField("stream");
    try s.write(params.stream);
    // The three-tier chain, not `params` alone. The agent loop never sets
    // `params.temperature`/`top_p` and the webui's per-run override writes
    // into the provider's models map, so reading only `params` discarded both
    // the configured per-model value and PRD 0024's table on every turn
    // ([bug](../../../docs/reports/bugs/2026-08-23-grok-kind-drops-model-sampling.md)).
    const rec = common.resolveSampling(params);
    if (options.max_output_tokens) {
        // `clampedMaxTokens`, so the half-the-context-window clamp applies
        // here as it does on the chat-completions wire.
        try s.objectField("max_output_tokens");
        try s.print("{d}", .{common.clampedMaxTokens(params)});
    }
    if (options.sampling) if (rec.temperature) |value| {
        try s.objectField("temperature");
        try s.print("{d}", .{value});
    };
    if (options.sampling) if (rec.top_p) |value| {
        try s.objectField("top_p");
        try s.print("{d}", .{value});
    };
    if (params.response_format_json) {
        try s.objectField("text");
        try s.beginObject();
        try s.objectField("format");
        try s.beginObject();
        try s.objectField("type");
        try s.write("json_object");
        try s.endObject();
        try s.endObject();
    }
    // The Responses API's own nested shape, so this codec spells the field
    // itself rather than going through `writeSamplingParams` — which would
    // write the flat OpenAI field for these kinds. Codex keeps the per-run
    // pin only; Grok also takes the config and table tiers.
    const effort = if (options.sampling) rec.reasoning_effort else params.reasoning_effort;
    if (effort) |value| {
        try s.objectField("reasoning");
        try s.beginObject();
        try s.objectField("effort");
        try s.write(value);
        try s.endObject();
    }
    try s.objectField("input");
    try s.beginArray();
    for (params.messages) |m| {
        if (m.role == .tool) {
            try s.beginObject();
            try s.objectField("type");
            try s.write("function_call_output");
            try s.objectField("call_id");
            try s.write(m.tool_call_id orelse "");
            try s.objectField("output");
            try s.write(m.content orelse "");
            try s.endObject();
            continue;
        }
        try s.beginObject();
        try s.objectField("role");
        try s.write(m.role.asStr());
        try s.objectField("content");
        if (m.images) |images| {
            try s.beginArray();
            if (m.content) |text| {
                try s.beginObject();
                try s.objectField("type");
                try s.write("input_text");
                try s.objectField("text");
                try s.write(text);
                try s.endObject();
            }
            for (images) |image| {
                const url = try std.fmt.allocPrint(gpa, "data:{s};base64,{s}", .{ image.mime, image.b64 });
                defer gpa.free(url);
                try s.beginObject();
                try s.objectField("type");
                try s.write("input_image");
                try s.objectField("image_url");
                try s.write(url);
                try s.endObject();
            }
            try s.endArray();
        } else try s.write(m.content orelse "");
        try s.endObject();
        if (m.tool_calls) |calls| for (calls) |call| {
            try s.beginObject();
            try s.objectField("type");
            try s.write("function_call");
            try s.objectField("call_id");
            try s.write(call.id);
            try s.objectField("name");
            try s.write(call.name);
            try s.objectField("arguments");
            try s.write(call.arguments);
            try s.endObject();
        };
    }
    try s.endArray();
    if (params.tools) |tools| {
        try s.objectField("tools");
        try s.beginArray();
        for (tools) |tool| {
            if (tool.internal) continue;
            try s.beginObject();
            try s.objectField("type");
            try s.write("function");
            try s.objectField("name");
            try s.write(tool.name);
            try s.objectField("description");
            try s.write(tool.description);
            try s.objectField("parameters");
            try s.write(tool.input_schema);
            try s.endObject();
        }
        try s.endArray();
    }
    try s.endObject();
    return out.toOwnedSlice();
}

fn string(obj: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    const value = obj.get(key) orelse return null;
    return if (value == .string) value.string else null;
}

fn uint(obj: std.json.ObjectMap, key: []const u8) u32 {
    const value = obj.get(key) orelse return 0;
    if (value != .integer or value.integer < 0) return 0;
    return std.math.cast(u32, value.integer) orelse 0;
}

fn usageUpdate(obj: std.json.ObjectMap) api.UsageUpdate {
    const input = uint(obj, "input_tokens");
    const output = uint(obj, "output_tokens");
    var cached: u32 = 0;
    if (obj.get("input_tokens_details")) |details| {
        if (details == .object) cached = uint(details.object, "cached_tokens");
    }
    return .{
        .prompt = .{ .tokens = input, .cache_hit_tokens = cached, .cache_miss_tokens = input -| cached },
        .completion = output,
        .total = uint(obj, "total_tokens"),
    };
}

pub fn parseResponse(arena: std.mem.Allocator, body: []const u8, err_detail: ?*?[]const u8) anyerror!types.ChatResponse {
    const root = try std.json.parseFromSliceLeaky(std.json.Value, arena, body, .{ .allocate = .alloc_always });
    if (root != .object) return error.BadResponse;
    if (root.object.get("error")) |e| if (e == .object) {
        // A 200 carrying an error body never reaches client.httpErrorDetail,
        // so this assignment is the only place the provider's message becomes
        // the caller-facing reason: it then goes to the REPL transcript and to
        // printUsageError's stderr, both raw writes. `error.message` is
        // provider- or base_url-controlled bytes, so it takes the same cap,
        // whitespace flattening and credential mask every other provider
        // applies here (openai.zig, gemini.zig, anthropic.zig) — uncapped, a
        // hostile endpoint picks both what clanker prints and how much of it.
        if (err_detail) |d| d.* = if (string(e.object, "message")) |m| try redact.forCaller(arena, m) else "no message";
        return error.ApiError;
    };
    var text: std.ArrayList(u8) = .empty;
    var calls: std.ArrayList(types.ToolCall) = .empty;
    if (root.object.get("output")) |output| if (output == .array) for (output.array.items) |item| {
        if (item != .object) continue;
        const kind = string(item.object, "type") orelse "";
        if (std.mem.eql(u8, kind, "function_call")) {
            try calls.append(arena, .{ .id = string(item.object, "call_id") orelse string(item.object, "id") orelse "", .name = string(item.object, "name") orelse "", .arguments = string(item.object, "arguments") orelse "{}" });
        } else if (std.mem.eql(u8, kind, "message")) {
            if (item.object.get("content")) |content| if (content == .array) for (content.array.items) |part| {
                if (part == .object and std.mem.eql(u8, string(part.object, "type") orelse "", "output_text"))
                    try text.appendSlice(arena, string(part.object, "text") orelse "");
            };
        }
    };
    var usage: ?types.Usage = null;
    if (root.object.get("usage")) |u| if (u == .object) {
        const update = usageUpdate(u.object);
        var value: types.Usage = .{};
        update.apply(&value);
        usage = value;
    };
    return .{ .message = .{ .role = .assistant, .content = if (text.items.len > 0) try text.toOwnedSlice(arena) else null, .tool_calls = if (calls.items.len > 0) try calls.toOwnedSlice(arena) else null }, .usage = usage, .finish_reason = string(root.object, "status"), .raw = body };
}

pub fn parseErrorDetail(arena: std.mem.Allocator, body: []const u8) ?[]const u8 {
    const root = std.json.parseFromSliceLeaky(std.json.Value, arena, body, .{}) catch return null;
    if (root != .object) return null;
    const e = root.object.get("error") orelse return null;
    return if (e == .object) string(e.object, "message") else null;
}

pub fn parseStreamEvent(arena: std.mem.Allocator, payload: []const u8) api.StreamParseError!?api.StreamEvent {
    if (std.mem.eql(u8, payload, "[DONE]")) return .{ .done = true };
    const root = std.json.parseFromSliceLeaky(std.json.Value, arena, payload, .{}) catch return null;
    if (root != .object) return null;
    const kind = string(root.object, "type") orelse return null;
    if (std.mem.eql(u8, kind, "response.output_text.delta")) return .{ .text = string(root.object, "delta") };
    if (std.mem.eql(u8, kind, "response.output_item.added")) if (root.object.get("item")) |item| if (item == .object and std.mem.eql(u8, string(item.object, "type") orelse "", "function_call")) {
        const frag = try arena.alloc(api.ToolCallFragment, 1);
        frag[0] = .{ .index = @intCast(uint(root.object, "output_index")), .id = string(item.object, "call_id") orelse string(item.object, "id"), .name = string(item.object, "name") };
        return .{ .tool_calls = frag };
    };
    if (std.mem.eql(u8, kind, "response.function_call_arguments.delta")) {
        const frag = try arena.alloc(api.ToolCallFragment, 1);
        frag[0] = .{ .index = @intCast(uint(root.object, "output_index")), .arguments = string(root.object, "delta") };
        return .{ .tool_calls = frag };
    }
    if (std.mem.eql(u8, kind, "response.completed")) {
        var event: api.StreamEvent = .{ .finish_reason = "stop" };
        if (root.object.get("response")) |response| {
            if (response == .object) if (response.object.get("usage")) |usage| {
                if (usage == .object) event.usage = usageUpdate(usage.object);
            };
        }
        // Keep this frame foldable by the core; EOF or a following [DONE]
        // terminates the stream. Marking it done would discard its usage.
        return event;
    }
    return .{};
}

test "a 200 carrying an error body is capped and masked like every other provider" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // The provider picks the bytes; a credential echoed in the message must
    // not survive into the caller's error string, which reaches stderr and
    // the REPL transcript raw.
    var detail: ?[]const u8 = null;
    try std.testing.expectError(error.ApiError, parseResponse(arena, "{\"error\":{\"message\":\"401 bad key sk-proj-AAAABBBBCCCCDDDD1234\"}}", &detail));
    const out = detail.?;
    try std.testing.expect(std.mem.indexOf(u8, out, "sk-proj-") == null);
    try std.testing.expect(std.mem.indexOf(u8, out, "AAAABBBBCCCCDDDD1234") == null);
    try std.testing.expect(std.mem.indexOf(u8, out, "[redacted]") != null);

    // And it is bounded: an endpoint cannot choose how much clanker prints.
    const long = "x" ** 4096;
    var long_detail: ?[]const u8 = null;
    try std.testing.expectError(error.ApiError, parseResponse(arena, "{\"error\":{\"message\":\"" ++ long ++ "\"}}", &long_detail));
    try std.testing.expect(long_detail.?.len <= redact.max_caller_detail_len);

    // An error object with no message still gets a reason rather than silence.
    var bare: ?[]const u8 = null;
    try std.testing.expectError(error.ApiError, parseResponse(arena, "{\"error\":{\"type\":\"server_error\"}}", &bare));
    try std.testing.expect(bare.?.len > 0);
}

test "Responses codec maps text tools and usage into neutral types" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const response = try parseResponse(arena, "{\"status\":\"completed\",\"output\":[{\"type\":\"message\",\"content\":[{\"type\":\"output_text\",\"text\":\"hi\"}]},{\"type\":\"function_call\",\"call_id\":\"c1\",\"name\":\"exec\",\"arguments\":\"{}\"}],\"usage\":{\"input_tokens\":10,\"output_tokens\":2,\"total_tokens\":12,\"input_tokens_details\":{\"cached_tokens\":4}}}", null);
    try std.testing.expectEqualStrings("hi", response.message.content.?);
    try std.testing.expectEqual(@as(usize, 1), response.message.tool_calls.?.len);
    // The agent loop matches a tool result to its call by id and executes
    // the arguments verbatim, so both have to survive the codec.
    try std.testing.expectEqualStrings("c1", response.message.tool_calls.?[0].id);
    try std.testing.expectEqualStrings("exec", response.message.tool_calls.?[0].name);
    try std.testing.expectEqualStrings("{}", response.message.tool_calls.?[0].arguments);
    try std.testing.expectEqualStrings("completed", response.finish_reason.?);
    try std.testing.expectEqual(@as(u32, 4), response.usage.?.prompt_cache_hit_tokens);
}

test "Responses stream deltas decode text and function-call fragments" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const text = (try parseStreamEvent(arena, "{\"type\":\"response.output_text.delta\",\"delta\":\"he\"}")).?;
    try std.testing.expectEqualStrings("he", text.text.?);

    // The opening frame names the call; argument frames carry only the index,
    // so the client folds fragments by that index (same contract as the
    // chat-completions codecs).
    const added = (try parseStreamEvent(arena, "{\"type\":\"response.output_item.added\",\"output_index\":0,\"item\":{\"type\":\"function_call\",\"call_id\":\"c9\",\"name\":\"exec\"}}")).?;
    try std.testing.expectEqual(@as(usize, 1), added.tool_calls.len);
    try std.testing.expectEqual(@as(usize, 0), added.tool_calls[0].index);
    try std.testing.expectEqualStrings("c9", added.tool_calls[0].id.?);
    try std.testing.expectEqualStrings("exec", added.tool_calls[0].name.?);

    const args = (try parseStreamEvent(arena, "{\"type\":\"response.function_call_arguments.delta\",\"output_index\":0,\"delta\":\"{}\"}")).?;
    try std.testing.expectEqual(@as(usize, 0), args.tool_calls[0].index);
    try std.testing.expectEqualStrings("{}", args.tool_calls[0].arguments.?);

    // [DONE] still terminates the stream.
    try std.testing.expect((try parseStreamEvent(arena, "[DONE]")).?.done);
}

test "Responses completed stream frame preserves final usage" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const event = (try parseStreamEvent(arena_state.allocator(), "{\"type\":\"response.completed\",\"response\":{\"usage\":{\"input_tokens\":9,\"output_tokens\":3,\"total_tokens\":12}}}")).?;
    try std.testing.expect(!event.done);
    try std.testing.expectEqual(@as(u32, 12), event.usage.?.total.?);
}

/// Seed frames for the Responses stream fuzz target. Outside a fuzzing
/// session `std.testing.fuzz` replays only its corpus, so these are what runs
/// in `zig build test`: one of every frame shape the endpoint sends, plus the
/// negative and over-large `output_index` and disagreeing token counts the
/// saturating helpers are written for.
const stream_fuzz_corpus = [_][]const u8{
    fuzz_corpus.entry("[DONE]"),
    fuzz_corpus.entry(""),
    fuzz_corpus.entry(
        \\{"type":"response.output_text.delta","delta":"he"}
    ),
    fuzz_corpus.entry(
        \\{"type":"response.output_text.delta","delta":""}
    ),
    fuzz_corpus.entry(
        \\{"type":"response.output_text.delta"}
    ),
    fuzz_corpus.entry(
        \\{"type":"response.output_item.added","output_index":0,"item":{"type":"function_call","call_id":"c9","name":"exec"}}
    ),
    fuzz_corpus.entry(
        \\{"type":"response.output_item.added","output_index":7,"item":{"type":"function_call","id":"fc_1"}}
    ),
    fuzz_corpus.entry(
        \\{"type":"response.output_item.added","output_index":-1,"item":{"type":"function_call","name":"exec"}}
    ),
    fuzz_corpus.entry(
        \\{"type":"response.output_item.added","output_index":4294967295,"item":{"type":"function_call","name":"exec"}}
    ),
    fuzz_corpus.entry(
        \\{"type":"response.output_item.added","output_index":0,"item":{"type":"message"}}
    ),
    fuzz_corpus.entry(
        \\{"type":"response.function_call_arguments.delta","output_index":0,"delta":"{"}
    ),
    fuzz_corpus.entry(
        \\{"type":"response.function_call_arguments.delta","output_index":"0","delta":3}
    ),
    fuzz_corpus.entry(
        \\{"type":"response.completed","response":{"usage":{"input_tokens":9,"output_tokens":3,"total_tokens":12,"input_tokens_details":{"cached_tokens":4}}}}
    ),
    fuzz_corpus.entry(
        \\{"type":"response.completed","response":{"usage":{"input_tokens":5,"input_tokens_details":{"cached_tokens":99}}}}
    ),
    fuzz_corpus.entry(
        \\{"type":"response.completed","response":{"usage":{"input_tokens":-5,"output_tokens":-1,"total_tokens":0}}}
    ),
    fuzz_corpus.entry(
        \\{"type":"response.completed"}
    ),
    fuzz_corpus.entry(
        \\{"type":"response.output_text.delta","delta":"\u00fcn\u00efcode \u2713"}
    ),
    fuzz_corpus.entry(
        \\{"type":"response.unknown.event","payload":{"nested":[1,2,{"deep":true}]}}
    ),
    fuzz_corpus.entry(
        \\{"type":7}
    ),
    fuzz_corpus.entry(
        \\{ not json
    ),
    fuzz_corpus.entry("[]"),
    fuzz_corpus.entry("null"),
    fuzz_corpus.entry("\"a string\""),
    fuzz_corpus.entry("3"),
};

test "fuzz: responses stream events stay a well-formed event on any payload" {
    // The Responses wire is the Codex and Grok stream, and `output_index` /
    // the usage block are whatever the endpoint sends. Every field the codec
    // derives from those is checked on a successful parse, so a frame that
    // decodes into a self-contradictory event fails here rather than silently
    // zeroing the token log or attaching a tool call to the wrong index.
    const F = struct {
        fn one(_: void, smith: *std.testing.Smith) anyerror!void {
            var buf: [4096]u8 = undefined;
            const len = smith.slice(&buf);

            var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
            defer arena_state.deinit();
            const ev = (try parseStreamEvent(arena_state.allocator(), buf[0..len])) orelse return;

            // `[DONE]` is the only source of `done` and returns before the
            // payload is read, so it can never also carry a delta or usage.
            if (ev.done) {
                try std.testing.expect(ev.text == null);
                try std.testing.expect(ev.tool_calls.len == 0);
                try std.testing.expect(ev.usage == null);
                try std.testing.expect(ev.finish_reason == null);
                return;
            }
            // One frame describes at most one output item.

            // `response.completed` is the only frame that sets a finish
            // reason, and it sets this one literal.
            if (ev.finish_reason) |r| try std.testing.expectEqualStrings("stop", r);
            // The miss half is saturating, so adding the cache read back can
            // only ever reach or exceed the prompt total, never fall short.
            if (ev.usage) |u| if (u.prompt) |p| {
                try std.testing.expect(
                    @as(u64, p.cache_miss_tokens) + p.cache_hit_tokens >= p.tokens,
                );
            };
        }
    };
    try std.testing.fuzz({}, F.one, .{ .corpus = &stream_fuzz_corpus });
}
