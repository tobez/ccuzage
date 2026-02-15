// ABOUTME: Integration tests exercising the full pipeline from JSONL parsing through JSON output.
// ABOUTME: Covers daily, monthly, weekly, session, and blocks pipelines with dedup and error handling.
const std = @import("std");
const types = @import("types.zig");
const loader = @import("loader.zig");
const aggregate = @import("aggregate.zig");
const blocks_mod = @import("blocks.zig");
const json_output = @import("json_output.zig");

// =============================================================================
// Test fixture: 8 JSONL lines spanning 3 dates, 2 models, 2 sessions.
// After dedup and filtering: 5 valid unique entries.
// =============================================================================

// Entry 1: sess-alpha, proj-alpha, 2025-01-14T10:00:00Z, sonnet, 500/100/50/200, $0.05
const line_1 =
    \\{"timestamp":"2025-01-14T10:00:00.000Z","message":{"usage":{"input_tokens":500,"output_tokens":100,"cache_creation_input_tokens":50,"cache_read_input_tokens":200},"model":"claude-sonnet-4-20250514","id":"msg-001"},"costUSD":0.05,"requestId":"req-001"}
;

// Entry 2: sess-alpha, proj-alpha, 2025-01-14T11:00:00Z, opus, 1000/200/100/400, $0.15
const line_2 =
    \\{"timestamp":"2025-01-14T11:00:00.000Z","message":{"usage":{"input_tokens":1000,"output_tokens":200,"cache_creation_input_tokens":100,"cache_read_input_tokens":400},"model":"claude-opus-4","id":"msg-002"},"costUSD":0.15,"requestId":"req-002"}
;

// Entry 3: DUPLICATE of entry 1 (same msg-001:req-001) — should be removed
const line_3_dup =
    \\{"timestamp":"2025-01-14T12:00:00.000Z","message":{"usage":{"input_tokens":500,"output_tokens":100,"cache_creation_input_tokens":50,"cache_read_input_tokens":200},"model":"claude-sonnet-4-20250514","id":"msg-001"},"costUSD":0.05,"requestId":"req-001"}
;

// Entry 4: invalid JSON — should be skipped
const line_4_invalid = "this is not valid json {{{";

// Entry 5: API error message — should be skipped
const line_5_error =
    \\{"timestamp":"2025-01-14T13:00:00.000Z","message":{"usage":{"input_tokens":100,"output_tokens":50},"model":"claude-sonnet-4-20250514","id":"msg-err"},"costUSD":0.01,"requestId":"req-err","isApiErrorMessage":true}
;

// Entry 6: sess-alpha, proj-alpha, 2025-01-15T09:00:00Z, sonnet, 300/60/30/120, $0.03
const line_6 =
    \\{"timestamp":"2025-01-15T09:00:00.000Z","message":{"usage":{"input_tokens":300,"output_tokens":60,"cache_creation_input_tokens":30,"cache_read_input_tokens":120},"model":"claude-sonnet-4-20250514","id":"msg-003"},"costUSD":0.03,"requestId":"req-003"}
;

// Entry 7: sess-beta, proj-beta, 2025-01-15T14:00:00Z, opus, 2000/500/200/800, $0.30
const line_7 =
    \\{"timestamp":"2025-01-15T14:00:00.000Z","message":{"usage":{"input_tokens":2000,"output_tokens":500,"cache_creation_input_tokens":200,"cache_read_input_tokens":800},"model":"claude-opus-4","id":"msg-004"},"costUSD":0.30,"requestId":"req-004"}
;

// Entry 8: sess-alpha, proj-alpha, 2025-01-16T10:00:00Z, sonnet, 400/80/40/160, $0.04
const line_8 =
    \\{"timestamp":"2025-01-16T10:00:00.000Z","message":{"usage":{"input_tokens":400,"output_tokens":80,"cache_creation_input_tokens":40,"cache_read_input_tokens":160},"model":"claude-sonnet-4-20250514","id":"msg-005"},"costUSD":0.04,"requestId":"req-005"}
;

const fixture_lines_alpha = &[_][]const u8{
    line_1, line_2, line_3_dup, line_4_invalid, line_5_error,
    line_6, line_8,
};

const fixture_lines_beta = &[_][]const u8{
    line_7,
};

// =============================================================================
// Helper: load the fixture into UsageEntry slice.
// Loads alpha and beta sessions separately (as they would be from different files),
// then concatenates.
// =============================================================================

