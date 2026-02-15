// ABOUTME: Date and time utilities for parsing, formatting, and manipulating timestamps.
// ABOUTME: Handles ISO 8601 parsing, epoch conversion, timezone offsets, and week calculations.
const std = @import("std");
const libc = @cImport(@cInclude("time.h"));

pub const ParseError = error{
    InvalidFormat,
    InvalidDate,
};

pub const DateComponents = struct {
    year: u16,
    month: u8, // 1-12
    day: u8, // 1-31
    hour: u8,
    minute: u8,
    second: u8,
    day_of_week: u8, // 0=Sunday, 1=Monday, ..., 6=Saturday
};

/// Parse an ISO 8601 timestamp in format "YYYY-MM-DDThh:mm:ss.sssZ" or "YYYY-MM-DDThh:mm:ssZ".
/// Returns epoch milliseconds.
pub fn parseIso8601(timestamp: []const u8) ParseError!i64 {
    // Must be either 24 chars (with millis) or 20 chars (without millis)
    if (timestamp.len != 24 and timestamp.len != 20) return ParseError.InvalidFormat;

    // Must end with 'Z'
    if (timestamp[timestamp.len - 1] != 'Z') return ParseError.InvalidFormat;

    // Check structural characters
    if (timestamp[4] != '-' or timestamp[7] != '-' or timestamp[10] != 'T' or timestamp[13] != ':' or timestamp[16] != ':')
        return ParseError.InvalidFormat;

    // Parse with millis separator check
    if (timestamp.len == 24 and timestamp[19] != '.') return ParseError.InvalidFormat;

    const year = parseDigits(u16, timestamp[0..4]) orelse return ParseError.InvalidFormat;
    const month = parseDigits(u8, timestamp[5..7]) orelse return ParseError.InvalidFormat;
    const day = parseDigits(u8, timestamp[8..10]) orelse return ParseError.InvalidFormat;
    const hour = parseDigits(u8, timestamp[11..13]) orelse return ParseError.InvalidFormat;
    const minute = parseDigits(u8, timestamp[14..16]) orelse return ParseError.InvalidFormat;
    const second = parseDigits(u8, timestamp[17..19]) orelse return ParseError.InvalidFormat;

    var millis: u16 = 0;
    if (timestamp.len == 24) {
        millis = parseDigits(u16, timestamp[20..23]) orelse return ParseError.InvalidFormat;
    }

    // Validate ranges
    if (month < 1 or month > 12) return ParseError.InvalidDate;
    if (day < 1 or day > daysInMonth(year, month)) return ParseError.InvalidDate;
    if (hour > 23) return ParseError.InvalidDate;
    if (minute > 59) return ParseError.InvalidDate;
    if (second > 59) return ParseError.InvalidDate;

    // Calculate epoch days
    const epoch_days = civilToEpochDays(year, month, day);
    const epoch_ms: i64 = epoch_days * 86400000 +
        @as(i64, hour) * 3600000 +
        @as(i64, minute) * 60000 +
        @as(i64, second) * 1000 +
        @as(i64, millis);

    return epoch_ms;
}

/// Convert epoch milliseconds to date components, applying timezone offset.
pub fn epochMillisToComponents(epoch_ms: i64, tz_offset_minutes: i32) DateComponents {
    const adjusted_ms = epoch_ms + @as(i64, tz_offset_minutes) * 60 * 1000;
    const day_ms: i64 = 86400000;

    // Integer division that rounds toward negative infinity
    const epoch_days = @divFloor(adjusted_ms, day_ms);
    const day_remainder_ms = @mod(adjusted_ms, day_ms);

    const hour: u8 = @intCast(@divFloor(day_remainder_ms, 3600000));
    const minute: u8 = @intCast(@divFloor(@mod(day_remainder_ms, 3600000), 60000));
    const second: u8 = @intCast(@divFloor(@mod(day_remainder_ms, 60000), 1000));

    // Day of week: epoch day 0 = Thursday (4)
    // (epoch_days % 7 + 4) % 7, but handle negatives
    const dow_raw = @mod(epoch_days + 4, 7);
    const day_of_week: u8 = @intCast(dow_raw);

    // Convert epoch days to civil date using the algorithm
    const civil = epochDaysToCivil(epoch_days);

    return .{
        .year = civil.year,
        .month = civil.month,
        .day = civil.day,
        .hour = hour,
        .minute = minute,
        .second = second,
        .day_of_week = day_of_week,
    };
}

/// Format epoch milliseconds as "YYYY-MM-DD" applying timezone offset.
pub fn formatDaily(epoch_ms: i64, tz_offset_minutes: i32) [10]u8 {
    const c = epochMillisToComponents(epoch_ms, tz_offset_minutes);
    var buf: [10]u8 = undefined;
    writeDecimal(&buf, 0, 4, c.year);
    buf[4] = '-';
    writeDecimal(&buf, 5, 2, c.month);
    buf[7] = '-';
    writeDecimal(&buf, 8, 2, c.day);
    return buf;
}

