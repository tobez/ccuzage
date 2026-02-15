// ABOUTME: Reads Claude Code status bar JSON from stdin and outputs a rich ccusage-compatible status string.
// ABOUTME: Shows model, session/today/block costs, burn rate, and context window usage.
const std = @import("std");
const types = @import("types.zig");
const loader = @import("loader.zig");
const aggregate = @import("aggregate.zig");
const blocks_mod = @import("blocks.zig");
const date = @import("date.zig");

pub const StatuslineInput = struct {
    model_id: []const u8,
    model_display_name: []const u8,
    session_cost_usd: f64,
    context_tokens: u64,
    context_window_size: u64,
};

// JSON shape structs matching Claude Code's status bar hook format
const JsonModel = struct {
    id: []const u8,
    display_name: []const u8,
};

const JsonCost = struct {
    total_cost_usd: f64,
};

const JsonContextWindow = struct {
    total_input_tokens: u64,
    context_window_size: u64,
};

const JsonStatusline = struct {
    model: JsonModel,
    cost: JsonCost,
    context_window: JsonContextWindow,
};

/// Parses JSON from Claude Code's status bar hook into StatuslineInput.
/// Caller must keep the returned parsed result alive while using the StatuslineInput,
/// since string fields borrow from the parsed JSON arena.
pub fn parseStatuslineInput(allocator: std.mem.Allocator, input: []const u8) !struct { value: StatuslineInput, parsed: std.json.Parsed(JsonStatusline) } {
    const parsed = try std.json.parseFromSlice(JsonStatusline, allocator, input, .{
        .ignore_unknown_fields = true,
    });

    return .{
        .value = StatuslineInput{
            .model_id = parsed.value.model.id,
            .model_display_name = parsed.value.model.display_name,
            .session_cost_usd = parsed.value.cost.total_cost_usd,
            .context_tokens = parsed.value.context_window.total_input_tokens,
            .context_window_size = parsed.value.context_window.context_window_size,
        },
        .parsed = parsed,
    };
}

pub fn formatCurrency(buf: []u8, amount: f64) []u8 {
    return std.fmt.bufPrint(buf, "${d:.2}", .{amount}) catch buf[0..0];
}

pub fn formatTokenCount(buf: []u8, count: u64) []u8 {
    if (count == 0) {
        buf[0] = '0';
        return buf[0..1];
    }
    // Format number with comma separators by building from right to left
    var tmp: [32]u8 = undefined;
    const plain = std.fmt.bufPrint(&tmp, "{d}", .{count}) catch return buf[0..0];
    var pos: usize = 0;
    for (plain, 0..) |c, i| {
        const remaining = plain.len - i;
        if (i > 0 and remaining % 3 == 0) {
            buf[pos] = ',';
            pos += 1;
        }
        buf[pos] = c;
        pos += 1;
    }
    return buf[0..pos];
}

fn formatTimeRemaining(buf: []u8, remaining_minutes: f64) []u8 {
    const clamped = @max(remaining_minutes, 0.0);
    const total_mins: u64 = @intFromFloat(clamped);
    const hours = total_mins / 60;
    const mins = total_mins % 60;
    if (hours > 0) {
        return std.fmt.bufPrint(buf, "{d}h {d}m left", .{ hours, mins }) catch buf[0..0];
    }
    return std.fmt.bufPrint(buf, "{d}m left", .{mins}) catch buf[0..0];
}

const BurnLevel = enum {
    normal,
    moderate,
    high,

    fn classify(io_tokens_per_minute: f64) BurnLevel {
        if (io_tokens_per_minute >= 5000.0) return .high;
        if (io_tokens_per_minute >= 2000.0) return .moderate;
        return .normal;
    }

    fn emoji(self: BurnLevel) []const u8 {
        return switch (self) {
            .normal => "\xf0\x9f\x9f\xa2",
            .moderate => "\xf0\x9f\x9f\xa1",
            .high => "\xf0\x9f\x94\xb4",
        };
    }

    fn label(self: BurnLevel) []const u8 {
        return switch (self) {
            .normal => "Normal",
            .moderate => "Moderate",
            .high => "High",
        };
    }
};

