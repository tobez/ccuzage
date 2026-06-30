// ABOUTME: Serializes aggregated usage data to JSON matching the ccusage output format.
// ABOUTME: Provides camelCase JSON output for daily, monthly, weekly, session, and block reports.
const std = @import("std");
const types = @import("types.zig");
const date = @import("date.zig");

const Writer = std.Io.Writer;

/// Writes a JSON-escaped string (with surrounding quotes) to the writer.
fn writeJsonString(w: *Writer, s: []const u8) Writer.Error!void {
    try w.writeByte('"');
    for (s) |c| {
        switch (c) {
            '"' => try w.writeAll("\\\""),
            '\\' => try w.writeAll("\\\\"),
            '\n' => try w.writeAll("\\n"),
            '\r' => try w.writeAll("\\r"),
            '\t' => try w.writeAll("\\t"),
            else => {
                if (c < 0x20) {
                    try w.print("\\u{x:0>4}", .{c});
                } else {
                    try w.writeByte(c);
                }
            },
        }
    }
    try w.writeByte('"');
}

/// Writes an integer value as JSON.
fn writeJsonInt(w: *Writer, v: u64) Writer.Error!void {
    try w.print("{d}", .{v});
}

/// Writes a float value as JSON with 6 decimal places.
fn writeJsonFloat(w: *Writer, v: f64) Writer.Error!void {
    try w.print("{d:.6}", .{v});
}

/// Writes a single model breakdown object as JSON.
fn writeModelBreakdown(w: *Writer, mb: types.ModelBreakdown) Writer.Error!void {
    try w.writeAll("{\"modelName\":");
    try writeJsonString(w, mb.model_name);
    try w.writeAll(",\"inputTokens\":");
    try writeJsonInt(w, mb.input_tokens);
    try w.writeAll(",\"outputTokens\":");
    try writeJsonInt(w, mb.output_tokens);
    try w.writeAll(",\"cacheCreationTokens\":");
    try writeJsonInt(w, mb.cache_creation_tokens);
    try w.writeAll(",\"cacheReadTokens\":");
    try writeJsonInt(w, mb.cache_read_tokens);
    try w.writeAll(",\"cost\":");
    try writeJsonFloat(w, mb.cost);
    try w.writeByte('}');
}

/// Writes a single aggregated usage item as JSON.
fn writeAggregatedItem(w: *Writer, comptime period_key: []const u8, item: types.AggregatedUsage) Writer.Error!void {
    try w.writeAll("{\"" ++ period_key ++ "\":");
    try writeJsonString(w, item.period);

    try w.writeAll(",\"inputTokens\":");
    try writeJsonInt(w, item.input_tokens);
    try w.writeAll(",\"outputTokens\":");
    try writeJsonInt(w, item.output_tokens);
    try w.writeAll(",\"cacheCreationTokens\":");
    try writeJsonInt(w, item.cache_creation_tokens);
    try w.writeAll(",\"cacheReadTokens\":");
    try writeJsonInt(w, item.cache_read_tokens);
    try w.writeAll(",\"totalTokens\":");
    try writeJsonInt(w, item.input_tokens + item.output_tokens + item.cache_creation_tokens + item.cache_read_tokens);
    try w.writeAll(",\"totalCost\":");
    try writeJsonFloat(w, item.total_cost);

    // modelsUsed array
    try w.writeAll(",\"modelsUsed\":[");
    for (item.models_used, 0..) |model, i| {
        if (i > 0) try w.writeByte(',');
        try writeJsonString(w, model);
    }
    try w.writeByte(']');

    // modelBreakdowns array
    try w.writeAll(",\"modelBreakdowns\":[");
    for (item.model_breakdowns, 0..) |mb, i| {
        if (i > 0) try w.writeByte(',');
        try writeModelBreakdown(w, mb);
    }
    try w.writeAll("]}");
}

/// Writes totals as JSON.
fn writeTotals(w: *Writer, totals: types.Totals) Writer.Error!void {
    try w.writeAll("{\"inputTokens\":");
    try writeJsonInt(w, totals.input_tokens);
    try w.writeAll(",\"outputTokens\":");
    try writeJsonInt(w, totals.output_tokens);
    try w.writeAll(",\"cacheCreationTokens\":");
    try writeJsonInt(w, totals.cache_creation_tokens);
    try w.writeAll(",\"cacheReadTokens\":");
    try writeJsonInt(w, totals.cache_read_tokens);
    try w.writeAll(",\"totalTokens\":");
    try writeJsonInt(w, totals.total_tokens);
    try w.writeAll(",\"totalCost\":");
    try writeJsonFloat(w, totals.total_cost);
    try w.writeByte('}');
}

/// Writes a full report (items + totals) as JSON to the given writer.
pub fn writeReportJson(
    w: *Writer,
    comptime command_name: []const u8,
    comptime period_key: []const u8,
    items: []const types.AggregatedUsage,
    totals: types.Totals,
) Writer.Error!void {
    try w.writeAll("{\"" ++ command_name ++ "\":[");

    for (items, 0..) |item, i| {
        if (i > 0) try w.writeByte(',');
        try writeAggregatedItem(w, period_key, item);
    }

    try w.writeAll("],\"totals\":");
    try writeTotals(w, totals);
    try w.writeByte('}');
}

