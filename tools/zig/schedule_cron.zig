//! The 5-field cron subset `clanker schedule` accepts, and the arithmetic that
//! turns one into a next-fire timestamp. Pure: no allocator, no clock, no
//! filesystem, no `std.Io`. Host-tested helper so the schedule guest and the
//! native runner share one dialect. Everything here is a function of its
//! arguments, which is what makes the awkward parts, month lengths, leap
//! years, the day-of-month vs day-of-week rule, testable on the host without
//! a fixture.
//!
//! Dialect: `minute hour day-of-month month day-of-week`, each field one of
//! `*`, a number, `a-b`, `*/n`, `a-b/n`, or a comma-separated list of those.
//! Day-of-week is Sunday-based (`0` or `7` is Sunday). Names (`MON`, `JAN`)
//! are not accepted, nor are the `@hourly`-style nicknames or the seconds
//! field some crons add; a spec that parses here means the same thing it
//! would in Vixie cron rather than something subtly different.
//!
//! **Time zone.** Fields are interpreted in UTC shifted by a fixed offset the
//! entry carries (`tz_offset_minutes`), never in "local time" read from the
//! host. There is no time zone database in this binary, so a real local time
//! would mean guessing at DST, and an entry that silently fires at the wrong
//! hour twice a year is worse than one whose offset is written down. See
//! `docs/adrs/0009-schedule-fires-on-fixed-utc-offsets.md`.

const std = @import("std");

pub const ParseError = error{
    /// Not exactly five whitespace-separated fields.
    WrongFieldCount,
    /// A field, or a comma-separated element of one, was empty.
    EmptyField,
    /// A number that is not a number, or a stray character.
    BadNumber,
    /// A number outside the field's range.
    OutOfRange,
    /// `a-b` with `a` greater than `b`. Wrapping ranges are not accepted:
    /// `55-5` reads as a typo far more often than as "the turn of the hour".
    BadRange,
    /// A step of zero, or a step on a bare number (`5/10`), which different
    /// crons read differently. Write `5-59/10` or `*/10`.
    BadStep,
};

/// Number of minutes a fixed-offset time zone may be from UTC, either way.
/// Real offsets top out at +14:00/-12:00; the cap only exists so an absurd
/// value cannot push the civil-date arithmetic somewhere untested.
pub const max_tz_offset_minutes: i32 = 26 * 60;

/// A parsed spec. Each field is a bitset over the field's own range, so
/// matching is a shift and a mask rather than a re-parse per candidate minute.
pub const Spec = struct {
    /// bits 0..59
    minute: u64 = 0,
    /// bits 0..23
    hour: u32 = 0,
    /// bits 1..31
    dom: u32 = 0,
    /// bits 1..12
    month: u16 = 0,
    /// bits 0..6, Sunday = 0
    dow: u8 = 0,
    /// Whether the day-of-month field was written as a star (`*` or `*/n`).
    /// Needed on its own because the dom/dow rule below turns on *how the
    /// field was written*, not on which days it happens to select.
    dom_star: bool = true,
    dow_star: bool = true,

    /// Vixie cron's rule, which surprises people often enough to be worth
    /// stating: when both day fields are restricted the entry fires when
    /// *either* matches, not both. `0 0 13 * 5` is "the 13th, and every
    /// Friday", not "Friday the 13th". When one of them is a star, the other
    /// alone decides.
    pub fn dayMatches(self: Spec, day: u8, weekday: u8) bool {
        const by_dom = bit32(self.dom, day);
        const by_dow = bit8(self.dow, weekday);
        if (self.dom_star and self.dow_star) return true;
        if (self.dom_star) return by_dow;
        if (self.dow_star) return by_dom;
        return by_dom or by_dow;
    }

    /// The first fire time strictly after `after`, both in Unix seconds UTC,
    /// with the spec's fields read at `tz_offset_minutes` east of UTC.
    /// `null` when the spec cannot fire within `search_years`, either it
    /// never can (`0 0 30 2 *`) or it is rarer than the horizon.
    pub fn nextAfter(self: Spec, after: i64, tz_offset_minutes: i32) ?i64 {
        const offset_secs: i64 = @as(i64, tz_offset_minutes) * 60;
        // Everything below happens on the civil clock the fields describe;
        // only the answer is converted back.
        const local_after = after + offset_secs;
        // Strictly after: a spec is never allowed to re-fire the minute it
        // just fired on, which is what would turn one `run-due` into a loop.
        var t: i64 = @divFloor(local_after, 60) * 60 + 60;
        const start = civilFromEpoch(t);
        const horizon = start.year + search_years;

        // Bounded so a never-firing spec returns rather than spins. Each
        // iteration advances at least a minute and usually a whole day or
        // month, so the cap is far above any real spec's worst case.
        var steps: u32 = 0;
        while (steps < max_steps) : (steps += 1) {
            const c = civilFromEpoch(t);
            if (c.year > horizon) return null;
            if (!bit16(self.month, c.month)) {
                t = startOfNextMonth(c);
                continue;
            }
            if (!self.dayMatches(c.day, c.weekday)) {
                t = startOfDay(c) + std.time.s_per_day;
                continue;
            }
            if (!bit32(self.hour, c.hour)) {
                t = startOfHour(c) + std.time.s_per_hour;
                continue;
            }
            if (!bit64(self.minute, c.minute)) {
                t += std.time.s_per_min;
                continue;
            }
            return t - offset_secs;
        }
        return null;
    }
};

