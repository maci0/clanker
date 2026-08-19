//! translate: a transform plugin. When enabled it sits after every tool call,
//! asks the model to translate the human-readable text in the result, and hands
//! the rewritten payload to the next layer.
//!
//! Input:  {"tool": "<wrapped tool>", "phase": "after", "payload": "<json>"}
//! Output: {"ok": true, "payload": "<rewritten json>"}
//!
//! Settings come from the `config` object in tools/manifests/translate.tool.json:
//!   lang       target language (default "en")
//!   provider   provider name for the translation call (default: the agent's)
//!   model      model name within that provider
//!   max_tokens output cap for the call
//! The harness reads provider/model/max_tokens to aim ck_llm; `lang` is ours.

const std = @import("std");
const lib = @import("lib.zig");
const model_reply = @import("model_reply.zig");

const Settings = struct {
    lang: []const u8 = "en",
};

const Request = struct {
    tool: []const u8 = "",
    phase: []const u8 = "",
    payload: []const u8 = "",
};

export fn run(ptr: u32, len: u32) callconv(.c) u64 {
    return lib.run(ptr, len, tool_main);
}

fn tool_main(input: []const u8, out: *lib.Out) !void {
    const alloc = lib.alloc;
    const req = std.json.parseFromSliceLeaky(Request, alloc, input, .{ .ignore_unknown_fields = true }) catch
        return lib.fail(out, "input is not a transform request");
    if (req.payload.len == 0) return lib.fail(out, "empty payload");

    const settings = std.json.parseFromSliceLeaky(Settings, alloc, lib.config(), .{ .ignore_unknown_fields = true }) catch Settings{};

    const prompt = try std.fmt.allocPrint(alloc,
        \\Translate the human-readable text in this JSON tool result into {s}.
        \\
        \\Rules:
        \\- Return only the JSON, no fences and no commentary.
        \\- Keep the exact same structure, keys, and value types.
        \\- Leave identifiers, URLs, file paths, code, and numbers untouched.
        \\- If nothing needs translating, return the input unchanged.
        \\
        \\Tool: {s}
        \\
        \\{s}
    , .{ settings.lang, req.tool, req.payload });

    const answer = lib.llm(prompt) catch |err| {
        lib.log(2, @errorName(err));
        return lib.fail(out, "translation call failed");
    };

    const cleaned = model_reply.stripFence(answer);
    // A translation that is no longer JSON would corrupt the tool result for
    // every later layer, so it is dropped rather than passed on.
    const is_json = std.json.validate(alloc, cleaned) catch false;
    if (!is_json) return lib.fail(out, "model returned text that is not JSON");

    try lib.okPayload(out, cleaned);
}
