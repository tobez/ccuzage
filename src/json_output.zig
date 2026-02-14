// ABOUTME: Serializes aggregated usage data to JSON matching the ccusage output format.
// ABOUTME: Provides camelCase JSON output for daily, monthly, and weekly reports.
const std = @import("std");
const types = @import("types.zig");

const Writer = std.io.Writer;

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
