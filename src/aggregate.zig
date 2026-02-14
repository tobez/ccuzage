// ABOUTME: Aggregation logic for grouping usage entries by time period and session.
// ABOUTME: Provides daily, monthly, weekly, and session aggregation with per-model breakdowns sorted by cost.
const std = @import("std");
const types = @import("types.zig");
const date = @import("date.zig");

const StringHashMap = std.StringHashMap;

const ModelAccumulator = struct {
    input_tokens: u64,
    output_tokens: u64,
    cache_creation_tokens: u64,
    cache_read_tokens: u64,
    cost: f64,
};

const Accumulator = struct {
    input_tokens: u64,
    output_tokens: u64,
    cache_creation_tokens: u64,
    cache_read_tokens: u64,
    total_cost: f64,
    models: StringHashMap(ModelAccumulator),
};

const PeriodMode = union(enum) {
    daily,
    monthly,
    weekly: u8, // week_start_day: 0=Sunday, 1=Monday, etc.
};

const PeriodKey = struct {
    buf: [10]u8,
    len: u8,

    fn slice(self: *const PeriodKey) []const u8 {
        return self.buf[0..self.len];
    }
};

/// Compute the period key for an entry's timestamp given the grouping mode.
fn computePeriodKey(mode: PeriodMode, timestamp: i64, tz_offset_minutes: i32) PeriodKey {
    switch (mode) {
        .daily => {
            const buf = date.formatDaily(timestamp, tz_offset_minutes);
            return .{ .buf = buf, .len = 10 };
        },
        .monthly => {
            const buf = date.formatMonthly(timestamp, tz_offset_minutes);
            var result: PeriodKey = .{ .buf = undefined, .len = 7 };
            @memcpy(result.buf[0..7], &buf);
            return result;
        },
        .weekly => |start_day| {
            const buf = date.weekStart(timestamp, tz_offset_minutes, start_day);
            return .{ .buf = buf, .len = 10 };
        },
    }
}

fn aggregateByPeriod(
    allocator: std.mem.Allocator,
    entries: []const types.UsageEntry,
    tz_offset_minutes: i32,
    mode: PeriodMode,
) ![]types.AggregatedUsage {
    var period_map = StringHashMap(Accumulator).init(allocator);
    defer {
        var it = period_map.iterator();
        while (it.next()) |kv| {
            kv.value_ptr.models.deinit();
            allocator.free(kv.key_ptr.*);
        }
        period_map.deinit();
    }

    // Accumulate entries grouped by period key
    for (entries) |entry| {
        const pk = computePeriodKey(mode, entry.timestamp, tz_offset_minutes);
        const key_slice = pk.slice();
        const period_key = period_map.getKey(key_slice) orelse blk: {
            const duped = try allocator.dupe(u8, key_slice);
            break :blk duped;
        };

        const gop = try period_map.getOrPut(period_key);
        if (!gop.found_existing) {
            gop.value_ptr.* = .{
                .input_tokens = 0,
                .output_tokens = 0,
                .cache_creation_tokens = 0,
                .cache_read_tokens = 0,
                .total_cost = 0,
                .models = StringHashMap(ModelAccumulator).init(allocator),
            };
        }

        const acc = gop.value_ptr;
        acc.input_tokens += entry.input_tokens;
        acc.output_tokens += entry.output_tokens;
        acc.cache_creation_tokens += entry.cache_creation_tokens;
        acc.cache_read_tokens += entry.cache_read_tokens;
        acc.total_cost += entry.cost_usd;

        const model_gop = try acc.models.getOrPut(entry.model);
        if (!model_gop.found_existing) {
            model_gop.value_ptr.* = .{
                .input_tokens = 0,
                .output_tokens = 0,
                .cache_creation_tokens = 0,
                .cache_read_tokens = 0,
                .cost = 0,
            };
        }
        model_gop.value_ptr.input_tokens += entry.input_tokens;
        model_gop.value_ptr.output_tokens += entry.output_tokens;
        model_gop.value_ptr.cache_creation_tokens += entry.cache_creation_tokens;
        model_gop.value_ptr.cache_read_tokens += entry.cache_read_tokens;
        model_gop.value_ptr.cost += entry.cost_usd;
    }

    // Convert accumulators to AggregatedUsage results
    const result = try allocator.alloc(types.AggregatedUsage, period_map.count());
    var i: usize = 0;

    var period_it = period_map.iterator();
    while (period_it.next()) |kv| {
        const period_str = kv.key_ptr.*;
        const acc = kv.value_ptr;

        // Build model breakdowns
        const breakdown_count = acc.models.count();
        const breakdowns = try allocator.alloc(types.ModelBreakdown, breakdown_count);
        var bi: usize = 0;
        var model_it = acc.models.iterator();
        while (model_it.next()) |mkv| {
            const macc = mkv.value_ptr.*;
            breakdowns[bi] = .{
                .model_name = try allocator.dupe(u8, mkv.key_ptr.*),
                .input_tokens = macc.input_tokens,
                .output_tokens = macc.output_tokens,
                .cache_creation_tokens = macc.cache_creation_tokens,
                .cache_read_tokens = macc.cache_read_tokens,
                .cost = macc.cost,
            };
            bi += 1;
        }

        // Sort breakdowns by cost descending
        std.mem.sort(types.ModelBreakdown, breakdowns, {}, struct {
            fn lessThan(_: void, a: types.ModelBreakdown, b: types.ModelBreakdown) bool {
                return a.cost > b.cost;
            }
        }.lessThan);

        // Build models_used list from sorted breakdowns
        const models_used = try allocator.alloc([]const u8, breakdown_count);
        for (breakdowns, 0..) |bd, mi| {
            models_used[mi] = try allocator.dupe(u8, bd.model_name);
        }

        // Dupe the period string for the result (the map key will be freed in defer)
        const period = try allocator.dupe(u8, period_str);

        result[i] = .{
            .period = period,
            .input_tokens = acc.input_tokens,
            .output_tokens = acc.output_tokens,
            .cache_creation_tokens = acc.cache_creation_tokens,
            .cache_read_tokens = acc.cache_read_tokens,
            .total_cost = acc.total_cost,
            .models_used = models_used,
            .model_breakdowns = breakdowns,
            .project = null,
        };
        i += 1;
    }

    return result;
}

