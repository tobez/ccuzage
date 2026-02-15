// ABOUTME: Session block algorithm that groups usage entries into 5-hour billing windows.
// ABOUTME: Identifies blocks, gaps, burn rates, active sessions, and projections.
const std = @import("std");
const types = @import("types.zig");
const date = @import("date.zig");

pub const DEFAULT_SESSION_DURATION_HOURS: u32 = 5;

/// Groups usage entries into session blocks based on a configurable time window.
/// Entries are grouped into blocks where each block spans session_duration_hours from
/// a floored hour start. Gap blocks are inserted between non-contiguous blocks.
/// Caller owns the returned slice and all allocated memory within it.
pub fn identifyBlocks(
    allocator: std.mem.Allocator,
    entries: []const types.UsageEntry,
    session_duration_hours: u32,
    now_ms: i64,
) ![]types.SessionBlock {
    if (entries.len == 0) return &[_]types.SessionBlock{};

    const session_duration_ms: i64 = @as(i64, session_duration_hours) * 3600 * 1000;

    // Copy and sort entries by timestamp (ascending)
    const sorted = try allocator.alloc(types.UsageEntry, entries.len);
    defer allocator.free(sorted);
    @memcpy(sorted, entries);
    std.mem.sort(types.UsageEntry, sorted, {}, struct {
        fn cmp(_: void, a: types.UsageEntry, b: types.UsageEntry) bool {
            return a.timestamp < b.timestamp;
        }
    }.cmp);

    // Group entries into blocks
    var block_groups: std.ArrayList(BlockGroup) = .{};
    defer {
        for (block_groups.items) |*bg| bg.deinit(allocator);
        block_groups.deinit(allocator);
    }

    var current_group = BlockGroup.init(sorted[0].timestamp, session_duration_ms);
    current_group.addEntry(allocator, sorted[0]);

    for (sorted[1..]) |entry| {
        const elapsed_from_start = entry.timestamp - current_group.block_start;
        const elapsed_from_last = entry.timestamp - current_group.last_timestamp;

        if (elapsed_from_start > session_duration_ms or elapsed_from_last > session_duration_ms) {
            // Finalize current group and start a new one
            try block_groups.append(allocator, current_group);
            current_group = BlockGroup.init(entry.timestamp, session_duration_ms);
        }
        current_group.addEntry(allocator, entry);
    }
    try block_groups.append(allocator, current_group);

    // Build session blocks with gap insertion
    var result: std.ArrayList(types.SessionBlock) = .{};
    errdefer {
        for (result.items) |*block| freeBlock(allocator, block);
        result.deinit(allocator);
    }

    for (block_groups.items, 0..) |*bg, i| {
        // Insert gap before this block if needed
        if (i > 0) {
            const prev = &block_groups.items[i - 1];
            const prev_end_time = prev.block_start + session_duration_ms;
            if (bg.block_start > prev_end_time) {
                try result.append(allocator, try makeGapBlock(allocator, prev_end_time, bg.block_start));
            }
        }

        const block = try buildSessionBlock(allocator, bg, session_duration_ms, now_ms);
        try result.append(allocator, block);
    }

    return try result.toOwnedSlice(allocator);
}

/// Free all allocations within a SessionBlock.
pub fn freeBlock(allocator: std.mem.Allocator, block: *types.SessionBlock) void {
    allocator.free(block.id);
    if (!block.is_gap) {
        allocator.free(block.models);
    }
}

/// Returns a new slice containing only blocks where is_active is true.
/// Caller owns the returned slice (but not the block contents, which are borrowed).
pub fn filterActive(allocator: std.mem.Allocator, blocks_slice: []const types.SessionBlock) ![]const types.SessionBlock {
    var list: std.ArrayList(types.SessionBlock) = .{};
    errdefer list.deinit(allocator);

    for (blocks_slice) |block| {
        if (block.is_active) {
            try list.append(allocator, block);
        }
    }

    return try list.toOwnedSlice(allocator);
}