/// Returns an allocated JSON string for the given report data.
pub fn reportToJson(
    allocator: std.mem.Allocator,
    comptime command_name: []const u8,
    comptime period_key: []const u8,
    items: []const types.AggregatedUsage,
    totals: types.Totals,
) ![]u8 {
    var aw: std.Io.Writer.Allocating = .init(allocator);
    errdefer aw.deinit();
    try writeReportJson(&aw.writer, command_name, period_key, items, totals);
    return aw.toOwnedSlice();
}

/// Writes a single session usage item as JSON.
fn writeSessionItem(w: *Writer, item: types.SessionUsage) Writer.Error!void {
    try w.writeAll("{\"sessionId\":");
    try writeJsonString(w, item.session_id);

    try w.writeAll(",\"inputTokens\":");
    try writeJsonInt(w, item.input_tokens);
    try w.writeAll(",\"outputTokens\":");
    try writeJsonInt(w, item.output_tokens);
    try w.writeAll(",\"cacheCreationTokens\":");
    try writeJsonInt(w, item.cache_creation_tokens);
    try w.writeAll(",\"cacheReadTokens\":");
    try writeJsonInt(w, item.cache_read_tokens);
    try w.writeAll(",\"totalTokens\":");
    try writeJsonInt(w, item.input_tokens + item.output_tokens + item.cache_creation_tokens + item.cache_read_tokens);
    try w.writeAll(",\"totalCost\":");
    try writeJsonFloat(w, item.total_cost);
    try w.writeAll(",\"lastActivity\":");
    try writeJsonString(w, item.last_activity);

    // modelsUsed array
    try w.writeAll(",\"modelsUsed\":[");
    for (item.models_used, 0..) |model, i| {
        if (i > 0) try w.writeByte(',');
        try writeJsonString(w, model);
    }
    try w.writeByte(']');

    // modelBreakdowns array
    try w.writeAll(",\"modelBreakdowns\":[");
    for (item.model_breakdowns, 0..) |mb, i| {
        if (i > 0) try w.writeByte(',');
        try writeModelBreakdown(w, mb);
    }
    try w.writeByte(']');

    try w.writeAll(",\"projectPath\":");
    try writeJsonString(w, item.project_path);

    try w.writeAll("}");
}

/// Writes a full session report (items + totals) as JSON to the given writer.
pub fn writeSessionJson(w: *Writer, items: []const types.SessionUsage, totals: types.Totals) Writer.Error!void {
    try w.writeAll("{\"sessions\":[");

    for (items, 0..) |item, i| {
        if (i > 0) try w.writeByte(',');
        try writeSessionItem(w, item);
    }

    try w.writeAll("],\"totals\":");
    try writeTotals(w, totals);
    try w.writeByte('}');
}

/// Returns an allocated JSON string for session data.
pub fn sessionToJson(allocator: std.mem.Allocator, items: []const types.SessionUsage, totals: types.Totals) ![]u8 {
    var aw: std.Io.Writer.Allocating = .init(allocator);
    errdefer aw.deinit();
    try writeSessionJson(&aw.writer, items, totals);
    return aw.toOwnedSlice();
}

/// Writes an ISO 8601 formatted timestamp string to the writer.
fn writeTimestamp(w: *Writer, epoch_ms: i64) Writer.Error!void {
    const buf = date.formatIso8601Output(epoch_ms);
    try w.writeByte('"');
    try w.writeAll(&buf);
    try w.writeByte('"');
}

/// Writes a single session block item as JSON.
fn writeBlockItem(w: *Writer, block: types.SessionBlock) Writer.Error!void {
    try w.writeAll("{\"id\":");
    try writeJsonString(w, block.id);

    try w.writeAll(",\"startTime\":");
    try writeTimestamp(w, block.start_time);

    try w.writeAll(",\"endTime\":");
    try writeTimestamp(w, block.end_time);

    try w.writeAll(",\"actualEndTime\":");
    if (block.actual_end_time) |aet| {
        try writeTimestamp(w, aet);
    } else {
        try w.writeAll("null");
    }

    try w.writeAll(",\"isActive\":");
    try w.writeAll(if (block.is_active) "true" else "false");

    try w.writeAll(",\"isGap\":");
    try w.writeAll(if (block.is_gap) "true" else "false");

    try w.writeAll(",\"entries\":");
    try writeJsonInt(w, block.entry_count);

    try w.writeAll(",\"tokenCounts\":{\"inputTokens\":");
    try writeJsonInt(w, block.input_tokens);
    try w.writeAll(",\"outputTokens\":");
    try writeJsonInt(w, block.output_tokens);
    try w.writeAll(",\"cacheCreationInputTokens\":");
    try writeJsonInt(w, block.cache_creation_tokens);
    try w.writeAll(",\"cacheReadInputTokens\":");
    try writeJsonInt(w, block.cache_read_tokens);
    try w.writeByte('}');

    try w.writeAll(",\"totalTokens\":");
    try writeJsonInt(w, block.totalTokens());

    try w.writeAll(",\"costUSD\":");
    try writeJsonFloat(w, block.cost_usd);

    // models array
    try w.writeAll(",\"models\":[");
    for (block.models, 0..) |model, i| {
        if (i > 0) try w.writeByte(',');
        try writeJsonString(w, model);
    }
    try w.writeByte(']');

    // burnRate (nullable)
    try w.writeAll(",\"burnRate\":");
    if (block.burn_rate) |br| {
        try w.writeAll("{\"tokensPerMinute\":");
        try writeJsonFloat(w, br.tokens_per_minute);
        try w.writeAll(",\"costPerHour\":");
        try writeJsonFloat(w, br.cost_per_hour);
        try w.writeByte('}');
    } else {
        try w.writeAll("null");
    }

    // projection (nullable)
    try w.writeAll(",\"projection\":");
    if (block.projection) |proj| {
        try w.writeAll("{\"totalTokens\":");
        try writeJsonInt(w, proj.total_tokens);
        try w.writeAll(",\"totalCost\":");
        try writeJsonFloat(w, proj.total_cost);
        try w.writeAll(",\"remainingMinutes\":");
        try writeJsonFloat(w, proj.remaining_minutes);
        try w.writeByte('}');
    } else {
        try w.writeAll("null");
    }

    try w.writeByte('}');
}