pub fn aggregateDaily(
    allocator: std.mem.Allocator,
    entries: []const types.UsageEntry,
    tz_offset_minutes: i32,
) ![]types.AggregatedUsage {
    return aggregateByPeriod(allocator, entries, tz_offset_minutes, .daily);
}

pub fn aggregateMonthly(
    allocator: std.mem.Allocator,
    entries: []const types.UsageEntry,
    tz_offset_minutes: i32,
) ![]types.AggregatedUsage {
    return aggregateByPeriod(allocator, entries, tz_offset_minutes, .monthly);
}

pub fn aggregateWeekly(
    allocator: std.mem.Allocator,
    entries: []const types.UsageEntry,
    tz_offset_minutes: i32,
    week_start_day: u8,
) ![]types.AggregatedUsage {
    return aggregateByPeriod(allocator, entries, tz_offset_minutes, .{ .weekly = week_start_day });
}

const SessionAccumulator = struct {
    input_tokens: u64,
    output_tokens: u64,
    cache_creation_tokens: u64,
    cache_read_tokens: u64,
    total_cost: f64,
    max_timestamp: i64,
    project_path: []const u8,
    models: StringHashMap(ModelAccumulator),
};

pub fn aggregateSession(
    allocator: std.mem.Allocator,
    entries: []const types.UsageEntry,
    tz_offset_minutes: i32,
) ![]types.SessionUsage {
    var session_map = StringHashMap(SessionAccumulator).init(allocator);
    defer {
        var it = session_map.iterator();
        while (it.next()) |kv| {
            kv.value_ptr.models.deinit();
            allocator.free(kv.key_ptr.*);
        }
        session_map.deinit();
    }

    // Accumulate entries grouped by session_id
    for (entries) |entry| {
        const session_key = session_map.getKey(entry.session_id) orelse blk: {
            const duped = try allocator.dupe(u8, entry.session_id);
            break :blk duped;
        };

        const gop = try session_map.getOrPut(session_key);
        if (!gop.found_existing) {
            gop.value_ptr.* = .{
                .input_tokens = 0,
                .output_tokens = 0,
                .cache_creation_tokens = 0,
                .cache_read_tokens = 0,
                .total_cost = 0,
                .max_timestamp = entry.timestamp,
                .project_path = entry.project,
                .models = StringHashMap(ModelAccumulator).init(allocator),
            };
        }

        const acc = gop.value_ptr;
        acc.input_tokens += entry.input_tokens;
        acc.output_tokens += entry.output_tokens;
        acc.cache_creation_tokens += entry.cache_creation_tokens;
        acc.cache_read_tokens += entry.cache_read_tokens;
        acc.total_cost += entry.cost_usd;

        if (entry.timestamp > acc.max_timestamp) {
            acc.max_timestamp = entry.timestamp;
        }

        const model_gop = try acc.models.getOrPut(entry.model);
        if (!model_gop.found_existing) {
            model_gop.value_ptr.* = .{
                .input_tokens = 0,
                .output_tokens = 0,
                .cache_creation_tokens = 0,
                .cache_read_tokens = 0,
                .cost = 0,
            };
        }
        model_gop.value_ptr.input_tokens += entry.input_tokens;
        model_gop.value_ptr.output_tokens += entry.output_tokens;
        model_gop.value_ptr.cache_creation_tokens += entry.cache_creation_tokens;
        model_gop.value_ptr.cache_read_tokens += entry.cache_read_tokens;
        model_gop.value_ptr.cost += entry.cost_usd;
    }

    // Convert accumulators to SessionUsage results
    const result = try allocator.alloc(types.SessionUsage, session_map.count());
    var i: usize = 0;

    var session_it = session_map.iterator();
    while (session_it.next()) |kv| {
        const acc = kv.value_ptr;

        // Build model breakdowns
        const breakdown_count = acc.models.count();
        const breakdowns = try allocator.alloc(types.ModelBreakdown, breakdown_count);
        var bi: usize = 0;
        var model_it = acc.models.iterator();
        while (model_it.next()) |mkv| {
            const macc = mkv.value_ptr.*;
            breakdowns[bi] = .{
                .model_name = try allocator.dupe(u8, mkv.key_ptr.*),
                .input_tokens = macc.input_tokens,
                .output_tokens = macc.output_tokens,
                .cache_creation_tokens = macc.cache_creation_tokens,
                .cache_read_tokens = macc.cache_read_tokens,
                .cost = macc.cost,
            };
            bi += 1;
        }

        // Sort breakdowns by cost descending
        std.mem.sort(types.ModelBreakdown, breakdowns, {}, struct {
            fn lessThan(_: void, a: types.ModelBreakdown, b: types.ModelBreakdown) bool {
                return a.cost > b.cost;
            }
        }.lessThan);

        // Build models_used list from sorted breakdowns
        const models_used = try allocator.alloc([]const u8, breakdown_count);
        for (breakdowns, 0..) |bd, mi| {
            models_used[mi] = try allocator.dupe(u8, bd.model_name);
        }

        // Format last_activity as YYYY-MM-DD from max timestamp
        const date_buf = date.formatDaily(acc.max_timestamp, tz_offset_minutes);
        const last_activity = try allocator.dupe(u8, &date_buf);

        result[i] = .{
            .session_id = try allocator.dupe(u8, kv.key_ptr.*),
            .project_path = try allocator.dupe(u8, acc.project_path),
            .input_tokens = acc.input_tokens,
            .output_tokens = acc.output_tokens,
            .cache_creation_tokens = acc.cache_creation_tokens,
            .cache_read_tokens = acc.cache_read_tokens,
            .total_cost = acc.total_cost,
            .last_activity = last_activity,
            .models_used = models_used,
            .model_breakdowns = breakdowns,
        };
        i += 1;
    }

    return result;
}