/// Returns a new slice containing blocks that started within the last `days` days,
/// or that are currently active.
/// Caller owns the returned slice (but not the block contents, which are borrowed).
pub fn filterRecent(allocator: std.mem.Allocator, blocks_slice: []const types.SessionBlock, now_ms: i64, days: u32) ![]const types.SessionBlock {
    const cutoff = now_ms - @as(i64, days) * 24 * 60 * 60 * 1000;

    var list: std.ArrayList(types.SessionBlock) = .{};
    errdefer list.deinit(allocator);

    for (blocks_slice) |block| {
        if (block.start_time >= cutoff or block.is_active) {
            try list.append(allocator, block);
        }
    }

    return try list.toOwnedSlice(allocator);
}

/// Free a slice of SessionBlocks and all their internal allocations.
pub fn freeBlocks(allocator: std.mem.Allocator, blocks: []types.SessionBlock) void {
    for (blocks) |*block| freeBlock(allocator, block);
    allocator.free(blocks);
}

// --- Internal types ---

const BlockGroup = struct {
    block_start: i64, // floored to hour
    session_duration_ms: i64,
    first_timestamp: i64,
    last_timestamp: i64,
    entry_count: u32,
    input_tokens: u64,
    output_tokens: u64,
    cache_creation_tokens: u64,
    cache_read_tokens: u64,
    cost_usd: f64,
    models: std.ArrayList([]const u8),

    fn init(first_entry_timestamp: i64, session_duration_ms: i64) BlockGroup {
        // Floor to nearest UTC hour
        const hour_ms: i64 = 3600000;
        const block_start = first_entry_timestamp - @mod(first_entry_timestamp, hour_ms);

        return .{
            .block_start = block_start,
            .session_duration_ms = session_duration_ms,
            .first_timestamp = first_entry_timestamp,
            .last_timestamp = first_entry_timestamp,
            .entry_count = 0,
            .input_tokens = 0,
            .output_tokens = 0,
            .cache_creation_tokens = 0,
            .cache_read_tokens = 0,
            .cost_usd = 0.0,
            .models = .{},
        };
    }

    fn deinit(self: *BlockGroup, allocator: std.mem.Allocator) void {
        self.models.deinit(allocator);
    }

    fn addEntry(self: *BlockGroup, allocator: std.mem.Allocator, entry: types.UsageEntry) void {
        self.entry_count += 1;
        self.input_tokens += entry.input_tokens;
        self.output_tokens += entry.output_tokens;
        self.cache_creation_tokens += entry.cache_creation_tokens;
        self.cache_read_tokens += entry.cache_read_tokens;
        self.cost_usd += entry.cost_usd;
        if (entry.timestamp > self.last_timestamp) {
            self.last_timestamp = entry.timestamp;
        }
        if (entry.timestamp < self.first_timestamp) {
            self.first_timestamp = entry.timestamp;
        }

        // Track unique models (linear scan - blocks typically have few models)
        var found = false;
        for (self.models.items) |m| {
            if (std.mem.eql(u8, m, entry.model)) {
                found = true;
                break;
            }
        }
        if (!found) {
            self.models.append(allocator, entry.model) catch {};
        }
    }
};

fn buildSessionBlock(
    allocator: std.mem.Allocator,
    bg: *const BlockGroup,
    session_duration_ms: i64,
    now_ms: i64,
) !types.SessionBlock {
    const end_time = bg.block_start + session_duration_ms;

    // Format block start as ISO 8601 for the id
    const id_buf = date.formatIso8601Output(bg.block_start);
    const id = try allocator.alloc(u8, 24);
    @memcpy(id, &id_buf);

    // Copy unique model names
    const models = try allocator.alloc([]const u8, bg.models.items.len);
    @memcpy(models, bg.models.items);

    // Active detection
    const is_active = now_ms < end_time and (now_ms - bg.last_timestamp) < session_duration_ms;

    // Burn rate calculation
    const duration_minutes = @as(f64, @floatFromInt(bg.last_timestamp - bg.block_start)) / 60000.0;
    const total_tokens = bg.input_tokens + bg.output_tokens + bg.cache_creation_tokens + bg.cache_read_tokens;

    var burn_rate: ?types.BurnRate = null;
    if (duration_minutes > 0) {
        const tokens_per_minute = @as(f64, @floatFromInt(total_tokens)) / duration_minutes;
        const cost_per_hour = (bg.cost_usd / duration_minutes) * 60.0;
        burn_rate = .{
            .tokens_per_minute = tokens_per_minute,
            .cost_per_hour = cost_per_hour,
        };
    }

    // Projection for active blocks with burn rate
    var projection: ?types.Projection = null;
    if (is_active) {
        if (burn_rate) |br| {
            const remaining_minutes = @as(f64, @floatFromInt(end_time - now_ms)) / 60000.0;
            const projected_tokens_f = @as(f64, @floatFromInt(total_tokens)) + br.tokens_per_minute * remaining_minutes;
            const projected_cost = bg.cost_usd + (br.cost_per_hour / 60.0) * remaining_minutes;
            projection = .{
                .total_tokens = @intFromFloat(projected_tokens_f),
                .total_cost = projected_cost,
                .remaining_minutes = remaining_minutes,
            };
        }
    }

    return .{
        .id = id,
        .start_time = bg.block_start,
        .end_time = end_time,
        .actual_end_time = bg.last_timestamp,
        .is_active = is_active,
        .is_gap = false,
        .entry_count = bg.entry_count,
        .input_tokens = bg.input_tokens,
        .output_tokens = bg.output_tokens,
        .cache_creation_tokens = bg.cache_creation_tokens,
        .cache_read_tokens = bg.cache_read_tokens,
        .cost_usd = bg.cost_usd,
        .models = models,
        .burn_rate = burn_rate,
        .projection = projection,
    };
}