/// Writes a full blocks report as JSON to the given writer.
pub fn writeBlocksJson(w: *Writer, blocks: []const types.SessionBlock) Writer.Error!void {
    try w.writeAll("{\"blocks\":[");

    for (blocks, 0..) |block, i| {
        if (i > 0) try w.writeByte(',');
        try writeBlockItem(w, block);
    }

    try w.writeAll("]}");
}

/// Returns an allocated JSON string for block data.
pub fn blocksToJson(allocator: std.mem.Allocator, blocks: []const types.SessionBlock) ![]u8 {
    var aw: std.Io.Writer.Allocating = .init(allocator);
    errdefer aw.deinit();
    try writeBlocksJson(&aw.writer, blocks);
    return aw.toOwnedSlice();
}

/// Writes a project-grouped report as JSON.
/// Items are grouped by their .project field into a "projects" object,
/// with each project key mapping to an array of aggregated items.
pub fn writeProjectGroupedJson(
    w: *Writer,
    comptime command_name: []const u8,
    comptime period_key: []const u8,
    items: []const types.AggregatedUsage,
    totals: types.Totals,
) Writer.Error!void {
    _ = command_name; // grouping uses "projects" key instead
    try w.writeAll("{\"projects\":{");

    // Collect unique project names in order of first appearance
    var seen_projects: [256][]const u8 = undefined;
    var project_count: usize = 0;

    for (items) |item| {
        const proj = item.project orelse continue;
        var found = false;
        for (seen_projects[0..project_count]) |sp| {
            if (std.mem.eql(u8, sp, proj)) {
                found = true;
                break;
            }
        }
        if (!found) {
            seen_projects[project_count] = proj;
            project_count += 1;
        }
    }

    // Write each project's items
    for (seen_projects[0..project_count], 0..) |proj, pi| {
        if (pi > 0) try w.writeByte(',');
        try writeJsonString(w, proj);
        try w.writeAll(":[");

        var first = true;
        for (items) |item| {
            const item_proj = item.project orelse continue;
            if (!std.mem.eql(u8, item_proj, proj)) continue;
            if (!first) try w.writeByte(',');
            try writeAggregatedItem(w, period_key, item);
            first = false;
        }
        try w.writeByte(']');
    }

    try w.writeAll("},\"totals\":");
    try writeTotals(w, totals);
    try w.writeByte('}');
}

/// Returns an allocated JSON string for project-grouped report data.
pub fn projectGroupedToJson(
    allocator: std.mem.Allocator,
    comptime command_name: []const u8,
    comptime period_key: []const u8,
    items: []const types.AggregatedUsage,
    totals: types.Totals,
) ![]u8 {
    var aw: std.Io.Writer.Allocating = .init(allocator);
    errdefer aw.deinit();
    try writeProjectGroupedJson(&aw.writer, command_name, period_key, items, totals);
    return aw.toOwnedSlice();
}

// =============================================================================
// Tests
// =============================================================================

const testing = std.testing;

fn parseJsonValue(allocator: std.mem.Allocator, json_str: []const u8) !std.json.Parsed(std.json.Value) {
    return std.json.parseFromSlice(std.json.Value, allocator, json_str, .{});
}

