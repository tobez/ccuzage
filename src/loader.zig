// ABOUTME: Loads JSONL lines and deduplicates entries using parser module.
// ABOUTME: Provides loadEntriesFromLines to build a deduplicated slice of UsageEntry structs.
const std = @import("std");
const types = @import("types.zig");
const parser = @import("parser.zig");

pub fn loadEntriesFromLines(
    allocator: std.mem.Allocator,
    lines: []const []const u8,
    session_id: []const u8,
    project: []const u8,
) ![]types.UsageEntry {
    var result: std.ArrayList(types.UsageEntry) = .{};
    errdefer {
        for (result.items) |e| {
            allocator.free(e.model);
            allocator.free(e.message_id);
            allocator.free(e.request_id);
        }
        result.deinit(allocator);
    }

    var seen = std.StringHashMap(void).init(allocator);
    defer {
        var it = seen.keyIterator();
        while (it.next()) |key| {
            allocator.free(key.*);
        }
        seen.deinit();
    }

    for (lines) |line| {
        const entry = parser.parseLine(allocator, line, session_id, project) orelse continue;

        if (parser.dedupKey(allocator, entry.message_id, entry.request_id)) |key| {
            const gop = try seen.getOrPut(key);
            if (gop.found_existing) {
                // Duplicate — free the key and the entry's owned strings
                allocator.free(key);
                allocator.free(entry.model);
                allocator.free(entry.message_id);
                allocator.free(entry.request_id);
                continue;
            }
            // First time seeing this key — it's now owned by the map
        }

        try result.append(allocator, entry);
    }

    return result.toOwnedSlice(allocator);
}

// =============================================================================
// Tests
// =============================================================================

fn freeEntries(allocator: std.mem.Allocator, entries: []types.UsageEntry) void {
    for (entries) |e| {
        allocator.free(e.model);
        allocator.free(e.message_id);
        allocator.free(e.request_id);
    }
    allocator.free(entries);
}

test "loadEntriesFromLines - no duplicates returns all entries" {
    const line1 =
        \\{"timestamp":"2025-01-15T10:00:00.000Z","message":{"usage":{"input_tokens":100,"output_tokens":50},"model":"claude-sonnet-4-20250514","id":"msg-001"},"costUSD":0.01,"requestId":"req-001"}
    ;
    const line2 =
        \\{"timestamp":"2025-01-15T11:00:00.000Z","message":{"usage":{"input_tokens":200,"output_tokens":100},"model":"claude-sonnet-4-20250514","id":"msg-002"},"costUSD":0.02,"requestId":"req-002"}
    ;
    const line3 =
        \\{"timestamp":"2025-01-15T12:00:00.000Z","message":{"usage":{"input_tokens":300,"output_tokens":150},"model":"claude-sonnet-4-20250514","id":"msg-003"},"costUSD":0.03,"requestId":"req-003"}
    ;

    const lines = &[_][]const u8{ line1, line2, line3 };
    const entries = try loadEntriesFromLines(std.testing.allocator, lines, "sess-1", "/proj");
    defer freeEntries(std.testing.allocator, entries);

    try std.testing.expectEqual(@as(usize, 3), entries.len);
}

test "loadEntriesFromLines - duplicates are removed" {
    const line1 =
        \\{"timestamp":"2025-01-15T10:00:00.000Z","message":{"usage":{"input_tokens":100,"output_tokens":50},"model":"claude-sonnet-4-20250514","id":"msg-001"},"costUSD":0.01,"requestId":"req-001"}
    ;
    const line1_dup =
        \\{"timestamp":"2025-01-15T10:05:00.000Z","message":{"usage":{"input_tokens":100,"output_tokens":50},"model":"claude-sonnet-4-20250514","id":"msg-001"},"costUSD":0.01,"requestId":"req-001"}
    ;

    const lines = &[_][]const u8{ line1, line1_dup };
    const entries = try loadEntriesFromLines(std.testing.allocator, lines, "sess-1", "/proj");
    defer freeEntries(std.testing.allocator, entries);

    try std.testing.expectEqual(@as(usize, 1), entries.len);
    try std.testing.expectEqualStrings("msg-001", entries[0].message_id);
}

