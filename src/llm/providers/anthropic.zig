//! `anthropic`: the Anthropic Messages API.
//!
//! The codec here is also the one Vertex uses (`vertex.zig` re-exports it with
//! a different body header, URL and auth), so the request builder takes the
//! one option those two differ on rather than switching on the provider kind.

const std = @import("std");
const json = std.json;
const api = @import("api.zig");
const common = @import("common.zig");
const auth = @import("../auth.zig");
const types = @import("../types.zig");
const config = @import("../../config.zig");
const log = @import("../../util/log.zig");

/// Prefix on Anthropic OAuth access tokens (`sk-ant-oat01-…`), as minted by
/// `ant auth login`. Matched without the version digits so a later `oat02`
/// is still recognised.
pub const oauth_token_prefix = "sk-ant-oat";
pub const oauth_beta = "oauth-2025-04-20";
pub const version_header = "2023-06-01";

pub const provider: api.Provider = .{
    .kind = .anthropic,
    // Same wire kind, two auth paths, told apart by the credential's shape:
    // an `sk-ant-oat…` token is an OAuth access token, anything else is an
    // API key. That is `oauth_static` in ADR 0005's terms, and keeping the
    // detection is what makes it zero-config.
    .auth = .{ .default = .api_key, .detect = detectStrategy },
    .buildRequest = buildRequest,
    .parseResponse = parseResponse,
    .parseErrorDetail = parseErrorDetail,
    .parseStreamEvent = parseStreamEvent,
    .authHeaders = authHeaders,
    .endpointUrl = endpointUrl,
};

const default_path = "/v1/messages";

fn endpointUrl(gpa: std.mem.Allocator, p: *const config.Provider, _: bool) anyerror![]u8 {
    return common.joinBaseAndPath(gpa, p, default_path);
}

// ------------------------------------------------------------------- auth --

/// An OAuth access token is not an API key: `/v1/messages` rejects it on
/// `x-api-key`. It authenticates as `Authorization: Bearer` and additionally
/// requires the oauth beta header.
pub fn isOauthToken(key: []const u8) bool {
    return std.mem.startsWith(u8, key, oauth_token_prefix);
}

fn detectStrategy(credential: []const u8) auth.Strategy {
    return if (isOauthToken(credential)) .oauth_static else .api_key;
}

fn authHeaders(
    cred: auth.Credential,
    headers: *std.http.Client.Request.Headers,
    extra: *api.ExtraHeaders,
) usize {
    var extra_len: usize = 0;
    if (cred.value) |k| {
        switch (cred.strategy) {
            .api_key => {
                extra[extra_len] = .{ .name = "x-api-key", .value = k };
                extra_len += 1;
            },
            // Both OAuth strategies end as a bearer token plus the beta
            // header: how the token was obtained is the axis, how it rides
            // the request is not.
            .oauth_static, .oauth_refresh => {
                if (cred.bearer) |b| headers.authorization = .{ .override = b };
                extra[extra_len] = .{ .name = "anthropic-beta", .value = oauth_beta };
                extra_len += 1;
            },
        }
    }
    extra[extra_len] = .{ .name = "anthropic-version", .value = version_header };
    extra_len += 1;
    return extra_len;
}

// ---------------------------------------------------------------- request --

pub const BodyOptions = struct {
    /// When set, the body carries `anthropic_version` instead of `model`,
    /// because the deployment addresses the model in the URL (Vertex).
    anthropic_version: ?[]const u8 = null,
};

fn buildRequest(gpa: std.mem.Allocator, params: api.RequestParams) api.BuildError![]u8 {
    return buildBody(gpa, params, .{});
}