fn formatBurnRate(buf: []u8, cost_per_hour: f64, io_tokens_per_minute: f64, visual: types.BurnRateVisual) []u8 {
    var cost_buf: [32]u8 = undefined;
    const cost_str = formatCurrency(&cost_buf, cost_per_hour);

    const level = BurnLevel.classify(io_tokens_per_minute);

    return switch (visual) {
        .off => std.fmt.bufPrint(buf, "\xf0\x9f\x94\xa5 {s}/hr", .{cost_str}) catch buf[0..0],
        .emoji => std.fmt.bufPrint(buf, "\xf0\x9f\x94\xa5 {s}/hr {s}", .{
            cost_str, level.emoji(),
        }) catch buf[0..0],
        .text => std.fmt.bufPrint(buf, "\xf0\x9f\x94\xa5 {s}/hr ({s})", .{
            cost_str, level.label(),
        }) catch buf[0..0],
        .emoji_text => std.fmt.bufPrint(buf, "\xf0\x9f\x94\xa5 {s}/hr {s} ({s})", .{
            cost_str, level.emoji(), level.label(),
        }) catch buf[0..0],
    };
}

pub const StatuslineData = struct {
    model_display_name: []const u8,
    session_cost: f64,
    today_cost: f64,
    block_cost: ?f64,
    remaining_minutes: ?f64,
    burn_rate_cost_per_hour: ?f64,
    io_tokens_per_minute: ?f64,
    context_tokens: u64,
    context_window_size: u64,
    burn_rate_visual: types.BurnRateVisual,
};

fn formatRichStatusline(buf: []u8, data: StatuslineData) []u8 {
    var pos: usize = 0;

    // Helper to append a slice to the output buffer
    const writer = struct {
        fn append(b: []u8, p: *usize, s: []const u8) void {
            @memcpy(b[p.*..][0..s.len], s);
            p.* += s.len;
        }
    };

    // 🤖 {model}
    writer.append(buf, &pos, "\xf0\x9f\xa4\x96 ");
    writer.append(buf, &pos, data.model_display_name);

    // | 💰 {session} session / {today} today
    writer.append(buf, &pos, " | \xf0\x9f\x92\xb0 ");
    var cost_buf: [32]u8 = undefined;
    var cost_str = formatCurrency(&cost_buf, data.session_cost);
    writer.append(buf, &pos, cost_str);
    writer.append(buf, &pos, " session / ");
    cost_str = formatCurrency(&cost_buf, data.today_cost);
    writer.append(buf, &pos, cost_str);
    writer.append(buf, &pos, " today / ");

    // Block info or "No active block"
    if (data.block_cost) |block_cost| {
        cost_str = formatCurrency(&cost_buf, block_cost);
        writer.append(buf, &pos, cost_str);
        writer.append(buf, &pos, " block");
        if (data.remaining_minutes) |remaining| {
            writer.append(buf, &pos, " (");
            var time_buf: [32]u8 = undefined;
            const time_str = formatTimeRemaining(&time_buf, remaining);
            writer.append(buf, &pos, time_str);
            writer.append(buf, &pos, ")");
        }
    } else {
        writer.append(buf, &pos, "No active block");
    }

    // | 🔥 burn rate (only if active block)
    if (data.burn_rate_cost_per_hour) |cost_per_hour| {
        writer.append(buf, &pos, " | ");
        var burn_buf: [128]u8 = undefined;
        const burn_str = formatBurnRate(&burn_buf, cost_per_hour, data.io_tokens_per_minute orelse 0.0, data.burn_rate_visual);
        writer.append(buf, &pos, burn_str);
    }

    // | 🧠 {tokens} ({pct}%)
    writer.append(buf, &pos, " | \xf0\x9f\xa7\xa0 ");
    var tok_buf: [32]u8 = undefined;
    const tok_str = formatTokenCount(&tok_buf, data.context_tokens);
    writer.append(buf, &pos, tok_str);

    if (data.context_window_size == 0) {
        writer.append(buf, &pos, " (?%)");
    } else {
        const pct: u64 = data.context_tokens * 100 / data.context_window_size;
        var pct_buf: [16]u8 = undefined;
        const pct_str = std.fmt.bufPrint(&pct_buf, " ({d}%)", .{pct}) catch pct_buf[0..0];
        writer.append(buf, &pos, pct_str);
    }

    return buf[0..pos];
}

