//! HTTP request helpers for `clanker serve`.
//!
//! Framing lives in `util/raw_http.zig`; routes stay in `cli.zig`. This module
//! is the request-target, header, Host/Origin, gzip, ETag, and tool-JSON
//! status layer those routes share. It depends on `std` only, so the checks
//! can run without standing a server up.

const std = @import("std");

/// First matching header value, trimmed. Header names are matched
/// case-insensitively; the first occurrence wins.
pub fn headerValue(headers_raw: []const u8, name: []const u8) ?[]const u8 {
    var lines = std.mem.splitSequence(u8, headers_raw, "\r\n");
    while (lines.next()) |line| {
        const colon = std.mem.findScalar(u8, line, ':') orelse continue;
        if (!std.ascii.eqlIgnoreCase(line[0..colon], name)) continue;
        return std.mem.trim(u8, line[colon + 1 ..], " ");
    }
    return null;
}

/// Request-target without the query string. Resource ids live on the path;
/// a cache-busting `?t=` must not become part of the id.
pub fn requestPath(target: []const u8) []const u8 {
    if (std.mem.findScalar(u8, target, '?')) |i| return target[0..i];
    return target;
}

/// Decodes `%XX` escapes and `+` in a query-string value. Invalid escapes are
/// left as the literal characters they are rather than rejected: this feeds a
/// room-name comparison, and a name that fails to decode simply fails to match.
pub fn percentDecode(arena: std.mem.Allocator, s: []const u8) ![]const u8 {
    var out = try std.ArrayList(u8).initCapacity(arena, s.len);
    var i: usize = 0;
    while (i < s.len) {
        const c = s[i];
        if (c == '%' and i + 2 < s.len) {
            const hi = std.fmt.charToDigit(s[i + 1], 16) catch {
                try out.append(arena, c);
                i += 1;
                continue;
            };
            const lo = std.fmt.charToDigit(s[i + 2], 16) catch {
                try out.append(arena, c);
                i += 1;
                continue;
            };
            try out.append(arena, hi * 16 + lo);
            i += 3;
            continue;
        }
        try out.append(arena, if (c == '+') ' ' else c);
        i += 1;
    }
    return out.toOwnedSlice(arena);
}

pub fn toolResultFailed(out: []const u8) bool {
    return std.mem.startsWith(u8, std.mem.trimStart(u8, out, " \t\r\n"), "{\"ok\":false");
}

/// HTTP status for a tool JSON body. Success is 200. A refusal that names a
/// missing resource (`no such …`, `not found`) is 404; every other refusal
/// is a client mistake (400).
pub fn toolRefusalStatus(out: []const u8) u16 {
    if (!toolResultFailed(out)) return 200;
    return if (toolRefusalIsMissing(out)) 404 else 400;
}

fn toolRefusalIsMissing(out: []const u8) bool {
    const key = "\"error\":\"";
    const start = std.mem.find(u8, out, key) orelse return false;
    const rest = out[start + key.len ..];
    const end = std.mem.findScalar(u8, rest, '"') orelse return false;
    const msg = rest[0..end];
    return std.mem.startsWith(u8, msg, "no such") or
        std.mem.eql(u8, msg, "not found") or
        std.mem.endsWith(u8, msg, " not found");
}

pub fn httpReason(status: u16) []const u8 {
    return switch (status) {
        200 => "OK",
        400 => "Bad Request",
        403 => "Forbidden",
        404 => "Not Found",
        405 => "Method Not Allowed",
        409 => "Conflict",
        413 => "Content Too Large",
        421 => "Misdirected Request",
        429 => "Too Many Requests",
        500 => "Internal Server Error",
        501 => "Not Implemented",
        503 => "Service Unavailable",
        else => "Error",
    };
}

