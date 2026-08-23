//! Anthropic Claude OAuth plugin descriptor (manual PKCE with pasted callback code).

const api = @import("api.zig");

pub const plugin = api.Plugin{
    .name = "claude",
    .provider_kind = .claude,
    .flow = .pkce_manual,
    .token_encoding = .json,
    .exchange_state = true,
    .authorize_code_param = true,
    .client_id = "9d1c250a-e61b-44d9-88ed-5944d1962f5e",
    .authorize_url = "https://claude.com/cai/oauth/authorize",
    .token_url = "https://platform.claude.com/v1/oauth/token",
    .redirect_uri = "https://platform.claude.com/oauth/code/callback",
    .scopes = &.{ "user:profile", "user:inference", "user:sessions:claude_code", "user:mcp_servers", "user:file_upload" },
    .api_key_env = "ANTHROPIC_API_KEY",
    .api_base_url = "https://api.anthropic.com",
};