test "daily JSON output structure" {
    const allocator = testing.allocator;

    const models_used = [_][]const u8{"claude-sonnet-4-20250514"};
    const breakdowns = [_]types.ModelBreakdown{
        .{
            .model_name = "claude-sonnet-4-20250514",
            .input_tokens = 1000,
            .output_tokens = 50,
            .cache_creation_tokens = 100,
            .cache_read_tokens = 500,
            .cost = 0.05,
        },
    };

    const items = [_]types.AggregatedUsage{
        .{
            .period = "2025-01-15",
            .input_tokens = 1000,
            .output_tokens = 50,
            .cache_creation_tokens = 100,
            .cache_read_tokens = 500,
            .total_cost = 0.05,
            .models_used = &models_used,
            .model_breakdowns = &breakdowns,
            .project = null,
        },
    };

    const totals = types.Totals{
        .input_tokens = 1000,
        .output_tokens = 50,
        .cache_creation_tokens = 100,
        .cache_read_tokens = 500,
        .total_tokens = 1650,
        .total_cost = 0.05,
    };

    const json_str = try reportToJson(allocator, "daily", "date", &items, totals);
    defer allocator.free(json_str);

    const parsed = try parseJsonValue(allocator, json_str);
    defer parsed.deinit();
    const root = parsed.value.object;

    // Top-level has "daily" array and "totals" object
    const daily_arr = root.get("daily").?.array;
    try testing.expectEqual(@as(usize, 1), daily_arr.items.len);

    const first = daily_arr.items[0].object;
    try testing.expectEqualStrings("2025-01-15", first.get("date").?.string);
    try testing.expectEqual(@as(i64, 1000), first.get("inputTokens").?.integer);
    try testing.expectEqual(@as(i64, 50), first.get("outputTokens").?.integer);
    try testing.expectEqual(@as(i64, 100), first.get("cacheCreationTokens").?.integer);
    try testing.expectEqual(@as(i64, 500), first.get("cacheReadTokens").?.integer);
    try testing.expectEqual(@as(i64, 1650), first.get("totalTokens").?.integer);
    try testing.expectApproxEqAbs(0.05, first.get("totalCost").?.float, 0.000001);

    // modelsUsed
    const models = first.get("modelsUsed").?.array;
    try testing.expectEqual(@as(usize, 1), models.items.len);
    try testing.expectEqualStrings("claude-sonnet-4-20250514", models.items[0].string);

    // totals
    const tot = root.get("totals").?.object;
    try testing.expectEqual(@as(i64, 1000), tot.get("inputTokens").?.integer);
    try testing.expectEqual(@as(i64, 50), tot.get("outputTokens").?.integer);
    try testing.expectEqual(@as(i64, 1650), tot.get("totalTokens").?.integer);
    try testing.expectApproxEqAbs(0.05, tot.get("totalCost").?.float, 0.000001);
}

test "monthly JSON uses monthly/month keys" {
    const allocator = testing.allocator;

    const items = [_]types.AggregatedUsage{
        .{
            .period = "2025-01",
            .input_tokens = 2000,
            .output_tokens = 100,
            .cache_creation_tokens = 200,
            .cache_read_tokens = 300,
            .total_cost = 0.10,
            .models_used = &.{},
            .model_breakdowns = &.{},
            .project = null,
        },
    };

    const totals = types.Totals{
        .input_tokens = 2000,
        .output_tokens = 100,
        .cache_creation_tokens = 200,
        .cache_read_tokens = 300,
        .total_tokens = 2600,
        .total_cost = 0.10,
    };

    const json_str = try reportToJson(allocator, "monthly", "month", &items, totals);
    defer allocator.free(json_str);

    const parsed = try parseJsonValue(allocator, json_str);
    defer parsed.deinit();
    const root = parsed.value.object;

    // Top-level key is "monthly"
    const monthly_arr = root.get("monthly").?.array;
    try testing.expectEqual(@as(usize, 1), monthly_arr.items.len);

    // Period field is "month"
    const first = monthly_arr.items[0].object;
    try testing.expectEqualStrings("2025-01", first.get("month").?.string);
    // "date" should not exist
    try testing.expectEqual(@as(?std.json.Value, null), first.get("date"));
}

test "weekly JSON uses weekly/week keys" {
    const allocator = testing.allocator;

    const items = [_]types.AggregatedUsage{
        .{
            .period = "2025-01-12",
            .input_tokens = 3000,
            .output_tokens = 150,
            .cache_creation_tokens = 300,
            .cache_read_tokens = 400,
            .total_cost = 0.15,
            .models_used = &.{},
            .model_breakdowns = &.{},
            .project = null,
        },
    };

    const totals = types.Totals{
        .input_tokens = 3000,
        .output_tokens = 150,
        .cache_creation_tokens = 300,
        .cache_read_tokens = 400,
        .total_tokens = 3850,
        .total_cost = 0.15,
    };

    const json_str = try reportToJson(allocator, "weekly", "week", &items, totals);
    defer allocator.free(json_str);

    const parsed = try parseJsonValue(allocator, json_str);
    defer parsed.deinit();
    const root = parsed.value.object;

    // Top-level key is "weekly"
    const weekly_arr = root.get("weekly").?.array;
    try testing.expectEqual(@as(usize, 1), weekly_arr.items.len);

    // Period field is "week"
    const first = weekly_arr.items[0].object;
    try testing.expectEqualStrings("2025-01-12", first.get("week").?.string);
    try testing.expectEqual(@as(?std.json.Value, null), first.get("date"));
    try testing.expectEqual(@as(?std.json.Value, null), first.get("month"));
}