pub fn buildBody(gpa: std.mem.Allocator, params: api.RequestParams, opts: BodyOptions) api.BuildError![]u8 {
    var b = common.Builder.init(gpa);
    errdefer b.deinit();
    // Scratch space for re-parsing tool arguments; freed when the body is
    // built, so the parsed values never outlive this call.
    var scratch_state = std.heap.ArenaAllocator.init(gpa);
    defer scratch_state.deinit();
    const scratch = scratch_state.allocator();
    var s = b.begin();

    try s.beginObject();
    if (opts.anthropic_version) |v| {
        try s.objectField("anthropic_version");
        try common.jstr(&s, v);
    } else {
        try s.objectField("model");
        try common.jstr(&s, params.provider.activeModelName());
    }
    // Anthropic streams only when asked in the body; the endpoint verb alone
    // (Vertex's :streamRawPredict) is not enough.
    if (params.stream) {
        try s.objectField("stream");
        try s.write(true);
    }
    const max_tokens = common.clampedMaxTokens(params);
    try s.objectField("max_tokens");
    try s.print("{d}", .{max_tokens});

    // Anthropic takes the system prompt as a top-level field.
    var system_parts: std.ArrayList([]const u8) = .empty;
    // The list is gpa-backed; only the strings it points at belong to the
    // caller's arena.
    defer system_parts.deinit(gpa);
    for (params.messages) |m| {
        if (m.role == .system and m.content != null) try system_parts.append(gpa, m.content.?);
    }
    if (system_parts.items.len > 0) {
        try s.objectField("system");
        // Always the block form, so a block can carry a cache breakpoint.
        // Tools and the system prompt are the stable prefix of every turn in a
        // run, and they render ahead of the messages, so a breakpoint here
        // caches both: without it a long system prompt is re-billed in full on
        // every iteration.
        //
        // The last two blocks are marked rather than only the last. A lookup
        // matches the longest cached prefix, so a caller that puts what changes
        // in its final block keeps the bulk cached when that block changes.
        // The improve engine does exactly this: the file it is about to patch
        // sits alone at the end, and everything before it survives the patch.
        try s.beginArray();
        const first_marked = system_parts.items.len -| 2;
        for (system_parts.items, 0..) |part, i| {
            try s.beginObject();
            try s.objectField("type");
            try common.jstr(&s, "text");
            try s.objectField("text");
            try common.jstr(&s, part);
            if (i >= first_marked) {
                try s.objectField("cache_control");
                try s.beginObject();
                try s.objectField("type");
                try common.jstr(&s, "ephemeral");
                try s.endObject();
            }
            try s.endObject();
        }
        try s.endArray();
    }

    try s.objectField("messages");
    try s.beginArray();
    for (params.messages) |m| {
        if (m.role == .system) continue;
        try s.beginObject();
        try s.objectField("role");
        try common.jstr(&s, switch (m.role) {
            .system => "user", // unreachable; skipped above
            .user => "user",
            .assistant => "assistant",
            .tool => "user",
        });
        try s.objectField("content");
        try s.beginArray();
        switch (m.role) {
            .tool => {
                try s.beginObject();
                try s.objectField("type");
                try common.jstr(&s, "tool_result");
                try s.objectField("tool_use_id");
                try common.jstr(&s, m.tool_call_id orelse "");
                try s.objectField("content");
                try common.jstr(&s, m.content orelse "");
                try s.endObject();
            },
            .assistant => {
                // Text first, then tool_use — the order the model produced
                // them. An assistant turn whose last block is text reads as a
                // prefill to continue, which Anthropic rejects outright
                // ("does not support assistant message prefill"); that fires
                // on every replayed turn where the model both spoke and
                // called a tool.
                if (m.content) |c| {
                    if (c.len > 0) {
                        try s.beginObject();
                        try s.objectField("type");
                        try common.jstr(&s, "text");
                        try s.objectField("text");
                        try common.jstr(&s, c);
                        try s.endObject();
                    }
                }
                if (m.tool_calls) |calls| {
                    for (calls) |tc| {
                        try s.beginObject();
                        try s.objectField("type");
                        try common.jstr(&s, "tool_use");
                        try s.objectField("id");
                        try common.jstr(&s, tc.id);
                        try s.objectField("name");
                        try common.jstr(&s, tc.name);
                        try s.objectField("input");
                        // Embed the raw arguments JSON.
                        const input = json.parseFromSliceLeaky(json.Value, scratch, tc.arguments, .{}) catch json.Value{ .object = .empty };
                        try common.jval(&s, input);
                        try s.endObject();
                    }
                }
            },
            else => {
                try s.beginObject();
                try s.objectField("type");
                try common.jstr(&s, "text");
                try s.objectField("text");
                try common.jstr(&s, m.content orelse "");
                try s.endObject();
            },
        }
        try s.endArray();
        try s.endObject();
    }
    try s.endArray();

    if (params.tools) |tools| {
        try s.objectField("tools");
        try s.beginArray();
        for (tools) |t| {
            try s.beginObject();
            try s.objectField("name");
            try common.jstr(&s, t.name);
            try s.objectField("description");
            try common.jstr(&s, t.description);
            try s.objectField("input_schema");
            try common.jval(&s, t.input_schema);
            try s.endObject();
        }
        try s.endArray();
    }

    try common.writeSamplingParams(&s, params);
    try s.endObject();

    return try b.finish();
}

