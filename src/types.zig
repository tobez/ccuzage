// ABOUTME: Core data structures used throughout the blazing CLI tool.
// ABOUTME: Defines types for token usage entries, aggregation, sessions, blocks, and CLI options.
const std = @import("std");

/// Fields `model`, `message_id`, and `request_id` are owned allocations that must be freed.
/// Fields `session_id` and `project` are borrowed from the caller and must not be freed.
pub const UsageEntry = struct {
    session_id: []const u8,
    project: []const u8,
    timestamp: i64, // epoch millis
    model: []const u8,
    input_tokens: u64,
    output_tokens: u64,
    cache_creation_tokens: u64,
    cache_read_tokens: u64,
    cost_usd: f64,
    message_id: []const u8,
    request_id: []const u8,

    pub fn totalTokens(self: UsageEntry) u64 {
        return self.input_tokens + self.output_tokens + self.cache_creation_tokens + self.cache_read_tokens;
    }
};

pub const ModelBreakdown = struct {
    model_name: []const u8,
    input_tokens: u64,
    output_tokens: u64,
    cache_creation_tokens: u64,
    cache_read_tokens: u64,
    cost: f64,

    pub fn totalTokens(self: ModelBreakdown) u64 {
        return self.input_tokens + self.output_tokens + self.cache_creation_tokens + self.cache_read_tokens;
    }
};

pub const AggregatedUsage = struct {
    period: []const u8,
    input_tokens: u64,
    output_tokens: u64,
    cache_creation_tokens: u64,
    cache_read_tokens: u64,
    total_cost: f64,
    models_used: []const []const u8,
    model_breakdowns: []const ModelBreakdown,
    project: ?[]const u8, // only with --instances
};

pub const SessionUsage = struct {
    session_id: []const u8,
    project_path: []const u8,
    input_tokens: u64,
    output_tokens: u64,
    cache_creation_tokens: u64,
    cache_read_tokens: u64,
    total_cost: f64,
    last_activity: []const u8, // YYYY-MM-DD
    models_used: []const []const u8,
    model_breakdowns: []const ModelBreakdown,
};

pub const BurnRate = struct {
    tokens_per_minute: f64,
    cost_per_hour: f64,
};

pub const Projection = struct {
    total_tokens: u64,
    total_cost: f64,
    remaining_minutes: f64,
};

pub const SessionBlock = struct {
    id: []const u8, // ISO timestamp of block start
    start_time: i64, // epoch millis
    end_time: i64, // start_time + session_duration
    actual_end_time: ?i64, // last activity timestamp
    is_active: bool,
    is_gap: bool,
    entry_count: u32,
    input_tokens: u64,
    output_tokens: u64,
    cache_creation_tokens: u64,
    cache_read_tokens: u64,
    cost_usd: f64,
    models: []const []const u8,
    burn_rate: ?BurnRate,
    projection: ?Projection,

    pub fn totalTokens(self: SessionBlock) u64 {
        return self.input_tokens + self.output_tokens + self.cache_creation_tokens + self.cache_read_tokens;
    }
};

pub const Totals = struct {
    input_tokens: u64,
    output_tokens: u64,
    cache_creation_tokens: u64,
    cache_read_tokens: u64,
    total_tokens: u64,
    total_cost: f64,
};

pub const Command = enum {
    daily,
    weekly,
    monthly,
    session,
    blocks,
    statusline,
};

pub const SortOrder = enum { asc, desc };

pub const CliOptions = struct {
    command: Command,
    since: ?[]const u8, // YYYYMMDD
    until: ?[]const u8, // YYYYMMDD
    json: bool,
    breakdown: bool,
    timezone_offset_minutes: ?i32, // null = use system timezone
    order: SortOrder,
    project: ?[]const u8,
    instances: bool,
    // blocks-specific
    active: bool,
    recent: bool,
    session_length: u32, // hours, default 5
    token_limit: ?u64,

    pub const default = CliOptions{
        .command = .daily,
        .since = null,
        .until = null,
        .json = true, // JSON-first approach
        .breakdown = false,
        .timezone_offset_minutes = null,
        .order = .desc,
        .project = null,
        .instances = false,
        .active = false,
        .recent = false,
        .session_length = 5,
        .token_limit = null,
    };
};