/// How far ahead `nextAfter` will look before giving up. Eight years clears
/// the worst legitimate case by a wide margin: `0 0 29 2 *` fires at most
/// four years apart, and the century rule (2100 is not a leap year) stretches
/// that to eight exactly once every 400 years.
const search_years: i32 = 8;

/// Loop cap for `nextAfter`. Month and day skips are whole jumps, so a real
/// spec needs a few thousand at most; the number only has to be big enough
/// that reaching it means the spec never fires.
const max_steps: u32 = 200_000;

fn bit64(mask: u64, n: u8) bool {
    if (n >= 64) return false;
    return (mask >> @intCast(n)) & 1 == 1;
}

fn bit32(mask: u32, n: u8) bool {
    if (n >= 32) return false;
    return (mask >> @intCast(n)) & 1 == 1;
}

fn bit16(mask: u16, n: u8) bool {
    if (n >= 16) return false;
    return (mask >> @intCast(n)) & 1 == 1;
}

fn bit8(mask: u8, n: u8) bool {
    if (n >= 8) return false;
    return (mask >> @intCast(n)) & 1 == 1;
}

/// Parses a whole spec. Leading, trailing and repeated whitespace between
/// fields are all fine, so a spec pasted out of a crontab keeps working.
pub fn parse(spec: []const u8) ParseError!Spec {
    const trimmed = std.mem.trim(u8, spec, " \t\r\n");
    var fields: [5][]const u8 = undefined;
    var count: usize = 0;
    var it = std.mem.tokenizeAny(u8, trimmed, " \t");
    while (it.next()) |f| {
        if (count == fields.len) return ParseError.WrongFieldCount;
        fields[count] = f;
        count += 1;
    }
    if (count != fields.len) return ParseError.WrongFieldCount;

    var out: Spec = .{};
    var star: bool = undefined;
    out.minute = @intCast(try parseField(fields[0], 0, 59, false, &star));
    out.hour = @intCast(try parseField(fields[1], 0, 23, false, &star));
    out.dom = @intCast(try parseField(fields[2], 1, 31, false, &out.dom_star));
    out.month = @intCast(try parseField(fields[3], 1, 12, false, &star));
    out.dow = @intCast(try parseField(fields[4], 0, 6, true, &out.dow_star));
    return out;
}

/// One field to a bitset over `lo..=hi`. `star` reports whether the field was
/// written as a star (`*`, or `*/n` over the whole range) rather than whether
/// it happens to select everything: `0-6` on day-of-week selects every day but
/// is still a restriction, and Vixie's dom/dow rule turns on the difference.
fn parseField(text: []const u8, lo: u8, hi: u8, sunday_alias: bool, star: *bool) ParseError!u64 {
    if (text.len == 0) return ParseError.EmptyField;
    // A star is the whole field being `*` or `*/n`, not merely starting with
    // one: `*/2,15` selects a set the writer chose, so the dom/dow rule must
    // treat it as the restriction it is.
    star.* = blk: {
        if (text[0] != '*') break :blk false;
        if (text.len == 1) break :blk true;
        if (text.len < 3 or text[1] != '/') break :blk false;
        for (text[2..]) |ch| {
            if (ch < '0' or ch > '9') break :blk false;
        }
        break :blk true;
    };

    var mask: u64 = 0;
    var it = std.mem.splitScalar(u8, text, ',');
    var any = false;
    while (it.next()) |raw| {
        any = true;
        const part = std.mem.trim(u8, raw, " \t");
        if (part.len == 0) return ParseError.EmptyField;

        // Split the optional /step off the base.
        var base = part;
        var step: u8 = 1;
        if (std.mem.findScalar(u8, part, '/')) |slash| {
            base = part[0..slash];
            const step_text = part[slash + 1 ..];
            if (step_text.len == 0) return ParseError.BadStep;
            step = parseNumber(step_text) catch return ParseError.BadStep;
            if (step == 0) return ParseError.BadStep;
        }
        if (base.len == 0) return ParseError.EmptyField;

        var from: u8 = undefined;
        var to: u8 = undefined;
        if (std.mem.eql(u8, base, "*")) {
            from = lo;
            to = hi;
        } else if (std.mem.findScalar(u8, base, '-')) |dash| {
            from = try boundedNumber(base[0..dash], lo, hi, sunday_alias);
            to = try boundedNumber(base[dash + 1 ..], lo, hi, sunday_alias);
            if (to < from) return ParseError.BadRange;
        } else {
            from = try boundedNumber(base, lo, hi, sunday_alias);
            to = from;
            // `5/10` means different things in different crons (Quartz reads
            // it as `5-59/10`, Vixie rejects it). Refusing is the only answer
            // that cannot silently do the wrong thing.
            if (step != 1) return ParseError.BadStep;
        }

        var v: u16 = from;
        while (v <= to) : (v += step) {
            // The Sunday alias again: `0-7/1` on day-of-week walks past 6.
            const day = if (sunday_alias and v == 7) @as(u8, 0) else @as(u8, @intCast(v));
            mask |= @as(u64, 1) << @intCast(day);
        }
    }
    if (!any) return ParseError.EmptyField;
    return mask;
}

