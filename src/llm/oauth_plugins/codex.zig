//! OpenAI Codex OAuth plugin descriptor (two-stage device authorization,
//! then a PKCE token exchange).

const api = @import("api.zig");

pub const plugin = api.Plugin{
    .name = "codex",
    .provider_kind = .codex,
    .flow = .codex_device,
    .client_id = "app_EMoamEEZ73f0CkXaXp7hrann",
    .device_code_url = "https://auth.openai.com/api/accounts/deviceauth/usercode",
    .device_token_url = "https://auth.openai.com/api/accounts/deviceauth/token",
    .verification_url = "https://auth.openai.com/codex/device",
    .token_url = "https://auth.openai.com/oauth/token",
    .redirect_uri = "https://auth.openai.com/deviceauth/callback",
    .scopes = &.{ "openid", "profile", "email", "offline_access" },
    .api_key_env = "OPENAI_API_KEY",
    .api_base_url = "https://chatgpt.com/backend-api/codex",
};
