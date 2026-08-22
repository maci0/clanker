//! Canonical conversation and tool types shared by the LLM client,
//! the agent loop, and the eval/improve engines.

const std = @import("std");

pub const Role = enum {
    system,
    user,
    assistant,
    tool,

    pub fn asStr(self: Role) []const u8 {
        return switch (self) {
            .system => "system",
            .user => "user",
            .assistant => "assistant",
            .tool => "tool",
        };
    }
};

pub const ToolCall = struct {
    id: []const u8,
    name: []const u8,
    /// Raw JSON string of the call arguments.
    arguments: []const u8,
};

/// A multimodal image part: base64 payload + MIME type.
pub const ImagePart = struct {
    mime: []const u8,
    b64: []const u8,
};

pub const Message = struct {
    role: Role,
    content: ?[]const u8 = null,
    /// Multimodal images attached to this message (OpenAI-compat image_url
    /// blocks). When non-empty, `content` is the accompanying text.
    images: ?[]ImagePart = null,
    /// Present on assistant messages that requested tools.
    tool_calls: ?[]const ToolCall = null,
    /// Present on tool messages; links to the tool_call_id of a call.
    tool_call_id: ?[]const u8 = null,
    /// This user message was interjected mid-run (POST /api/steer, or the
    /// REPL composer during a turn), not typed as a turn of its own.
    /// `content` is the user's own words; the harness's framing sentence is
    /// applied to the *request* copy by
    /// [[agent/loop.zig:applySteerFraming]] and never stored, so a
    /// transcript reader is not shown the harness speaking as the user.
    /// The flag persists with the message (session store, transcript JSON)
    /// because the framing has to be re-applied identically on every later
    /// turn: a prefix that changes between requests busts the provider's
    /// prompt cache for everything after it.
    steered: bool = false,
};

pub const ToolDef = struct {
    name: []const u8,
    description: []const u8,
    /// JSON Schema object for the tool input.
    input_schema: std.json.Value,
    /// If true, the tool is loaded and runnable but hidden from the LLM catalog.
    internal: bool = false,
};

pub const Usage = struct {
    prompt_tokens: u32 = 0,
    completion_tokens: u32 = 0,
    total_tokens: u32 = 0,
    /// Prompt tokens served from the provider's prompt cache.
    prompt_cache_hit_tokens: u32 = 0,
    /// Prompt tokens NOT served from cache (computed when the provider only
    /// reports hits: prompt_tokens - hit).
    prompt_cache_miss_tokens: u32 = 0,
};

pub const ChatResponse = struct {
    message: Message,
    usage: ?Usage = null,
    finish_reason: ?[]const u8 = null,
    /// Chain-of-thought text, when the provider separates it
    /// (e.g. DeepSeek's reasoning_content). Arena-owned.
    reasoning: ?[]const u8 = null,
    /// Full raw response body (arena-owned).
    raw: ?[]const u8 = null,
    /// Time from request start to the first content delta (streaming only;
    /// null on a non-streaming call, where the whole response arrives at
    /// once and the number would just restate the total).
    ttft_ms: ?u64 = null,
};

// ---------------------------------------------------------------------------
// tests
// ---------------------------------------------------------------------------

test "role strings" {
    try std.testing.expectEqualStrings("assistant", Role.assistant.asStr());
}