/// A field element as the literal it was written as, range-checked. Day-of-week
/// accepts one past its upper bound because `7` is a second spelling of
/// Sunday; the 7-to-0 fold happens where bits are set, not here, so `5-7` stays
/// an ascending range instead of decoding to the backwards `5-0`.
fn boundedNumber(text: []const u8, lo: u8, hi: u8, sunday_alias: bool) ParseError!u8 {
    const n = try parseNumber(text);
    const ceiling = if (sunday_alias) hi + 1 else hi;
    if (n < lo or n > ceiling) return ParseError.OutOfRange;
    return n;
}

/// Digits only, and small enough that no field can overflow. `std.fmt.parseInt`
/// would also accept `+5` and `_` separators, which a crontab never means.
fn parseNumber(text: []const u8) ParseError!u8 {
    if (text.len == 0 or text.len > 3) return ParseError.BadNumber;
    var n: u16 = 0;
    for (text) |ch| {
        if (ch < '0' or ch > '9') return ParseError.BadNumber;
        n = n * 10 + (ch - '0');
        if (n > 255) return ParseError.BadNumber;
    }
    return @intCast(n);
}

// ------------------------------------------------------- civil date helpers --

pub const Civil = struct {
    year: i32,
    /// 1..12
    month: u8,
    /// 1..31
    day: u8,
    hour: u8,
    minute: u8,
    second: u8,
    /// 0..6, Sunday = 0
    weekday: u8,
};

/// Days from 1970-01-01 to y-m-d, proleptic Gregorian. Howard Hinnant's
/// `days_from_civil`, which is exact for every year in range and needs no
/// table of month lengths.
pub fn daysFromCivil(year: i32, month: u8, day: u8) i64 {
    var y: i64 = year;
    const m: i64 = month;
    y -= @intFromBool(m <= 2);
    const era: i64 = @divFloor(y, 400);
    const yoe: i64 = y - era * 400; // [0, 399]
    const doy: i64 = @divTrunc(153 * (m + (if (m > 2) @as(i64, -3) else 9)) + 2, 5) + day - 1; // [0, 365]
    const doe: i64 = yoe * 365 + @divTrunc(yoe, 4) - @divTrunc(yoe, 100) + doy; // [0, 146096]
    return era * 146097 + doe - 719468;
}

/// The inverse of `daysFromCivil` (Hinnant's `civil_from_days`), plus the
/// weekday, which falls out of the day number directly.
pub fn civilFromDays(z_in: i64) struct { year: i32, month: u8, day: u8, weekday: u8 } {
    const z = z_in + 719468;
    const era: i64 = @divFloor(z, 146097);
    const doe: i64 = z - era * 146097; // [0, 146096]
    const yoe: i64 = @divTrunc(doe - @divTrunc(doe, 1460) + @divTrunc(doe, 36524) - @divTrunc(doe, 146096), 365); // [0, 399]
    const y: i64 = yoe + era * 400;
    const doy: i64 = doe - (365 * yoe + @divTrunc(yoe, 4) - @divTrunc(yoe, 100)); // [0, 365]
    const mp: i64 = @divTrunc(5 * doy + 2, 153); // [0, 11]
    const d: i64 = doy - @divTrunc(153 * mp + 2, 5) + 1; // [1, 31]
    const m: i64 = mp + (if (mp < 10) @as(i64, 3) else -9); // [1, 12]
    // Day 0 (1970-01-01) was a Thursday; +4 puts Sunday at 0.
    const weekday: i64 = @mod(z_in + 4, 7);
    return .{
        .year = @intCast(y + @intFromBool(m <= 2)),
        .month = @intCast(m),
        .day = @intCast(d),
        .weekday = @intCast(weekday),
    };
}