fn makeGapBlock(allocator: std.mem.Allocator, start: i64, end: i64) !types.SessionBlock {
    const id_buf = date.formatIso8601Output(start);
    const id = try allocator.alloc(u8, 24);
    @memcpy(id, &id_buf);

    return .{
        .id = id,
        .start_time = start,
        .end_time = end,
        .actual_end_time = null,
        .is_active = false,
        .is_gap = true,
        .entry_count = 0,
        .input_tokens = 0,
        .output_tokens = 0,
        .cache_creation_tokens = 0,
        .cache_read_tokens = 0,
        .cost_usd = 0.0,
        .models = &[_][]const u8{},
        .burn_rate = null,
        .projection = null,
    };
}

// =============================================================================
// Test helpers
// =============================================================================

fn makeTestEntry(timestamp: i64, input_tokens: u64, output_tokens: u64, cost_usd: f64, model: []const u8) types.UsageEntry {
    return .{
        .session_id = "test-session",
        .project = "/tmp/test",
        .timestamp = timestamp,
        .model = model,
        .input_tokens = input_tokens,
        .output_tokens = output_tokens,
        .cache_creation_tokens = 0,
        .cache_read_tokens = 0,
        .cost_usd = cost_usd,
        .message_id = "msg-1",
        .request_id = "req-1",
    };
}

/// Convert hour:minute on 2025-01-15 to epoch ms (UTC).
fn hhmm(hour: u8, minute: u8) i64 {
    // 2025-01-15T00:00:00.000Z = 1736899200000
    const base: i64 = 1736899200000;
    return base + @as(i64, hour) * 3600000 + @as(i64, minute) * 60000;
}

// =============================================================================
// Tests
// =============================================================================

test "basic block creation - all entries within window" {
    const allocator = std.testing.allocator;
    const entries = [_]types.UsageEntry{
        makeTestEntry(hhmm(10, 0), 100, 200, 0.10, "claude-opus-4"),
        makeTestEntry(hhmm(10, 30), 150, 250, 0.15, "claude-opus-4"),
        makeTestEntry(hhmm(11, 0), 200, 300, 0.20, "claude-opus-4"),
    };

    const blocks = try identifyBlocks(allocator, &entries, 5, hhmm(11, 30));
    defer freeBlocks(allocator, blocks);

    try std.testing.expectEqual(@as(usize, 1), blocks.len);
    try std.testing.expectEqual(@as(u32, 3), blocks[0].entry_count);
    try std.testing.expectEqual(hhmm(10, 0), blocks[0].start_time); // floored to 10:00
    try std.testing.expectEqual(hhmm(10, 0) + 5 * 3600000, blocks[0].end_time); // 15:00
    try std.testing.expectEqual(false, blocks[0].is_gap);
    try std.testing.expectEqual(@as(u64, 450), blocks[0].input_tokens);
    try std.testing.expectEqual(@as(u64, 750), blocks[0].output_tokens);
    try std.testing.expectApproxEqAbs(@as(f64, 0.45), blocks[0].cost_usd, 0.001);
}