fn computeIoTokensPerMinute(io_tokens: u64, total_tokens: u64, total_tokens_per_minute: f64) ?f64 {
    if (total_tokens_per_minute <= 0 or total_tokens == 0) return null;
    const io_f: f64 = @floatFromInt(io_tokens);
    const total_f: f64 = @floatFromInt(total_tokens);
    return io_f * total_tokens_per_minute / total_f;
}

const TodayData = struct {
    today_cost: f64,
    block_cost: ?f64,
    remaining_minutes: ?f64,
    burn_rate_cost_per_hour: ?f64,
    io_tokens_per_minute: ?f64,
};

fn loadTodayData(allocator: std.mem.Allocator, tz_offset: i32, session_length: u32) !TodayData {
    const now_ms = std.time.milliTimestamp();

    // Compute today's YYYYMMDD string
    const daily_str = date.formatDaily(now_ms, tz_offset);
    const today_yyyymmdd = date.dailyToFilterDate(&daily_str);

    // Build file time filter for today only
    const since_epoch_ms = date.filterDateToEpochMs(&today_yyyymmdd) orelse
        return error.InvalidDate;
    const utc_since_ms = since_epoch_ms - @as(i64, tz_offset) * 60_000;
    const time_filter = loader.FileTimeFilter{
        .since_cutoff_ns = @as(i128, utc_since_ms) * 1_000_000,
    };

    const all_entries = try loader.loadAllEntries(allocator, time_filter);

    // Filter to today only
    const entries = try aggregate.filterByDateRange(
        allocator,
        all_entries,
        &today_yyyymmdd,
        &today_yyyymmdd,
        tz_offset,
    );

    // Aggregate today's cost
    const daily = try aggregate.aggregateDaily(allocator, entries, tz_offset, false);
    const totals = aggregate.calculateTotals(daily);

    // Find active block
    const all_blocks = try blocks_mod.identifyBlocks(allocator, entries, session_length, now_ms);
    const active_blocks = try blocks_mod.filterActive(allocator, all_blocks);

    if (active_blocks.len > 0) {
        const block = active_blocks[0];
        const burn_rate = block.burn_rate;
        const remaining = if (block.projection) |proj| proj.remaining_minutes else null;

        const io_tpm: ?f64 = if (burn_rate) |br|
            computeIoTokensPerMinute(
                block.input_tokens + block.output_tokens,
                block.totalTokens(),
                br.tokens_per_minute,
            )
        else
            null;

        return TodayData{
            .today_cost = totals.total_cost,
            .block_cost = block.cost_usd,
            .remaining_minutes = remaining,
            .burn_rate_cost_per_hour = if (burn_rate) |br| br.cost_per_hour else null,
            .io_tokens_per_minute = io_tpm,
        };
    }

    return TodayData{
        .today_cost = totals.total_cost,
        .block_cost = null,
        .remaining_minutes = null,
        .burn_rate_cost_per_hour = null,
        .io_tokens_per_minute = null,
    };
}

pub fn runStatusline(
    allocator: std.mem.Allocator,
    tz_offset: i32,
    session_length: u32,
    burn_rate_visual: types.BurnRateVisual,
) !void {
    const input = try std.fs.File.stdin().readToEndAlloc(allocator, 1024 * 1024);
    defer allocator.free(input);

    const result = try parseStatuslineInput(allocator, input);
    defer result.parsed.deinit();
    const parsed = result.value;

    // Load today's cost and active block info (non-fatal on error)
    const today = loadTodayData(allocator, tz_offset, session_length) catch TodayData{
        .today_cost = parsed.session_cost_usd,
        .block_cost = null,
        .remaining_minutes = null,
        .burn_rate_cost_per_hour = null,
        .io_tokens_per_minute = null,
    };

    const model_name = if (parsed.model_display_name.len > 64) parsed.model_display_name[0..64] else parsed.model_display_name;

    const data = StatuslineData{
        .model_display_name = model_name,
        .session_cost = parsed.session_cost_usd,
        .today_cost = today.today_cost,
        .block_cost = today.block_cost,
        .remaining_minutes = today.remaining_minutes,
        .burn_rate_cost_per_hour = today.burn_rate_cost_per_hour,
        .io_tokens_per_minute = today.io_tokens_per_minute,
        .context_tokens = parsed.context_tokens,
        .context_window_size = parsed.context_window_size,
        .burn_rate_visual = burn_rate_visual,
    };

    var buf: [512]u8 = undefined;
    const output = formatRichStatusline(&buf, data);

    var stdout_buffer: [4096]u8 = undefined;
    var stdout_writer = std.fs.File.stdout().writer(&stdout_buffer);
    const stdout = &stdout_writer.interface;
    try stdout.print("{s}\n", .{output});
    try stdout.flush();
}