/// True when `value`, an HTTP authority, `host` or `host:port`, is one this
/// listener answers to. Shared by the `Host` and `Origin` guards below so the
/// two can never disagree: an address the Host guard admits would otherwise be
/// refused a second time as "cross-origin".
///
/// The rule exists for DNS rebinding, and DNS rebinding needs a *name* whose
/// resolution the attacker controls. An IP literal has no resolution step and
/// cannot be rebound, so any IP literal at this listener's port is accepted;
/// that is what makes `serve --host 0.0.0.0` reachable from the LAN. A name
/// can be rebound, so only `localhost` and the names an operator listed with
/// `--serve-as` pass, and `attacker.example:17921` stays refused however the
/// socket is bound.
///
/// The port has to be present and has to be this listener's, with one
/// deliberate exception: a bare name carrying no port is accepted when it is
/// in `serve_as_hosts`, because that is exactly what a reverse proxy
/// terminating on 443 forwards. A portless IP literal or `localhost` means
/// port 80, which is not this server, and nobody opted into it, so those stay
/// refused.
fn allowedAuthority(value: []const u8, port: u16, serve_as_hosts: []const []const u8) bool {
    var hostname = value;
    var port_text: ?[]const u8 = null;
    var bracketed = false;
    if (value.len > 0 and value[0] == '[') {
        // An IPv6 literal is bracketed in an authority precisely so its own
        // colons cannot be mistaken for the port separator.
        const close = std.mem.findScalar(u8, value, ']') orelse return false;
        hostname = value[1..close];
        bracketed = true;
        const rest = value[close + 1 ..];
        if (rest.len > 0) {
            if (rest[0] != ':') return false;
            port_text = rest[1..];
        }
    } else if (std.mem.findScalar(u8, value, ':')) |colon| {
        hostname = value[0..colon];
        const rest = value[colon + 1 ..];
        // A second colon is an unbracketed IPv6 literal, which is not a legal
        // authority. Refuse it rather than guess where the port begins.
        if (std.mem.findScalar(u8, rest, ':') != null) return false;
        port_text = rest;
    }
    if (hostname.len == 0) return false;

    if (port_text) |text| {
        const got = std.fmt.parseInt(u16, text, 10) catch return false;
        if (got != port) return false;
    } else {
        if (bracketed) return false;
        for (serve_as_hosts) |allowed| {
            if (std.ascii.eqlIgnoreCase(hostname, allowed)) return true;
        }
        return false;
    }

    // Parsed rather than pattern-matched, so "999.1.2.3" and "1.2.3.4.5" are
    // names that happen to look numeric, not addresses.
    if (bracketed) {
        _ = std.Io.net.IpAddress.parseIp6(hostname, port) catch return false;
        return true;
    }
    if (std.Io.net.IpAddress.parseIp4(hostname, port)) |_| {
        return true;
    } else |_| {}
    if (std.ascii.eqlIgnoreCase(hostname, "localhost")) return true;
    for (serve_as_hosts) |allowed| {
        if (std.ascii.eqlIgnoreCase(hostname, allowed)) return true;
    }
    return false;
}

/// True when the request carries an `Origin` header naming something other
/// than this server itself. Browsers attach `Origin` to every cross-site
/// fetch/XHR/form submission (and to same-origin ones too, which is why a
/// same-host origin is accepted alongside the missing-header case rather than
/// rejected as "not GET/HEAD").
///
/// Same authority rule as `unexpectedHost`: comparing against the two loopback
/// origins alone meant a LAN browser reaching a `--host 0.0.0.0` server could
/// load the page and then have every POST from it refused as cross-origin.
pub fn crossOriginRequest(headers_raw: []const u8, port: u16, serve_as_hosts: []const []const u8) bool {
    const origin = headerValue(headers_raw, "origin") orelse return false;
    const authority = if (std.mem.startsWith(u8, origin, "http://"))
        origin["http://".len..]
    else if (std.mem.startsWith(u8, origin, "https://"))
        origin["https://".len..]
    else
        return true;
    // An origin is a scheme and an authority and nothing else, so a path (or
    // "null", handled by the scheme check above) is malformed, not same-site.
    if (std.mem.findScalar(u8, authority, '/') != null) return true;
    return !allowedAuthority(authority, port, serve_as_hosts);
}