/// Unix seconds to a civil date. `@divFloor`/`@mod` rather than truncation so
/// pre-1970 timestamps decompose correctly instead of landing an hour into
/// the wrong day.
pub fn civilFromEpoch(secs: i64) Civil {
    const days = @divFloor(secs, std.time.s_per_day);
    const rem = @mod(secs, std.time.s_per_day);
    const ymd = civilFromDays(days);
    return .{
        .year = ymd.year,
        .month = ymd.month,
        .day = ymd.day,
        .hour = @intCast(@divTrunc(rem, std.time.s_per_hour)),
        .minute = @intCast(@divTrunc(@mod(rem, std.time.s_per_hour), std.time.s_per_min)),
        .second = @intCast(@mod(rem, std.time.s_per_min)),
        .weekday = ymd.weekday,
    };
}

pub fn epochFromCivil(year: i32, month: u8, day: u8, hour: u8, minute: u8, second: u8) i64 {
    return daysFromCivil(year, month, day) * std.time.s_per_day +
        @as(i64, hour) * std.time.s_per_hour +
        @as(i64, minute) * std.time.s_per_min +
        @as(i64, second);
}

fn startOfDay(c: Civil) i64 {
    return epochFromCivil(c.year, c.month, c.day, 0, 0, 0);
}

fn startOfHour(c: Civil) i64 {
    return epochFromCivil(c.year, c.month, c.day, c.hour, 0, 0);
}

fn startOfNextMonth(c: Civil) i64 {
    const year = if (c.month == 12) c.year + 1 else c.year;
    const month: u8 = if (c.month == 12) 1 else c.month + 1;
    return epochFromCivil(year, month, 1, 0, 0, 0);
}

/// How many fire times fall in `(from, to]`. Used to say how many windows a
/// sleeping machine slept through; capped because a `*/1` entry that has not
/// run for a year would otherwise cost half a million iterations to count
/// exactly, for a number nobody reads past "a lot".
pub fn countBetween(spec: Spec, from: i64, to: i64, tz_offset_minutes: i32, cap: u32) u32 {
    var n: u32 = 0;
    var t = from;
    while (n < cap) {
        const next = spec.nextAfter(t, tz_offset_minutes) orelse return n;
        if (next > to) return n;
        n += 1;
        t = next;
    }
    return n;
}

/// Formats a Unix second as `YYYY-MM-DD HH:MM` at the given offset, for the
/// `schedule list` table. Here rather than in the command so the offset is
/// applied by the same code that interprets it.
pub fn formatStamp(buf: []u8, secs: i64, tz_offset_minutes: i32) []const u8 {
    const c = civilFromEpoch(secs + @as(i64, tz_offset_minutes) * 60);
    // Unsigned, because a zero-padded signed integer is formatted with an
    // explicit `+` and the year would come out as "+2026".
    const year: u32 = if (c.year < 0) 0 else @intCast(c.year);
    return std.fmt.bufPrint(buf, "{d:0>4}-{d:0>2}-{d:0>2} {d:0>2}:{d:0>2}", .{
        year, c.month, c.day, c.hour, c.minute,
    }) catch "????-??-?? ??:??";
}

/// Parses `+HH:MM` / `-HH:MM` / `UTC` / `Z` / `+HH` into minutes east of UTC.
/// A bare number is read as minutes, so `--tz-offset 60` and
/// `--tz-offset +01:00` mean the same thing.
pub fn parseOffset(text: []const u8) ParseError!i32 {
    const t = std.mem.trim(u8, text, " \t");
    if (t.len == 0) return ParseError.EmptyField;
    if (std.mem.eql(u8, t, "Z") or std.mem.eql(u8, t, "z") or
        std.mem.eql(u8, t, "UTC") or std.mem.eql(u8, t, "utc")) return 0;

    var rest = t;
    var sign: i32 = 1;
    if (rest[0] == '+' or rest[0] == '-') {
        if (rest[0] == '-') sign = -1;
        rest = rest[1..];
    }
    if (rest.len == 0) return ParseError.BadNumber;

    var minutes: i32 = undefined;
    if (std.mem.findScalar(u8, rest, ':')) |colon| {
        const hours = std.fmt.parseInt(i32, rest[0..colon], 10) catch return ParseError.BadNumber;
        const mins = std.fmt.parseInt(i32, rest[colon + 1 ..], 10) catch return ParseError.BadNumber;
        if (hours < 0 or mins < 0 or mins > 59) return ParseError.OutOfRange;
        minutes = hours * 60 + mins;
    } else {
        minutes = std.fmt.parseInt(i32, rest, 10) catch return ParseError.BadNumber;
        if (minutes < 0) return ParseError.BadNumber;
    }
    const signed = sign * minutes;
    if (signed > max_tz_offset_minutes or signed < -max_tz_offset_minutes) return ParseError.OutOfRange;
    return signed;
}