// --------------------------------------------------------------- response --

const ErrorBody = struct {
    @"error": ?struct {
        message: ?[]const u8 = null,
        type: ?[]const u8 = null,
    } = null,
};

const Block = struct {
    type: []const u8 = "",
    text: ?[]const u8 = null,
    id: ?[]const u8 = null,
    name: ?[]const u8 = null,
    input: ?std.json.Value = null,
};

const Response = struct {
    content: []const Block = &.{},
    stop_reason: ?[]const u8 = null,
    usage: ?Usage = null,
    @"error": ?struct {
        message: ?[]const u8 = null,
        type: ?[]const u8 = null,
    } = null,
};

const Usage = struct {
    input_tokens: u32 = 0,
    output_tokens: u32 = 0,
    cache_read_input_tokens: u32 = 0,
    cache_creation_input_tokens: u32 = 0,

    /// `input_tokens` already excludes cached reads and cache writes, so the
    /// prompt total is the sum of all three. Both the blocking and the
    /// streaming path go through here, which is what keeps them from
    /// reporting different numbers for the same request.
    fn prompt(self: Usage) api.PromptUsage {
        return .{
            .tokens = self.input_tokens + self.cache_read_input_tokens + self.cache_creation_input_tokens,
            .cache_hit_tokens = self.cache_read_input_tokens,
            .cache_miss_tokens = self.input_tokens + self.cache_creation_input_tokens,
        };
    }

    /// True when this report says anything at all about the prompt side.
    /// A frame reporting only `output_tokens` must leave the prompt numbers
    /// a previous frame supplied alone.
    fn hasPrompt(self: Usage) bool {
        return self.input_tokens > 0 or self.cache_read_input_tokens > 0 or self.cache_creation_input_tokens > 0;
    }
};

fn parseResponse(arena: std.mem.Allocator, body: []const u8, err_detail: ?*?[]const u8) anyerror!types.ChatResponse {
    const parsed = try json.parseFromSliceLeaky(Response, arena, body, .{ .ignore_unknown_fields = true });
    if (parsed.@"error") |e| {
        // A 200 carrying an error body never reaches the HTTP error path, so
        // this is the only place the reason is visible: log it AND hand it to
        // the caller.
        log.log(.error_, "anthropic error ({s}): {s}", .{ e.type orelse "unknown", e.message orelse "no message" });
        if (err_detail) |d| d.* = if (e.message) |m| try arena.dupe(u8, m) else e.type;
        return error.ApiError;
    }

    var text_parts: std.ArrayList(u8) = .empty;
    var calls: std.ArrayList(types.ToolCall) = .empty;

    for (parsed.content) |block| {
        if (std.mem.eql(u8, block.type, "text")) {
            if (block.text) |t| try text_parts.appendSlice(arena, t);
        } else if (std.mem.eql(u8, block.type, "tool_use")) {
            // Growable: a fixed buffer silently truncated large tool inputs
            // into invalid JSON that the next request then replayed.
            var args: std.Io.Writer.Allocating = .init(arena);
            if (block.input) |inp| {
                try json.Stringify.value(inp, .{}, &args.writer);
            }
            const written = args.written();
            try calls.append(arena, .{
                .id = try arena.dupe(u8, block.id orelse ""),
                .name = try arena.dupe(u8, block.name orelse ""),
                // A tool taking no arguments must still replay as valid JSON.
                .arguments = if (written.len > 0) written else "{}",
            });
        }
    }

    var msg = types.Message{ .role = .assistant, .content = null };
    if (text_parts.items.len > 0) {
        msg.content = try text_parts.toOwnedSlice(arena);
    }
    if (calls.items.len > 0) {
        msg.tool_calls = try calls.toOwnedSlice(arena);
    }

    var usage: ?types.Usage = null;
    if (parsed.usage) |u| {
        const p = u.prompt();
        usage = .{
            .prompt_tokens = p.tokens,
            .completion_tokens = u.output_tokens,
            .total_tokens = p.tokens + u.output_tokens,
            .prompt_cache_hit_tokens = p.cache_hit_tokens,
            .prompt_cache_miss_tokens = p.cache_miss_tokens,
        };
    }

    return .{
        .message = msg,
        .usage = usage,
        .finish_reason = parsed.stop_reason,
        .raw = try arena.dupe(u8, body),
    };
}

