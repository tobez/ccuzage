// ABOUTME: Shared helpers for the `ccuzage context` subcommand.
// ABOUTME: Currently holds the token/window percentage rounding helper.
const std = @import("std");

/// Percentage of `window` used by `tokens`, rounded to nearest. Window 0 → 0.
pub fn contextPercent(tokens: u64, window: u64) u64 {
    if (window == 0) return 0;
    return (tokens * 100 + window / 2) / window;
}

// =============================================================================
// Tests
// =============================================================================

test "contextPercent: exact 50 percent" {
    try std.testing.expectEqual(@as(u64, 50), contextPercent(100_000, 200_000));
}

test "contextPercent: tokens equal window returns 100" {
    try std.testing.expectEqual(@as(u64, 100), contextPercent(200_000, 200_000));
}

test "contextPercent: rounds down below the half boundary" {
    // 704 / 1000 = 70.4% -> 70
    try std.testing.expectEqual(@as(u64, 70), contextPercent(704, 1000));
}

test "contextPercent: rounds up above the half boundary" {
    // 706 / 1000 = 70.6% -> 71
    try std.testing.expectEqual(@as(u64, 71), contextPercent(706, 1000));
    // 15_000 / 200_000 = 7.5% -> 8
    try std.testing.expectEqual(@as(u64, 8), contextPercent(15_000, 200_000));
}

test "contextPercent: exact half boundary rounds up" {
    // 705 / 1000 = 70.5% -> 71
    try std.testing.expectEqual(@as(u64, 71), contextPercent(705, 1000));
}

test "contextPercent: window zero returns zero" {
    try std.testing.expectEqual(@as(u64, 0), contextPercent(1000, 0));
}

test "contextPercent: tokens zero returns zero" {
    try std.testing.expectEqual(@as(u64, 0), contextPercent(0, 200_000));
}