test "block boundary crossing - new block after session duration" {
    const allocator = std.testing.allocator;
    const entries = [_]types.UsageEntry{
        makeTestEntry(hhmm(10, 0), 100, 100, 0.10, "claude-opus-4"),
        makeTestEntry(hhmm(12, 0), 100, 100, 0.10, "claude-opus-4"),
        makeTestEntry(hhmm(16, 0), 100, 100, 0.10, "claude-opus-4"), // 6h after block start
    };

    const blocks = try identifyBlocks(allocator, &entries, 5, hhmm(17, 0));
    defer freeBlocks(allocator, blocks);

    // Should have 2 data blocks + possible gap
    var data_blocks: u32 = 0;
    for (blocks) |b| {
        if (!b.is_gap) data_blocks += 1;
    }
    try std.testing.expectEqual(@as(u32, 2), data_blocks);
    // First block: entries at 10:00 and 12:00
    try std.testing.expectEqual(@as(u32, 2), blocks[0].entry_count);
    // Last data block: entry at 16:00
    try std.testing.expectEqual(@as(u32, 1), blocks[blocks.len - 1].entry_count);
}

test "gap detection - large time gap" {
    const allocator = std.testing.allocator;
    const entries = [_]types.UsageEntry{
        makeTestEntry(hhmm(10, 0), 100, 100, 0.10, "claude-opus-4"),
        makeTestEntry(hhmm(20, 0), 100, 100, 0.10, "claude-opus-4"), // 10h gap
    };

    const blocks = try identifyBlocks(allocator, &entries, 5, hhmm(21, 0));
    defer freeBlocks(allocator, blocks);

    // block, gap, block = 3
    try std.testing.expectEqual(@as(usize, 3), blocks.len);
    try std.testing.expectEqual(false, blocks[0].is_gap);
    try std.testing.expectEqual(true, blocks[1].is_gap);
    try std.testing.expectEqual(false, blocks[2].is_gap);

    // Gap has zero entries and tokens
    try std.testing.expectEqual(@as(u32, 0), blocks[1].entry_count);
    try std.testing.expectEqual(@as(u64, 0), blocks[1].totalTokens());
    try std.testing.expectApproxEqAbs(@as(f64, 0.0), blocks[1].cost_usd, 0.001);
    try std.testing.expectEqual(@as(?i64, null), blocks[1].actual_end_time);

    // Gap starts at first block's end_time and ends at second block's start_time
    try std.testing.expectEqual(blocks[0].end_time, blocks[1].start_time);
    try std.testing.expectEqual(blocks[2].start_time, blocks[1].end_time);
}

test "burn rate calculation" {
    const allocator = std.testing.allocator;
    // Block from 10:00 to 10:30 (30 min), 3000 total tokens, $0.30 cost
    const entries = [_]types.UsageEntry{
        makeTestEntry(hhmm(10, 0), 1000, 500, 0.10, "claude-opus-4"),
        makeTestEntry(hhmm(10, 15), 500, 500, 0.10, "claude-opus-4"),
        makeTestEntry(hhmm(10, 30), 300, 200, 0.10, "claude-opus-4"),
    };

    const blocks = try identifyBlocks(allocator, &entries, 5, hhmm(8, 0)); // now is before block, not active
    defer freeBlocks(allocator, blocks);

    try std.testing.expectEqual(@as(usize, 1), blocks.len);
    const br = blocks[0].burn_rate orelse return error.TestUnexpectedResult;
    // duration_minutes = (10:30 - 10:00) / 60000 = 30
    // total_tokens = 1000+500+500+500+300+200 = 3000
    // tokens_per_minute = 3000 / 30 = 100
    try std.testing.expectApproxEqAbs(@as(f64, 100.0), br.tokens_per_minute, 0.1);
    // cost_per_hour = (0.30 / 30) * 60 = 0.60
    try std.testing.expectApproxEqAbs(@as(f64, 0.60), br.cost_per_hour, 0.01);
}