fn parseErrorDetail(arena: std.mem.Allocator, body: []const u8) ?[]const u8 {
    const parsed = json.parseFromSliceLeaky(ErrorBody, arena, body, .{ .ignore_unknown_fields = true }) catch return null;
    if (parsed.@"error") |e| return e.message;
    return null;
}

// ----------------------------------------------------------------- stream --

/// One frame of an Anthropic (and Vertex) stream. Only the fields the harness
/// consumes are declared; everything else is ignored.
const Event = struct {
    type: []const u8 = "",
    index: usize = 0,
    message: ?struct {
        usage: ?Usage = null,
    } = null,
    content_block: ?struct {
        type: []const u8 = "",
        id: ?[]const u8 = null,
        name: ?[]const u8 = null,
    } = null,
    delta: ?struct {
        type: []const u8 = "",
        text: ?[]const u8 = null,
        partial_json: ?[]const u8 = null,
        /// Only on `message_delta`: "end_turn", "tool_use", "max_tokens", ...
        stop_reason: ?[]const u8 = null,
    } = null,
    usage: ?Usage = null,
};

fn usageUpdate(u: Usage) api.UsageUpdate {
    return .{
        .prompt = if (u.hasPrompt()) u.prompt() else null,
        .completion = if (u.output_tokens > 0) u.output_tokens else null,
        // Anthropic never states a total; it is prompt + completion, which
        // the core derives once both halves have arrived.
        .total = null,
    };
}