// ------------------------------------------------------------------- tests --

/// Test helper: the spec's next fire after a civil UTC instant, as a civil
/// UTC instant, so a test reads as "after this wall clock, then that one"
/// rather than as two epoch integers nobody can check by eye.
fn nextCivil(spec_text: []const u8, after: [5]i32, offset: i32) !Civil {
    const spec = try parse(spec_text);
    const t = epochFromCivil(after[0], @intCast(after[1]), @intCast(after[2]), @intCast(after[3]), @intCast(after[4]), 0);
    const next = spec.nextAfter(t, offset) orelse return error.NeverFires;
    return civilFromEpoch(next);
}

fn expectCivil(got: Civil, want: [5]i32) !void {
    try std.testing.expectEqual(want[0], got.year);
    try std.testing.expectEqual(@as(u8, @intCast(want[1])), got.month);
    try std.testing.expectEqual(@as(u8, @intCast(want[2])), got.day);
    try std.testing.expectEqual(@as(u8, @intCast(want[3])), got.hour);
    try std.testing.expectEqual(@as(u8, @intCast(want[4])), got.minute);
    try std.testing.expectEqual(@as(u8, 0), got.second);
}

test "civil date round-trips across leap years and century rules" {
    // 2000 is a leap year (divisible by 400), 1900 and 2100 are not. Getting
    // this wrong shifts every date after February by a day.
    const cases = [_][3]i32{
        .{ 1970, 1, 1 },
        .{ 1969, 12, 31 },
        .{ 1900, 3, 1 },
        .{ 2000, 2, 29 },
        .{ 2024, 2, 29 },
        .{ 2100, 2, 28 },
        .{ 2100, 3, 1 },
        .{ 2026, 8, 13 },
        .{ 2400, 12, 31 },
    };
    for (cases) |c| {
        const secs = epochFromCivil(c[0], @intCast(c[1]), @intCast(c[2]), 13, 37, 5);
        const back = civilFromEpoch(secs);
        try std.testing.expectEqual(c[0], back.year);
        try std.testing.expectEqual(@as(u8, @intCast(c[1])), back.month);
        try std.testing.expectEqual(@as(u8, @intCast(c[2])), back.day);
        try std.testing.expectEqual(@as(u8, 13), back.hour);
        try std.testing.expectEqual(@as(u8, 37), back.minute);
        try std.testing.expectEqual(@as(u8, 5), back.second);
    }
}

test "the epoch and some known dates land on the right weekday" {
    // 1970-01-01 was a Thursday; Sunday is 0, so Thursday is 4.
    try std.testing.expectEqual(@as(u8, 4), civilFromEpoch(0).weekday);
    // 2000-01-01 was a Saturday.
    try std.testing.expectEqual(@as(u8, 6), civilFromEpoch(epochFromCivil(2000, 1, 1, 0, 0, 0)).weekday);
    // 2026-08-13 is a Thursday.
    try std.testing.expectEqual(@as(u8, 4), civilFromEpoch(epochFromCivil(2026, 8, 13, 0, 0, 0)).weekday);
    // Every weekday appears exactly once across seven consecutive days, and
    // in order.
    var seen: u8 = 0;
    for (0..7) |i| {
        const wd = civilFromEpoch(epochFromCivil(2026, 8, 13, 0, 0, 0) + @as(i64, @intCast(i)) * std.time.s_per_day).weekday;
        seen |= @as(u8, 1) << @intCast(wd);
    }
    try std.testing.expectEqual(@as(u8, 0x7f), seen);
}

test "pre-1970 timestamps decompose with floor division, not truncation" {
    // Truncating toward zero puts a negative remainder into the hour field
    // and reports the day after the real one.
    const t = epochFromCivil(1969, 12, 31, 23, 30, 0);
    try std.testing.expect(t < 0);
    const c = civilFromEpoch(t);
    try std.testing.expectEqual(@as(i32, 1969), c.year);
    try std.testing.expectEqual(@as(u8, 12), c.month);
    try std.testing.expectEqual(@as(u8, 31), c.day);
    try std.testing.expectEqual(@as(u8, 23), c.hour);
    try std.testing.expectEqual(@as(u8, 30), c.minute);
}

