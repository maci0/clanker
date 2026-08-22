const std = @import("std");
const api = @import("api.zig");
const codex = @import("codex.zig");
const grok = @import("grok.zig");
const claude = @import("claude.zig");

pub const plugins = [_]api.Plugin{ codex.plugin, grok.plugin, claude.plugin };

pub fn find(name: []const u8) ?*const api.Plugin {
    for (&plugins) |*plugin| if (std.mem.eql(u8, plugin.name, name)) return plugin;
    return null;
}

test "all shipped native OAuth plugins are valid and support an API key" {
    for (plugins) |plugin| {
        try plugin.validate();
        try std.testing.expect(plugin.api_key_env.len > 0);
    }
    try std.testing.expectEqualStrings("OPENAI_API_KEY", find("codex").?.api_key_env);
    try std.testing.expectEqualStrings("XAI_API_KEY", find("grok").?.api_key_env);
    try std.testing.expectEqualStrings("ANTHROPIC_API_KEY", find("claude").?.api_key_env);
    try std.testing.expect(find("acp") == null);
}