test "loadEntriesFromLines - mixed duplicates and unique" {
    const line1 =
        \\{"timestamp":"2025-01-15T10:00:00.000Z","message":{"usage":{"input_tokens":100,"output_tokens":50},"model":"claude-sonnet-4-20250514","id":"msg-001"},"costUSD":0.01,"requestId":"req-001"}
    ;
    const line2 =
        \\{"timestamp":"2025-01-15T11:00:00.000Z","message":{"usage":{"input_tokens":200,"output_tokens":100},"model":"claude-sonnet-4-20250514","id":"msg-002"},"costUSD":0.02,"requestId":"req-002"}
    ;
    const line1_dup =
        \\{"timestamp":"2025-01-15T10:05:00.000Z","message":{"usage":{"input_tokens":100,"output_tokens":50},"model":"claude-sonnet-4-20250514","id":"msg-001"},"costUSD":0.01,"requestId":"req-001"}
    ;

    const lines = &[_][]const u8{ line1, line2, line1_dup };
    const entries = try loadEntriesFromLines(std.testing.allocator, lines, "sess-1", "/proj");
    defer freeEntries(std.testing.allocator, entries);

    try std.testing.expectEqual(@as(usize, 2), entries.len);
}

test "loadEntriesFromLines - entries without dedup key are always included" {
    // Lines without message_id -> empty message_id -> no dedup key -> always included
    const line_no_id1 =
        \\{"timestamp":"2025-01-15T10:00:00.000Z","message":{"usage":{"input_tokens":100,"output_tokens":50},"model":"claude-sonnet-4-20250514"},"costUSD":0.01,"requestId":"req-001"}
    ;
    const line_no_id2 =
        \\{"timestamp":"2025-01-15T11:00:00.000Z","message":{"usage":{"input_tokens":200,"output_tokens":100},"model":"claude-sonnet-4-20250514"},"costUSD":0.02,"requestId":"req-001"}
    ;

    const lines = &[_][]const u8{ line_no_id1, line_no_id2 };
    const entries = try loadEntriesFromLines(std.testing.allocator, lines, "sess-1", "/proj");
    defer freeEntries(std.testing.allocator, entries);

    // Both should be included even though they share request_id, because message_id is empty
    try std.testing.expectEqual(@as(usize, 2), entries.len);
}

test "loadEntriesFromLines - invalid lines are skipped" {
    const valid_line =
        \\{"timestamp":"2025-01-15T10:00:00.000Z","message":{"usage":{"input_tokens":100,"output_tokens":50},"model":"claude-sonnet-4-20250514","id":"msg-001"},"costUSD":0.01,"requestId":"req-001"}
    ;
    const invalid_line = "not valid json {{{";
    const another_valid =
        \\{"timestamp":"2025-01-15T11:00:00.000Z","message":{"usage":{"input_tokens":200,"output_tokens":100},"model":"claude-sonnet-4-20250514","id":"msg-002"},"costUSD":0.02,"requestId":"req-002"}
    ;

    const lines = &[_][]const u8{ valid_line, invalid_line, another_valid };
    const entries = try loadEntriesFromLines(std.testing.allocator, lines, "sess-1", "/proj");
    defer freeEntries(std.testing.allocator, entries);

    try std.testing.expectEqual(@as(usize, 2), entries.len);
}

test "loadEntriesFromLines - empty input returns empty result" {
    const lines = &[_][]const u8{};
    const entries = try loadEntriesFromLines(std.testing.allocator, lines, "sess-1", "/proj");
    defer freeEntries(std.testing.allocator, entries);

    try std.testing.expectEqual(@as(usize, 0), entries.len);
}