pub fn calculateTotals(items: []const types.AggregatedUsage) types.Totals {
    var totals = types.Totals{
        .input_tokens = 0,
        .output_tokens = 0,
        .cache_creation_tokens = 0,
        .cache_read_tokens = 0,
        .total_tokens = 0,
        .total_cost = 0,
    };
    for (items) |item| {
        totals.input_tokens += item.input_tokens;
        totals.output_tokens += item.output_tokens;
        totals.cache_creation_tokens += item.cache_creation_tokens;
        totals.cache_read_tokens += item.cache_read_tokens;
        totals.total_cost += item.total_cost;
    }
    totals.total_tokens = totals.input_tokens + totals.output_tokens +
        totals.cache_creation_tokens + totals.cache_read_tokens;
    return totals;
}

pub fn calculateSessionTotals(items: []const types.SessionUsage) types.Totals {
    var totals = types.Totals{
        .input_tokens = 0,
        .output_tokens = 0,
        .cache_creation_tokens = 0,
        .cache_read_tokens = 0,
        .total_tokens = 0,
        .total_cost = 0,
    };
    for (items) |item| {
        totals.input_tokens += item.input_tokens;
        totals.output_tokens += item.output_tokens;
        totals.cache_creation_tokens += item.cache_creation_tokens;
        totals.cache_read_tokens += item.cache_read_tokens;
        totals.total_cost += item.total_cost;
    }
    totals.total_tokens = totals.input_tokens + totals.output_tokens +
        totals.cache_creation_tokens + totals.cache_read_tokens;
    return totals;
}

