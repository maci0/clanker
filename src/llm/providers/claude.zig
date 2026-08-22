//! Native Claude OAuth plugin. The wire is Anthropic Messages; this distinct
//! registry entry binds it to clanker's Claude OAuth metadata while retaining
//! API-key support.
const std = @import("std");
const api = @import("api.zig");
const config = @import("../../config.zig");
const common = @import("common.zig");
const anthropic = @import("anthropic.zig");

pub const provider: api.Provider = .{
    .kind = .claude,
    .auth = .{ .default = .api_key },
    .proxy = .{ .family = .anthropic, .vtable_messages = true, .overlay_anthropic = true },
    .buildRequest = anthropic.provider.buildRequest,
    .parseResponse = anthropic.provider.parseResponse,
    .parseErrorDetail = anthropic.provider.parseErrorDetail,
    .parseStreamEvent = anthropic.provider.parseStreamEvent,
    .authHeaders = anthropic.provider.authHeaders,
    .endpointUrl = endpointUrl,
};
fn endpointUrl(gpa: std.mem.Allocator, p: *const config.Provider, _: bool) anyerror![]u8 {
    return common.joinBaseAndPath(gpa, p, "/v1/messages");
}