/// Refuse requests addressed through any authority this `clanker serve` does
/// not answer to; see `allowedAuthority` for the rule. This closes DNS
/// rebinding for both the state-changing API and sensitive GET endpoints.
/// HTTP/1.1 requires Host; treating a missing or duplicate Host as invalid
/// also avoids ambiguity between intermediaries and this deliberately small
/// parser.
pub fn unexpectedHost(headers_raw: []const u8, port: u16, serve_as_hosts: []const []const u8) bool {
    var lines = std.mem.splitSequence(u8, headers_raw, "\r\n");
    var authority: ?[]const u8 = null;
    while (lines.next()) |line| {
        const colon = std.mem.findScalar(u8, line, ':') orelse continue;
        if (!std.ascii.eqlIgnoreCase(line[0..colon], "host")) continue;
        if (authority != null) return true;
        authority = std.mem.trim(u8, line[colon + 1 ..], " \t");
    }
    const value = authority orelse return true;
    return !allowedAuthority(value, port, serve_as_hosts);
}

/// True when the request's Accept-Encoding lists gzip. Scoped to that header's
/// own line so a request target that happens to contain "gzip" cannot flip it.
/// A `*` wildcard (RFC 9110 §12.5.3) also makes gzip acceptable, unless an
/// explicit `gzip;q=0` in the same header refuses it: some hand-rolled clients
/// (curl with `--compressed` among them) negotiate with `*`, and those used to
/// get identity bytes for every asset. A q=0 on some *other* coding does not
/// matter: this server only ever offers gzip.
pub fn acceptsGzip(headers_raw: []const u8) bool {
    var wildcard_ok = false;
    var gzip_refused = false;
    var lines = std.mem.splitSequence(u8, headers_raw, "\r\n");
    while (lines.next()) |line| {
        const colon = std.mem.findScalar(u8, line, ':') orelse continue;
        if (!std.ascii.eqlIgnoreCase(line[0..colon], "accept-encoding")) continue;
        var codings = std.mem.splitScalar(u8, line[colon + 1 ..], ',');
        while (codings.next()) |coding_raw| {
            var parts = std.mem.splitScalar(u8, coding_raw, ';');
            const coding = std.mem.trim(u8, parts.next() orelse continue, " \t");
            const q_zero = blk: {
                while (parts.next()) |parameter_raw| {
                    const parameter = std.mem.trim(u8, parameter_raw, " \t");
                    const equals = std.mem.findScalar(u8, parameter, '=') orelse continue;
                    const name = std.mem.trim(u8, parameter[0..equals], " \t");
                    const value = std.mem.trim(u8, parameter[equals + 1 ..], " \t");
                    if (std.ascii.eqlIgnoreCase(name, "q") and isZeroQuality(value)) break :blk true;
                }
                break :blk false;
            };
            if (std.ascii.eqlIgnoreCase(coding, "gzip")) {
                if (q_zero) {
                    // An explicit refusal beats a wildcard elsewhere in the header.
                    gzip_refused = true;
                } else return true;
            } else if (std.ascii.eqlIgnoreCase(coding, "*") and !q_zero) {
                wildcard_ok = true;
            }
        }
    }
    return wildcard_ok and !gzip_refused;
}

fn isZeroQuality(value: []const u8) bool {
    if (value.len == 0 or value[0] != '0') return false;
    if (value.len == 1) return true;
    if (value[1] != '.') return false;
    for (value[2..]) |c| if (c != '0') return false;
    return true;
}

/// A weak content hash formatted as a quoted ETag value. Cheap enough (CRC32
/// over at most ~200 KB) to compute fresh per request instead of caching it:
/// it is orders of magnitude faster than the gzip pass already paid for above.
pub fn etagFor(buf: []u8, body: []const u8) []const u8 {
    return std.fmt.bufPrint(buf, "\"{x}\"", .{std.hash.Crc32.hash(body)}) catch unreachable;
}