// =============================================================================
// Test helpers
// =============================================================================

fn freeAggregated(allocator: std.mem.Allocator, items: []types.AggregatedUsage) void {
    for (items) |item| {
        allocator.free(item.period);
        for (item.model_breakdowns) |mb| allocator.free(mb.model_name);
        allocator.free(item.model_breakdowns);
        for (item.models_used) |m| allocator.free(m);
        allocator.free(item.models_used);
    }
    allocator.free(items);
}

fn makeEntry(
    session_id: []const u8,
    project: []const u8,
    timestamp: i64,
    model: []const u8,
    input_tokens: u64,
    output_tokens: u64,
    cache_creation_tokens: u64,
    cache_read_tokens: u64,
    cost_usd: f64,
) types.UsageEntry {
    return .{
        .session_id = session_id,
        .project = project,
        .timestamp = timestamp,
        .model = model,
        .input_tokens = input_tokens,
        .output_tokens = output_tokens,
        .cache_creation_tokens = cache_creation_tokens,
        .cache_read_tokens = cache_read_tokens,
        .cost_usd = cost_usd,
        .message_id = "msg-001",
        .request_id = "req-001",
    };
}

// =============================================================================
// Tests
// =============================================================================

test "aggregateDaily - empty input returns empty result" {
    const result = try aggregateDaily(std.testing.allocator, &.{}, 0);
    defer freeAggregated(std.testing.allocator, result);
    try std.testing.expectEqual(@as(usize, 0), result.len);
}

test "aggregateDaily - single day single model" {
    const entries = [_]types.UsageEntry{
        makeEntry("s1", "proj", 1736937000000, "claude-sonnet-4-20250514", 100, 10, 5, 50, 0.01), // 2025-01-15T10:30:00Z
        makeEntry("s1", "proj", 1736940600000, "claude-sonnet-4-20250514", 200, 20, 10, 100, 0.02), // 2025-01-15T11:30:00Z
        makeEntry("s1", "proj", 1736944200000, "claude-sonnet-4-20250514", 300, 30, 15, 150, 0.03), // 2025-01-15T12:30:00Z
    };

    const result = try aggregateDaily(std.testing.allocator, &entries, 0);
    defer freeAggregated(std.testing.allocator, result);

    try std.testing.expectEqual(@as(usize, 1), result.len);

    const day = result[0];
    try std.testing.expectEqualStrings("2025-01-15", day.period);
    try std.testing.expectEqual(@as(u64, 600), day.input_tokens);
    try std.testing.expectEqual(@as(u64, 60), day.output_tokens);
    try std.testing.expectEqual(@as(u64, 30), day.cache_creation_tokens);
    try std.testing.expectEqual(@as(u64, 300), day.cache_read_tokens);
    try std.testing.expectApproxEqAbs(@as(f64, 0.06), day.total_cost, 0.0001);

    try std.testing.expectEqual(@as(usize, 1), day.models_used.len);
    try std.testing.expectEqualStrings("claude-sonnet-4-20250514", day.models_used[0]);

    try std.testing.expectEqual(@as(usize, 1), day.model_breakdowns.len);
    try std.testing.expectEqualStrings("claude-sonnet-4-20250514", day.model_breakdowns[0].model_name);
    try std.testing.expectEqual(@as(u64, 600), day.model_breakdowns[0].input_tokens);
    try std.testing.expectApproxEqAbs(@as(f64, 0.06), day.model_breakdowns[0].cost, 0.0001);

    try std.testing.expectEqual(@as(?[]const u8, null), day.project);
}

