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

/// The smallest value `T` can hold, and the first value past the largest.
/// Neither `minInt` nor `maxInt` is exactly representable as an f64 once the
/// type is 64 bits wide (`maxInt(i64)` rounds to 2^63), so both bounds are
/// powers of two, which are exact at every width.
fn bounds(comptime T: type) struct { lo: f64, hi: f64 } {
    const info = @typeInfo(T).int;
    if (info.bits == 64) {
        return if (info.signedness == .signed)
            .{ .lo = -9223372036854775808.0, .hi = 9223372036854775808.0 }
        else
            .{ .lo = 0, .hi = 18446744073709551616.0 };
    }
    const exp: u6 = if (info.signedness == .signed) @intCast(info.bits - 1) else @intCast(info.bits);
    const hi: f64 = @floatFromInt(@as(u64, 1) << exp);
    return .{ .lo = if (info.signedness == .signed) -hi else 0, .hi = hi };
}

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
    const b = bounds(T);
    if (!(t >= b.lo and t < b.hi)) return null;
    // `@trunc` with an integer result type is the 0.16 form of the conversion;
    // the bound check above is what keeps it off an out-of-range value.
    return @trunc(t);
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

/// A parsed JSON integer clamped into `lo..=hi` as a `T`. The same hazard as
/// `clampInt` one step earlier in the parse: the `.integer` arm of a
/// `std.json.Value` is an unbounded `i64`, and the guests build as wasm32, so
/// `usize` is 32 bits there. A bound checked against the `i64` does not
/// survive the narrowing, and `{"max": 4294967296}` is a value a model emits
/// without thinking twice: `if (n < 1) 1 else @as(usize, @intCast(n))` passes
/// it and yields 0, so a walk bounded by `max` returns nothing at all.
pub fn clampJsonInt(comptime T: type, n: i64, lo: T, hi: T) T {
    // Both endpoints widen to i128 exactly, so the comparison is against the
    // value the cast will produce rather than against the i64 it came from.
    const wide: i128 = n;
    if (wide < @as(i128, lo)) return lo;
    if (wide > @as(i128, hi)) return hi;
    return @intCast(wide);
}

test "clampJsonInt bounds a parsed integer before the narrowing" {
    try std.testing.expectEqual(@as(usize, 5), clampJsonInt(usize, 5, 1, 100));
    try std.testing.expectEqual(@as(usize, 100), clampJsonInt(usize, 5000, 1, 100));
    try std.testing.expectEqual(@as(usize, 1), clampJsonInt(usize, 0, 1, 100));
    try std.testing.expectEqual(@as(usize, 1), clampJsonInt(usize, -7, 1, 100));
    // 2^32 is 0 as a wasm32 usize, and `max_commits - 1` off that is an
    // out-of-bounds slice in the guest.
    try std.testing.expectEqual(@as(u32, 100), clampJsonInt(u32, 4294967296, 1, 100));
    try std.testing.expectEqual(@as(u32, 100), clampJsonInt(u32, std.math.maxInt(i64), 1, 100));
    // Below the floor, so the low bound, and the widening holds for the
    // negative edge too (`minInt(i64)` reaches i128 exactly).
    try std.testing.expectEqual(@as(u32, 1), clampJsonInt(u32, std.math.minInt(i64), 1, 100));
    // A cap the type cannot represent would itself be a wrap, so the widest
    // legal destination value is still returned as itself.
    try std.testing.expectEqual(@as(u64, 4294967295), clampJsonInt(u64, 4294967295, 1, std.math.maxInt(u64)));
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

    // Wider than 64 bits' worth of checking would not catch: every one of
    // these is inside the f64 range a 64-bit bound admits, and inside the
    // range of the *type* only at the very edge. A bound hardcoded to 64 bits
    // let all four through to the unchecked conversion.
    try std.testing.expect(intFromFloat(u32, 5_000_000_000) == null);
    try std.testing.expectEqual(@as(u32, 4294967295), intFromFloat(u32, 4294967295).?);
    try std.testing.expect(intFromFloat(u16, 70000) == null);
    try std.testing.expect(intFromFloat(i32, 3_000_000_000) == null);
    try std.testing.expect(intFromFloat(i32, -3_000_000_000) == null);
    try std.testing.expectEqual(@as(i32, 2147483647), intFromFloat(i32, 2147483647).?);
    try std.testing.expectEqual(@as(i8, -128), intFromFloat(i8, -128.9).?);
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
    // Out of range for the type but not for a 64-bit check, so only the type's
    // own bound sends it to the saturating branch.
    try std.testing.expectEqual(@as(u32, 800), clampInt(u32, 5_000_000_000.0, 1, 800));
}