test "field syntax: star, number, list, range and step" {
    const every = try parse("* * * * *");
    try std.testing.expectEqual(@as(u64, (1 << 60) - 1), every.minute);
    try std.testing.expectEqual(@as(u32, (1 << 24) - 1), every.hour);
    try std.testing.expect(every.dom_star and every.dow_star);

    const step = try parse("*/15 * * * *");
    try std.testing.expectEqual(@as(u64, (1 << 0) | (1 << 15) | (1 << 30) | (1 << 45)), step.minute);
    // `*/n` is still a star for the dom/dow rule.
    try std.testing.expect((try parse("* * */2 * *")).dom_star);

    const list = try parse("0,30 9,17 * * *");
    try std.testing.expectEqual(@as(u64, (1 << 0) | (1 << 30)), list.minute);
    try std.testing.expectEqual(@as(u32, (1 << 9) | (1 << 17)), list.hour);

    const range = try parse("0 9-11 * * *");
    try std.testing.expectEqual(@as(u32, (1 << 9) | (1 << 10) | (1 << 11)), range.hour);

    const ranged_step = try parse("5-30/10 * * * *");
    try std.testing.expectEqual(@as(u64, (1 << 5) | (1 << 15) | (1 << 25)), ranged_step.minute);

    // A mixed list of every form in one field.
    const mixed = try parse("0,5-9,*/20 * * * *");
    try std.testing.expect(bit64(mixed.minute, 0));
    try std.testing.expect(bit64(mixed.minute, 7));
    try std.testing.expect(bit64(mixed.minute, 20));
    try std.testing.expect(bit64(mixed.minute, 40));
    try std.testing.expect(!bit64(mixed.minute, 1));
    // A list is a restriction even when it starts with a star element.
    try std.testing.expect(!(try parse("0 0 */2,15 * *")).dom_star);
}

test "day-of-week takes 0 and 7 for Sunday, in ranges too" {
    try std.testing.expectEqual(@as(u8, 1 << 0), (try parse("0 0 * * 0")).dow);
    try std.testing.expectEqual(@as(u8, 1 << 0), (try parse("0 0 * * 7")).dow);
    // 5-7 is Friday, Saturday, Sunday, not a backwards range. Folding 7 to 0
    // before the range check is what used to make this one.
    try std.testing.expectEqual(@as(u8, (1 << 5) | (1 << 6) | (1 << 0)), (try parse("0 0 * * 5-7")).dow);
    // And 7-7 is Sunday alone, not every day of the week.
    try std.testing.expectEqual(@as(u8, 1 << 0), (try parse("0 0 * * 7-7")).dow);
    try std.testing.expectEqual(@as(u8, 0x7f), (try parse("0 0 * * 0-7")).dow);
    try std.testing.expectEqual(@as(u8, (1 << 1) | (1 << 2) | (1 << 3) | (1 << 4) | (1 << 5)), (try parse("0 0 * * 1-5")).dow);
}

test "malformed specs are rejected, each with the reason" {
    try std.testing.expectError(ParseError.WrongFieldCount, parse("* * * *"));
    try std.testing.expectError(ParseError.WrongFieldCount, parse("* * * * * *"));
    try std.testing.expectError(ParseError.WrongFieldCount, parse(""));
    try std.testing.expectError(ParseError.OutOfRange, parse("60 * * * *"));
    try std.testing.expectError(ParseError.OutOfRange, parse("* 24 * * *"));
    try std.testing.expectError(ParseError.OutOfRange, parse("* * 0 * *"));
    try std.testing.expectError(ParseError.OutOfRange, parse("* * 32 * *"));
    try std.testing.expectError(ParseError.OutOfRange, parse("* * * 13 *"));
    try std.testing.expectError(ParseError.OutOfRange, parse("* * * * 8"));
    try std.testing.expectError(ParseError.BadRange, parse("30-10 * * * *"));
    try std.testing.expectError(ParseError.BadStep, parse("*/0 * * * *"));
    try std.testing.expectError(ParseError.BadStep, parse("*/ * * * *"));
    // A step on a bare number reads differently in different crons, so it is
    // refused rather than guessed at.
    try std.testing.expectError(ParseError.BadStep, parse("5/10 * * * *"));
    try std.testing.expectError(ParseError.BadNumber, parse("a * * * *"));
    try std.testing.expectError(ParseError.BadNumber, parse("+5 * * * *"));
    try std.testing.expectError(ParseError.BadNumber, parse("1_0 * * * *"));
    try std.testing.expectError(ParseError.EmptyField, parse("0,, * * * *"));
    // Names are a real cron dialect this one deliberately does not speak;
    // rejecting them beats silently never firing.
    try std.testing.expectError(ParseError.BadNumber, parse("0 0 * * MON"));
    try std.testing.expectError(ParseError.BadNumber, parse("0 0 * JAN *"));
    // Nicknames likewise.
    try std.testing.expectError(ParseError.WrongFieldCount, parse("@hourly"));
    // Leading and trailing whitespace, and runs between fields, are fine.
    _ = try parse("  0   0  *  *  *  ");
}