test "aggregateDaily - multiple days" {
    const entries = [_]types.UsageEntry{
        makeEntry("s1", "proj", 1736937000000, "claude-sonnet-4-20250514", 100, 10, 0, 0, 0.01), // 2025-01-15T10:30:00Z
        makeEntry("s1", "proj", 1736940600000, "claude-sonnet-4-20250514", 200, 20, 0, 0, 0.02), // 2025-01-15T11:30:00Z
        makeEntry("s1", "proj", 1737023400000, "claude-sonnet-4-20250514", 300, 30, 0, 0, 0.03), // 2025-01-16T10:30:00Z
    };

    const result = try aggregateDaily(std.testing.allocator, &entries, 0);
    defer freeAggregated(std.testing.allocator, result);

    try std.testing.expectEqual(@as(usize, 2), result.len);

    // Find each day (order not guaranteed)
    var found_15 = false;
    var found_16 = false;
    for (result) |day| {
        if (std.mem.eql(u8, day.period, "2025-01-15")) {
            found_15 = true;
            try std.testing.expectEqual(@as(u64, 300), day.input_tokens);
            try std.testing.expectEqual(@as(u64, 30), day.output_tokens);
            try std.testing.expectApproxEqAbs(@as(f64, 0.03), day.total_cost, 0.0001);
        } else if (std.mem.eql(u8, day.period, "2025-01-16")) {
            found_16 = true;
            try std.testing.expectEqual(@as(u64, 300), day.input_tokens);
            try std.testing.expectEqual(@as(u64, 30), day.output_tokens);
            try std.testing.expectApproxEqAbs(@as(f64, 0.03), day.total_cost, 0.0001);
        }
    }
    try std.testing.expect(found_15);
    try std.testing.expect(found_16);
}

test "aggregateDaily - multiple models sorted by cost descending" {
    const entries = [_]types.UsageEntry{
        makeEntry("s1", "proj", 1736937000000, "model-a", 100, 10, 0, 0, 2.0), // model A entry 1
        makeEntry("s1", "proj", 1736940600000, "model-a", 100, 10, 0, 0, 3.0), // model A entry 2
        makeEntry("s1", "proj", 1736944200000, "model-b", 500, 50, 0, 0, 10.0), // model B
        makeEntry("s1", "proj", 1736947800000, "model-c", 50, 5, 0, 0, 1.0), // model C
    };

    const result = try aggregateDaily(std.testing.allocator, &entries, 0);
    defer freeAggregated(std.testing.allocator, result);

    try std.testing.expectEqual(@as(usize, 1), result.len);
    const day = result[0];

    // Total cost: 2+3+10+1 = 16
    try std.testing.expectApproxEqAbs(@as(f64, 16.0), day.total_cost, 0.0001);

    // 3 unique models
    try std.testing.expectEqual(@as(usize, 3), day.models_used.len);

    // Model breakdowns sorted by cost descending: B(10), A(5), C(1)
    try std.testing.expectEqual(@as(usize, 3), day.model_breakdowns.len);
    try std.testing.expectEqualStrings("model-b", day.model_breakdowns[0].model_name);
    try std.testing.expectApproxEqAbs(@as(f64, 10.0), day.model_breakdowns[0].cost, 0.0001);

    try std.testing.expectEqualStrings("model-a", day.model_breakdowns[1].model_name);
    try std.testing.expectApproxEqAbs(@as(f64, 5.0), day.model_breakdowns[1].cost, 0.0001);

    try std.testing.expectEqualStrings("model-c", day.model_breakdowns[2].model_name);
    try std.testing.expectApproxEqAbs(@as(f64, 1.0), day.model_breakdowns[2].cost, 0.0001);
}

test "aggregateDaily - timezone affects grouping" {
    // 2025-01-15T23:30:00Z = epoch ms 1736983800000
    // With tz_offset=120 (+02:00), local time is 2025-01-16T01:30:00
    // Should be grouped under "2025-01-16"
    const entries = [_]types.UsageEntry{
        makeEntry("s1", "proj", 1736983800000, "claude-sonnet-4-20250514", 100, 10, 0, 0, 0.01),
    };

    const result = try aggregateDaily(std.testing.allocator, &entries, 120);
    defer freeAggregated(std.testing.allocator, result);

    try std.testing.expectEqual(@as(usize, 1), result.len);
    try std.testing.expectEqualStrings("2025-01-16", result[0].period);
}