test "active block detection - within window" {
    const allocator = std.testing.allocator;
    // Block ends at 15:00, last activity at 14:30, now = 14:45
    const entries = [_]types.UsageEntry{
        makeTestEntry(hhmm(10, 0), 100, 100, 0.10, "claude-opus-4"),
        makeTestEntry(hhmm(14, 30), 100, 100, 0.10, "claude-opus-4"),
    };

    const blocks_active = try identifyBlocks(allocator, &entries, 5, hhmm(14, 45));
    defer freeBlocks(allocator, blocks_active);
    try std.testing.expectEqual(@as(usize, 1), blocks_active.len);
    try std.testing.expectEqual(true, blocks_active[0].is_active);
}

test "active block detection - past window" {
    const allocator = std.testing.allocator;
    // Same block but now = 15:30 (past end_time)
    const entries = [_]types.UsageEntry{
        makeTestEntry(hhmm(10, 0), 100, 100, 0.10, "claude-opus-4"),
        makeTestEntry(hhmm(14, 30), 100, 100, 0.10, "claude-opus-4"),
    };

    const blocks_past = try identifyBlocks(allocator, &entries, 5, hhmm(15, 30));
    defer freeBlocks(allocator, blocks_past);
    try std.testing.expectEqual(@as(usize, 1), blocks_past.len);
    try std.testing.expectEqual(false, blocks_past[0].is_active);
}

test "projection for active block" {
    const allocator = std.testing.allocator;
    // Block from 10:00 with 5h duration (ends 15:00)
    // Entries at 10:00 and 10:30, now = 14:30 (30 min remaining)
    // total_tokens = 600, duration = 30 min -> 20 tokens/min
    // cost = 0.30, cost_per_hour = 0.60 -> cost_per_min = 0.01
    const entries = [_]types.UsageEntry{
        makeTestEntry(hhmm(10, 0), 100, 200, 0.15, "claude-opus-4"),
        makeTestEntry(hhmm(10, 30), 100, 200, 0.15, "claude-opus-4"),
    };

    const blocks = try identifyBlocks(allocator, &entries, 5, hhmm(14, 30));
    defer freeBlocks(allocator, blocks);

    try std.testing.expectEqual(@as(usize, 1), blocks.len);
    try std.testing.expectEqual(true, blocks[0].is_active);

    const proj = blocks[0].projection orelse return error.TestUnexpectedResult;
    // remaining_minutes = (15:00 - 14:30) / 60000 = 30
    try std.testing.expectApproxEqAbs(@as(f64, 30.0), proj.remaining_minutes, 0.1);
    // projected_tokens = 600 + 20 * 30 = 1200
    try std.testing.expectEqual(@as(u64, 1200), proj.total_tokens);
    // projected_cost = 0.30 + (0.60/60) * 30 = 0.30 + 0.30 = 0.60
    try std.testing.expectApproxEqAbs(@as(f64, 0.60), proj.total_cost, 0.01);
}

test "empty input returns empty result" {
    const allocator = std.testing.allocator;
    const entries = [_]types.UsageEntry{};

    const blocks = try identifyBlocks(allocator, &entries, 5, hhmm(12, 0));
    // Empty slice from comptime literal, nothing to free
    try std.testing.expectEqual(@as(usize, 0), blocks.len);
}

test "single entry - one block with null burn rate" {
    const allocator = std.testing.allocator;
    const entries = [_]types.UsageEntry{
        makeTestEntry(hhmm(10, 0), 500, 500, 0.50, "claude-opus-4"),
    };

    const blocks = try identifyBlocks(allocator, &entries, 5, hhmm(8, 0)); // not active
    defer freeBlocks(allocator, blocks);

    try std.testing.expectEqual(@as(usize, 1), blocks.len);
    try std.testing.expectEqual(@as(u32, 1), blocks[0].entry_count);
    // duration is 0 (single entry at block start), burn_rate should be null
    try std.testing.expectEqual(@as(?types.BurnRate, null), blocks[0].burn_rate);
    try std.testing.expectEqual(@as(?types.Projection, null), blocks[0].projection);
}

