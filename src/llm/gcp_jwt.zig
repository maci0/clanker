//! RS256 service-account assertions for Google's OAuth token endpoint.
//!
//! `std.crypto.Certificate.rsa` verifies signatures but cannot make them: it
//! has a PublicKey and no SecretKey. The pieces to build one are all in std
//! though, so signing is done here rather than by shelling out:
//!
//!   - `std.crypto.Certificate.der` parses the PKCS#8 key,
//!   - `std.crypto.ff` provides constant-time modular exponentiation,
//!   - `std.crypto.hash.sha2.Sha256` and `std.base64` do the rest.
//!
//! The signature itself is RSASSA-PKCS1-v1_5 (RFC 8017 §8.2.1): EMSA encode the
//! digest, then `s = m^d mod n`. `Modulus.pow` is the constant-time variant,
//! which is the one to use with a private exponent.

const std = @import("std");
const der = std.crypto.Certificate.der;
const Sha256 = std.crypto.hash.sha2.Sha256;

pub const max_modulus_bits = 4096;
const Modulus = std.crypto.ff.Modulus(max_modulus_bits);
const Fe = Modulus.Fe;

const b64url = std.base64.url_safe_no_pad;

/// The fields of a service account JSON that matter for signing.
pub const ServiceAccount = struct {
    client_email: []const u8 = "",
    private_key: []const u8 = "",
    token_uri: []const u8 = "https://oauth2.googleapis.com/token",
};

pub const Error = error{
    ServiceAccountIncomplete,
    PrivateKeyMalformed,
    ModulusTooLarge,
    SignFailed,
    OutOfMemory,
};

/// Builds a signed JWT bearer assertion for `scope`, valid for one hour.
/// `now_s` is the current Unix time; the caller has the clock.
pub fn assertion(
    arena: std.mem.Allocator,
    sa: ServiceAccount,
    scope: []const u8,
    now_s: i64,
) Error![]const u8 {
    if (sa.client_email.len == 0 or sa.private_key.len == 0) return error.ServiceAccountIncomplete;

    const header = "{\"alg\":\"RS256\",\"typ\":\"JWT\"}";
    const claims = try std.fmt.allocPrint(
        arena,
        "{{\"iss\":\"{s}\",\"scope\":\"{s}\",\"aud\":\"{s}\",\"iat\":{d},\"exp\":{d}}}",
        .{ sa.client_email, scope, sa.token_uri, now_s, now_s + 3600 },
    );

    const signing_input = try std.fmt.allocPrint(arena, "{s}.{s}", .{
        try b64(arena, header),
        try b64(arena, claims),
    });

    const key = try parsePkcs8(arena, sa.private_key);
    const sig = try signPkcs1v15(arena, key, signing_input);
    return std.fmt.allocPrint(arena, "{s}.{s}", .{ signing_input, try b64(arena, sig) });
}

fn b64(arena: std.mem.Allocator, data: []const u8) Error![]const u8 {
    const buf = try arena.alloc(u8, b64url.Encoder.calcSize(data.len));
    return b64url.Encoder.encode(buf, data);
}

/// The modulus and private exponent, big-endian, as stored in the key.
pub const RsaKey = struct {
    n: []const u8,
    d: []const u8,
};

/// Strips the PEM armor and pulls (n, d) out of a PKCS#8 RSA private key.
/// Layout: PrivateKeyInfo { version, algorithm, privateKey OCTET STRING },
/// whose contents are RSAPrivateKey { version, n, e, d, p, q, ... }.
pub fn parsePkcs8(arena: std.mem.Allocator, pem: []const u8) Error!RsaKey {
    const body = try pemBody(arena, pem);

    const info = der.Element.parse(body, 0) catch return error.PrivateKeyMalformed;
    const version = der.Element.parse(body, info.slice.start) catch return error.PrivateKeyMalformed;
    const algorithm = der.Element.parse(body, version.slice.end) catch return error.PrivateKeyMalformed;
    const key_octets = der.Element.parse(body, algorithm.slice.end) catch return error.PrivateKeyMalformed;

    const inner = body[key_octets.slice.start..key_octets.slice.end];
    const rsa_key = der.Element.parse(inner, 0) catch return error.PrivateKeyMalformed;
    const rsa_version = der.Element.parse(inner, rsa_key.slice.start) catch return error.PrivateKeyMalformed;
    const modulus = der.Element.parse(inner, rsa_version.slice.end) catch return error.PrivateKeyMalformed;
    const pub_exp = der.Element.parse(inner, modulus.slice.end) catch return error.PrivateKeyMalformed;
    const priv_exp = der.Element.parse(inner, pub_exp.slice.end) catch return error.PrivateKeyMalformed;

    return .{
        // DER integers carry a leading zero byte when the high bit is set.
        .n = trimLeadingZeros(inner[modulus.slice.start..modulus.slice.end]),
        .d = trimLeadingZeros(inner[priv_exp.slice.start..priv_exp.slice.end]),
    };
}

/// Returns `bytes` with leading zero bytes stripped, but never empty: DER
/// integers carry a leading zero byte when the high bit is set (sign
/// padding), and a value of zero must stay a single 0x00. The empty case is
/// unreachable from a valid RSAPrivateKey but guarded so this cannot index
/// out of bounds (`bytes.len - 1` underflows on an empty slice).
fn trimLeadingZeros(bytes: []const u8) []const u8 {
    if (bytes.len == 0) return bytes;
    var i: usize = 0;
    while (i < bytes.len - 1 and bytes[i] == 0) i += 1;
    return bytes[i..];
}