test "aggregateMonthly - groups entries by month" {
    const entries = [_]types.UsageEntry{
        makeEntry("s1", "proj", 1736937000000, "model-a", 100, 10, 5, 50, 0.01), // 2025-01-15T10:30:00Z
        makeEntry("s1", "proj", 1737369000000, "model-a", 200, 20, 10, 100, 0.02), // 2025-01-20T10:30:00Z
        makeEntry("s1", "proj", 1738396200000, "model-b", 300, 30, 15, 150, 0.03), // 2025-02-01T10:30:00Z
    };

    const result = try aggregateMonthly(std.testing.allocator, &entries, 0);
    defer freeAggregated(std.testing.allocator, result);

    try std.testing.expectEqual(@as(usize, 2), result.len);

    var found_jan = false;
    var found_feb = false;
    for (result) |item| {
        if (std.mem.eql(u8, item.period, "2025-01")) {
            found_jan = true;
            try std.testing.expectEqual(@as(u64, 300), item.input_tokens);
            try std.testing.expectEqual(@as(u64, 30), item.output_tokens);
            try std.testing.expectEqual(@as(u64, 15), item.cache_creation_tokens);
            try std.testing.expectEqual(@as(u64, 150), item.cache_read_tokens);
            try std.testing.expectApproxEqAbs(@as(f64, 0.03), item.total_cost, 0.0001);
        } else if (std.mem.eql(u8, item.period, "2025-02")) {
            found_feb = true;
            try std.testing.expectEqual(@as(u64, 300), item.input_tokens);
            try std.testing.expectEqual(@as(u64, 30), item.output_tokens);
            try std.testing.expectEqual(@as(u64, 15), item.cache_creation_tokens);
            try std.testing.expectEqual(@as(u64, 150), item.cache_read_tokens);
            try std.testing.expectApproxEqAbs(@as(f64, 0.03), item.total_cost, 0.0001);
        }
    }
    try std.testing.expect(found_jan);
    try std.testing.expect(found_feb);
}

test "aggregateWeekly - week starts Sunday" {
    // Mon 2025-01-13T10:30:00Z = 1736764200000  (week starting Sun 2025-01-12)
    // Wed 2025-01-15T10:30:00Z = 1736937000000  (week starting Sun 2025-01-12)
    // Mon 2025-01-20T10:30:00Z = 1737369000000  (week starting Sun 2025-01-19)
    const entries = [_]types.UsageEntry{
        makeEntry("s1", "proj", 1736764200000, "model-a", 100, 10, 5, 50, 0.01),
        makeEntry("s1", "proj", 1736937000000, "model-a", 200, 20, 10, 100, 0.02),
        makeEntry("s1", "proj", 1737369000000, "model-b", 300, 30, 15, 150, 0.03),
    };

    const result = try aggregateWeekly(std.testing.allocator, &entries, 0, 0);
    defer freeAggregated(std.testing.allocator, result);

    try std.testing.expectEqual(@as(usize, 2), result.len);

    var found_w12 = false;
    var found_w19 = false;
    for (result) |item| {
        if (std.mem.eql(u8, item.period, "2025-01-12")) {
            found_w12 = true;
            try std.testing.expectEqual(@as(u64, 300), item.input_tokens);
            try std.testing.expectEqual(@as(u64, 30), item.output_tokens);
            try std.testing.expectApproxEqAbs(@as(f64, 0.03), item.total_cost, 0.0001);
        } else if (std.mem.eql(u8, item.period, "2025-01-19")) {
            found_w19 = true;
            try std.testing.expectEqual(@as(u64, 300), item.input_tokens);
            try std.testing.expectEqual(@as(u64, 30), item.output_tokens);
            try std.testing.expectApproxEqAbs(@as(f64, 0.03), item.total_cost, 0.0001);
        }
    }
    try std.testing.expect(found_w12);
    try std.testing.expect(found_w19);
}

test "aggregateWeekly - week starts Monday" {
    // Mon 2025-01-13T10:30:00Z = 1736764200000  (week starting Mon 2025-01-13)
    // Wed 2025-01-15T10:30:00Z = 1736937000000  (week starting Mon 2025-01-13)
    // Mon 2025-01-20T10:30:00Z = 1737369000000  (week starting Mon 2025-01-20)
    const entries = [_]types.UsageEntry{
        makeEntry("s1", "proj", 1736764200000, "model-a", 100, 10, 5, 50, 0.01),
        makeEntry("s1", "proj", 1736937000000, "model-a", 200, 20, 10, 100, 0.02),
        makeEntry("s1", "proj", 1737369000000, "model-b", 300, 30, 15, 150, 0.03),
    };

    const result = try aggregateWeekly(std.testing.allocator, &entries, 0, 1);
    defer freeAggregated(std.testing.allocator, result);

    try std.testing.expectEqual(@as(usize, 2), result.len);

    var found_w13 = false;
    var found_w20 = false;
    for (result) |item| {
        if (std.mem.eql(u8, item.period, "2025-01-13")) {
            found_w13 = true;
            try std.testing.expectEqual(@as(u64, 300), item.input_tokens);
            try std.testing.expectEqual(@as(u64, 30), item.output_tokens);
            try std.testing.expectApproxEqAbs(@as(f64, 0.03), item.total_cost, 0.0001);
        } else if (std.mem.eql(u8, item.period, "2025-01-20")) {
            found_w20 = true;
            try std.testing.expectEqual(@as(u64, 300), item.input_tokens);
            try std.testing.expectEqual(@as(u64, 30), item.output_tokens);
            try std.testing.expectApproxEqAbs(@as(f64, 0.03), item.total_cost, 0.0001);
        }
    }
    try std.testing.expect(found_w13);
    try std.testing.expect(found_w20);
}