test "unique models are tracked" {
    const allocator = std.testing.allocator;
    const entries = [_]types.UsageEntry{
        makeTestEntry(hhmm(10, 0), 100, 100, 0.10, "claude-opus-4"),
        makeTestEntry(hhmm(10, 15), 100, 100, 0.10, "claude-sonnet-4"),
        makeTestEntry(hhmm(10, 30), 100, 100, 0.10, "claude-opus-4"), // duplicate
    };

    const blocks = try identifyBlocks(allocator, &entries, 5, hhmm(8, 0));
    defer freeBlocks(allocator, blocks);

    try std.testing.expectEqual(@as(usize, 1), blocks.len);
    try std.testing.expectEqual(@as(usize, 2), blocks[0].models.len);
}

test "block id is ISO 8601 formatted start time" {
    const allocator = std.testing.allocator;
    const entries = [_]types.UsageEntry{
        makeTestEntry(hhmm(10, 15), 100, 100, 0.10, "claude-opus-4"),
    };

    const blocks = try identifyBlocks(allocator, &entries, 5, hhmm(8, 0));
    defer freeBlocks(allocator, blocks);

    // Start time is floored to 10:00
    const expected_id = date.formatIso8601Output(hhmm(10, 0));
    try std.testing.expectEqualStrings(&expected_id, blocks[0].id);
}

test "gap block has null burn rate and projection" {
    const allocator = std.testing.allocator;
    const entries = [_]types.UsageEntry{
        makeTestEntry(hhmm(2, 0), 100, 100, 0.10, "claude-opus-4"),
        makeTestEntry(hhmm(20, 0), 100, 100, 0.10, "claude-opus-4"),
    };

    const blocks = try identifyBlocks(allocator, &entries, 5, hhmm(21, 0));
    defer freeBlocks(allocator, blocks);

    // Find the gap block
    var gap_found = false;
    for (blocks) |b| {
        if (b.is_gap) {
            gap_found = true;
            try std.testing.expectEqual(@as(?types.BurnRate, null), b.burn_rate);
            try std.testing.expectEqual(@as(?types.Projection, null), b.projection);
            try std.testing.expectEqual(@as(usize, 0), b.models.len);
        }
    }
    try std.testing.expect(gap_found);
}

test "filterActive - returns only active blocks" {
    const allocator = std.testing.allocator;

    // 3 blocks: 1 active, 2 inactive
    const blocks_input = [_]types.SessionBlock{
        .{
            .id = "block-1",
            .start_time = hhmm(2, 0),
            .end_time = hhmm(7, 0),
            .actual_end_time = hhmm(3, 0),
            .is_active = false,
            .is_gap = false,
            .entry_count = 1,
            .input_tokens = 100,
            .output_tokens = 50,
            .cache_creation_tokens = 0,
            .cache_read_tokens = 0,
            .cost_usd = 0.10,
            .models = &.{},
            .burn_rate = null,
            .projection = null,
        },
        .{
            .id = "block-2",
            .start_time = hhmm(10, 0),
            .end_time = hhmm(15, 0),
            .actual_end_time = hhmm(12, 0),
            .is_active = true,
            .is_gap = false,
            .entry_count = 3,
            .input_tokens = 500,
            .output_tokens = 200,
            .cache_creation_tokens = 0,
            .cache_read_tokens = 0,
            .cost_usd = 0.50,
            .models = &.{},
            .burn_rate = null,
            .projection = null,
        },
        .{
            .id = "block-3",
            .start_time = hhmm(18, 0),
            .end_time = hhmm(23, 0),
            .actual_end_time = hhmm(20, 0),
            .is_active = false,
            .is_gap = false,
            .entry_count = 2,
            .input_tokens = 200,
            .output_tokens = 100,
            .cache_creation_tokens = 0,
            .cache_read_tokens = 0,
            .cost_usd = 0.20,
            .models = &.{},
            .burn_rate = null,
            .projection = null,
        },
    };

    const result = try filterActive(allocator, &blocks_input);
    defer allocator.free(result);

    try std.testing.expectEqual(@as(usize, 1), result.len);
    try std.testing.expectEqualStrings("block-2", result[0].id);
    try std.testing.expectEqual(true, result[0].is_active);
}