test "next fire: the common shapes, checked as wall clock" {
    // Every five minutes: the next multiple of five, never the current minute.
    try expectCivil(try nextCivil("*/5 * * * *", .{ 2026, 8, 13, 12, 3 }, 0), .{ 2026, 8, 13, 12, 5 });
    try expectCivil(try nextCivil("*/5 * * * *", .{ 2026, 8, 13, 12, 5 }, 0), .{ 2026, 8, 13, 12, 10 });
    // Daily at 09:00, from before and from after.
    try expectCivil(try nextCivil("0 9 * * *", .{ 2026, 8, 13, 8, 59 }, 0), .{ 2026, 8, 13, 9, 0 });
    try expectCivil(try nextCivil("0 9 * * *", .{ 2026, 8, 13, 9, 0 }, 0), .{ 2026, 8, 14, 9, 0 });
    // Hourly on the hour rolls the day over.
    try expectCivil(try nextCivil("0 * * * *", .{ 2026, 8, 13, 23, 30 }, 0), .{ 2026, 8, 14, 0, 0 });
    // Monthly on the 1st rolls the year over.
    try expectCivil(try nextCivil("0 0 1 * *", .{ 2026, 12, 15, 0, 0 }, 0), .{ 2027, 1, 1, 0, 0 });
    // A weekday-only entry skips the weekend: 2026-08-14 is a Friday, so the
    // next Monday-to-Friday 09:00 after Friday noon is the 17th.
    try expectCivil(try nextCivil("0 9 * * 1-5", .{ 2026, 8, 14, 12, 0 }, 0), .{ 2026, 8, 17, 9, 0 });
}

test "next fire: month lengths and leap days" {
    // The 31st skips the months that do not have one: after 2026-01-31, the
    // next is March, not February.
    try expectCivil(try nextCivil("0 0 31 * *", .{ 2026, 1, 31, 0, 0 }, 0), .{ 2026, 3, 31, 0, 0 });
    // The last day of a 30-day month rolls to the next month, not to a 31st
    // that does not exist.
    try expectCivil(try nextCivil("0 0 * * *", .{ 2026, 4, 30, 12, 0 }, 0), .{ 2026, 5, 1, 0, 0 });
    // February 29th only exists in a leap year: from 2026 the next is 2028.
    try expectCivil(try nextCivil("0 0 29 2 *", .{ 2026, 3, 1, 0, 0 }, 0), .{ 2028, 2, 29, 0, 0 });
    // And a date that never exists never fires, rather than spinning.
    const never = try parse("0 0 30 2 *");
    try std.testing.expectEqual(@as(?i64, null), never.nextAfter(epochFromCivil(2026, 1, 1, 0, 0, 0), 0));
}

test "next fire: day-of-month and day-of-week are OR'd when both are set" {
    // Vixie's rule. 2026-11-13 is a Friday, so "the 13th or any Friday" in
    // November 2026 hits the 6th, then the 13th, then the 20th.
    try expectCivil(try nextCivil("0 0 13 * 5", .{ 2026, 11, 1, 0, 0 }, 0), .{ 2026, 11, 6, 0, 0 });
    try expectCivil(try nextCivil("0 0 13 * 5", .{ 2026, 11, 6, 0, 0 }, 0), .{ 2026, 11, 13, 0, 0 });
    // With day-of-week starred, day-of-month alone decides.
    try expectCivil(try nextCivil("0 0 13 * *", .{ 2026, 11, 1, 0, 0 }, 0), .{ 2026, 11, 13, 0, 0 });
    // With day-of-month starred, day-of-week alone decides.
    try expectCivil(try nextCivil("0 0 * * 5", .{ 2026, 11, 1, 0, 0 }, 0), .{ 2026, 11, 6, 0, 0 });
}

test "next fire: a fixed offset shifts the wall clock the fields describe" {
    // 09:00 at UTC+2 is 07:00 UTC.
    try expectCivil(try nextCivil("0 9 * * *", .{ 2026, 8, 13, 0, 0 }, 120), .{ 2026, 8, 13, 7, 0 });
    // 00:30 at UTC-5 is 05:30 UTC the same day; the offset can also push the
    // fire across a UTC date boundary without moving the local date.
    try expectCivil(try nextCivil("30 0 * * *", .{ 2026, 8, 13, 0, 0 }, -300), .{ 2026, 8, 13, 5, 30 });
    try expectCivil(try nextCivil("30 23 * * *", .{ 2026, 8, 13, 0, 0 }, 120), .{ 2026, 8, 13, 21, 30 });
    // A day-of-week entry uses the *local* day: 2026-08-17 00:30 at UTC+2 is
    // a Monday locally but Sunday 22:30 in UTC.
    try expectCivil(try nextCivil("30 0 * * 1", .{ 2026, 8, 15, 0, 0 }, 120), .{ 2026, 8, 16, 22, 30 });
}