// =============================================================================
// Tests
// =============================================================================

test "parseStatuslineInput: parse valid input with all fields" {
    const input =
        \\{"session_id":"abc","transcript_path":"/tmp/session.jsonl","cwd":"/home","model":{"id":"claude-sonnet-4-20250514","display_name":"Sonnet 4"},"cost":{"total_cost_usd":0.056},"context_window":{"total_input_tokens":42500,"context_window_size":200000}}
    ;
    const result = try parseStatuslineInput(std.testing.allocator, input);
    defer result.parsed.deinit();
    try std.testing.expectEqualStrings("claude-sonnet-4-20250514", result.value.model_id);
    try std.testing.expectEqualStrings("Sonnet 4", result.value.model_display_name);
    try std.testing.expectApproxEqAbs(@as(f64, 0.056), result.value.session_cost_usd, 0.0001);
    try std.testing.expectEqual(@as(u64, 42500), result.value.context_tokens);
    try std.testing.expectEqual(@as(u64, 200000), result.value.context_window_size);
}

test "parseStatuslineInput: parse minimal input with required fields only" {
    const input =
        \\{"model":{"id":"claude-opus-4","display_name":"Opus 4"},"cost":{"total_cost_usd":1.23},"context_window":{"total_input_tokens":100000,"context_window_size":200000}}
    ;
    const result = try parseStatuslineInput(std.testing.allocator, input);
    defer result.parsed.deinit();
    try std.testing.expectEqualStrings("claude-opus-4", result.value.model_id);
    try std.testing.expectEqualStrings("Opus 4", result.value.model_display_name);
    try std.testing.expectApproxEqAbs(@as(f64, 1.23), result.value.session_cost_usd, 0.0001);
    try std.testing.expectEqual(@as(u64, 100000), result.value.context_tokens);
    try std.testing.expectEqual(@as(u64, 200000), result.value.context_window_size);
}

test "formatCurrency: typical amount" {
    var buf: [32]u8 = undefined;
    try std.testing.expectEqualStrings("$0.23", formatCurrency(&buf, 0.23));
}

test "formatCurrency: zero" {
    var buf: [32]u8 = undefined;
    try std.testing.expectEqualStrings("$0.00", formatCurrency(&buf, 0.0));
}

test "formatCurrency: large amount" {
    var buf: [32]u8 = undefined;
    try std.testing.expectEqualStrings("$12.34", formatCurrency(&buf, 12.34));
}

test "formatCurrency: tiny amount" {
    var buf: [32]u8 = undefined;
    try std.testing.expectEqualStrings("$0.01", formatCurrency(&buf, 0.005));
}

test "formatTokenCount: small number" {
    var buf: [32]u8 = undefined;
    try std.testing.expectEqualStrings("500", formatTokenCount(&buf, 500));
}

test "formatTokenCount: thousands" {
    var buf: [32]u8 = undefined;
    try std.testing.expectEqualStrings("25,000", formatTokenCount(&buf, 25000));
}

test "formatTokenCount: millions" {
    var buf: [32]u8 = undefined;
    try std.testing.expectEqualStrings("1,234,567", formatTokenCount(&buf, 1234567));
}

test "formatTokenCount: zero" {
    var buf: [32]u8 = undefined;
    try std.testing.expectEqualStrings("0", formatTokenCount(&buf, 0));
}

test "formatTimeRemaining: hours and minutes" {
    var buf: [32]u8 = undefined;
    try std.testing.expectEqualStrings("2h 45m left", formatTimeRemaining(&buf, 165.0));
}

test "formatTimeRemaining: minutes only" {
    var buf: [32]u8 = undefined;
    try std.testing.expectEqualStrings("45m left", formatTimeRemaining(&buf, 45.0));
}

test "formatTimeRemaining: exact hours" {
    var buf: [32]u8 = undefined;
    try std.testing.expectEqualStrings("3h 0m left", formatTimeRemaining(&buf, 180.0));
}