/// Decodes one Anthropic stream event.
///
/// The shape differs from OpenAI in three ways that matter: text arrives as
/// `content_block_delta` with a `text_delta`, tool arguments arrive as
/// `input_json_delta` fragments that must be concatenated per block index, and
/// usage is split across `message_start` (input) and `message_delta` (output).
fn parseStreamEvent(chunk_arena: std.mem.Allocator, payload: []const u8) api.StreamParseError!?api.StreamEvent {
    // Anthropic does not send the OpenAI sentinel, but a proxy in front of it
    // may, and treating it as an unparseable frame would spin the reader
    // until the connection closed.
    if (common.isDoneSentinel(payload)) return .{ .done = true };

    const ev = json.parseFromSliceLeaky(Event, chunk_arena, payload, .{ .ignore_unknown_fields = true }) catch {
        // Dropping a frame silently hides truncated or re-framed streams as
        // "the model said nothing". Log the byte count only — the payload is
        // raw provider output that may contain generated content or echoed
        // user data.
        log.log(.debug, "unparseable stream frame ({d} bytes)", .{payload.len});
        return null;
    };

    if (std.mem.eql(u8, ev.type, "message_start")) {
        const m = ev.message orelse return null;
        const u = m.usage orelse return null;
        return .{ .usage = usageUpdate(u) };
    }

    if (std.mem.eql(u8, ev.type, "content_block_start")) {
        const block = ev.content_block orelse return null;
        // A text block is not a tool-call slot; claiming one here would make
        // the assistant's prose look like a nameless tool call.
        if (!std.mem.eql(u8, block.type, "tool_use")) return null;
        const frags = try chunk_arena.alloc(api.ToolCallFragment, 1);
        frags[0] = .{ .index = ev.index, .id = block.id, .name = block.name };
        return .{ .tool_calls = frags };
    }

    if (std.mem.eql(u8, ev.type, "content_block_delta")) {
        const d = ev.delta orelse return null;
        if (d.text) |text| return .{ .text = if (text.len > 0) text else null };
        const frag = d.partial_json orelse return null;
        if (frag.len == 0) return null;
        const frags = try chunk_arena.alloc(api.ToolCallFragment, 1);
        frags[0] = .{ .index = ev.index, .arguments = frag };
        return .{ .tool_calls = frags };
    }

    if (std.mem.eql(u8, ev.type, "message_delta")) {
        var out: api.StreamEvent = .{};
        if (ev.usage) |u| out.usage = usageUpdate(u);
        // The stop reason only ever arrives here; without it the agent loop
        // cannot tell "end_turn" from "max_tokens" (a truncated answer).
        if (ev.delta) |d| out.finish_reason = d.stop_reason;
        return out;
    }

    // ping, content_block_stop, message_stop, thinking/signature deltas:
    // known and deliberately ignored, same as anything unrecognised.
    return null;
}

// ------------------------------------------------------------------- tests --

test "anthropic request body has system field and content blocks" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const p = try config.Provider.single(arena, "claude", "https://api.anthropic.com", .anthropic, "claude-sonnet", .{ .max_tokens = 256 });
    const messages = [_]types.Message{
        .{ .role = .system, .content = "sys" },
        .{ .role = .user, .content = "hello" },
    };
    const body = try buildRequest(arena, .{ .provider = &p, .messages = &messages });
    defer arena.free(body);

    const parsed = try json.parseFromSliceLeaky(json.Value, arena, body, .{});
    const obj = parsed.object;
    const system_blocks = obj.get("system").?.array.items;
    try std.testing.expectEqualStrings("sys", system_blocks[0].object.get("text").?.string);
    // The stable tools+system prefix carries the cache breakpoint.
    try std.testing.expectEqualStrings("ephemeral", system_blocks[0].object.get("cache_control").?.object.get("type").?.string);
    const msgs = obj.get("messages").?.array.items;
    try std.testing.expectEqual(@as(usize, 1), msgs.len);
    try std.testing.expectEqualStrings("user", msgs[0].object.get("role").?.string);
}

test "anthropic max_tokens is clamped to half the context window" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const p = try config.Provider.single(arena, "claude", "https://api.anthropic.com", .anthropic, "claude-sonnet", .{
        .context_window = 8000,
        .max_tokens = 32000,
    });
    const messages = [_]types.Message{.{ .role = .user, .content = "hi" }};
    const body = try buildRequest(arena, .{ .provider = &p, .messages = &messages });
    defer arena.free(body);

    const parsed = try json.parseFromSliceLeaky(json.Value, arena, body, .{});
    try std.testing.expectEqual(@as(i64, 4000), parsed.object.get("max_tokens").?.integer);
}