/// Format epoch milliseconds as "YYYY-MM" applying timezone offset.
pub fn formatMonthly(epoch_ms: i64, tz_offset_minutes: i32) [7]u8 {
    const c = epochMillisToComponents(epoch_ms, tz_offset_minutes);
    var buf: [7]u8 = undefined;
    writeDecimal(&buf, 0, 4, c.year);
    buf[4] = '-';
    writeDecimal(&buf, 5, 2, c.month);
    return buf;
}

/// Format epoch milliseconds as "YYYY-MM-DDThh:mm:ss.sssZ" (always UTC).
pub fn formatIso8601Output(epoch_ms: i64) [24]u8 {
    const c = epochMillisToComponents(epoch_ms, 0);
    const millis: u16 = @intCast(@mod(epoch_ms, 1000));
    var buf: [24]u8 = undefined;
    writeDecimal(&buf, 0, 4, c.year);
    buf[4] = '-';
    writeDecimal(&buf, 5, 2, c.month);
    buf[7] = '-';
    writeDecimal(&buf, 8, 2, c.day);
    buf[10] = 'T';
    writeDecimal(&buf, 11, 2, c.hour);
    buf[13] = ':';
    writeDecimal(&buf, 14, 2, c.minute);
    buf[16] = ':';
    writeDecimal(&buf, 17, 2, c.second);
    buf[19] = '.';
    writeDecimal(&buf, 20, 3, millis);
    buf[23] = 'Z';
    return buf;
}

/// Given a timestamp and a week start day (0=Sunday, 1=Monday, etc.),
/// return the "YYYY-MM-DD" of the first day of that week.
pub fn weekStart(epoch_ms: i64, tz_offset_minutes: i32, start_day: u8) [10]u8 {
    const c = epochMillisToComponents(epoch_ms, tz_offset_minutes);
    const shift = (c.day_of_week -% start_day +% 7) % 7;

    // Subtract shift days from the current date
    const adjusted_ms = epoch_ms + @as(i64, tz_offset_minutes) * 60 * 1000;
    const epoch_days = @divFloor(adjusted_ms, @as(i64, 86400000));
    const target_days = epoch_days - @as(i64, shift);
    const civil = epochDaysToCivil(target_days);

    var buf: [10]u8 = undefined;
    writeDecimal(&buf, 0, 4, civil.year);
    buf[4] = '-';
    writeDecimal(&buf, 5, 2, civil.month);
    buf[7] = '-';
    writeDecimal(&buf, 8, 2, civil.day);
    return buf;
}

/// Strip dashes from "YYYY-MM-DD" to get "YYYYMMDD" for comparison.
pub fn dailyToFilterDate(daily: *const [10]u8) [8]u8 {
    return .{
        daily[0], daily[1], daily[2], daily[3],
        daily[5], daily[6],
        daily[8], daily[9],
    };
}

/// Detect the system's local timezone offset in minutes from UTC.
/// Uses the C library's localtime_r to read the system timezone.
pub fn getLocalTimezoneOffset() i32 {
    var now: libc.time_t = @intCast(std.time.timestamp());
    var tm: libc.struct_tm = undefined;
    _ = libc.localtime_r(&now, &tm);
    return @intCast(@divTrunc(tm.tm_gmtoff, 60));
}

// --- Internal helpers ---

fn isLeapYear(year: u16) bool {
    return (year % 4 == 0 and year % 100 != 0) or (year % 400 == 0);
}

fn daysInMonth(year: u16, month: u8) u8 {
    const days_table = [_]u8{ 31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31 };
    if (month == 2 and isLeapYear(year)) return 29;
    return days_table[month - 1];
}

/// Convert a civil date to days since Unix epoch (1970-01-01).
fn civilToEpochDays(year: u16, month: u8, day: u8) i64 {
    // Algorithm from Howard Hinnant's date library
    const y: i64 = @as(i64, year) - @as(i64, if (month <= 2) @as(u8, 1) else @as(u8, 0));
    const m: i64 = @as(i64, month) + (if (month > 2) @as(i64, -3) else @as(i64, 9));
    const era: i64 = @divFloor(y, 400);
    const yoe: i64 = y - era * 400; // year of era [0, 399]
    const doy: i64 = @divFloor(153 * m + 2, 5) + @as(i64, day) - 1; // day of year [0, 365]
    const doe: i64 = yoe * 365 + @divFloor(yoe, 4) - @divFloor(yoe, 100) + doy; // day of era [0, 146096]
    return era * 146097 + doe - 719468;
}

const CivilDate = struct {
    year: u16,
    month: u8,
    day: u8,
};