test "formatTimeRemaining: less than one minute" {
    var buf: [32]u8 = undefined;
    try std.testing.expectEqualStrings("0m left", formatTimeRemaining(&buf, 0.5));
}

// formatBurnRate tests: 4 visual modes x 3 threshold levels
test "formatBurnRate: off mode, normal rate" {
    var buf: [128]u8 = undefined;
    const result = formatBurnRate(&buf, 0.12, 1000.0, .off);
    try std.testing.expectEqualStrings("\xf0\x9f\x94\xa5 $0.12/hr", result);
}

test "formatBurnRate: off mode, high rate" {
    var buf: [128]u8 = undefined;
    const result = formatBurnRate(&buf, 5.50, 6000.0, .off);
    try std.testing.expectEqualStrings("\xf0\x9f\x94\xa5 $5.50/hr", result);
}

test "formatBurnRate: emoji mode, normal rate" {
    var buf: [128]u8 = undefined;
    const result = formatBurnRate(&buf, 0.12, 1000.0, .emoji);
    try std.testing.expectEqualStrings("\xf0\x9f\x94\xa5 $0.12/hr \xf0\x9f\x9f\xa2", result);
}

test "formatBurnRate: emoji mode, moderate rate" {
    var buf: [128]u8 = undefined;
    const result = formatBurnRate(&buf, 2.00, 3000.0, .emoji);
    try std.testing.expectEqualStrings("\xf0\x9f\x94\xa5 $2.00/hr \xf0\x9f\x9f\xa1", result);
}

test "formatBurnRate: emoji mode, high rate" {
    var buf: [128]u8 = undefined;
    const result = formatBurnRate(&buf, 10.00, 6000.0, .emoji);
    try std.testing.expectEqualStrings("\xf0\x9f\x94\xa5 $10.00/hr \xf0\x9f\x94\xb4", result);
}

test "formatBurnRate: text mode, normal rate" {
    var buf: [128]u8 = undefined;
    const result = formatBurnRate(&buf, 0.12, 1000.0, .text);
    try std.testing.expectEqualStrings("\xf0\x9f\x94\xa5 $0.12/hr (Normal)", result);
}

test "formatBurnRate: text mode, moderate rate" {
    var buf: [128]u8 = undefined;
    const result = formatBurnRate(&buf, 2.00, 3000.0, .text);
    try std.testing.expectEqualStrings("\xf0\x9f\x94\xa5 $2.00/hr (Moderate)", result);
}

test "formatBurnRate: text mode, high rate" {
    var buf: [128]u8 = undefined;
    const result = formatBurnRate(&buf, 10.00, 6000.0, .text);
    try std.testing.expectEqualStrings("\xf0\x9f\x94\xa5 $10.00/hr (High)", result);
}

test "formatBurnRate: emoji_text mode, normal rate" {
    var buf: [128]u8 = undefined;
    const result = formatBurnRate(&buf, 0.12, 1000.0, .emoji_text);
    try std.testing.expectEqualStrings("\xf0\x9f\x94\xa5 $0.12/hr \xf0\x9f\x9f\xa2 (Normal)", result);
}

test "formatBurnRate: emoji_text mode, moderate rate" {
    var buf: [128]u8 = undefined;
    const result = formatBurnRate(&buf, 2.00, 3000.0, .emoji_text);
    try std.testing.expectEqualStrings("\xf0\x9f\x94\xa5 $2.00/hr \xf0\x9f\x9f\xa1 (Moderate)", result);
}

test "formatBurnRate: emoji_text mode, high rate" {
    var buf: [128]u8 = undefined;
    const result = formatBurnRate(&buf, 10.00, 6000.0, .emoji_text);
    try std.testing.expectEqualStrings("\xf0\x9f\x94\xa5 $10.00/hr \xf0\x9f\x94\xb4 (High)", result);
}