test "anthropic response parse keeps a no-argument tool call and counts cached prompt tokens" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const body =
        \\{"id":"msg_1","type":"message","role":"assistant","content":[
        \\{"type":"text","text":"Checking."},
        \\{"type":"tool_use","id":"toolu_1","name":"roadmap","input":{}},
        \\{"type":"tool_use","id":"toolu_2","name":"history","input":{"n":3}}
        \\],"stop_reason":"tool_use","usage":{"input_tokens":40,"output_tokens":35,"cache_read_input_tokens":10,"cache_creation_input_tokens":5}}
    ;
    const resp = try parseResponse(arena, body, null);

    try std.testing.expectEqualStrings("Checking.", resp.message.content.?);
    const calls = resp.message.tool_calls.?;
    try std.testing.expectEqual(@as(usize, 2), calls.len);
    // Empty input must serialize as an object, not an empty string: the next
    // request replays these arguments verbatim.
    try std.testing.expectEqualStrings("{}", calls[0].arguments);
    try std.testing.expectEqualStrings("{\"n\":3}", calls[1].arguments);
    try std.testing.expectEqualStrings("tool_use", resp.finish_reason.?);

    // Prompt tokens are uncached + cache writes + cache reads, matching the
    // streaming path's accounting for the same request.
    const u = resp.usage.?;
    try std.testing.expectEqual(@as(u32, 55), u.prompt_tokens);
    try std.testing.expectEqual(@as(u32, 10), u.prompt_cache_hit_tokens);
    try std.testing.expectEqual(@as(u32, 45), u.prompt_cache_miss_tokens);
    try std.testing.expectEqual(@as(u32, 90), u.total_tokens);
}

test "a large tool input is not truncated" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // Bigger than the old fixed 64 KiB scratch buffer, which truncated the
    // arguments into invalid JSON without an error.
    const big = try arena.alloc(u8, 100 * 1024);
    @memset(big, 'x');
    const body = try std.fmt.allocPrint(
        arena,
        "{{\"content\":[{{\"type\":\"tool_use\",\"id\":\"t1\",\"name\":\"write\",\"input\":{{\"text\":\"{s}\"}}}}]}}",
        .{big},
    );
    const resp = try parseResponse(arena, body, null);

    const args = resp.message.tool_calls.?[0].arguments;
    const reparsed = try json.parseFromSliceLeaky(json.Value, arena, args, .{});
    try std.testing.expectEqual(big.len, reparsed.object.get("text").?.string.len);
}

test "assistant text precedes tool_use in the anthropic body" {
    // Anthropic reads an assistant turn whose last block is text as a prefill
    // to continue and rejects the request, so a replayed turn where the model
    // spoke *and* called tools must put the text block first.
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const p = try config.Provider.single(arena, "claude", "https://api.anthropic.com", .anthropic, "claude-opus-4-6", .{ .max_tokens = 256 });
    const calls = [_]types.ToolCall{.{ .id = "toolu_1", .name = "roadmap", .arguments = "{}" }};
    const messages = [_]types.Message{
        .{ .role = .user, .content = "what next?" },
        .{ .role = .assistant, .content = "Let me check the roadmap.", .tool_calls = &calls },
        .{ .role = .tool, .tool_call_id = "toolu_1", .content = "(no planned items)" },
    };
    const body = try buildRequest(arena, .{ .provider = &p, .messages = &messages });
    defer arena.free(body);

    const parsed = try json.parseFromSliceLeaky(json.Value, arena, body, .{});
    const msgs = parsed.object.get("messages").?.array.items;
    const blocks = msgs[1].object.get("content").?.array.items;
    try std.testing.expectEqualStrings("text", blocks[0].object.get("type").?.string);
    try std.testing.expectEqualStrings("tool_use", blocks[1].object.get("type").?.string);
    // The conversation still has to end on a user turn.
    try std.testing.expectEqualStrings("user", msgs[msgs.len - 1].object.get("role").?.string);
}

test "an assistant turn with empty content emits no text block" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const p = try config.Provider.single(arena, "claude", "https://api.anthropic.com", .anthropic, "claude-opus-4-6", .{ .max_tokens = 256 });
    const calls = [_]types.ToolCall{.{ .id = "toolu_1", .name = "roadmap", .arguments = "{}" }};
    const messages = [_]types.Message{
        .{ .role = .user, .content = "go" },
        .{ .role = .assistant, .content = "", .tool_calls = &calls },
        .{ .role = .tool, .tool_call_id = "toolu_1", .content = "ok" },
    };
    const body = try buildRequest(arena, .{ .provider = &p, .messages = &messages });
    defer arena.free(body);

    const parsed = try json.parseFromSliceLeaky(json.Value, arena, body, .{});
    const blocks = parsed.object.get("messages").?.array.items[1].object.get("content").?.array.items;
    // An empty text block is rejected by the API; only the tool_use survives.
    try std.testing.expectEqual(@as(usize, 1), blocks.len);
    try std.testing.expectEqualStrings("tool_use", blocks[0].object.get("type").?.string);
}