/// Convert days since Unix epoch to a civil date.
fn epochDaysToCivil(epoch_days: i64) CivilDate {
    // Algorithm from Howard Hinnant's date library
    const z = epoch_days + 719468;
    const era = @divFloor(z, 146097);
    const doe = z - era * 146097; // day of era [0, 146096]
    const yoe = @divFloor(doe - @divFloor(doe, 1460) + @divFloor(doe, 36524) - @divFloor(doe, 146096), 365);
    const y = yoe + era * 400;
    const doy = doe - (365 * yoe + @divFloor(yoe, 4) - @divFloor(yoe, 100)); // day of year [0, 365]
    const mp = @divFloor(5 * doy + 2, 153); // [0, 11]
    const d = doy - @divFloor(153 * mp + 2, 5) + 1; // day [1, 31]
    const m_raw = mp + (if (mp < 10) @as(i64, 3) else @as(i64, -9)); // month [1, 12]
    const y_adj = y + (if (m_raw <= 2) @as(i64, 1) else @as(i64, 0));

    return .{
        .year = @intCast(y_adj),
        .month = @intCast(m_raw),
        .day = @intCast(d),
    };
}

/// Parse a string of digits into an integer. Returns null if any character is not a digit.
fn parseDigits(comptime T: type, s: []const u8) ?T {
    var result: T = 0;
    for (s) |ch| {
        if (ch < '0' or ch > '9') return null;
        result = result * 10 + @as(T, ch - '0');
    }
    return result;
}

/// Write a decimal number right-aligned with zero-padding into buf at the given offset.
fn writeDecimal(buf: []u8, offset: usize, width: usize, value: anytype) void {
    var v = value;
    var i: usize = width;
    while (i > 0) {
        i -= 1;
        buf[offset + i] = '0' + @as(u8, @intCast(@mod(v, 10)));
        v = @divFloor(v, 10);
    }
}

// =============================================================================
// Tests
// =============================================================================

test "parseIso8601 - basic timestamp with milliseconds" {
    const result = try parseIso8601("2025-01-15T10:30:00.000Z");
    try std.testing.expectEqual(@as(i64, 1736937000000), result);
}

test "parseIso8601 - end of year timestamp" {
    const result = try parseIso8601("2025-12-31T23:59:59.999Z");
    try std.testing.expectEqual(@as(i64, 1767225599999), result);
}

test "parseIso8601 - leap year Feb 29" {
    const result = try parseIso8601("2024-02-29T00:00:00.000Z");
    try std.testing.expectEqual(@as(i64, 1709164800000), result);
}

test "parseIso8601 - non-leap year Feb 29 errors" {
    const result = parseIso8601("2025-02-29T00:00:00.000Z");
    try std.testing.expectError(ParseError.InvalidDate, result);
}

test "parseIso8601 - invalid string" {
    try std.testing.expectError(ParseError.InvalidFormat, parseIso8601("invalid"));
}

test "parseIso8601 - empty string" {
    try std.testing.expectError(ParseError.InvalidFormat, parseIso8601(""));
}

test "parseIso8601 - without milliseconds" {
    const result = try parseIso8601("2025-01-15T10:30:00Z");
    try std.testing.expectEqual(@as(i64, 1736937000000), result);
}

test "parseIso8601 - epoch zero" {
    const result = try parseIso8601("1970-01-01T00:00:00.000Z");
    try std.testing.expectEqual(@as(i64, 0), result);
}

test "parseIso8601 - invalid month" {
    try std.testing.expectError(ParseError.InvalidDate, parseIso8601("2025-13-01T00:00:00.000Z"));
}

test "parseIso8601 - invalid day" {
    try std.testing.expectError(ParseError.InvalidDate, parseIso8601("2025-01-32T00:00:00.000Z"));
}

test "parseIso8601 - invalid hour" {
    try std.testing.expectError(ParseError.InvalidDate, parseIso8601("2025-01-15T24:00:00.000Z"));
}

test "epochMillisToComponents - epoch zero" {
    const c = epochMillisToComponents(0, 0);
    try std.testing.expectEqual(@as(u16, 1970), c.year);
    try std.testing.expectEqual(@as(u8, 1), c.month);
    try std.testing.expectEqual(@as(u8, 1), c.day);
    try std.testing.expectEqual(@as(u8, 0), c.hour);
    try std.testing.expectEqual(@as(u8, 0), c.minute);
    try std.testing.expectEqual(@as(u8, 0), c.second);
    try std.testing.expectEqual(@as(u8, 4), c.day_of_week); // Thursday
}