/// True when the request's If-None-Match covers this ETag, meaning the client
/// already has this body cached and a 304 can skip resending it.
///
/// RFC 9110 13.1.2 requires two things beyond an exact string compare, and
/// both were missing. `If-None-Match: *` matches any current representation.
/// And the comparison is the *weak* one: `W/"x"` matches `"x"`. The second is
/// not a curiosity: intermediaries weaken ETags they re-encode (nginx's gzip
/// filter, for one, turns `"x"` into `W/"x"` on the way out), so a client
/// behind such a proxy revalidates with the weak form forever, and an exact
/// compare answers 200 with the full body to every one of those requests: a
/// cache that can never confirm freshness again. The tags this server hands
/// out are content hashes, so weak comparison of them is exact in practice.
pub fn ifNoneMatchHits(headers_raw: []const u8, etag: []const u8) bool {
    var lines = std.mem.splitSequence(u8, headers_raw, "\r\n");
    while (lines.next()) |line| {
        if (!std.ascii.startsWithIgnoreCase(line, "if-none-match:")) continue;
        var values = std.mem.tokenizeAny(u8, line["if-none-match:".len..], " ,");
        while (values.next()) |v| {
            if (std.mem.eql(u8, v, "*")) return true;
            const candidate = if (std.mem.startsWith(u8, v, "W/")) v[2..] else v;
            if (std.mem.eql(u8, candidate, etag)) return true;
        }
    }
    return false;
}

test "requestPath drops the query string and leaves a bare path alone" {
    try std.testing.expectEqualStrings("/api/sessions/abc", requestPath("/api/sessions/abc?t=1"));
    try std.testing.expectEqualStrings("/api/runs/run-1", requestPath("/api/runs/run-1"));
    try std.testing.expectEqualStrings("/api/knowledge", requestPath("/api/knowledge?"));
}

test "toolRefusalStatus maps missing resources to 404 and other refusals to 400" {
    try std.testing.expectEqual(@as(u16, 200), toolRefusalStatus("{\"ok\":true}"));
    try std.testing.expectEqual(@as(u16, 404), toolRefusalStatus("{\"ok\":false,\"error\":\"no such collection\"}"));
    try std.testing.expectEqual(@as(u16, 404), toolRefusalStatus("{\"ok\":false,\"error\":\"no such card\"}"));
    try std.testing.expectEqual(@as(u16, 404), toolRefusalStatus("{\"ok\":false,\"error\":\"not found\"}"));
    try std.testing.expectEqual(@as(u16, 400), toolRefusalStatus("{\"ok\":false,\"error\":\"need a title\"}"));
    try std.testing.expectEqual(@as(u16, 400), toolRefusalStatus("{\"ok\":false,\"error\":\"pick must be A, B or C\"}"));
}

test "percentDecode handles dm room names" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    try std.testing.expectEqualStrings("dm:a|b", try percentDecode(arena, "dm%3Aa%7Cb"));
    try std.testing.expectEqualStrings("dev", try percentDecode(arena, "dev"));
    try std.testing.expectEqualStrings("a b", try percentDecode(arena, "a+b"));
    // A stray percent is data, not an error.
    try std.testing.expectEqualStrings("100%", try percentDecode(arena, "100%"));
    try std.testing.expectEqualStrings("%zz", try percentDecode(arena, "%zz"));
}