test "next fire is strictly after, so a fired entry cannot re-fire its own minute" {
    const spec = try parse("* * * * *");
    const t = epochFromCivil(2026, 8, 13, 12, 0, 0);
    // Exactly on a fire time.
    try std.testing.expectEqual(t + 60, spec.nextAfter(t, 0).?);
    // Mid-minute rounds up to the next boundary rather than to the boundary
    // that has already passed.
    try std.testing.expectEqual(t + 60, spec.nextAfter(t + 30, 0).?);
}

test "countBetween counts the windows a sleeping machine slept through" {
    const five = try parse("*/5 * * * *");
    const from = epochFromCivil(2026, 8, 13, 0, 0, 0);
    // One hour of a */5 entry is twelve windows.
    try std.testing.expectEqual(@as(u32, 12), countBetween(five, from, from + std.time.s_per_hour, 0, 1000));
    // A full day is 288, which is the number the missed-run policy exists to
    // keep off the provider bill.
    try std.testing.expectEqual(@as(u32, 288), countBetween(five, from, from + std.time.s_per_day, 0, 1000));
    // The cap is honoured rather than counted past.
    try std.testing.expectEqual(@as(u32, 10), countBetween(five, from, from + std.time.s_per_day, 0, 10));
    // Nothing between a time and itself, and nothing going backwards.
    try std.testing.expectEqual(@as(u32, 0), countBetween(five, from, from, 0, 1000));
    try std.testing.expectEqual(@as(u32, 0), countBetween(five, from, from - 100, 0, 1000));
}

test "offsets parse in every spelling that means the same thing" {
    try std.testing.expectEqual(@as(i32, 0), try parseOffset("UTC"));
    try std.testing.expectEqual(@as(i32, 0), try parseOffset("Z"));
    try std.testing.expectEqual(@as(i32, 0), try parseOffset("+00:00"));
    try std.testing.expectEqual(@as(i32, 60), try parseOffset("+01:00"));
    try std.testing.expectEqual(@as(i32, 60), try parseOffset("60"));
    try std.testing.expectEqual(@as(i32, -300), try parseOffset("-05:00"));
    try std.testing.expectEqual(@as(i32, 330), try parseOffset("+05:30"));
    try std.testing.expectEqual(@as(i32, -570), try parseOffset("-09:30"));
    try std.testing.expectError(ParseError.OutOfRange, parseOffset("+99:00"));
    try std.testing.expectError(ParseError.OutOfRange, parseOffset("+01:99"));
    try std.testing.expectError(ParseError.BadNumber, parseOffset("east"));
    try std.testing.expectError(ParseError.EmptyField, parseOffset(""));
}

test "formatStamp renders at the entry's own offset" {
    var buf: [32]u8 = undefined;
    const t = epochFromCivil(2026, 8, 13, 7, 0, 0);
    try std.testing.expectEqualStrings("2026-08-13 07:00", formatStamp(&buf, t, 0));
    try std.testing.expectEqualStrings("2026-08-13 09:00", formatStamp(&buf, t, 120));
    try std.testing.expectEqualStrings("2026-08-13 02:00", formatStamp(&buf, t, -300));
}

test "a year of minutes agrees with a brute-force scan" {
    // The stepping search skips whole months, days and hours; a minute-by-
    // minute walk over the same window is the independent implementation that
    // catches a skip landing one slot early or late.
    const specs = [_][]const u8{
        "*/17 * * * *",
        "0 9 * * 1-5",
        "30 6,18 1,15 * *",
        "0 0 13 * 5",
        "0 0 * 2 *",
    };
    for (specs) |text| {
        const spec = try parse(text);
        const start = epochFromCivil(2026, 1, 1, 0, 0, 0);
        var t = start;
        // Two weeks of minutes is 20160 candidate slots per spec: enough to
        // cross month, week and day boundaries without making the suite slow.
        const end = start + 14 * std.time.s_per_day;
        while (t < end) {
            const next = spec.nextAfter(t, 0) orelse break;
            var brute = @divFloor(t, 60) * 60 + 60;
            while (brute < end) : (brute += 60) {
                const c = civilFromEpoch(brute);
                if (bit16(spec.month, c.month) and spec.dayMatches(c.day, c.weekday) and
                    bit32(spec.hour, c.hour) and bit64(spec.minute, c.minute)) break;
            }
            if (brute >= end) break;
            try std.testing.expectEqual(brute, next);
            t = next;
        }
    }
}

test "fuzz: no byte sequence crashes the cron parser" {
    const Ctx = struct {
        fn one(_: void, smith: *std.testing.Smith) anyerror!void {
            var buf: [256]u8 = undefined;
            const len = smith.slice(&buf);
            const input = buf[0..len];
            if (parse(input)) |spec| {
                _ = spec.nextAfter(0, 0);
                _ = spec.nextAfter(-1, 0);
                _ = spec.nextAfter(0, 330);
            } else |_| {}
            _ = parseOffset(input) catch 0;
        }
    };
    try std.testing.fuzz({}, Ctx.one, .{});
}
