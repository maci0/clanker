//! Minimal raw-socket HTTP framing shared by the webui server (cli.zig) and
//! the test-only mock LLM server (llm/mock_server.zig).
//!
//! Everything here reads bytes that arrived from a socket, so nothing here may
//! trust a length, a number, or the presence of a delimiter. A panic in this
//! file is a remote kill: `Content-Length: 18446744073709551615` used to
//! overflow the completeness check and take the whole process down, from one
//! connection, with no valid endpoint and no session.

const std = @import("std");

/// The reader in cli.zig stops accumulating past this, so a declared body
/// larger than it can never arrive and waiting for one is a hang. Kept here
/// because the framing decision belongs with the framing code.
pub const max_body_bytes: usize = 1 << 20;

pub fn writeAllFd(fd: std.posix.fd_t, bytes: []const u8) void {
    var off: usize = 0;
    while (off < bytes.len) {
        const n = std.c.write(fd, bytes[off..].ptr, bytes.len - off);
        if (n < 0) return; // errno
        off += @intCast(n);
    }
}

/// Whether `data` holds a whole request: headers, the blank line, and as many
/// body bytes as the headers declared.
pub fn requestComplete(data: []const u8) bool {
    const hdr_end = std.mem.indexOf(u8, data, "\r\n\r\n") orelse return false;
    const declared = parseContentLength(data[0..hdr_end]) orelse 0;
    // Saturating: hdr_end + 4 + declared overflowed usize on a large
    // Content-Length and panicked. A body that cannot fit in memory is treated
    // as complete so the caller answers it and closes rather than reading
    // forever; the handler then sees a body shorter than the header claimed,
    // which is the honest outcome for a request that lied.
    const needed = hdr_end +| 4 +| declared;
    if (declared > max_body_bytes) return true;
    return data.len >= needed;
}

/// The declared body length, or null when the header is absent or unusable.
/// A value that does not fit a usize is not clamped to something plausible:
/// it is refused, because a request declaring more than the address space is
/// not a request with a big body, it is a malformed one.
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

test "requestComplete waits for the declared body" {
    try std.testing.expect(!requestComplete("POST / HTTP/1.1\r\n"));
    try std.testing.expect(!requestComplete("POST / HTTP/1.1\r\nContent-Length: 5\r\n\r\nabc"));
    try std.testing.expect(requestComplete("POST / HTTP/1.1\r\nContent-Length: 5\r\n\r\nabcde"));
    try std.testing.expect(requestComplete("GET / HTTP/1.1\r\nHost: x\r\n\r\n"));
}

test "a Content-Length that would overflow does not panic" {
    // The exact request that killed the server: the sum hdr_end + 4 + declared
    // wrapped, and the process died before it could answer anything.
    const huge = "POST / HTTP/1.1\r\nContent-Length: 18446744073709551615\r\n\r\n{}";
    try std.testing.expect(requestComplete(huge));

    // One below the maximum, and the maximum itself, both through the same path.
    const near = "POST / HTTP/1.1\r\nContent-Length: 18446744073709551614\r\n\r\n";
    try std.testing.expect(requestComplete(near));
}

test "a body larger than the reader will hold is not waited for" {
    const over = "POST / HTTP/1.1\r\nContent-Length: 2097152\r\n\r\n";
    try std.testing.expect(requestComplete(over));
}

test "parseContentLength refuses what it cannot represent" {
    try std.testing.expectEqual(@as(?usize, 5), parseContentLength("Content-Length: 5"));
    try std.testing.expectEqual(@as(?usize, 5), parseContentLength("content-length:  5  "));
    try std.testing.expectEqual(@as(?usize, 5), parseContentLength("X: 1\r\nCONTENT-LENGTH: 5"));
    try std.testing.expectEqual(@as(?usize, null), parseContentLength("Content-Length: "));
    try std.testing.expectEqual(@as(?usize, null), parseContentLength("Content-Length: -1"));
    try std.testing.expectEqual(@as(?usize, null), parseContentLength("Content-Length: 99999999999999999999999999"));
    try std.testing.expectEqual(@as(?usize, null), parseContentLength("Content-Length: abc"));
    try std.testing.expectEqual(@as(?usize, null), parseContentLength("Host: x"));
    try std.testing.expectEqual(@as(?usize, null), parseContentLength(""));
}

test "fuzz: no byte sequence makes the framing panic" {
    // These functions see whatever arrives on the socket, so the property under
    // test is simply that nothing crashes, whatever the bytes are.
    const Ctx = struct {
        fn one(_: void, input: []const u8) anyerror!void {
            _ = requestComplete(input);
            _ = parseContentLength(input);
        }
    };
    try std.testing.fuzz({}, Ctx.one, .{});
}