test "unexpectedHost accepts IP literals, localhost and allowlisted names only" {
    const none: []const []const u8 = &.{};
    const allow: []const []const u8 = &.{ "clanker.lan", "Box.Tailnet.Ts.Net" };

    // Loopback, as before the --host flag existed.
    try std.testing.expect(!unexpectedHost("GET / HTTP/1.1\r\nHost: 127.0.0.1:4173\r\n", 4173, none));
    try std.testing.expect(!unexpectedHost("GET / HTTP/1.1\r\nhOsT: LOCALHOST:4173\r\n", 4173, none));

    // An IP literal cannot be rebound, so a LAN client reaching a
    // `--host 0.0.0.0` listener by address is served with nothing else set.
    try std.testing.expect(!unexpectedHost("GET / HTTP/1.1\r\nHost: 192.168.1.5:4173\r\n", 4173, none));
    try std.testing.expect(!unexpectedHost("GET / HTTP/1.1\r\nHost: 0.0.0.0:4173\r\n", 4173, none));
    try std.testing.expect(!unexpectedHost("GET / HTTP/1.1\r\nHost: [::1]:4173\r\n", 4173, none));
    try std.testing.expect(!unexpectedHost("GET / HTTP/1.1\r\nHost: [fe80::1]:4173\r\n", 4173, none));

    // A name can be, so it is refused until an operator names it.
    try std.testing.expect(unexpectedHost("GET / HTTP/1.1\r\nHost: attacker.example:4173\r\n", 4173, none));
    try std.testing.expect(unexpectedHost("GET / HTTP/1.1\r\nHost: clanker.lan:4173\r\n", 4173, none));
    try std.testing.expect(!unexpectedHost("GET / HTTP/1.1\r\nHost: clanker.lan:4173\r\n", 4173, allow));
    // Matched case-insensitively, in both directions.
    try std.testing.expect(!unexpectedHost("GET / HTTP/1.1\r\nHost: box.tailnet.ts.net:4173\r\n", 4173, allow));
    // Allowlisting a name does not allowlist every other one.
    try std.testing.expect(unexpectedHost("GET / HTTP/1.1\r\nHost: attacker.example:4173\r\n", 4173, allow));

    // The port is still this listener's, allowlisted or not.
    try std.testing.expect(unexpectedHost("GET / HTTP/1.1\r\nHost: localhost:9999\r\n", 4173, none));
    try std.testing.expect(unexpectedHost("GET / HTTP/1.1\r\nHost: clanker.lan:9999\r\n", 4173, allow));
    try std.testing.expect(unexpectedHost("GET / HTTP/1.1\r\nHost: 192.168.1.5:9999\r\n", 4173, none));
    try std.testing.expect(unexpectedHost("GET / HTTP/1.1\r\nHost: [::1]:9999\r\n", 4173, none));

    // Numeric-looking is not numeric: these are names, and unlisted ones.
    try std.testing.expect(unexpectedHost("GET / HTTP/1.1\r\nHost: 999.1.2.3:4173\r\n", 4173, none));
    try std.testing.expect(unexpectedHost("GET / HTTP/1.1\r\nHost: 1.2.3.4.5:4173\r\n", 4173, none));
    try std.testing.expect(unexpectedHost("GET / HTTP/1.1\r\nHost: 1.2.3:4173\r\n", 4173, none));
    try std.testing.expect(unexpectedHost("GET / HTTP/1.1\r\nHost: [not:an:address]:4173\r\n", 4173, none));
    // An unbracketed IPv6 literal is not a legal authority, and guessing where
    // its port starts is how a parser differs from the intermediary in front.
    try std.testing.expect(unexpectedHost("GET / HTTP/1.1\r\nHost: ::1:4173\r\n", 4173, none));
    try std.testing.expect(unexpectedHost("GET / HTTP/1.1\r\nHost: [::1\r\n", 4173, none));
    try std.testing.expect(unexpectedHost("GET / HTTP/1.1\r\nHost: :4173\r\n", 4173, none));

    // No port at all: refused, as before, unless the operator named it, which
    // is the reverse-proxy-on-443 case --serve-as exists for.
    try std.testing.expect(unexpectedHost("GET / HTTP/1.1\r\nHost: localhost\r\n", 4173, none));
    try std.testing.expect(unexpectedHost("GET / HTTP/1.1\r\nHost: 127.0.0.1\r\n", 4173, none));
    try std.testing.expect(unexpectedHost("GET / HTTP/1.1\r\nHost: [::1]\r\n", 4173, none));
    try std.testing.expect(unexpectedHost("GET / HTTP/1.1\r\nHost: clanker.lan\r\n", 4173, none));
    try std.testing.expect(!unexpectedHost("GET / HTTP/1.1\r\nHost: clanker.lan\r\n", 4173, allow));

    // Structural rejections, unchanged.
    try std.testing.expect(unexpectedHost("GET / HTTP/1.1\r\nUser-Agent: test\r\n", 4173, none));
    try std.testing.expect(unexpectedHost("GET / HTTP/1.1\r\nHost: localhost:4173\r\nHost: attacker.example\r\n", 4173, none));
    try std.testing.expect(unexpectedHost("GET / HTTP/1.1\r\nHost: 127.0.0.1:4173\r\nHost: 127.0.0.1:4173\r\n", 4173, none));
}