test "model breakdowns in output" {
    const allocator = testing.allocator;

    const models_used = [_][]const u8{ "claude-opus-4", "claude-sonnet-4" };
    const breakdowns = [_]types.ModelBreakdown{
        .{
            .model_name = "claude-opus-4",
            .input_tokens = 500,
            .output_tokens = 25,
            .cache_creation_tokens = 50,
            .cache_read_tokens = 200,
            .cost = 0.03,
        },
        .{
            .model_name = "claude-sonnet-4",
            .input_tokens = 500,
            .output_tokens = 25,
            .cache_creation_tokens = 50,
            .cache_read_tokens = 300,
            .cost = 0.02,
        },
    };

    const items = [_]types.AggregatedUsage{
        .{
            .period = "2025-01-15",
            .input_tokens = 1000,
            .output_tokens = 50,
            .cache_creation_tokens = 100,
            .cache_read_tokens = 500,
            .total_cost = 0.05,
            .models_used = &models_used,
            .model_breakdowns = &breakdowns,
            .project = null,
        },
    };

    const totals = types.Totals{
        .input_tokens = 1000,
        .output_tokens = 50,
        .cache_creation_tokens = 100,
        .cache_read_tokens = 500,
        .total_tokens = 1650,
        .total_cost = 0.05,
    };

    const json_str = try reportToJson(allocator, "daily", "date", &items, totals);
    defer allocator.free(json_str);

    const parsed = try parseJsonValue(allocator, json_str);
    defer parsed.deinit();
    const root = parsed.value.object;

    const first = root.get("daily").?.array.items[0].object;
    const mbs = first.get("modelBreakdowns").?.array;
    try testing.expectEqual(@as(usize, 2), mbs.items.len);

    const mb0 = mbs.items[0].object;
    try testing.expectEqualStrings("claude-opus-4", mb0.get("modelName").?.string);
    try testing.expectEqual(@as(i64, 500), mb0.get("inputTokens").?.integer);
    try testing.expectApproxEqAbs(0.03, mb0.get("cost").?.float, 0.000001);

    const mb1 = mbs.items[1].object;
    try testing.expectEqualStrings("claude-sonnet-4", mb1.get("modelName").?.string);
    try testing.expectEqual(@as(i64, 500), mb1.get("inputTokens").?.integer);
    try testing.expectApproxEqAbs(0.02, mb1.get("cost").?.float, 0.000001);
}

test "empty items array" {
    const allocator = testing.allocator;

    const items = [_]types.AggregatedUsage{};

    const totals = types.Totals{
        .input_tokens = 0,
        .output_tokens = 0,
        .cache_creation_tokens = 0,
        .cache_read_tokens = 0,
        .total_tokens = 0,
        .total_cost = 0.0,
    };

    const json_str = try reportToJson(allocator, "daily", "date", &items, totals);
    defer allocator.free(json_str);

    const parsed = try parseJsonValue(allocator, json_str);
    defer parsed.deinit();
    const root = parsed.value.object;

    const daily_arr = root.get("daily").?.array;
    try testing.expectEqual(@as(usize, 0), daily_arr.items.len);

    const tot = root.get("totals").?.object;
    try testing.expectEqual(@as(i64, 0), tot.get("inputTokens").?.integer);
    try testing.expectEqual(@as(i64, 0), tot.get("outputTokens").?.integer);
    try testing.expectEqual(@as(i64, 0), tot.get("totalTokens").?.integer);
    try testing.expectApproxEqAbs(0.0, tot.get("totalCost").?.float, 0.000001);
}

test "session JSON structure with all fields" {
    const allocator = testing.allocator;

    const models_used = [_][]const u8{"claude-sonnet-4-20250514"};
    const breakdowns = [_]types.ModelBreakdown{
        .{
            .model_name = "claude-sonnet-4-20250514",
            .input_tokens = 1000,
            .output_tokens = 50,
            .cache_creation_tokens = 100,
            .cache_read_tokens = 500,
            .cost = 0.05,
        },
    };

    const items = [_]types.SessionUsage{
        .{
            .session_id = "abc-123",
            .project_path = "myproject",
            .input_tokens = 1000,
            .output_tokens = 50,
            .cache_creation_tokens = 100,
            .cache_read_tokens = 500,
            .total_cost = 0.05,
            .last_activity = "2025-01-15",
            .models_used = &models_used,
            .model_breakdowns = &breakdowns,
        },
    };

    const totals = types.Totals{
        .input_tokens = 1000,
        .output_tokens = 50,
        .cache_creation_tokens = 100,
        .cache_read_tokens = 500,
        .total_tokens = 1650,
        .total_cost = 0.05,
    };

    const json_str = try sessionToJson(allocator, &items, totals);
    defer allocator.free(json_str);

    const parsed = try parseJsonValue(allocator, json_str);
    defer parsed.deinit();
    const root = parsed.value.object;

    // Top-level has "sessions" array and "totals" object
    const sessions_arr = root.get("sessions").?.array;
    try testing.expectEqual(@as(usize, 1), sessions_arr.items.len);

    const first = sessions_arr.items[0].object;
    try testing.expectEqualStrings("abc-123", first.get("sessionId").?.string);
    try testing.expectEqual(@as(i64, 1000), first.get("inputTokens").?.integer);
    try testing.expectEqual(@as(i64, 50), first.get("outputTokens").?.integer);
    try testing.expectEqual(@as(i64, 100), first.get("cacheCreationTokens").?.integer);
    try testing.expectEqual(@as(i64, 500), first.get("cacheReadTokens").?.integer);
    try testing.expectEqual(@as(i64, 1650), first.get("totalTokens").?.integer);
    try testing.expectApproxEqAbs(0.05, first.get("totalCost").?.float, 0.000001);
    try testing.expectEqualStrings("2025-01-15", first.get("lastActivity").?.string);
    try testing.expectEqualStrings("myproject", first.get("projectPath").?.string);

    // modelsUsed
    const models = first.get("modelsUsed").?.array;
    try testing.expectEqual(@as(usize, 1), models.items.len);
    try testing.expectEqualStrings("claude-sonnet-4-20250514", models.items[0].string);

    // modelBreakdowns
    const mbs = first.get("modelBreakdowns").?.array;
    try testing.expectEqual(@as(usize, 1), mbs.items.len);
    try testing.expectEqualStrings("claude-sonnet-4-20250514", mbs.items[0].object.get("modelName").?.string);

    // totals
    const tot = root.get("totals").?.object;
    try testing.expectEqual(@as(i64, 1000), tot.get("inputTokens").?.integer);
    try testing.expectEqual(@as(i64, 50), tot.get("outputTokens").?.integer);
    try testing.expectEqual(@as(i64, 1650), tot.get("totalTokens").?.integer);
    try testing.expectApproxEqAbs(0.05, tot.get("totalCost").?.float, 0.000001);
}

