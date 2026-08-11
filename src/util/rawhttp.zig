//! Minimal raw-socket HTTP framing shared by the webui server (cli.zig) and
//! the test-only mock LLM server (llm/mock_server.zig).

const std = @import("std");

pub fn writeAllFd(fd: std.posix.fd_t, bytes: []const u8) void {
    var off: usize = 0;
    while (off < bytes.len) {
        const n = std.c.write(fd, bytes[off..].ptr, bytes.len - off);
        if (n < 0) return; // errno
        off += @intCast(n);
    }
}

pub fn requestComplete(data: []const u8) bool {
    if (std.mem.indexOf(u8, data, "\r\n\r\n")) |hdr_end| {
        const content_length = parseContentLength(data[0..hdr_end]) orelse 0;
        return data.len >= hdr_end + 4 + content_length;
    }
    return false;
}

pub fn parseContentLength(headers: []const u8) ?usize {
    var lines = std.mem.splitSequence(u8, headers, "\r\n");
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t");
        const prefix = "content-length:";
        if (trimmed.len >= prefix.len and std.ascii.eqlIgnoreCase(trimmed[0..prefix.len], prefix)) {
            const value = std.mem.trim(u8, trimmed[prefix.len..], " \t");
            return std.fmt.parseInt(usize, value, 10) catch null;
        }
    }
    return null;
}
