//! Minimal raw-socket HTTP framing shared by the webui server (cli.zig),
//! the SSE bus (serve/live.zig), and the test-only mock LLM server
//! (llm/mock_server.zig).
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
// Four 4 MiB image attachments expand to about 21.4 MiB as base64, with the
// task and JSON framing on top. Keep the transport ceiling slightly above
// that documented API payload while still bounding unauthenticated input.
pub const max_body_bytes: usize = 24 << 20;

/// Writes `bytes` to `fd` in full; fails when the fd errors or the peer
/// closes mid-way. The SSE bus (serve/live.zig) uses this to notice a
/// subscriber went away; plain HTTP responses use the swallowing
/// `writeAllFd` below.
pub fn writeAll(fd: std.posix.fd_t, bytes: []const u8) !void {
    var off: usize = 0;
    while (off < bytes.len) {
        const n = std.c.write(fd, bytes[off..].ptr, bytes.len - off);
        if (n <= 0) return error.Closed; // errno or a closed peer
        off += @intCast(n);
    }
}

/// Best-effort variant: HTTP response bodies are fire-and-forget (the
/// response status was already recorded, and a half-written body cannot be
/// retried). Errors are swallowed; callers that must learn the peer went
/// away use `writeAll`.
pub fn writeAllFd(fd: std.posix.fd_t, bytes: []const u8) void {
    writeAll(fd, bytes) catch {};
}

/// Whether `data` holds a whole request: headers, the blank line, and as many
/// body bytes as the headers declared.
pub fn requestComplete(data: []const u8) bool {
    const hdr_end = std.mem.find(u8, data, "\r\n\r\n") orelse return false;
    const declared = switch (bodyFraming(data[0..hdr_end])) {
        .refused => return true, // answered with 400/501 before a body is read
        .length => |n| n,
        .none => 0,
    };
    // Saturating: hdr_end + 4 + declared overflowed usize on a large
    // Content-Length and panicked. A body that cannot fit in memory is treated
    // as complete so the caller answers it and closes rather than reading
    // forever; the handler then sees a body shorter than the header claimed,
    // which is the honest outcome for a request that lied.
    const needed = hdr_end +| 4 +| declared;
    if (declared > max_body_bytes) return true;
    return data.len >= needed;
}

/// How a request's body length is determined, per RFC 9112 §6.3.
pub const Framing = union(enum) {
    /// No body: no `Content-Length`, no `Transfer-Encoding`.
    none,
    /// The declared body length. Every `Content-Length` agreed on it.
    length: usize,
    /// The framing is ambiguous or is a coding this server does not speak.
    /// RFC 9112 §6.3 requires such a message to be rejected rather than
    /// interpreted, because two hops in front of each other reading the same
    /// bytes differently is request smuggling (CL.TE, TE.CL).
    refused,
};

/// Resolve the body framing of a request head (headers only, no CRLFCRLF).
///
/// Two shapes this used to accept by accident, both smuggling primitives:
///
///   - **Conflicting/duplicate `Content-Length`.** The scan took the first
///     header and ignored the rest, so `Content-Length: 0` followed by
///     `Content-Length: 42` framed a 0-byte request here and a 42-byte one at
///     any hop that counts. Two identical headers are equally refused: RFC 9112
///     §6.3.5 permits a proxy to normalize them only when it forwards the same
///     list it received, and nothing here is a normalizing proxy.
///   - **`Transfer-Encoding`.** The server has no chunked decoder, so a chunked
///     request read as a zero-length body and the chunk framing itself was
///     handed to handlers as if it were the payload. RFC 9110 §7.6.1 also makes
///     it unusable to send both `Transfer-Encoding` and `Content-Length`, so
///     that combination is the sharpest case of the TE.CL desync.
pub fn bodyFraming(headers: []const u8) Framing {
    var declared: ?usize = null;
    var lines = std.mem.splitSequence(u8, headers, "\r\n");
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t");
        if (trimmed.len == 0) continue;
        const colon = std.mem.indexOfScalar(u8, trimmed, ':') orelse continue;
        const name = trimmed[0..colon];
        const value = std.mem.trim(u8, trimmed[colon + 1 ..], " \t");
        if (std.ascii.eqlIgnoreCase(name, "transfer-encoding")) {
            // An empty value is a TE header with no coding, which RFC 9112
            // §6.1 forbids a sender from sending and gives a receiver no way to
            // resolve; it is refused with the rest rather than read as "no
            // body", which is the framing a second hop could disagree with.
            return .refused;
        } else if (std.ascii.eqlIgnoreCase(name, "content-length")) {
            // A single field may itself carry a comma-separated list
            // (`Content-Length: 5, 5`), which RFC 9110 §5.3 allows a proxy to
            // collapse. Anything but one bare decimal is refused rather than
            // guessed at.
            if (std.mem.indexOfScalar(u8, value, ',') != null) return .refused;
            const n = std.fmt.parseInt(usize, value, 10) catch return .refused;
            // Any second `Content-Length`, agreeing or not, is the duplicate
            // RFC 9112 §6.3.5 says to refuse rather than resolve.
            if (declared != null) return .refused;
            declared = n;
        }
    }
    if (declared) |n| return .{ .length = n };
    return .none;
}