fn freeSessionUsage(allocator: std.mem.Allocator, items: []types.SessionUsage) void {
    for (items) |item| {
        allocator.free(item.session_id);
        allocator.free(item.project_path);
        allocator.free(item.last_activity);
        for (item.model_breakdowns) |mb| allocator.free(mb.model_name);
        allocator.free(item.model_breakdowns);
        for (item.models_used) |m| allocator.free(m);
        allocator.free(item.models_used);
    }
    allocator.free(items);
}

test "aggregateSession - single session sums tokens and cost" {
    const entries = [_]types.UsageEntry{
        makeEntry("sess-1", "/tmp/proj", 1736937000000, "claude-sonnet-4-20250514", 100, 10, 5, 50, 0.01), // 2025-01-15T10:30:00Z
        makeEntry("sess-1", "/tmp/proj", 1736940600000, "claude-sonnet-4-20250514", 200, 20, 10, 100, 0.02), // 2025-01-15T11:30:00Z
        makeEntry("sess-1", "/tmp/proj", 1736944200000, "claude-sonnet-4-20250514", 300, 30, 15, 150, 0.03), // 2025-01-15T12:30:00Z
    };

    const result = try aggregateSession(std.testing.allocator, &entries, 0);
    defer freeSessionUsage(std.testing.allocator, result);

    try std.testing.expectEqual(@as(usize, 1), result.len);

    const sess = result[0];
    try std.testing.expectEqualStrings("sess-1", sess.session_id);
    try std.testing.expectEqualStrings("/tmp/proj", sess.project_path);
    try std.testing.expectEqual(@as(u64, 600), sess.input_tokens);
    try std.testing.expectEqual(@as(u64, 60), sess.output_tokens);
    try std.testing.expectEqual(@as(u64, 30), sess.cache_creation_tokens);
    try std.testing.expectEqual(@as(u64, 300), sess.cache_read_tokens);
    try std.testing.expectApproxEqAbs(@as(f64, 0.06), sess.total_cost, 0.0001);
    try std.testing.expectEqualStrings("2025-01-15", sess.last_activity);

    try std.testing.expectEqual(@as(usize, 1), sess.models_used.len);
    try std.testing.expectEqualStrings("claude-sonnet-4-20250514", sess.models_used[0]);
    try std.testing.expectEqual(@as(usize, 1), sess.model_breakdowns.len);
    try std.testing.expectEqualStrings("claude-sonnet-4-20250514", sess.model_breakdowns[0].model_name);
}

test "aggregateSession - multiple sessions grouped correctly" {
    const entries = [_]types.UsageEntry{
        makeEntry("sess-1", "/tmp/proj-a", 1736937000000, "model-a", 100, 10, 5, 50, 0.01),
        makeEntry("sess-1", "/tmp/proj-a", 1736940600000, "model-a", 200, 20, 10, 100, 0.02),
        makeEntry("sess-2", "/tmp/proj-b", 1736944200000, "model-b", 500, 50, 25, 250, 0.10),
    };

    const result = try aggregateSession(std.testing.allocator, &entries, 0);
    defer freeSessionUsage(std.testing.allocator, result);

    try std.testing.expectEqual(@as(usize, 2), result.len);

    var found_s1 = false;
    var found_s2 = false;
    for (result) |sess| {
        if (std.mem.eql(u8, sess.session_id, "sess-1")) {
            found_s1 = true;
            try std.testing.expectEqualStrings("/tmp/proj-a", sess.project_path);
            try std.testing.expectEqual(@as(u64, 300), sess.input_tokens);
            try std.testing.expectEqual(@as(u64, 30), sess.output_tokens);
            try std.testing.expectApproxEqAbs(@as(f64, 0.03), sess.total_cost, 0.0001);
        } else if (std.mem.eql(u8, sess.session_id, "sess-2")) {
            found_s2 = true;
            try std.testing.expectEqualStrings("/tmp/proj-b", sess.project_path);
            try std.testing.expectEqual(@as(u64, 500), sess.input_tokens);
            try std.testing.expectEqual(@as(u64, 50), sess.output_tokens);
            try std.testing.expectApproxEqAbs(@as(f64, 0.10), sess.total_cost, 0.0001);
        }
    }
    try std.testing.expect(found_s1);
    try std.testing.expect(found_s2);
}