/// Decodes the base64 between the BEGIN/END lines of a PEM block.
fn pemBody(arena: std.mem.Allocator, pem: []const u8) Error![]const u8 {
    const begin = std.mem.find(u8, pem, "-----BEGIN") orelse return error.PrivateKeyMalformed;
    const begin_eol = std.mem.findScalarPos(u8, pem, begin, '\n') orelse return error.PrivateKeyMalformed;
    const end = std.mem.findPos(u8, pem, begin_eol, "-----END") orelse return error.PrivateKeyMalformed;

    var clean: std.ArrayList(u8) = .empty;
    for (pem[begin_eol + 1 .. end]) |c| {
        if (c == '\n' or c == '\r' or c == ' ' or c == '\t') continue;
        try clean.append(arena, c);
    }
    const decoder = std.base64.standard.Decoder;
    const len = decoder.calcSizeForSlice(clean.items) catch return error.PrivateKeyMalformed;
    const out = try arena.alloc(u8, len);
    decoder.decode(out, clean.items) catch return error.PrivateKeyMalformed;
    return out;
}

/// RSASSA-PKCS1-v1_5 over SHA-256.
fn signPkcs1v15(arena: std.mem.Allocator, key: RsaKey, message: []const u8) Error![]const u8 {
    if (key.n.len * 8 > max_modulus_bits) return error.ModulusTooLarge;

    var digest: [Sha256.digest_length]u8 = undefined;
    Sha256.hash(message, &digest, .{});

    // DigestInfo for SHA-256, DER-encoded, per RFC 8017 §9.2 note 1.
    const prefix = [_]u8{
        0x30, 0x31, 0x30, 0x0d, 0x06, 0x09, 0x60, 0x86, 0x48, 0x01,
        0x65, 0x03, 0x04, 0x02, 0x01, 0x05, 0x00, 0x04, 0x20,
    };

    const k = key.n.len;
    // 0x00 || 0x01 || PS (0xff, >= 8 bytes) || 0x00 || DigestInfo
    if (k < prefix.len + digest.len + 11) return error.SignFailed;
    const em = try arena.alloc(u8, k);
    @memset(em, 0xff);
    em[0] = 0x00;
    em[1] = 0x01;
    const t_start = k - prefix.len - digest.len;
    em[t_start - 1] = 0x00;
    @memcpy(em[t_start..][0..prefix.len], &prefix);
    @memcpy(em[t_start + prefix.len ..], &digest);

    const modulus = Modulus.fromBytes(key.n, .big) catch return error.SignFailed;
    const m = Fe.fromBytes(modulus, em, .big) catch return error.SignFailed;
    const d = Fe.fromBytes(modulus, key.d, .big) catch return error.SignFailed;
    // Constant-time: `pow` is the variant to use when the exponent is secret.
    const s = modulus.pow(m, d) catch return error.SignFailed;

    const out = try arena.alloc(u8, k);
    s.toBytes(out, .big) catch return error.SignFailed;
    return out;
}

// ------------------------------------------------------------------- tests --

test "pkcs1v15 signature verifies against the matching public key" {
    // A 2048-bit key generated for this test only; it signs nothing real.
    const pem = @embedFile("testdata/rsa_test_key.pem");
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const key = try parsePkcs8(arena, pem);
    const msg = "clanker.vertex.assertion";
    const sig = try signPkcs1v15(arena, key, msg);
    try std.testing.expectEqual(key.n.len, sig.len);

    // Verify with std's public-key path: if the padding, digest info, or
    // exponentiation were wrong, this rejects.
    const e = [_]u8{ 0x01, 0x00, 0x01 };
    const pk = try std.crypto.Certificate.rsa.PublicKey.fromBytes(&e, key.n);
    var sig_buf: [256]u8 = undefined;
    @memcpy(sig_buf[0..sig.len], sig);
    try std.crypto.Certificate.rsa.PKCS1v1_5Signature.verify(256, sig_buf, msg, pk, Sha256);
}

test "pem parsing rejects garbage" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    try std.testing.expectError(error.PrivateKeyMalformed, parsePkcs8(arena_state.allocator(), "not a pem"));
}

test "trimLeadingZeros strips sign padding but keeps a zero value" {
    // DER sign padding: a leading 0x00 before a high-bit-set byte is padding.
    try std.testing.expectEqualStrings("\x42", trimLeadingZeros("\x00\x42"));
    // Multiple padding zeros collapse down to the magnitude.
    try std.testing.expectEqualSlices(u8, &.{ 0x01, 0x02 }, trimLeadingZeros(&.{ 0x00, 0x00, 0x01, 0x02 }));
    // A value of zero keeps the single 0x00 that represents it.
    try std.testing.expectEqualSlices(u8, &.{0x00}, trimLeadingZeros(&.{0x00}));
    // An already-unpadded value passes through untouched.
    try std.testing.expectEqualSlices(u8, &.{ 0x42, 0x00 }, trimLeadingZeros(&.{ 0x42, 0x00 }));
    // An empty slice is returned as-is rather than indexing out of bounds.
    try std.testing.expectEqualSlices(u8, &.{}, trimLeadingZeros(&.{}));
}