// =============================================================================
// Tests
// =============================================================================

test "UsageEntry totalTokens sums all token fields" {
    const entry = UsageEntry{
        .session_id = "sess-1",
        .project = "/tmp/proj",
        .timestamp = 1700000000000,
        .model = "claude-opus-4",
        .input_tokens = 100,
        .output_tokens = 200,
        .cache_creation_tokens = 50,
        .cache_read_tokens = 25,
        .cost_usd = 0.01,
        .message_id = "msg-1",
        .request_id = "req-1",
    };
    try std.testing.expectEqual(@as(u64, 375), entry.totalTokens());
}

test "ModelBreakdown totalTokens sums all token fields" {
    const mb = ModelBreakdown{
        .model_name = "claude-sonnet-4",
        .input_tokens = 1000,
        .output_tokens = 2000,
        .cache_creation_tokens = 500,
        .cache_read_tokens = 300,
        .cost = 0.05,
    };
    try std.testing.expectEqual(@as(u64, 3800), mb.totalTokens());
}

test "CliOptions default has expected values" {
    const opts = CliOptions.default;
    try std.testing.expectEqual(Command.daily, opts.command);
    try std.testing.expectEqual(@as(?[]const u8, null), opts.since);
    try std.testing.expectEqual(@as(?[]const u8, null), opts.until);
    try std.testing.expectEqual(true, opts.json);
    try std.testing.expectEqual(false, opts.breakdown);
    try std.testing.expectEqual(@as(?i32, null), opts.timezone_offset_minutes);
    try std.testing.expectEqual(SortOrder.desc, opts.order);
    try std.testing.expectEqual(@as(?[]const u8, null), opts.project);
    try std.testing.expectEqual(false, opts.instances);
    try std.testing.expectEqual(false, opts.active);
    try std.testing.expectEqual(false, opts.recent);
    try std.testing.expectEqual(@as(u32, 5), opts.session_length);
    try std.testing.expectEqual(@as(?u64, null), opts.token_limit);
}

test "Totals struct fields are accessible" {
    const totals = Totals{
        .input_tokens = 10000,
        .output_tokens = 5000,
        .cache_creation_tokens = 2000,
        .cache_read_tokens = 1000,
        .total_tokens = 18000,
        .total_cost = 1.23,
    };
    try std.testing.expectEqual(@as(u64, 10000), totals.input_tokens);
    try std.testing.expectEqual(@as(u64, 5000), totals.output_tokens);
    try std.testing.expectEqual(@as(u64, 2000), totals.cache_creation_tokens);
    try std.testing.expectEqual(@as(u64, 1000), totals.cache_read_tokens);
    try std.testing.expectEqual(@as(u64, 18000), totals.total_tokens);
    try std.testing.expectApproxEqAbs(@as(f64, 1.23), totals.total_cost, 0.001);
}

test "SessionBlock totalTokens sums all token fields" {
    const block = SessionBlock{
        .id = "2025-01-15T10:00:00.000Z",
        .start_time = 1736937000000,
        .end_time = 1736955000000,
        .actual_end_time = null,
        .is_active = false,
        .is_gap = false,
        .entry_count = 42,
        .input_tokens = 5000,
        .output_tokens = 3000,
        .cache_creation_tokens = 1000,
        .cache_read_tokens = 500,
        .cost_usd = 0.50,
        .models = &.{},
        .burn_rate = null,
        .projection = null,
    };
    try std.testing.expectEqual(@as(u64, 9500), block.totalTokens());
}
