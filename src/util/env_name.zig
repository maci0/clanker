//! One rule for "is this string an environment variable name a shell can
//! actually export?", shared by the config keys that *name* a secret's source
//! (`providers.<name>.api_key_env`, `serve.proxy_token_env`) and the `.env`
//! loader that *defines* those names.
//!
//! Both sides treat a name they cannot resolve as "no secret configured"
//! rather than as a bad config, so an unexportable name is not a refusal --
//! it is a silently absent credential. That is why the check belongs here,
//! next to neither caller: config.zig cannot be imported by the util it feeds
//! (config owns the whole log/error surface), and duplicating the rule in
//! each would let them drift, which is exactly the drift this prevents.

const std = @import("std");

/// True when `name` is a spelling a shell will accept in `export NAME=...`
/// and a process environment can carry: non-empty, and no `=` or byte a shell
/// would treat as a separator or refuse to pass through. `Environ.Map.get`
/// answers null for anything else, which every caller here reads as "no
/// secret" rather than "your config is wrong".
pub fn isEnvVarName(name: []const u8) bool {
    if (name.len == 0) return false;
    for (name) |c| switch (c) {
        // Every POSIX shell accepts these in a name. `=` terminates the
        // assignment; space, NUL and the control bytes are separators or are
        // unrepresentable in a process environment, so a name holding one
        // can be written in a config file but never set for a child.
        'A'...'Z', 'a'...'z', '0'...'9', '_', '.', '-' => {},
        else => return false,
    };
    return true;
}

test "isEnvVarName accepts the spellings shells export and refuses the rest" {
    try std.testing.expect(isEnvVarName("CLANKER_PROXY_TOKEN"));
    try std.testing.expect(isEnvVarName("DEEPSEEK_API_KEY"));
    try std.testing.expect(isEnvVarName("A"));
    try std.testing.expect(isEnvVarName("9LIVES"));
    try std.testing.expect(isEnvVarName("my.var-1"));

    try std.testing.expect(!isEnvVarName(""));
    try std.testing.expect(!isEnvVarName("CLANKER PROXY TOKEN"));
    try std.testing.expect(!isEnvVarName("TOKEN=x"));
    try std.testing.expect(!isEnvVarName("CLANKER$PROXY"));
    try std.testing.expect(!isEnvVarName("TOKEN\nX"));
    try std.testing.expect(!isEnvVarName("TOKEN\tX"));
}