test "session JSON with multiple sessions" {
    const allocator = testing.allocator;

    const items = [_]types.SessionUsage{
        .{
            .session_id = "sess-1",
            .project_path = "project-a",
            .input_tokens = 500,
            .output_tokens = 25,
            .cache_creation_tokens = 50,
            .cache_read_tokens = 200,
            .total_cost = 0.02,
            .last_activity = "2025-01-14",
            .models_used = &.{},
            .model_breakdowns = &.{},
        },
        .{
            .session_id = "sess-2",
            .project_path = "project-b",
            .input_tokens = 800,
            .output_tokens = 40,
            .cache_creation_tokens = 80,
            .cache_read_tokens = 300,
            .total_cost = 0.03,
            .last_activity = "2025-01-15",
            .models_used = &.{},
            .model_breakdowns = &.{},
        },
    };

    const totals = types.Totals{
        .input_tokens = 1300,
        .output_tokens = 65,
        .cache_creation_tokens = 130,
        .cache_read_tokens = 500,
        .total_tokens = 1995,
        .total_cost = 0.05,
    };

    const json_str = try sessionToJson(allocator, &items, totals);
    defer allocator.free(json_str);

    const parsed = try parseJsonValue(allocator, json_str);
    defer parsed.deinit();
    const root = parsed.value.object;

    const sessions_arr = root.get("sessions").?.array;
    try testing.expectEqual(@as(usize, 2), sessions_arr.items.len);

    try testing.expectEqualStrings("sess-1", sessions_arr.items[0].object.get("sessionId").?.string);
    try testing.expectEqualStrings("sess-2", sessions_arr.items[1].object.get("sessionId").?.string);
    try testing.expectEqualStrings("project-a", sessions_arr.items[0].object.get("projectPath").?.string);
    try testing.expectEqualStrings("project-b", sessions_arr.items[1].object.get("projectPath").?.string);
}

test "session JSON with empty sessions array" {
    const allocator = testing.allocator;

    const items = [_]types.SessionUsage{};

    const totals = types.Totals{
        .input_tokens = 0,
        .output_tokens = 0,
        .cache_creation_tokens = 0,
        .cache_read_tokens = 0,
        .total_tokens = 0,
        .total_cost = 0.0,
    };

    const json_str = try sessionToJson(allocator, &items, totals);
    defer allocator.free(json_str);

    const parsed = try parseJsonValue(allocator, json_str);
    defer parsed.deinit();
    const root = parsed.value.object;

    const sessions_arr = root.get("sessions").?.array;
    try testing.expectEqual(@as(usize, 0), sessions_arr.items.len);

    const tot = root.get("totals").?.object;
    try testing.expectEqual(@as(i64, 0), tot.get("inputTokens").?.integer);
    try testing.expectEqual(@as(i64, 0), tot.get("outputTokens").?.integer);
    try testing.expectEqual(@as(i64, 0), tot.get("totalTokens").?.integer);
    try testing.expectApproxEqAbs(0.0, tot.get("totalCost").?.float, 0.000001);
}