test "an anthropic error body surfaces the provider's message to the caller" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const body =
        \\{"error":{"message":"model: claude-nope not found","type":"not_found_error"}}
    ;
    var detail: ?[]const u8 = null;
    try std.testing.expectError(error.ApiError, parseResponse(arena, body, &detail));
    try std.testing.expectEqualStrings("model: claude-nope not found", detail.?);
    try std.testing.expectEqualStrings("model: claude-nope not found", parseErrorDetail(arena, body).?);
}

test "anthropic stream frames decode into neutral events" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // Frames taken from the Messages streaming docs, tool-use example.
    const start = (try parseStreamEvent(arena,
        \\{"type":"message_start","message":{"usage":{"input_tokens":472,"cache_read_input_tokens":8,"output_tokens":2}}}
    )).?;
    try std.testing.expectEqual(@as(u32, 480), start.usage.?.prompt.?.tokens);
    try std.testing.expectEqual(@as(u32, 8), start.usage.?.prompt.?.cache_hit_tokens);
    try std.testing.expectEqual(@as(u32, 2), start.usage.?.completion.?);

    // A text block must not claim a tool-call slot.
    try std.testing.expect(try parseStreamEvent(arena,
        \\{"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}}
    ) == null);
    try std.testing.expect(try parseStreamEvent(arena, "{\"type\":\"ping\"}") == null);

    const text = (try parseStreamEvent(arena,
        \\{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"Okay"}}
    )).?;
    try std.testing.expectEqualStrings("Okay", text.text.?);

    const tool_start = (try parseStreamEvent(arena,
        \\{"type":"content_block_start","index":1,"content_block":{"type":"tool_use","id":"toolu_01T1","name":"get_weather","input":{}}}
    )).?;
    try std.testing.expectEqual(@as(usize, 1), tool_start.tool_calls[0].index);
    try std.testing.expectEqualStrings("toolu_01T1", tool_start.tool_calls[0].id.?);
    try std.testing.expectEqualStrings("get_weather", tool_start.tool_calls[0].name.?);
    try std.testing.expect(tool_start.tool_calls[0].arguments == null);

    const frag = (try parseStreamEvent(arena,
        \\{"type":"content_block_delta","index":1,"delta":{"type":"input_json_delta","partial_json":"{\"location\":"}}
    )).?;
    try std.testing.expectEqual(@as(usize, 1), frag.tool_calls[0].index);
    try std.testing.expectEqualStrings("{\"location\":", frag.tool_calls[0].arguments.?);

    // thinking_delta and signature_delta carry neither text nor a json
    // fragment, so they are ignored rather than treated as errors.
    try std.testing.expect(try parseStreamEvent(arena,
        \\{"type":"content_block_delta","index":0,"delta":{"type":"thinking_delta","thinking":"ignored"}}
    ) == null);

    // message_delta carries the stop reason and output tokens only: the
    // prompt half must stay null so a previous frame's numbers survive.
    const end = (try parseStreamEvent(arena,
        \\{"type":"message_delta","delta":{"stop_reason":"tool_use"},"usage":{"output_tokens":89}}
    )).?;
    try std.testing.expectEqualStrings("tool_use", end.finish_reason.?);
    try std.testing.expect(end.usage.?.prompt == null);
    try std.testing.expectEqual(@as(u32, 89), end.usage.?.completion.?);

    try std.testing.expect(try parseStreamEvent(arena, "{\"type\":\"message_stop\"}") == null);
    try std.testing.expect(try parseStreamEvent(arena, "not json") == null);
}

