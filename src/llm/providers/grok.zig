//! Native xAI Grok provider plugin using the Responses API.
const std = @import("std");
const api = @import("api.zig");
const config = @import("../../config.zig");
const common = @import("common.zig");
const responses = @import("responses.zig");

pub const provider: api.Provider = .{
    .kind = .grok,
    .auth = .{ .default = .api_key },
    .buildRequest = responses.buildRequest,
    .parseResponse = responses.parseResponse,
    .parseErrorDetail = responses.parseErrorDetail,
    .parseStreamEvent = responses.parseStreamEvent,
    .authHeaders = common.bearerAuthHeaders,
    .endpointUrl = endpointUrl,
};
fn endpointUrl(gpa: std.mem.Allocator, p: *const config.Provider, _: bool) anyerror![]u8 {
    return common.joinBaseAndPath(gpa, p, "/responses");
}
