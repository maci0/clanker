const api = @import("api.zig");

pub const plugin = api.Plugin{
    .name = "grok",
    .provider_kind = .grok,
    .flow = .device_code,
    .client_id = "b1a00492-073a-47ea-816f-4c329264a828",
    .device_code_url = "https://auth.x.ai/oauth2/device/code",
    .device_token_url = "https://auth.x.ai/oauth2/token",
    .token_url = "https://auth.x.ai/oauth2/token",
    .scopes = &.{ "openid", "offline_access", "grok-cli:access" },
    .api_key_env = "XAI_API_KEY",
    .api_base_url = "https://api.x.ai/v1",
};