fn loadFixture(allocator: std.mem.Allocator) ![]types.UsageEntry {
    const alpha = try loader.loadEntriesFromLines(allocator, fixture_lines_alpha, "sess-alpha", "proj-alpha");
    errdefer freeEntries(allocator, alpha);

    const beta = try loader.loadEntriesFromLines(allocator, fixture_lines_beta, "sess-beta", "proj-beta");
    errdefer freeEntries(allocator, beta);

    const combined = try allocator.alloc(types.UsageEntry, alpha.len + beta.len);
    @memcpy(combined[0..alpha.len], alpha);
    @memcpy(combined[alpha.len..], beta);

    // Free the temporary slice containers (entry data is copied into combined)
    allocator.free(alpha);
    allocator.free(beta);

    return combined;
}

fn freeEntries(allocator: std.mem.Allocator, entries: []types.UsageEntry) void {
    for (entries) |e| {
        allocator.free(e.model);
        allocator.free(e.message_id);
        allocator.free(e.request_id);
    }
    allocator.free(entries);
}

fn freeAggregated(allocator: std.mem.Allocator, items: []types.AggregatedUsage) void {
    for (items) |item| {
        allocator.free(item.period);
        if (item.project) |p| allocator.free(p);
        for (item.model_breakdowns) |mb| allocator.free(mb.model_name);
        allocator.free(item.model_breakdowns);
        for (item.models_used) |m| allocator.free(m);
        allocator.free(item.models_used);
    }
    allocator.free(items);
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

fn parseJsonValue(allocator: std.mem.Allocator, json_str: []const u8) !std.json.Parsed(std.json.Value) {
    return std.json.parseFromSlice(std.json.Value, allocator, json_str, .{});
}

// =============================================================================
// Test 1: Deduplication verification
// =============================================================================

test "integration: dedup and filtering produces exactly 5 entries" {
    const allocator = std.testing.allocator;
    const entries = try loadFixture(allocator);
    defer freeEntries(allocator, entries);

    // 8 raw lines -> 5 valid unique entries
    // Removed: 1 duplicate (line_3_dup), 1 invalid JSON (line_4_invalid), 1 API error (line_5_error)
    try std.testing.expectEqual(@as(usize, 5), entries.len);
}

// =============================================================================
// Test 2: Full daily pipeline
// =============================================================================

test "integration: daily pipeline produces correct JSON" {
    const allocator = std.testing.allocator;
    const entries = try loadFixture(allocator);
    defer freeEntries(allocator, entries);

    const daily = try aggregate.aggregateDaily(allocator, entries, 0, false);
    defer freeAggregated(allocator, daily);

    aggregate.sortAggregated(daily, .asc);
    const totals = aggregate.calculateTotals(daily);

    const json_str = try json_output.reportToJson(allocator, "daily", "date", daily, totals);
    defer allocator.free(json_str);

    const parsed = try parseJsonValue(allocator, json_str);
    defer parsed.deinit();
    const root = parsed.value.object;

    // 3 days
    const daily_arr = root.get("daily").?.array;
    try std.testing.expectEqual(@as(usize, 3), daily_arr.items.len);

    // Sorted ascending: 2025-01-14, 2025-01-15, 2025-01-16
    const day0 = daily_arr.items[0].object;
    const day1 = daily_arr.items[1].object;
    const day2 = daily_arr.items[2].object;

    try std.testing.expectEqualStrings("2025-01-14", day0.get("date").?.string);
    try std.testing.expectEqualStrings("2025-01-15", day1.get("date").?.string);
    try std.testing.expectEqualStrings("2025-01-16", day2.get("date").?.string);

    // Day 2025-01-14: entry1(500/100/50/200) + entry2(1000/200/100/400) = 1500/300/150/600
    try std.testing.expectEqual(@as(i64, 1500), day0.get("inputTokens").?.integer);
    try std.testing.expectEqual(@as(i64, 300), day0.get("outputTokens").?.integer);
    try std.testing.expectEqual(@as(i64, 150), day0.get("cacheCreationTokens").?.integer);
    try std.testing.expectEqual(@as(i64, 600), day0.get("cacheReadTokens").?.integer);
    try std.testing.expectApproxEqAbs(0.20, day0.get("totalCost").?.float, 0.001);
    // 2 models on this day
    try std.testing.expectEqual(@as(usize, 2), day0.get("modelsUsed").?.array.items.len);

    // Day 2025-01-15: entry6(300/60/30/120) + entry7(2000/500/200/800) = 2300/560/230/920
    try std.testing.expectEqual(@as(i64, 2300), day1.get("inputTokens").?.integer);
    try std.testing.expectEqual(@as(i64, 560), day1.get("outputTokens").?.integer);
    try std.testing.expectEqual(@as(i64, 230), day1.get("cacheCreationTokens").?.integer);
    try std.testing.expectEqual(@as(i64, 920), day1.get("cacheReadTokens").?.integer);
    try std.testing.expectApproxEqAbs(0.33, day1.get("totalCost").?.float, 0.001);
    // 2 models on this day
    try std.testing.expectEqual(@as(usize, 2), day1.get("modelsUsed").?.array.items.len);

    // Day 2025-01-16: entry8(400/80/40/160)
    try std.testing.expectEqual(@as(i64, 400), day2.get("inputTokens").?.integer);
    try std.testing.expectEqual(@as(i64, 80), day2.get("outputTokens").?.integer);
    try std.testing.expectEqual(@as(i64, 40), day2.get("cacheCreationTokens").?.integer);
    try std.testing.expectEqual(@as(i64, 160), day2.get("cacheReadTokens").?.integer);
    try std.testing.expectApproxEqAbs(0.04, day2.get("totalCost").?.float, 0.001);
    // 1 model on this day
    try std.testing.expectEqual(@as(usize, 1), day2.get("modelsUsed").?.array.items.len);

    // Totals: 4200/940/420/1680, $0.57
    const tot = root.get("totals").?.object;
    try std.testing.expectEqual(@as(i64, 4200), tot.get("inputTokens").?.integer);
    try std.testing.expectEqual(@as(i64, 940), tot.get("outputTokens").?.integer);
    try std.testing.expectEqual(@as(i64, 420), tot.get("cacheCreationTokens").?.integer);
    try std.testing.expectEqual(@as(i64, 1680), tot.get("cacheReadTokens").?.integer);
    try std.testing.expectApproxEqAbs(0.57, tot.get("totalCost").?.float, 0.001);
}

// =============================================================================
// Test 3: Full monthly pipeline
// =============================================================================

test "integration: monthly pipeline produces correct JSON" {
    const allocator = std.testing.allocator;
    const entries = try loadFixture(allocator);
    defer freeEntries(allocator, entries);

    const monthly = try aggregate.aggregateMonthly(allocator, entries, 0, false);
    defer freeAggregated(allocator, monthly);

    aggregate.sortAggregated(monthly, .asc);
    const totals = aggregate.calculateTotals(monthly);

    const json_str = try json_output.reportToJson(allocator, "monthly", "month", monthly, totals);
    defer allocator.free(json_str);

    const parsed = try parseJsonValue(allocator, json_str);
    defer parsed.deinit();
    const root = parsed.value.object;

    // All entries are in 2025-01 -> 1 month
    const monthly_arr = root.get("monthly").?.array;
    try std.testing.expectEqual(@as(usize, 1), monthly_arr.items.len);

    const month0 = monthly_arr.items[0].object;
    try std.testing.expectEqualStrings("2025-01", month0.get("month").?.string);
    try std.testing.expectEqual(@as(i64, 4200), month0.get("inputTokens").?.integer);
    try std.testing.expectApproxEqAbs(0.57, month0.get("totalCost").?.float, 0.001);

    // Totals match
    const tot = root.get("totals").?.object;
    try std.testing.expectEqual(@as(i64, 4200), tot.get("inputTokens").?.integer);
    try std.testing.expectApproxEqAbs(0.57, tot.get("totalCost").?.float, 0.001);
}

// =============================================================================
// Test 4: Full weekly pipeline
// =============================================================================

test "integration: weekly pipeline produces correct JSON" {
    const allocator = std.testing.allocator;
    const entries = try loadFixture(allocator);
    defer freeEntries(allocator, entries);

    // Week starts Monday (day=1). 2025-01-14 is a Tuesday.
    // Week of 2025-01-13 covers Jan 13-19 -> entries on 14, 15, 16 all in same week
    const weekly = try aggregate.aggregateWeekly(allocator, entries, 0, 1, false);
    defer freeAggregated(allocator, weekly);

    aggregate.sortAggregated(weekly, .asc);
    const totals = aggregate.calculateTotals(weekly);

    const json_str = try json_output.reportToJson(allocator, "weekly", "week", weekly, totals);
    defer allocator.free(json_str);

    const parsed = try parseJsonValue(allocator, json_str);
    defer parsed.deinit();
    const root = parsed.value.object;

    // All 3 dates fall in same Mon-start week -> 1 week
    const weekly_arr = root.get("weekly").?.array;
    try std.testing.expectEqual(@as(usize, 1), weekly_arr.items.len);

    const week0 = weekly_arr.items[0].object;
    try std.testing.expectEqualStrings("2025-01-13", week0.get("week").?.string);
    try std.testing.expectEqual(@as(i64, 4200), week0.get("inputTokens").?.integer);
    try std.testing.expectApproxEqAbs(0.57, week0.get("totalCost").?.float, 0.001);

    const tot = root.get("totals").?.object;
    try std.testing.expectApproxEqAbs(0.57, tot.get("totalCost").?.float, 0.001);
}

// =============================================================================
// Test 5: Full session pipeline
// =============================================================================

test "integration: session pipeline produces correct JSON" {
    const allocator = std.testing.allocator;
    const entries = try loadFixture(allocator);
    defer freeEntries(allocator, entries);

    const sessions = try aggregate.aggregateSession(allocator, entries, 0);
    defer freeSessionUsage(allocator, sessions);

    aggregate.sortSessions(sessions, .desc);
    const totals = aggregate.calculateSessionTotals(sessions);

    const json_str = try json_output.sessionToJson(allocator, sessions, totals);
    defer allocator.free(json_str);

    const parsed = try parseJsonValue(allocator, json_str);
    defer parsed.deinit();
    const root = parsed.value.object;

    const sessions_arr = root.get("sessions").?.array;
    try std.testing.expectEqual(@as(usize, 2), sessions_arr.items.len);

    // Find each session (order depends on last_activity desc sort)
    var found_alpha = false;
    var found_beta = false;
    for (sessions_arr.items) |item| {
        const obj = item.object;
        const sid = obj.get("sessionId").?.string;

        if (std.mem.eql(u8, sid, "sess-alpha")) {
            found_alpha = true;
            // sess-alpha: entries 1,2,6,8 -> 500+1000+300+400=2200 input, 100+200+60+80=440 output
            try std.testing.expectEqual(@as(i64, 2200), obj.get("inputTokens").?.integer);
            try std.testing.expectEqual(@as(i64, 440), obj.get("outputTokens").?.integer);
            try std.testing.expectApproxEqAbs(0.27, obj.get("totalCost").?.float, 0.001);
            try std.testing.expectEqualStrings("proj-alpha", obj.get("projectPath").?.string);
            // Last activity: 2025-01-16 (entry 8)
            try std.testing.expectEqualStrings("2025-01-16", obj.get("lastActivity").?.string);
        } else if (std.mem.eql(u8, sid, "sess-beta")) {
            found_beta = true;
            // sess-beta: entry 7 -> 2000 input, 500 output
            try std.testing.expectEqual(@as(i64, 2000), obj.get("inputTokens").?.integer);
            try std.testing.expectEqual(@as(i64, 500), obj.get("outputTokens").?.integer);
            try std.testing.expectApproxEqAbs(0.30, obj.get("totalCost").?.float, 0.001);
            try std.testing.expectEqualStrings("proj-beta", obj.get("projectPath").?.string);
            try std.testing.expectEqualStrings("2025-01-15", obj.get("lastActivity").?.string);
        }
    }
    try std.testing.expect(found_alpha);
    try std.testing.expect(found_beta);

    // Totals
    const tot = root.get("totals").?.object;
    try std.testing.expectEqual(@as(i64, 4200), tot.get("inputTokens").?.integer);
    try std.testing.expectEqual(@as(i64, 940), tot.get("outputTokens").?.integer);
    try std.testing.expectApproxEqAbs(0.57, tot.get("totalCost").?.float, 0.001);
}

// =============================================================================
// Test 6: Full blocks pipeline
// =============================================================================

test "integration: blocks pipeline produces valid JSON structure" {
    const allocator = std.testing.allocator;
    const entries = try loadFixture(allocator);
    defer freeEntries(allocator, entries);

    // Use now_ms far in the future so nothing is active
    const far_future: i64 = 2000000000000;
    const blks = try blocks_mod.identifyBlocks(allocator, entries, 5, far_future);
    defer blocks_mod.freeBlocks(allocator, blks);

    const json_str = try json_output.blocksToJson(allocator, blks);
    defer allocator.free(json_str);

    const parsed = try parseJsonValue(allocator, json_str);
    defer parsed.deinit();
    const root = parsed.value.object;

    // Must have "blocks" array
    const blocks_arr = root.get("blocks").?.array;
    try std.testing.expect(blocks_arr.items.len > 0);

    // No "totals" key (blocks format doesn't have totals)
    try std.testing.expectEqual(@as(?std.json.Value, null), root.get("totals"));

    // Verify every non-gap block has required fields
    var total_entries: i64 = 0;
    var total_input: i64 = 0;
    for (blocks_arr.items) |item| {
        const obj = item.object;
        // All blocks must have these fields
        try std.testing.expect(obj.get("id") != null);
        try std.testing.expect(obj.get("startTime") != null);
        try std.testing.expect(obj.get("endTime") != null);
        try std.testing.expect(obj.get("isActive") != null);
        try std.testing.expect(obj.get("isGap") != null);
        try std.testing.expect(obj.get("entries") != null);
        try std.testing.expect(obj.get("costUSD") != null);
        try std.testing.expect(obj.get("models") != null);
        try std.testing.expect(obj.get("tokenCounts") != null);

        const is_gap = obj.get("isGap").?.bool;
        if (!is_gap) {
            total_entries += obj.get("entries").?.integer;
            total_input += obj.get("tokenCounts").?.object.get("inputTokens").?.integer;
        }

        // Nothing should be active (far future now)
        try std.testing.expectEqual(false, obj.get("isActive").?.bool);
    }

    // Total entries across non-gap blocks should equal our 5 valid entries
    try std.testing.expectEqual(@as(i64, 5), total_entries);
    // Total input tokens across non-gap blocks should equal 4200
    try std.testing.expectEqual(@as(i64, 4200), total_input);
}

// =============================================================================
// Test 7: Empty input full pipeline
// =============================================================================

test "integration: empty input produces empty JSON for all pipelines" {
    const allocator = std.testing.allocator;

    // Load from empty lines array
    const empty_lines = &[_][]const u8{};
    const entries = try loader.loadEntriesFromLines(allocator, empty_lines, "sess-empty", "proj-empty");
    defer allocator.free(entries);
    try std.testing.expectEqual(@as(usize, 0), entries.len);

    // Daily pipeline
    {
        const daily = try aggregate.aggregateDaily(allocator, entries, 0, false);
        defer allocator.free(daily);
        try std.testing.expectEqual(@as(usize, 0), daily.len);

        const totals = aggregate.calculateTotals(daily);
        try std.testing.expectEqual(@as(u64, 0), totals.input_tokens);
        try std.testing.expectEqual(@as(u64, 0), totals.output_tokens);
        try std.testing.expectEqual(@as(u64, 0), totals.total_tokens);
        try std.testing.expectApproxEqAbs(@as(f64, 0.0), totals.total_cost, 0.001);

        const json_str = try json_output.reportToJson(allocator, "daily", "date", daily, totals);
        defer allocator.free(json_str);

        const parsed = try parseJsonValue(allocator, json_str);
        defer parsed.deinit();
        const root = parsed.value.object;

        try std.testing.expectEqual(@as(usize, 0), root.get("daily").?.array.items.len);
        try std.testing.expectEqual(@as(i64, 0), root.get("totals").?.object.get("totalTokens").?.integer);
    }

    // Session pipeline
    {
        const sessions = try aggregate.aggregateSession(allocator, entries, 0);
        defer allocator.free(sessions);
        try std.testing.expectEqual(@as(usize, 0), sessions.len);

        const totals = aggregate.calculateSessionTotals(sessions);

        const json_str = try json_output.sessionToJson(allocator, sessions, totals);
        defer allocator.free(json_str);

        const parsed = try parseJsonValue(allocator, json_str);
        defer parsed.deinit();
        const root = parsed.value.object;

        try std.testing.expectEqual(@as(usize, 0), root.get("sessions").?.array.items.len);
        try std.testing.expectEqual(@as(i64, 0), root.get("totals").?.object.get("totalTokens").?.integer);
    }

    // Blocks pipeline
    {
        const blks = try blocks_mod.identifyBlocks(allocator, entries, 5, 2000000000000);
        // Empty input returns a comptime empty slice, no need to free
        try std.testing.expectEqual(@as(usize, 0), blks.len);

        const json_str = try json_output.blocksToJson(allocator, blks);
        defer allocator.free(json_str);

        const parsed = try parseJsonValue(allocator, json_str);
        defer parsed.deinit();
        const root = parsed.value.object;

        try std.testing.expectEqual(@as(usize, 0), root.get("blocks").?.array.items.len);
        try std.testing.expectEqual(@as(?std.json.Value, null), root.get("totals"));
    }
}

// =============================================================================
// Test 8: Single entry full pipeline
// =============================================================================

test "integration: single entry produces correct output across all pipelines" {
    const allocator = std.testing.allocator;

    // One valid JSONL line: 2025-01-14T10:00:00Z, sonnet, 500/100/50/200, $0.05
    const single_line = &[_][]const u8{line_1};
    const entries = try loader.loadEntriesFromLines(allocator, single_line, "sess-single", "proj-single");
    defer freeEntries(allocator, entries);
    try std.testing.expectEqual(@as(usize, 1), entries.len);

    // Daily pipeline: 1 day with correct values
    {
        const daily = try aggregate.aggregateDaily(allocator, entries, 0, false);
        defer freeAggregated(allocator, daily);
        try std.testing.expectEqual(@as(usize, 1), daily.len);

        aggregate.sortAggregated(daily, .asc);
        try std.testing.expectEqualStrings("2025-01-14", daily[0].period);
        try std.testing.expectEqual(@as(u64, 500), daily[0].input_tokens);
        try std.testing.expectEqual(@as(u64, 100), daily[0].output_tokens);
        try std.testing.expectEqual(@as(u64, 50), daily[0].cache_creation_tokens);
        try std.testing.expectEqual(@as(u64, 200), daily[0].cache_read_tokens);
        try std.testing.expectApproxEqAbs(@as(f64, 0.05), daily[0].total_cost, 0.001);

        const totals = aggregate.calculateTotals(daily);
        try std.testing.expectEqual(@as(u64, 850), totals.total_tokens);

        const json_str = try json_output.reportToJson(allocator, "daily", "date", daily, totals);
        defer allocator.free(json_str);

        const parsed = try parseJsonValue(allocator, json_str);
        defer parsed.deinit();
        const root = parsed.value.object;

        try std.testing.expectEqual(@as(usize, 1), root.get("daily").?.array.items.len);
        try std.testing.expectApproxEqAbs(@as(f64, 0.05), root.get("totals").?.object.get("totalCost").?.float, 0.001);
    }

    // Session pipeline: 1 session
    {
        const sessions = try aggregate.aggregateSession(allocator, entries, 0);
        defer freeSessionUsage(allocator, sessions);
        try std.testing.expectEqual(@as(usize, 1), sessions.len);
        try std.testing.expectEqualStrings("sess-single", sessions[0].session_id);
        try std.testing.expectEqualStrings("proj-single", sessions[0].project_path);

        const totals = aggregate.calculateSessionTotals(sessions);

        const json_str = try json_output.sessionToJson(allocator, sessions, totals);
        defer allocator.free(json_str);

        const parsed = try parseJsonValue(allocator, json_str);
        defer parsed.deinit();
        const root = parsed.value.object;

        try std.testing.expectEqual(@as(usize, 1), root.get("sessions").?.array.items.len);
    }

    // Blocks pipeline: 1 block, not active (now far in future)
    {
        const far_future: i64 = 2000000000000;
        const blks = try blocks_mod.identifyBlocks(allocator, entries, 5, far_future);
        defer blocks_mod.freeBlocks(allocator, blks);

        // Single entry => 1 data block, no gaps
        try std.testing.expectEqual(@as(usize, 1), blks.len);
        try std.testing.expectEqual(false, blks[0].is_gap);
        try std.testing.expectEqual(false, blks[0].is_active);
        try std.testing.expectEqual(@as(u32, 1), blks[0].entry_count);
        // Single entry => duration = 0 => burn_rate should be null
        try std.testing.expectEqual(@as(?types.BurnRate, null), blks[0].burn_rate);

        const json_str = try json_output.blocksToJson(allocator, blks);
        defer allocator.free(json_str);

        const parsed = try parseJsonValue(allocator, json_str);
        defer parsed.deinit();
        const root = parsed.value.object;

        const blocks_arr = root.get("blocks").?.array;
        try std.testing.expectEqual(@as(usize, 1), blocks_arr.items.len);
        // burn_rate is null in JSON
        try std.testing.expect(blocks_arr.items[0].object.get("burnRate").? == .null);
    }
}

// =============================================================================
// Test 9: All-zero tokens through blocks pipeline
// =============================================================================

test "integration: zero tokens with nonzero duration produces zero burn rate" {
    const allocator = std.testing.allocator;

    // Two entries with all-zero tokens but different timestamps (nonzero duration)
    // The parser defaults missing token fields to 0, so we craft lines with explicit 0s
    const zero_line_1 =
        \\{"timestamp":"2025-01-15T10:00:00.000Z","message":{"usage":{"input_tokens":0,"output_tokens":0,"cache_creation_input_tokens":0,"cache_read_input_tokens":0},"model":"claude-sonnet-4-20250514","id":"msg-z1"},"costUSD":0.0,"requestId":"req-z1"}
    ;
    const zero_line_2 =
        \\{"timestamp":"2025-01-15T10:30:00.000Z","message":{"usage":{"input_tokens":0,"output_tokens":0,"cache_creation_input_tokens":0,"cache_read_input_tokens":0},"model":"claude-sonnet-4-20250514","id":"msg-z2"},"costUSD":0.0,"requestId":"req-z2"}
    ;

    const lines = &[_][]const u8{ zero_line_1, zero_line_2 };
    const entries = try loader.loadEntriesFromLines(allocator, lines, "sess-zero", "proj-zero");
    defer freeEntries(allocator, entries);
    try std.testing.expectEqual(@as(usize, 2), entries.len);

    // Blocks pipeline: 2 entries 30 min apart => 1 block with nonzero duration
    const far_future: i64 = 2000000000000;
    const blks = try blocks_mod.identifyBlocks(allocator, entries, 5, far_future);
    defer blocks_mod.freeBlocks(allocator, blks);

    try std.testing.expectEqual(@as(usize, 1), blks.len);
    try std.testing.expectEqual(false, blks[0].is_gap);
    try std.testing.expectEqual(@as(u32, 2), blks[0].entry_count);
    try std.testing.expectEqual(@as(u64, 0), blks[0].totalTokens());
    try std.testing.expectApproxEqAbs(@as(f64, 0.0), blks[0].cost_usd, 0.001);

    // burn_rate should exist (duration > 0) but tokens_per_minute = 0.0
    try std.testing.expect(blks[0].burn_rate != null);
    const br = blks[0].burn_rate.?;
    try std.testing.expectApproxEqAbs(@as(f64, 0.0), br.tokens_per_minute, 0.001);
    try std.testing.expectApproxEqAbs(@as(f64, 0.0), br.cost_per_hour, 0.001);

    // Verify JSON output doesn't panic
    const json_str = try json_output.blocksToJson(allocator, blks);
    defer allocator.free(json_str);

    const parsed = try parseJsonValue(allocator, json_str);
    defer parsed.deinit();
    const root = parsed.value.object;

    const block_obj = root.get("blocks").?.array.items[0].object;
    const br_json = block_obj.get("burnRate").?.object;
    try std.testing.expectApproxEqAbs(@as(f64, 0.0), br_json.get("tokensPerMinute").?.float, 0.001);
    try std.testing.expectApproxEqAbs(@as(f64, 0.0), br_json.get("costPerHour").?.float, 0.001);
}

test "integration: single zero-token entry produces null burn rate" {
    const allocator = std.testing.allocator;

    // Single entry with all-zero tokens => duration = 0 => burn_rate = null
    const zero_line =
        \\{"timestamp":"2025-01-15T10:00:00.000Z","message":{"usage":{"input_tokens":0,"output_tokens":0},"model":"claude-sonnet-4-20250514","id":"msg-z0"},"costUSD":0.0,"requestId":"req-z0"}
    ;

    const lines = &[_][]const u8{zero_line};
    const entries = try loader.loadEntriesFromLines(allocator, lines, "sess-z0", "proj-z0");
    defer freeEntries(allocator, entries);
    try std.testing.expectEqual(@as(usize, 1), entries.len);

    const far_future: i64 = 2000000000000;
    const blks = try blocks_mod.identifyBlocks(allocator, entries, 5, far_future);
    defer blocks_mod.freeBlocks(allocator, blks);

    try std.testing.expectEqual(@as(usize, 1), blks.len);
    try std.testing.expectEqual(@as(u64, 0), blks[0].totalTokens());
    try std.testing.expectEqual(@as(?types.BurnRate, null), blks[0].burn_rate);
    try std.testing.expectEqual(@as(?types.Projection, null), blks[0].projection);

    // JSON: burnRate should be null
    const json_str = try json_output.blocksToJson(allocator, blks);
    defer allocator.free(json_str);

    const parsed = try parseJsonValue(allocator, json_str);
    defer parsed.deinit();
    const block_obj = parsed.value.object.get("blocks").?.array.items[0].object;
    try std.testing.expect(block_obj.get("burnRate").? == .null);
}

// =============================================================================
// Test 10: Zero-cost entries through all pipelines
// =============================================================================

test "integration: zero-cost entries aggregate correctly" {
    const allocator = std.testing.allocator;

    // Entries with tokens but zero cost (costUSD missing => defaults to 0.0)
    const nocost_line_1 =
        \\{"timestamp":"2025-01-15T10:00:00.000Z","message":{"usage":{"input_tokens":100,"output_tokens":50},"model":"claude-sonnet-4-20250514","id":"msg-nc1"},"requestId":"req-nc1"}
    ;
    const nocost_line_2 =
        \\{"timestamp":"2025-01-15T11:00:00.000Z","message":{"usage":{"input_tokens":200,"output_tokens":100},"model":"claude-sonnet-4-20250514","id":"msg-nc2"},"costUSD":0.0,"requestId":"req-nc2"}
    ;

    const lines = &[_][]const u8{ nocost_line_1, nocost_line_2 };
    const entries = try loader.loadEntriesFromLines(allocator, lines, "sess-nc", "proj-nc");
    defer freeEntries(allocator, entries);
    try std.testing.expectEqual(@as(usize, 2), entries.len);

    // Daily aggregation: tokens sum correctly, cost is 0
    {
        const daily = try aggregate.aggregateDaily(allocator, entries, 0, false);
        defer freeAggregated(allocator, daily);
        try std.testing.expectEqual(@as(usize, 1), daily.len);
        try std.testing.expectEqual(@as(u64, 300), daily[0].input_tokens);
        try std.testing.expectEqual(@as(u64, 150), daily[0].output_tokens);
        try std.testing.expectApproxEqAbs(@as(f64, 0.0), daily[0].total_cost, 0.001);

        const totals = aggregate.calculateTotals(daily);
        try std.testing.expectApproxEqAbs(@as(f64, 0.0), totals.total_cost, 0.001);
        try std.testing.expectEqual(@as(u64, 450), totals.total_tokens);

        const json_str = try json_output.reportToJson(allocator, "daily", "date", daily, totals);
        defer allocator.free(json_str);

        const parsed = try parseJsonValue(allocator, json_str);
        defer parsed.deinit();
        const tot = parsed.value.object.get("totals").?.object;
        try std.testing.expectApproxEqAbs(@as(f64, 0.0), tot.get("totalCost").?.float, 0.001);
    }

    // Session pipeline: zero cost aggregates correctly
    {
        const sessions = try aggregate.aggregateSession(allocator, entries, 0);
        defer freeSessionUsage(allocator, sessions);
        try std.testing.expectEqual(@as(usize, 1), sessions.len);
        try std.testing.expectApproxEqAbs(@as(f64, 0.0), sessions[0].total_cost, 0.001);
        try std.testing.expectEqual(@as(u64, 300), sessions[0].input_tokens);
        try std.testing.expectEqual(@as(u64, 150), sessions[0].output_tokens);
    }

    // Blocks pipeline: zero cost with nonzero duration => cost_per_hour = 0.0
    {
        const far_future: i64 = 2000000000000;
        const blks = try blocks_mod.identifyBlocks(allocator, entries, 5, far_future);
        defer blocks_mod.freeBlocks(allocator, blks);

        try std.testing.expectEqual(@as(usize, 1), blks.len);
        try std.testing.expectApproxEqAbs(@as(f64, 0.0), blks[0].cost_usd, 0.001);

        try std.testing.expect(blks[0].burn_rate != null);
    const br = blks[0].burn_rate.?;
        // tokens_per_minute should be nonzero (450 tokens / 60 min = 7.5)
        try std.testing.expect(br.tokens_per_minute > 0.0);
        // cost_per_hour should be 0
        try std.testing.expectApproxEqAbs(@as(f64, 0.0), br.cost_per_hour, 0.001);

        const json_str = try json_output.blocksToJson(allocator, blks);
        defer allocator.free(json_str);

        const parsed = try parseJsonValue(allocator, json_str);
        defer parsed.deinit();
        const br_json = parsed.value.object.get("blocks").?.array.items[0].object.get("burnRate").?.object;
        try std.testing.expect(br_json.get("tokensPerMinute").?.float > 0.0);
        try std.testing.expectApproxEqAbs(@as(f64, 0.0), br_json.get("costPerHour").?.float, 0.001);
    }
}