test "crossOriginRequest allows same-origin and no-Origin requests, refuses others" {
    const none: []const []const u8 = &.{};
    const allow: []const []const u8 = &.{"clanker.lan"};
    try std.testing.expect(!crossOriginRequest("POST /api/run HTTP/1.1\r\nHost: x\r\n", 4173, none));
    try std.testing.expect(!crossOriginRequest("POST /api/run HTTP/1.1\r\nOrigin: http://127.0.0.1:4173\r\n", 4173, none));
    try std.testing.expect(!crossOriginRequest("POST /api/run HTTP/1.1\r\nOrigin: http://localhost:4173\r\n", 4173, none));
    try std.testing.expect(crossOriginRequest("POST /api/run HTTP/1.1\r\nOrigin: http://evil.example:4173\r\n", 4173, none));
    try std.testing.expect(crossOriginRequest("POST /api/run HTTP/1.1\r\nOrigin: http://127.0.0.1:9999\r\n", 4173, none));
    try std.testing.expect(crossOriginRequest("POST /api/run HTTP/1.1\r\nOrigin: null\r\n", 4173, none));
    // The web UI a LAN client actually loaded posts back from that origin, so
    // refusing it made --host 0.0.0.0 serve a page that could not do anything.
    try std.testing.expect(!crossOriginRequest("POST /api/run HTTP/1.1\r\nOrigin: http://192.168.1.5:4173\r\n", 4173, none));
    try std.testing.expect(!crossOriginRequest("POST /api/run HTTP/1.1\r\nOrigin: http://[fe80::1]:4173\r\n", 4173, none));
    try std.testing.expect(crossOriginRequest("POST /api/run HTTP/1.1\r\nOrigin: http://clanker.lan:4173\r\n", 4173, none));
    try std.testing.expect(!crossOriginRequest("POST /api/run HTTP/1.1\r\nOrigin: http://clanker.lan:4173\r\n", 4173, allow));
    // A proxy terminating TLS in front of an allowlisted name.
    try std.testing.expect(!crossOriginRequest("POST /api/run HTTP/1.1\r\nOrigin: https://clanker.lan\r\n", 4173, allow));
    // A scheme that is not http(s), or an origin carrying a path, is not one
    // of ours however its authority reads.
    try std.testing.expect(crossOriginRequest("POST /api/run HTTP/1.1\r\nOrigin: file://localhost:4173\r\n", 4173, none));
    try std.testing.expect(crossOriginRequest("POST /api/run HTTP/1.1\r\nOrigin: http://localhost:4173/evil\r\n", 4173, none));
}

test "acceptsGzip only matches the header's own line" {
    try std.testing.expect(acceptsGzip("GET / HTTP/1.1\r\nAccept-Encoding: gzip, deflate\r\n"));
    try std.testing.expect(acceptsGzip("GET / HTTP/1.1\r\naccept-encoding:gzip\r\n"));
    try std.testing.expect(acceptsGzip("GET / HTTP/1.1\r\nAccept-Encoding: br, gzip;q=0.5\r\n"));
    try std.testing.expect(!acceptsGzip("GET / HTTP/1.1\r\nAccept-Encoding: gzip;q=0\r\n"));
    try std.testing.expect(!acceptsGzip("GET / HTTP/1.1\r\nAccept-Encoding: br, gzip; q=0.000\r\n"));
    try std.testing.expect(!acceptsGzip("GET /gzip.js HTTP/1.1\r\nHost: x\r\n"));
    try std.testing.expect(!acceptsGzip("GET / HTTP/1.1\r\nAccept-Encoding: br, zstd\r\n"));
    try std.testing.expect(!acceptsGzip(""));
}

