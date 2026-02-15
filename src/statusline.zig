// ABOUTME: Reads Claude Code status bar JSON from stdin and outputs a compact status string.
// ABOUTME: Provides model name, session cost, and context window usage at a glance.
const std = @import("std");

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

pub fn parseStatuslineInput(allocator: std.mem.Allocator, input: []const u8) !StatuslineInput {
    const parsed = try std.json.parseFromSlice(JsonStatusline, allocator, input, .{
        .ignore_unknown_fields = true,
    });
    defer parsed.deinit();

    return StatuslineInput{
        .model_id = parsed.value.model.id,
        .model_display_name = parsed.value.model.display_name,
        .session_cost_usd = parsed.value.cost.total_cost_usd,
        .context_tokens = parsed.value.context_window.total_input_tokens,
        .context_window_size = parsed.value.context_window.context_window_size,
    };
}

pub fn formatStatusline(allocator: std.mem.Allocator, input: StatuslineInput) ![]u8 {
    if (input.context_window_size == 0) {
        return std.fmt.allocPrint(allocator, "{s} | ${d:.4} | ? ctx", .{
            input.model_display_name,
            input.session_cost_usd,
        });
    }
    const pct = @as(f64, @floatFromInt(input.context_tokens)) / @as(f64, @floatFromInt(input.context_window_size)) * 100.0;
    return std.fmt.allocPrint(allocator, "{s} | ${d:.4} | {d:.0}% ctx", .{
        input.model_display_name,
        input.session_cost_usd,
        pct,
    });
}

fn formatCurrency(buf: []u8, amount: f64) []u8 {
    return std.fmt.bufPrint(buf, "${d:.2}", .{amount}) catch buf[0..0];
}

fn formatTokenCount(buf: []u8, count: u64) []u8 {
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
    const total_mins: u64 = @intFromFloat(remaining_minutes);
    const hours = total_mins / 60;
    const mins = total_mins % 60;
    if (hours > 0) {
        return std.fmt.bufPrint(buf, "{d}h {d}m left", .{ hours, mins }) catch buf[0..0];
    }
    return std.fmt.bufPrint(buf, "{d}m left", .{mins}) catch buf[0..0];
}

pub fn runStatusline(allocator: std.mem.Allocator) !void {
    const input = try std.fs.File.stdin().readToEndAlloc(allocator, 1024 * 1024);
    defer allocator.free(input);

    const parsed = try parseStatuslineInput(allocator, input);
    const output = try formatStatusline(allocator, parsed);
    defer allocator.free(output);

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
    try std.testing.expectEqualStrings("claude-sonnet-4-20250514", result.model_id);
    try std.testing.expectEqualStrings("Sonnet 4", result.model_display_name);
    try std.testing.expectApproxEqAbs(@as(f64, 0.056), result.session_cost_usd, 0.0001);
    try std.testing.expectEqual(@as(u64, 42500), result.context_tokens);
    try std.testing.expectEqual(@as(u64, 200000), result.context_window_size);
}

test "parseStatuslineInput: parse minimal input with required fields only" {
    const input =
        \\{"model":{"id":"claude-opus-4","display_name":"Opus 4"},"cost":{"total_cost_usd":1.23},"context_window":{"total_input_tokens":100000,"context_window_size":200000}}
    ;
    const result = try parseStatuslineInput(std.testing.allocator, input);
    try std.testing.expectEqualStrings("claude-opus-4", result.model_id);
    try std.testing.expectEqualStrings("Opus 4", result.model_display_name);
    try std.testing.expectApproxEqAbs(@as(f64, 1.23), result.session_cost_usd, 0.0001);
    try std.testing.expectEqual(@as(u64, 100000), result.context_tokens);
    try std.testing.expectEqual(@as(u64, 200000), result.context_window_size);
}

test "formatStatusline: formats output correctly" {
    const input = StatuslineInput{
        .model_id = "claude-sonnet-4-20250514",
        .model_display_name = "Sonnet 4",
        .session_cost_usd = 0.056,
        .context_tokens = 42500,
        .context_window_size = 200000,
    };
    const result = try formatStatusline(std.testing.allocator, input);
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("Sonnet 4 | $0.0560 | 21% ctx", result);
}

test "formatStatusline: zero context window shows question mark" {
    const input = StatuslineInput{
        .model_id = "claude-opus-4",
        .model_display_name = "Opus 4",
        .session_cost_usd = 2.5,
        .context_tokens = 1000,
        .context_window_size = 0,
    };
    const result = try formatStatusline(std.testing.allocator, input);
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("Opus 4 | $2.5000 | ? ctx", result);
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
