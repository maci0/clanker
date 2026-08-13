//! Hardcoded per-use-case sampling defaults. Fills the gap
//! `writeSamplingParams` currently leaves empty when neither a per-run
//! override nor a model config value is set. Never overrides either.

const std = @import("std");
const config = @import("../config.zig");
const types = @import("types.zig");
const api = @import("providers/api.zig");

pub const UseCase = enum { chat, tool_use };

pub const Profile = struct {
    temperature: ?f64 = null,
    top_p: ?f64 = null,
    reasoning_effort: ?[]const u8 = null,
};

pub fn hasThinking(caps: []const []const u8) bool {
    for (caps) |c| {
        if (std.mem.eql(u8, c, "thinking") or std.mem.eql(u8, c, "always_thinking")) return true;
    }
    return false;
}

pub fn useCase(tools: ?[]const types.ToolDef) UseCase {
    return if (tools != null and tools.?.len > 0) .tool_use else .chat;
}

pub fn profile(use_case: UseCase, caps: []const []const u8) Profile {
    if (hasThinking(caps)) {
        return switch (use_case) {
            .chat => .{ .reasoning_effort = "medium" },
            .tool_use => .{ .reasoning_effort = "high" },
        };
    }
    return switch (use_case) {
        .chat => .{ .temperature = 0.7 },
        .tool_use => .{ .temperature = 0.0 },
    };
}

pub fn forParams(params: api.RequestParams) Profile {
    return profile(useCase(params.tools), params.provider.activeModel().capabilities);
}

test "non-thinking chat is 0.7, tool_use is 0.0" {
    try std.testing.expectEqual(@as(?f64, 0.7), profile(.chat, &.{}).temperature);
    try std.testing.expectEqual(@as(?f64, 0.0), profile(.tool_use, &.{}).temperature);
    try std.testing.expect(profile(.chat, &.{}).reasoning_effort == null);
}

test "thinking models get reasoning_effort and no temperature" {
    const caps = [_][]const u8{"thinking"};
    const chat = profile(.chat, &caps);
    try std.testing.expect(chat.temperature == null);
    try std.testing.expectEqualStrings("medium", chat.reasoning_effort.?);
    const tools = profile(.tool_use, &caps);
    try std.testing.expect(tools.temperature == null);
    try std.testing.expectEqualStrings("high", tools.reasoning_effort.?);
}

test "useCase is tool_use only when tools are actually offered" {
    try std.testing.expectEqual(UseCase.chat, useCase(null));
    try std.testing.expectEqual(UseCase.chat, useCase(&.{}));
}