test "the whole tool-use stream folds into one usage total" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var acc: types.Usage = .{};
    const frames = [_][]const u8{
        \\{"type":"message_start","message":{"usage":{"input_tokens":472,"cache_read_input_tokens":8,"output_tokens":2}}}
        ,
        \\{"type":"message_delta","delta":{"stop_reason":"end_turn"},"usage":{"output_tokens":89}}
        ,
    };
    for (frames) |f| {
        const ev = (try parseStreamEvent(arena, f)).?;
        if (ev.usage) |u| u.apply(&acc);
    }
    try std.testing.expectEqual(@as(u32, 480), acc.prompt_tokens);
    try std.testing.expectEqual(@as(u32, 8), acc.prompt_cache_hit_tokens);
    try std.testing.expectEqual(@as(u32, 89), acc.completion_tokens);
    try std.testing.expectEqual(@as(u32, 569), acc.total_tokens);
}

test "fuzz: anthropic stream events never hang or crash on malformed payloads" {
    // parseStreamEvent parses whatever the wire sends as a stream frame,
    // including a bare `index` field that used to drive an unbounded
    // call_args/call_ids/call_names growth loop in the core (index:
    // 999999999999 would try to allocate that many slots). The property here
    // is just: no crash, no unbounded allocation, for any bytes.
    const F = struct {
        fn one(_: void, smith: *std.testing.Smith) anyerror!void {
            var buf: [4096]u8 = undefined;
            const len = smith.slice(&buf);
            const payload = buf[0..len];

            var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
            defer arena_state.deinit();
            _ = try parseStreamEvent(arena_state.allocator(), payload);
        }
    };
    try std.testing.fuzz({}, F.one, .{});
}

test "oauth token prefix matching is version-agnostic" {
    try std.testing.expect(isOauthToken("sk-ant-oat01-abc"));
    try std.testing.expect(isOauthToken("sk-ant-oat02-abc"));
    try std.testing.expect(!isOauthToken("sk-ant-api03-abc"));
    try std.testing.expect(!isOauthToken(""));
    try std.testing.expectEqual(auth.Strategy.oauth_static, detectStrategy("sk-ant-oat01-abc"));
    try std.testing.expectEqual(auth.Strategy.api_key, detectStrategy("sk-ant-api03-abc"));
}

test "an api key goes on x-api-key, an oauth token on Authorization plus the beta" {
    var headers: std.http.Client.Request.Headers = .{};
    var extra: api.ExtraHeaders = undefined;

    var n = authHeaders(.{ .value = "sk-ant-api03-secret", .bearer = "Bearer sk-ant-api03-secret", .strategy = .api_key }, &headers, &extra);
    try std.testing.expectEqual(@as(usize, 2), n);
    try std.testing.expectEqualStrings("x-api-key", extra[0].name);
    try std.testing.expectEqualStrings("sk-ant-api03-secret", extra[0].value);
    try std.testing.expectEqualStrings("anthropic-version", extra[1].name);
    // The token must not also be sent as a bearer; the API rejects both.
    try std.testing.expect(headers.authorization == .default);

    headers = .{};
    n = authHeaders(.{ .value = "sk-ant-oat01-secret", .bearer = "Bearer sk-ant-oat01-secret", .strategy = .oauth_static }, &headers, &extra);
    try std.testing.expectEqual(@as(usize, 2), n);
    try std.testing.expectEqualStrings("anthropic-beta", extra[0].name);
    try std.testing.expectEqualStrings(oauth_beta, extra[0].value);
    try std.testing.expectEqualStrings("Bearer sk-ant-oat01-secret", headers.authorization.override);

    // With no credential at all the version header still goes out.
    headers = .{};
    n = authHeaders(.{}, &headers, &extra);
    try std.testing.expectEqual(@as(usize, 1), n);
    try std.testing.expectEqualStrings("anthropic-version", extra[0].name);
}

test "anthropic endpoint url" {
    const p = config.Provider{ .name = "a", .kind = .anthropic, .base_url = "https://api.anthropic.com", .default_model = "x" };
    const url = try endpointUrl(std.testing.allocator, &p, false);
    defer std.testing.allocator.free(url);
    try std.testing.expectEqualStrings("https://api.anthropic.com/v1/messages", url);
}