test "acceptsGzip honors a * wildcard but never over an explicit refusal" {
    try std.testing.expect(acceptsGzip("GET / HTTP/1.1\r\nAccept-Encoding: *\r\n"));
    try std.testing.expect(acceptsGzip("GET / HTTP/1.1\r\nAccept-Encoding: br, zstd, *\r\n"));
    try std.testing.expect(acceptsGzip("GET / HTTP/1.1\r\nAccept-Encoding: *\r\nAccept-Encoding: gzip\r\n"));
    try std.testing.expect(!acceptsGzip("GET / HTTP/1.1\r\nAccept-Encoding: *;q=0\r\n"));
    try std.testing.expect(!acceptsGzip("GET / HTTP/1.1\r\nAccept-Encoding: gzip;q=0, *\r\n"));
    // Multiple header lines combine as if comma-joined; the explicit refusal
    // there beats the wildcard just as it does on one line.
    try std.testing.expect(!acceptsGzip("GET / HTTP/1.1\r\nAccept-Encoding: *\r\nAccept-Encoding: gzip;q=0\r\n"));
    // A wildcard with a nonzero quality is still a wildcard.
    try std.testing.expect(acceptsGzip("GET / HTTP/1.1\r\nAccept-Encoding: *;q=0.5, br\r\n"));
}

test "ifNoneMatchHits matches only its own header line and exact value" {
    try std.testing.expect(ifNoneMatchHits("GET / HTTP/1.1\r\nIf-None-Match: \"abc\", \"def\"\r\n", "\"def\""));
    try std.testing.expect(!ifNoneMatchHits("GET / HTTP/1.1\r\nIf-None-Match: \"abc\"\r\n", "\"def\""));
    try std.testing.expect(!ifNoneMatchHits("GET /x HTTP/1.1\r\nHost: If-None-Match: \"def\"\r\n", "\"def\""));
    try std.testing.expect(!ifNoneMatchHits("", "\"def\""));
}

test "ifNoneMatchHits honors weak comparison and the * form" {
    // A proxy that re-encodes the response weakens the tag; the client then
    // revalidates with W/ and must still get its 304.
    try std.testing.expect(ifNoneMatchHits("GET / HTTP/1.1\r\nIf-None-Match: W/\"def\"\r\n", "\"def\""));
    try std.testing.expect(ifNoneMatchHits("GET / HTTP/1.1\r\nIf-None-Match: \"abc\", W/\"def\"\r\n", "\"def\""));
    try std.testing.expect(ifNoneMatchHits("GET / HTTP/1.1\r\nIf-None-Match: *\r\n", "\"anything\""));
    // W/ is a prefix of the opaque tag, not a substring license.
    try std.testing.expect(!ifNoneMatchHits("GET / HTTP/1.1\r\nIf-None-Match: W/\"abc\"\r\n", "\"def\""));
    try std.testing.expect(!ifNoneMatchHits("GET / HTTP/1.1\r\nIf-None-Match: \"W/def\"\r\n", "\"def\""));
}

test "fuzz: header parsing never panics on bytes straight off the socket" {
    // headers_raw here is attacker-controlled the same way raw_http.zig's
    // framing input is: it comes from the raw bytes of an unauthenticated
    // connection to the listener, before any validation. These functions all
    // slice on colons/commas/semicolons/brackets found in that input, the same
    // category of bug that overflowed raw_http's Content-Length check.
    const Ctx = struct {
        fn one(_: void, smith: *std.testing.Smith) anyerror!void {
            var buf: [4096]u8 = undefined;
            const len = smith.slice(&buf);
            const headers_raw = buf[0..len];
            const allow: []const []const u8 = &.{"clanker.lan"};
            _ = headerValue(headers_raw, "origin");
            _ = crossOriginRequest(headers_raw, 4173, allow);
            _ = unexpectedHost(headers_raw, 4173, allow);
            _ = acceptsGzip(headers_raw);
            _ = ifNoneMatchHits(headers_raw, "\"abc\"");
        }
    };
    try std.testing.fuzz({}, Ctx.one, .{});
}
