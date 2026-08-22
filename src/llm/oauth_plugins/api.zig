//! Native OAuth provider-plugin contract. Plugins contain public protocol
//! metadata only; the native auth core owns PKCE, HTTP, tokens, and storage.

const std = @import("std");
const config = @import("../../config.zig");

pub const Flow = enum {
    /// RFC 8628 device authorization (xAI).
    device_code,
    /// OpenAI's two-stage device authorization, followed by a PKCE exchange.
    codex_device,
    /// Authorization URL opened by the operator; callback code pasted back.
    pkce_manual,
};
pub const TokenEncoding = enum { form, json };

pub const Plugin = struct {
    name: []const u8,
    provider_kind: config.ProviderKind,
    flow: Flow,
    token_encoding: TokenEncoding = .form,
    /// Claude binds the pasted callback to the authorization request twice:
    /// in the local state check and in the token exchange body.
    exchange_state: bool = false,
    authorize_code_param: bool = false,
    client_id: []const u8,
    authorize_url: []const u8 = "",
    device_code_url: []const u8 = "",
    device_token_url: []const u8 = "",
    verification_url: []const u8 = "",
    token_url: []const u8,
    redirect_uri: []const u8 = "",
    scopes: []const []const u8,
    api_key_env: []const u8,
    api_base_url: []const u8,

    pub fn validate(self: Plugin) !void {
        if (self.name.len == 0 or self.client_id.len == 0 or self.token_url.len == 0) return error.IncompleteOAuthPlugin;
        if (self.api_key_env.len == 0 or self.api_base_url.len == 0 or self.scopes.len == 0) return error.IncompleteOAuthPlugin;
        switch (self.flow) {
            .device_code, .codex_device => if (self.device_code_url.len == 0 or self.device_token_url.len == 0) return error.IncompleteOAuthPlugin,
            .pkce_manual => if (self.authorize_url.len == 0 or self.redirect_uri.len == 0) return error.IncompleteOAuthPlugin,
        }
        inline for (.{ self.token_url, self.api_base_url }) |url| {
            if (!std.mem.startsWith(u8, url, "https://")) return error.InsecureOAuthUrl;
        }
        if (self.redirect_uri.len > 0 and !std.mem.startsWith(u8, self.redirect_uri, "https://")) return error.InsecureOAuthUrl;
    }
};
