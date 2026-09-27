//! Checked narrowing from a JSON number to a fixed-width integer.
//!
//! Model-supplied input reaches every guest as `f64`, and `@trunc` on a value
//! outside the destination's range is undefined behaviour: a trap in a checked
//! build and silent garbage in `ReleaseSmall`, which is what the wasm guests
//! ship as. `{"max_tokens": 1e30}` and `{"size": -5}` are both ordinary things
//! for a model to emit, and both are ordinary things a clamp applied *after*
//! the conversion cannot catch, because the conversion has already happened.
//!
//! So the range check has to come first, and every guest float-to-int read
//! goes through one of these rather than reaching for `@trunc` directly.

const std = @import("std");

/// The integer part of `f` as a `T`, or null when it does not fit: nan and inf
/// never do, a negative value never fits an unsigned type, and a value whose
/// integer part is past the type's range is refused rather than wrapped.
pub fn intFromFloat(comptime T: type, f: f64) ?T {
    if (!std.math.isFinite(f)) return null;
    // Sign is tested on `f`, not on the truncated value: `@trunc(-0.5)` is
    // `-0.0`, which compares `>= 0` and so would pass a check on the result
    // and turn a negative request into a zero-sized one.
    if (@typeInfo(T).int.signedness == .unsigned and f < 0) return null;
    const t = @trunc(f);
    // `maxInt` is not exactly representable as an f64 once the type is 64 bits
    // wide (it rounds to 2^63), so the upper bound is compared against the
    // first value past it rather than against maxInt itself.
    if (@typeInfo(T).int.signedness == .signed) {
        if (!(t >= -9223372036854775808.0 and t < 9223372036854775808.0)) return null;
    } else {
        if (!(t >= 0 and t < 18446744073709551616.0)) return null;
    }
    return @intFromFloat(t);
}

/// `intFromFloat` that also demands the value be integral. A count, a token
/// budget or a page size is a whole number; `2.5` is a caller mistake, and
/// truncating it silently reads as a different, plausible request.
pub fn intFromFloatExact(comptime T: type, f: f64) ?T {
    if (!std.math.isFinite(f)) return null;
    if (@trunc(f) != f) return null;
    return intFromFloat(T, f);
}

/// `f` clamped into `lo..=hi` as a `T`. For a caller that wants the nearest
/// legal value rather than a refusal: an out-of-range dimension is clamped to
/// the cap, not turned into a tool error.
pub fn clampInt(comptime T: type, f: f64, lo: T, hi: T) T {
    if (std.math.isNan(f)) return lo;
    if (intFromFloat(T, f)) |n| return @max(lo, @min(hi, n));
    // Out of range for T entirely, so compare against the endpoints in float
    // space. An inf compares correctly here; a nan was handled above.
    if (f < 0) return lo;
    return hi;
}

test "intFromFloat refuses what @trunc would corrupt" {
    try std.testing.expectEqual(@as(u32, 5), intFromFloat(u32, 5.9).?);
    try std.testing.expectEqual(@as(u32, 5), intFromFloat(u32, 5.0).?);
    try std.testing.expectEqual(@as(i64, -5), intFromFloat(i64, -5.9).?);
    try std.testing.expectEqual(@as(i32, 0), intFromFloat(i32, 0).?);

    // Every one of these is a trap in a checked build and garbage in
    // ReleaseSmall, which is how the guests are built.
    try std.testing.expect(intFromFloat(u32, -1) == null);
    try std.testing.expect(intFromFloat(u32, -0.5) == null);
    try std.testing.expect(intFromFloat(u32, 1e30) == null);
    try std.testing.expect(intFromFloat(u32, std.math.inf(f64)) == null);
    try std.testing.expect(intFromFloat(u32, -std.math.inf(f64)) == null);
    try std.testing.expect(intFromFloat(u32, std.math.nan(f64)) == null);
    try std.testing.expect(intFromFloat(usize, 1e30) == null);
    try std.testing.expect(intFromFloat(i32, 1e30) == null);
    try std.testing.expect(intFromFloat(i32, -1e30) == null);
}

test "intFromFloatExact additionally refuses a fraction" {
    try std.testing.expectEqual(@as(u32, 5), intFromFloatExact(u32, 5.0).?);
    try std.testing.expect(intFromFloatExact(u32, 2.5) == null);
    try std.testing.expect(intFromFloatExact(u32, std.math.nan(f64)) == null);
    try std.testing.expect(intFromFloatExact(u32, -0.0) != null);
}

test "clampInt saturates instead of refusing" {
    try std.testing.expectEqual(@as(u32, 800), clampInt(u32, 1e30, 1, 800));
    try std.testing.expectEqual(@as(u32, 800), clampInt(u32, std.math.inf(f64), 1, 800));
    try std.testing.expectEqual(@as(u32, 1), clampInt(u32, -5, 1, 800));
    try std.testing.expectEqual(@as(u32, 1), clampInt(u32, std.math.nan(f64), 1, 800));
    try std.testing.expectEqual(@as(u32, 640), clampInt(u32, 640.7, 1, 800));
    try std.testing.expectEqual(@as(i32, -1440), clampInt(i32, -1e30, -1440, 1440));
}