test "filterActive - no active blocks returns empty" {
    const allocator = std.testing.allocator;

    const blocks_input = [_]types.SessionBlock{
        .{
            .id = "block-1",
            .start_time = hhmm(2, 0),
            .end_time = hhmm(7, 0),
            .actual_end_time = hhmm(3, 0),
            .is_active = false,
            .is_gap = false,
            .entry_count = 1,
            .input_tokens = 100,
            .output_tokens = 50,
            .cache_creation_tokens = 0,
            .cache_read_tokens = 0,
            .cost_usd = 0.10,
            .models = &.{},
            .burn_rate = null,
            .projection = null,
        },
        .{
            .id = "block-2",
            .start_time = hhmm(10, 0),
            .end_time = hhmm(15, 0),
            .actual_end_time = hhmm(12, 0),
            .is_active = false,
            .is_gap = false,
            .entry_count = 2,
            .input_tokens = 200,
            .output_tokens = 100,
            .cache_creation_tokens = 0,
            .cache_read_tokens = 0,
            .cost_usd = 0.20,
            .models = &.{},
            .burn_rate = null,
            .projection = null,
        },
    };

    const result = try filterActive(allocator, &blocks_input);
    defer allocator.free(result);

    try std.testing.expectEqual(@as(usize, 0), result.len);
}

test "filterRecent - keeps recent and active blocks" {
    const allocator = std.testing.allocator;

    // "now" is 2025-01-15T12:00, 3-day cutoff means 2025-01-12T12:00
    const now = hhmm(12, 0); // 2025-01-15T12:00
    const day_ms: i64 = 24 * 60 * 60 * 1000;

    const blocks_input = [_]types.SessionBlock{
        // 7 days ago - should be filtered out (inactive + old)
        .{
            .id = "old-block",
            .start_time = now - 7 * day_ms,
            .end_time = now - 7 * day_ms + 5 * 3600000,
            .actual_end_time = now - 7 * day_ms + 3600000,
            .is_active = false,
            .is_gap = false,
            .entry_count = 1,
            .input_tokens = 100,
            .output_tokens = 50,
            .cache_creation_tokens = 0,
            .cache_read_tokens = 0,
            .cost_usd = 0.10,
            .models = &.{},
            .burn_rate = null,
            .projection = null,
        },
        // 5 days ago, but active - should be kept
        .{
            .id = "old-active-block",
            .start_time = now - 5 * day_ms,
            .end_time = now - 5 * day_ms + 5 * 3600000,
            .actual_end_time = now - 5 * day_ms + 3600000,
            .is_active = true,
            .is_gap = false,
            .entry_count = 2,
            .input_tokens = 200,
            .output_tokens = 100,
            .cache_creation_tokens = 0,
            .cache_read_tokens = 0,
            .cost_usd = 0.20,
            .models = &.{},
            .burn_rate = null,
            .projection = null,
        },
        // 2 days ago - recent, should be kept
        .{
            .id = "recent-block",
            .start_time = now - 2 * day_ms,
            .end_time = now - 2 * day_ms + 5 * 3600000,
            .actual_end_time = now - 2 * day_ms + 3600000,
            .is_active = false,
            .is_gap = false,
            .entry_count = 3,
            .input_tokens = 300,
            .output_tokens = 150,
            .cache_creation_tokens = 0,
            .cache_read_tokens = 0,
            .cost_usd = 0.30,
            .models = &.{},
            .burn_rate = null,
            .projection = null,
        },
        // 1 day ago - recent, should be kept
        .{
            .id = "yesterday-block",
            .start_time = now - 1 * day_ms,
            .end_time = now - 1 * day_ms + 5 * 3600000,
            .actual_end_time = now - 1 * day_ms + 3600000,
            .is_active = false,
            .is_gap = false,
            .entry_count = 4,
            .input_tokens = 400,
            .output_tokens = 200,
            .cache_creation_tokens = 0,
            .cache_read_tokens = 0,
            .cost_usd = 0.40,
            .models = &.{},
            .burn_rate = null,
            .projection = null,
        },
    };

    const result = try filterRecent(allocator, &blocks_input, now, 3);
    defer allocator.free(result);

    // Should keep: old-active-block (active), recent-block (2d ago), yesterday-block (1d ago)
    // Should drop: old-block (7d ago, inactive)
    try std.testing.expectEqual(@as(usize, 3), result.len);

    // Verify correct blocks are present (order preserved from input)
    try std.testing.expectEqualStrings("old-active-block", result[0].id);
    try std.testing.expectEqualStrings("recent-block", result[1].id);
    try std.testing.expectEqualStrings("yesterday-block", result[2].id);
}