test "blocks JSON with all fields populated (non-gap, inactive, with burn rate)" {
    const allocator = testing.allocator;

    const models = [_][]const u8{"claude-sonnet-4-20250514"};

    const blocks = [_]types.SessionBlock{
        .{
            .id = "2025-01-15T10:00:00.000Z",
            .start_time = 1736935200000, // 2025-01-15T10:00:00.000Z
            .end_time = 1736953200000, // 2025-01-15T15:00:00.000Z
            .actual_end_time = 1736940600000, // 2025-01-15T11:30:00.000Z
            .is_active = false,
            .is_gap = false,
            .entry_count = 5,
            .input_tokens = 1000,
            .output_tokens = 50,
            .cache_creation_tokens = 100,
            .cache_read_tokens = 500,
            .cost_usd = 0.05,
            .models = &models,
            .burn_rate = .{ .tokens_per_minute = 18.3, .cost_per_hour = 0.033 },
            .projection = null,
        },
    };

    const json_str = try blocksToJson(allocator, &blocks);
    defer allocator.free(json_str);

    const parsed = try parseJsonValue(allocator, json_str);
    defer parsed.deinit();
    const root = parsed.value.object;

    // Top-level has "blocks" array, no "totals"
    const blocks_arr = root.get("blocks").?.array;
    try testing.expectEqual(@as(usize, 1), blocks_arr.items.len);
    try testing.expectEqual(@as(?std.json.Value, null), root.get("totals"));

    const first = blocks_arr.items[0].object;
    try testing.expectEqualStrings("2025-01-15T10:00:00.000Z", first.get("id").?.string);
    try testing.expectEqualStrings("2025-01-15T10:00:00.000Z", first.get("startTime").?.string);
    try testing.expectEqualStrings("2025-01-15T15:00:00.000Z", first.get("endTime").?.string);
    try testing.expectEqualStrings("2025-01-15T11:30:00.000Z", first.get("actualEndTime").?.string);
    try testing.expect(first.get("isActive").?.bool == false);
    try testing.expect(first.get("isGap").?.bool == false);
    try testing.expectEqual(@as(i64, 5), first.get("entries").?.integer);

    // tokenCounts sub-object
    const tc = first.get("tokenCounts").?.object;
    try testing.expectEqual(@as(i64, 1000), tc.get("inputTokens").?.integer);
    try testing.expectEqual(@as(i64, 50), tc.get("outputTokens").?.integer);
    try testing.expectEqual(@as(i64, 100), tc.get("cacheCreationInputTokens").?.integer);
    try testing.expectEqual(@as(i64, 500), tc.get("cacheReadInputTokens").?.integer);

    try testing.expectEqual(@as(i64, 1650), first.get("totalTokens").?.integer);
    try testing.expectApproxEqAbs(0.05, first.get("costUSD").?.float, 0.000001);

    // models array
    const models_arr = first.get("models").?.array;
    try testing.expectEqual(@as(usize, 1), models_arr.items.len);
    try testing.expectEqualStrings("claude-sonnet-4-20250514", models_arr.items[0].string);

    // burnRate object
    const br = first.get("burnRate").?.object;
    try testing.expectApproxEqAbs(18.3, br.get("tokensPerMinute").?.float, 0.001);
    try testing.expectApproxEqAbs(0.033, br.get("costPerHour").?.float, 0.000001);

    // projection is null
    try testing.expect(first.get("projection").? == .null);
}

test "blocks JSON gap block (null burnRate, null projection, null actualEndTime)" {
    const allocator = testing.allocator;

    const blocks = [_]types.SessionBlock{
        .{
            .id = "2025-01-15T12:00:00.000Z",
            .start_time = 1736942400000, // 2025-01-15T12:00:00.000Z
            .end_time = 1736946000000, // 2025-01-15T13:00:00.000Z
            .actual_end_time = null,
            .is_active = false,
            .is_gap = true,
            .entry_count = 0,
            .input_tokens = 0,
            .output_tokens = 0,
            .cache_creation_tokens = 0,
            .cache_read_tokens = 0,
            .cost_usd = 0.0,
            .models = &.{},
            .burn_rate = null,
            .projection = null,
        },
    };

    const json_str = try blocksToJson(allocator, &blocks);
    defer allocator.free(json_str);

    const parsed = try parseJsonValue(allocator, json_str);
    defer parsed.deinit();
    const root = parsed.value.object;

    const blocks_arr = root.get("blocks").?.array;
    try testing.expectEqual(@as(usize, 1), blocks_arr.items.len);

    const first = blocks_arr.items[0].object;
    try testing.expect(first.get("isGap").?.bool == true);
    try testing.expect(first.get("isActive").?.bool == false);
    try testing.expect(first.get("actualEndTime").? == .null);
    try testing.expectEqual(@as(i64, 0), first.get("entries").?.integer);

    // burnRate is null
    try testing.expect(first.get("burnRate").? == .null);
    // projection is null
    try testing.expect(first.get("projection").? == .null);

    // models is empty array
    const models_arr = first.get("models").?.array;
    try testing.expectEqual(@as(usize, 0), models_arr.items.len);
}