test "formatRichStatusline: with active block" {
    var buf: [512]u8 = undefined;
    const data = StatuslineData{
        .model_display_name = "Opus",
        .session_cost = 0.23,
        .today_cost = 1.23,
        .block_cost = 0.45,
        .remaining_minutes = 165.0,
        .burn_rate_cost_per_hour = 0.12,
        .io_tokens_per_minute = 1000.0,
        .context_tokens = 25000,
        .context_window_size = 200000,
        .burn_rate_visual = .off,
    };
    const result = formatRichStatusline(&buf, data);
    // 🤖 Opus | 💰 $0.23 session / $1.23 today / $0.45 block (2h 45m left) | 🔥 $0.12/hr | 🧠 25,000 (12%)
    try std.testing.expectEqualStrings(
        "\xf0\x9f\xa4\x96 Opus | \xf0\x9f\x92\xb0 $0.23 session / $1.23 today / $0.45 block (2h 45m left) | \xf0\x9f\x94\xa5 $0.12/hr | \xf0\x9f\xa7\xa0 25,000 (12%)",
        result,
    );
}

test "formatRichStatusline: without active block" {
    var buf: [512]u8 = undefined;
    const data = StatuslineData{
        .model_display_name = "Opus",
        .session_cost = 0.23,
        .today_cost = 1.23,
        .block_cost = null,
        .remaining_minutes = null,
        .burn_rate_cost_per_hour = null,
        .io_tokens_per_minute = null,
        .context_tokens = 25000,
        .context_window_size = 200000,
        .burn_rate_visual = .off,
    };
    const result = formatRichStatusline(&buf, data);
    // 🤖 Opus | 💰 $0.23 session / $1.23 today / No active block | 🧠 25,000 (12%)
    try std.testing.expectEqualStrings(
        "\xf0\x9f\xa4\x96 Opus | \xf0\x9f\x92\xb0 $0.23 session / $1.23 today / No active block | \xf0\x9f\xa7\xa0 25,000 (12%)",
        result,
    );
}

test "formatRichStatusline: with burn rate emoji visual" {
    var buf: [512]u8 = undefined;
    const data = StatuslineData{
        .model_display_name = "Sonnet",
        .session_cost = 0.05,
        .today_cost = 0.05,
        .block_cost = 0.05,
        .remaining_minutes = 290.0,
        .burn_rate_cost_per_hour = 0.50,
        .io_tokens_per_minute = 3000.0,
        .context_tokens = 50000,
        .context_window_size = 200000,
        .burn_rate_visual = .emoji,
    };
    const result = formatRichStatusline(&buf, data);
    try std.testing.expectEqualStrings(
        "\xf0\x9f\xa4\x96 Sonnet | \xf0\x9f\x92\xb0 $0.05 session / $0.05 today / $0.05 block (4h 50m left) | \xf0\x9f\x94\xa5 $0.50/hr \xf0\x9f\x9f\xa1 | \xf0\x9f\xa7\xa0 50,000 (25%)",
        result,
    );
}

test "formatRichStatusline: zero context window" {
    var buf: [512]u8 = undefined;
    const data = StatuslineData{
        .model_display_name = "Opus",
        .session_cost = 0.10,
        .today_cost = 0.10,
        .block_cost = null,
        .remaining_minutes = null,
        .burn_rate_cost_per_hour = null,
        .io_tokens_per_minute = null,
        .context_tokens = 1000,
        .context_window_size = 0,
        .burn_rate_visual = .off,
    };
    const result = formatRichStatusline(&buf, data);
    try std.testing.expectEqualStrings(
        "\xf0\x9f\xa4\x96 Opus | \xf0\x9f\x92\xb0 $0.10 session / $0.10 today / No active block | \xf0\x9f\xa7\xa0 1,000 (?%)",
        result,
    );
}

test "formatTimeRemaining: negative input clamps to zero" {
    var buf: [32]u8 = undefined;
    try std.testing.expectEqualStrings("0m left", formatTimeRemaining(&buf, -5.0));
}

test "computeIoTokensPerMinute: typical block" {
    // 8000 IO tokens out of 10000 total, at 100 total tokens/min
    // Expected: 8000 * 100 / 10000 = 80 IO tokens/min
    const result = computeIoTokensPerMinute(8000, 10000, 100.0);
    try std.testing.expectApproxEqAbs(@as(f64, 80.0), result.?, 0.01);
}

test "computeIoTokensPerMinute: zero total tokens returns null" {
    try std.testing.expect(computeIoTokensPerMinute(0, 0, 100.0) == null);
}

test "computeIoTokensPerMinute: zero rate returns null" {
    try std.testing.expect(computeIoTokensPerMinute(5000, 10000, 0.0) == null);
}