test "calculateTotals - sums two AggregatedUsage items" {
    const items = [_]types.AggregatedUsage{
        .{
            .period = "2025-01-15",
            .input_tokens = 100,
            .output_tokens = 50,
            .cache_creation_tokens = 10,
            .cache_read_tokens = 20,
            .total_cost = 1.5,
            .models_used = &.{},
            .model_breakdowns = &.{},
            .project = null,
        },
        .{
            .period = "2025-01-16",
            .input_tokens = 200,
            .output_tokens = 100,
            .cache_creation_tokens = 30,
            .cache_read_tokens = 40,
            .total_cost = 2.5,
            .models_used = &.{},
            .model_breakdowns = &.{},
            .project = null,
        },
    };

    const totals = calculateTotals(&items);
    try std.testing.expectEqual(@as(u64, 300), totals.input_tokens);
    try std.testing.expectEqual(@as(u64, 150), totals.output_tokens);
    try std.testing.expectEqual(@as(u64, 40), totals.cache_creation_tokens);
    try std.testing.expectEqual(@as(u64, 60), totals.cache_read_tokens);
    try std.testing.expectEqual(@as(u64, 550), totals.total_tokens);
    try std.testing.expectApproxEqAbs(@as(f64, 4.0), totals.total_cost, 0.0001);
}

test "calculateTotals - empty slice returns all zeros" {
    const items = [_]types.AggregatedUsage{};
    const totals = calculateTotals(&items);
    try std.testing.expectEqual(@as(u64, 0), totals.input_tokens);
    try std.testing.expectEqual(@as(u64, 0), totals.output_tokens);
    try std.testing.expectEqual(@as(u64, 0), totals.cache_creation_tokens);
    try std.testing.expectEqual(@as(u64, 0), totals.cache_read_tokens);
    try std.testing.expectEqual(@as(u64, 0), totals.total_tokens);
    try std.testing.expectApproxEqAbs(@as(f64, 0.0), totals.total_cost, 0.0001);
}

test "calculateSessionTotals - sums two SessionUsage items" {
    const items = [_]types.SessionUsage{
        .{
            .session_id = "sess-1",
            .project_path = "/proj",
            .input_tokens = 500,
            .output_tokens = 200,
            .cache_creation_tokens = 50,
            .cache_read_tokens = 100,
            .total_cost = 3.0,
            .last_activity = "2025-01-15",
            .models_used = &.{},
            .model_breakdowns = &.{},
        },
        .{
            .session_id = "sess-2",
            .project_path = "/proj",
            .input_tokens = 300,
            .output_tokens = 150,
            .cache_creation_tokens = 25,
            .cache_read_tokens = 75,
            .total_cost = 2.0,
            .last_activity = "2025-01-16",
            .models_used = &.{},
            .model_breakdowns = &.{},
        },
    };

    const totals = calculateSessionTotals(&items);
    try std.testing.expectEqual(@as(u64, 800), totals.input_tokens);
    try std.testing.expectEqual(@as(u64, 350), totals.output_tokens);
    try std.testing.expectEqual(@as(u64, 75), totals.cache_creation_tokens);
    try std.testing.expectEqual(@as(u64, 175), totals.cache_read_tokens);
    try std.testing.expectEqual(@as(u64, 1400), totals.total_tokens);
    try std.testing.expectApproxEqAbs(@as(f64, 5.0), totals.total_cost, 0.0001);
}

test "aggregateSession - last activity reflects latest timestamp" {
    // Entries at 10:00, 12:00, 11:00 — last_activity should be from 12:00
    const entries = [_]types.UsageEntry{
        makeEntry("sess-1", "/tmp/proj", 1736937000000, "model-a", 100, 10, 0, 0, 0.01), // 2025-01-15T10:30:00Z
        makeEntry("sess-1", "/tmp/proj", 1736944200000, "model-a", 100, 10, 0, 0, 0.01), // 2025-01-15T12:30:00Z
        makeEntry("sess-1", "/tmp/proj", 1736940600000, "model-a", 100, 10, 0, 0, 0.01), // 2025-01-15T11:30:00Z
    };

    const result = try aggregateSession(std.testing.allocator, &entries, 0);
    defer freeSessionUsage(std.testing.allocator, result);

    try std.testing.expectEqual(@as(usize, 1), result.len);
    try std.testing.expectEqualStrings("2025-01-15", result[0].last_activity);
}