test "blocks JSON active block with projection" {
    const allocator = testing.allocator;

    const models = [_][]const u8{ "claude-opus-4", "claude-sonnet-4" };

    const blocks = [_]types.SessionBlock{
        .{
            .id = "2025-01-15T14:00:00.000Z",
            .start_time = 1736949600000, // 2025-01-15T14:00:00.000Z
            .end_time = 1736967600000, // 2025-01-15T19:00:00.000Z
            .actual_end_time = 1736953200000, // 2025-01-15T15:00:00.000Z
            .is_active = true,
            .is_gap = false,
            .entry_count = 10,
            .input_tokens = 5000,
            .output_tokens = 1000,
            .cache_creation_tokens = 500,
            .cache_read_tokens = 2000,
            .cost_usd = 0.25,
            .models = &models,
            .burn_rate = .{ .tokens_per_minute = 141.7, .cost_per_hour = 0.25 },
            .projection = .{ .total_tokens = 42500, .total_cost = 1.25, .remaining_minutes = 240.0 },
        },
    };

    const json_str = try blocksToJson(allocator, &blocks);
    defer allocator.free(json_str);

    const parsed = try parseJsonValue(allocator, json_str);
    defer parsed.deinit();
    const root = parsed.value.object;

    const blocks_arr = root.get("blocks").?.array;
    const first = blocks_arr.items[0].object;
    try testing.expect(first.get("isActive").?.bool == true);
    try testing.expectEqual(@as(i64, 10), first.get("entries").?.integer);

    // models has two entries
    const models_arr = first.get("models").?.array;
    try testing.expectEqual(@as(usize, 2), models_arr.items.len);
    try testing.expectEqualStrings("claude-opus-4", models_arr.items[0].string);
    try testing.expectEqualStrings("claude-sonnet-4", models_arr.items[1].string);

    // burnRate
    const br = first.get("burnRate").?.object;
    try testing.expectApproxEqAbs(141.7, br.get("tokensPerMinute").?.float, 0.1);
    try testing.expectApproxEqAbs(0.25, br.get("costPerHour").?.float, 0.000001);

    // projection is non-null
    const proj = first.get("projection").?.object;
    try testing.expectEqual(@as(i64, 42500), proj.get("totalTokens").?.integer);
    try testing.expectApproxEqAbs(1.25, proj.get("totalCost").?.float, 0.000001);
    try testing.expectApproxEqAbs(240.0, proj.get("remainingMinutes").?.float, 0.1);
}

test "blocks JSON empty blocks array" {
    const allocator = testing.allocator;

    const blocks = [_]types.SessionBlock{};

    const json_str = try blocksToJson(allocator, &blocks);
    defer allocator.free(json_str);

    const parsed = try parseJsonValue(allocator, json_str);
    defer parsed.deinit();
    const root = parsed.value.object;

    const blocks_arr = root.get("blocks").?.array;
    try testing.expectEqual(@as(usize, 0), blocks_arr.items.len);

    // No totals key
    try testing.expectEqual(@as(?std.json.Value, null), root.get("totals"));
}

test "project-grouped JSON nests items by project" {
    const allocator = testing.allocator;

    const items = [_]types.AggregatedUsage{
        .{
            .period = "2025-01-15",
            .input_tokens = 100,
            .output_tokens = 10,
            .cache_creation_tokens = 0,
            .cache_read_tokens = 0,
            .total_cost = 0.01,
            .models_used = &.{},
            .model_breakdowns = &.{},
            .project = "project-a",
        },
        .{
            .period = "2025-01-15",
            .input_tokens = 200,
            .output_tokens = 20,
            .cache_creation_tokens = 0,
            .cache_read_tokens = 0,
            .total_cost = 0.02,
            .models_used = &.{},
            .model_breakdowns = &.{},
            .project = "project-b",
        },
        .{
            .period = "2025-01-16",
            .input_tokens = 300,
            .output_tokens = 30,
            .cache_creation_tokens = 0,
            .cache_read_tokens = 0,
            .total_cost = 0.03,
            .models_used = &.{},
            .model_breakdowns = &.{},
            .project = "project-a",
        },
    };

    const totals = types.Totals{
        .input_tokens = 600,
        .output_tokens = 60,
        .cache_creation_tokens = 0,
        .cache_read_tokens = 0,
        .total_tokens = 660,
        .total_cost = 0.06,
    };

    const json_str = try projectGroupedToJson(allocator, "daily", "date", &items, totals);
    defer allocator.free(json_str);

    const parsed = try parseJsonValue(allocator, json_str);
    defer parsed.deinit();
    const root = parsed.value.object;

    // Top-level has "projects" object and "totals"
    const projects = root.get("projects").?.object;
    try testing.expect(projects.contains("project-a"));
    try testing.expect(projects.contains("project-b"));

    // project-a has 2 items
    const proj_a = projects.get("project-a").?.array;
    try testing.expectEqual(@as(usize, 2), proj_a.items.len);

    // project-b has 1 item
    const proj_b = projects.get("project-b").?.array;
    try testing.expectEqual(@as(usize, 1), proj_b.items.len);

    // Verify item structure within a project
    const first_a = proj_a.items[0].object;
    try testing.expect(first_a.contains("date"));
    try testing.expect(first_a.contains("inputTokens"));
    try testing.expect(first_a.contains("totalCost"));

    // Verify totals are present
    const tot = root.get("totals").?.object;
    try testing.expectEqual(@as(i64, 600), tot.get("inputTokens").?.integer);
    try testing.expectApproxEqAbs(0.06, tot.get("totalCost").?.float, 0.000001);

    // No top-level "daily" key
    try testing.expectEqual(@as(?std.json.Value, null), root.get("daily"));
}