/// True when the head's framing is ambiguous or unsupported, so the caller can
/// refuse the request before reading a body it cannot correctly delimit.
pub fn framingRefused(headers: []const u8) bool {
    return bodyFraming(headers) == .refused;
}

/// The declared body length, or null when the header is absent, unusable, or
/// the head's framing is refused. A value that does not fit a usize is not
/// clamped to something plausible: it is refused, because a request declaring
/// more than the address space is not a request with a big body, it is a
/// malformed one.
pub fn parseContentLength(headers: []const u8) ?usize {
    return switch (bodyFraming(headers)) {
        .length => |n| n,
        .none, .refused => null,
    };
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
    const over = "POST / HTTP/1.1\r\nContent-Length: 33554432\r\n\r\n";
    try std.testing.expect(requestComplete(over));
}

test "transport limit admits four base64 encoded image attachments" {
    // Four maximum-sized decoded images occupy ceil(n/3)*4 bytes each in
    // JSON. This is the largest payload shape the run endpoint advertises.
    const encoded_images = 4 * ((4 * 1024 * 1024 + 2) / 3 * 4);
    try std.testing.expect(encoded_images < max_body_bytes);
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
    // A header whose *name* merely contains the string is not a length header.
    try std.testing.expectEqual(@as(?usize, null), parseContentLength("X-Content-Length: 9"));
}

test "a request whose body framing is ambiguous or undecodable is refused" {
    // CL.TE: one hop reads Content-Length, the next reads chunked. Neither
    // value is guessed at here (RFC 9112 §6.3).
    try std.testing.expect(bodyFraming("Content-Length: 6\r\nTransfer-Encoding: chunked") == .refused);
    try std.testing.expect(framingRefused("Content-Length: 6\r\nTransfer-Encoding: chunked"));
    // TE alone: this server has no chunked decoder, so it cannot delimit the
    // body at all.
    try std.testing.expect(bodyFraming("Transfer-Encoding: chunked") == .refused);
    // TE with an empty value is still a TE header, and RFC 9112 §6.1 says a
    // sender must not send an empty one.
    try std.testing.expect(bodyFraming("Transfer-Encoding:") == .refused);
    // Two headers disagreeing: the first-wins scan this replaced framed a
    // 0-byte request here and a 42-byte one at the next hop.
    try std.testing.expect(bodyFraming("Content-Length: 0\r\nContent-Length: 42") == .refused);
    // Two headers agreeing is a duplicate too, and RFC 9110 §5.3 lets a proxy
    // collapse only a list it forwards unchanged.
    try std.testing.expect(bodyFraming("Content-Length: 5\r\nContent-Length: 5") == .refused);
    // A comma-separated list in one field is the same ambiguity spelled
    // inside a single line.
    try std.testing.expect(bodyFraming("Content-Length: 5, 5") == .refused);
    try std.testing.expect(bodyFraming("Content-Length: 5, 6") == .refused);

    // What must keep working: one length, several headers around it, and a
    // head with no body at all.
    try std.testing.expectEqual(Framing{ .length = 5 }, bodyFraming("Content-Length: 5"));
    try std.testing.expectEqual(Framing{ .length = 5 }, bodyFraming("Host: x\r\nContent-Length: 5\r\nAccept: */*"));
    try std.testing.expectEqual(Framing{ .length = 0 }, bodyFraming("Content-Length: 0"));
    try std.testing.expectEqual(Framing.none, bodyFraming("Host: x"));
    try std.testing.expectEqual(Framing.none, bodyFraming(""));
    try std.testing.expectEqual(Framing.none, bodyFraming("X-Content-Length: 9"));
}

test "a refused head ends the read, so the caller can answer 400" {
    // The refusal has to reach `requestComplete` as "complete", or the reader
    // waits for a body whose framing nobody can delimit and the connection
    // hangs until the read timeout instead of being answered.
    try std.testing.expect(requestComplete("POST / HTTP/1.1\r\nContent-Length: 0\r\nContent-Length: 42\r\n\r\n"));
    try std.testing.expect(requestComplete("POST / HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\n0\r\n\r\n"));
}

test "fuzz: no byte sequence makes the framing panic" {
    // These functions see whatever arrives on the socket, so the property under
    // test is simply that nothing crashes, whatever the bytes are.
    const Ctx = struct {
        fn one(_: void, smith: *std.testing.Smith) anyerror!void {
            var buf: [4096]u8 = undefined;
            const len = smith.slice(&buf);
            const input = buf[0..len];
            _ = requestComplete(input);
            _ = parseContentLength(input);
            _ = bodyFraming(input);
            _ = framingRefused(input);
        }
    };
    try std.testing.fuzz({}, Ctx.one, .{});
}