test "epochMillisToComponents - known date" {
    // 2025-01-15T10:30:00.000Z
    const c = epochMillisToComponents(1736937000000, 0);
    try std.testing.expectEqual(@as(u16, 2025), c.year);
    try std.testing.expectEqual(@as(u8, 1), c.month);
    try std.testing.expectEqual(@as(u8, 15), c.day);
    try std.testing.expectEqual(@as(u8, 10), c.hour);
    try std.testing.expectEqual(@as(u8, 30), c.minute);
    try std.testing.expectEqual(@as(u8, 0), c.second);
    try std.testing.expectEqual(@as(u8, 3), c.day_of_week); // Wednesday
}

test "epochMillisToComponents - timezone +02:00 crosses day boundary" {
    // 2025-01-15T23:30:00Z with +02:00 => 2025-01-16T01:30:00
    const c = epochMillisToComponents(1736983800000, 120);
    try std.testing.expectEqual(@as(u16, 2025), c.year);
    try std.testing.expectEqual(@as(u8, 1), c.month);
    try std.testing.expectEqual(@as(u8, 16), c.day);
    try std.testing.expectEqual(@as(u8, 1), c.hour);
    try std.testing.expectEqual(@as(u8, 30), c.minute);
}

test "epochMillisToComponents - timezone -05:00 crosses day boundary backward" {
    // 2025-01-16T03:00:00Z with -05:00 => 2025-01-15T22:00:00
    const c = epochMillisToComponents(1736996400000, -300);
    try std.testing.expectEqual(@as(u16, 2025), c.year);
    try std.testing.expectEqual(@as(u8, 1), c.month);
    try std.testing.expectEqual(@as(u8, 15), c.day);
    try std.testing.expectEqual(@as(u8, 22), c.hour);
    try std.testing.expectEqual(@as(u8, 0), c.minute);
}

test "formatDaily - basic" {
    const result = formatDaily(1736937000000, 0);
    try std.testing.expectEqualStrings("2025-01-15", &result);
}

test "formatDaily - with timezone offset" {
    // 2025-01-15T23:30:00Z with +02:00 => 2025-01-16
    const result = formatDaily(1736983800000, 120);
    try std.testing.expectEqualStrings("2025-01-16", &result);
}

test "formatMonthly - basic" {
    const result = formatMonthly(1736937000000, 0);
    try std.testing.expectEqualStrings("2025-01", &result);
}

test "formatIso8601Output - basic" {
    const result = formatIso8601Output(1736937000000);
    try std.testing.expectEqualStrings("2025-01-15T10:30:00.000Z", &result);
}

test "formatIso8601Output - with milliseconds" {
    const result = formatIso8601Output(1767225599999);
    try std.testing.expectEqualStrings("2025-12-31T23:59:59.999Z", &result);
}

test "formatIso8601Output - epoch zero" {
    const result = formatIso8601Output(0);
    try std.testing.expectEqualStrings("1970-01-01T00:00:00.000Z", &result);
}

test "weekStart - Wednesday, start=Sunday" {
    // 2025-01-15 (Wed), start=Sun(0) => 2025-01-12
    const result = weekStart(1736937000000, 0, 0);
    try std.testing.expectEqualStrings("2025-01-12", &result);
}

test "weekStart - Wednesday, start=Monday" {
    // 2025-01-15 (Wed), start=Mon(1) => 2025-01-13
    const result = weekStart(1736937000000, 0, 1);
    try std.testing.expectEqualStrings("2025-01-13", &result);
}

test "weekStart - Sunday, start=Sunday (already on start)" {
    // 2025-01-12 (Sun), start=Sun(0) => 2025-01-12
    const result = weekStart(1736683200000, 0, 0);
    try std.testing.expectEqualStrings("2025-01-12", &result);
}

test "weekStart - Saturday, start=Sunday (crosses month boundary)" {
    // 2025-03-01 (Sat), start=Sun(0) => 2025-02-23
    const result = weekStart(1740830400000, 0, 0);
    try std.testing.expectEqualStrings("2025-02-23", &result);
}

test "weekStart - Monday, start=Monday (already on start)" {
    // 2025-01-06 (Mon), start=Mon(1) => 2025-01-06
    const result = weekStart(1736164800000, 0, 1);
    try std.testing.expectEqualStrings("2025-01-06", &result);
}

test "dailyToFilterDate - basic" {
    const daily: [10]u8 = "2025-01-15".*;
    const result = dailyToFilterDate(&daily);
    try std.testing.expectEqualStrings("20250115", &result);
}

test "dailyToFilterDate - different date" {
    const daily: [10]u8 = "2024-12-31".*;
    const result = dailyToFilterDate(&daily);
    try std.testing.expectEqualStrings("20241231", &result);
}

test "parseIso8601 roundtrip with formatIso8601Output" {
    const original = "2025-06-15T14:22:33.456Z";
    const epoch = try parseIso8601(original);
    const formatted = formatIso8601Output(epoch);
    try std.testing.expectEqualStrings(original, &formatted);
}
