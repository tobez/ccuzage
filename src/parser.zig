// ABOUTME: Parses individual JSONL lines from Claude Code usage logs into UsageEntry structs.
// ABOUTME: Handles field extraction, default values, error skipping, and dedup key generation.
const std = @import("std");
const types = @import("types.zig");
const date = @import("date.zig");

const JsonUsage = struct {
    input_tokens: ?u64 = null,
    output_tokens: ?u64 = null,
    cache_creation_input_tokens: ?u64 = null,
    cache_read_input_tokens: ?u64 = null,
};

const JsonMessage = struct {
    usage: ?JsonUsage = null,
    model: ?[]const u8 = null,
    id: ?[]const u8 = null,
};

const JsonLine = struct {
    timestamp: ?[]const u8 = null,
    message: ?JsonMessage = null,
    costUSD: ?f64 = null,
    requestId: ?[]const u8 = null,
    isApiErrorMessage: ?bool = null,
};

pub fn parseLine(
    allocator: std.mem.Allocator,
    line: []const u8,
    session_id: []const u8,
    project: []const u8,
) ?types.UsageEntry {
    if (line.len == 0) return null;

    const parsed = std.json.parseFromSlice(JsonLine, allocator, line, .{
        .ignore_unknown_fields = true,
    }) catch return null;
    defer parsed.deinit();

    const json = parsed.value;

    // Skip API error messages
    if (json.isApiErrorMessage) |is_err| {
        if (is_err) return null;
    }

    // Required: timestamp
    const timestamp_str = json.timestamp orelse return null;
    const timestamp = date.parseIso8601(timestamp_str) catch return null;

    // Required: message
    const message = json.message orelse return null;

    // Required: message.usage
    const usage = message.usage orelse return null;

    // Required: message.model
    const model_raw = message.model orelse return null;

    // Duplicate strings that need to outlive the parsed JSON
    const model = allocator.dupe(u8, model_raw) catch return null;

    const message_id = if (message.id) |id|
        (allocator.dupe(u8, id) catch {
            allocator.free(model);
            return null;
        })
    else
        allocator.dupe(u8, "") catch {
            allocator.free(model);
            return null;
        };

    const request_id = if (json.requestId) |rid|
        (allocator.dupe(u8, rid) catch {
            allocator.free(model);
            allocator.free(message_id);
            return null;
        })
    else
        allocator.dupe(u8, "") catch {
            allocator.free(model);
            allocator.free(message_id);
            return null;
        };

    return types.UsageEntry{
        .session_id = session_id,
        .project = project,
        .timestamp = timestamp,
        .model = model,
        .input_tokens = usage.input_tokens orelse 0,
        .output_tokens = usage.output_tokens orelse 0,
        .cache_creation_tokens = usage.cache_creation_input_tokens orelse 0,
        .cache_read_tokens = usage.cache_read_input_tokens orelse 0,
        .cost_usd = json.costUSD orelse 0.0,
        .message_id = message_id,
        .request_id = request_id,
    };
}

pub fn dedupKey(
    allocator: std.mem.Allocator,
    message_id: []const u8,
    request_id: []const u8,
) ?[]const u8 {
    if (message_id.len == 0 or request_id.len == 0) return null;

    const result = allocator.alloc(u8, message_id.len + 1 + request_id.len) catch return null;
    @memcpy(result[0..message_id.len], message_id);
    result[message_id.len] = ':';
    @memcpy(result[message_id.len + 1 ..], request_id);
    return result;
}

// =============================================================================
// Tests
// =============================================================================

test "parseLine - valid complete line returns populated UsageEntry" {
    const line =
        \\{"timestamp":"2025-01-15T10:30:00.000Z","message":{"usage":{"input_tokens":1000,"output_tokens":50,"cache_creation_input_tokens":100,"cache_read_input_tokens":500},"model":"claude-sonnet-4-20250514","id":"msg-001"},"costUSD":0.05,"requestId":"req-001"}
    ;
    const entry = parseLine(std.testing.allocator, line, "sess-abc", "/tmp/project");
    try std.testing.expect(entry != null);
    const e = entry.?;
    defer {
        std.testing.allocator.free(e.model);
        std.testing.allocator.free(e.message_id);
        std.testing.allocator.free(e.request_id);
    }

    try std.testing.expectEqualStrings("sess-abc", e.session_id);
    try std.testing.expectEqualStrings("/tmp/project", e.project);
    try std.testing.expectEqual(@as(i64, 1736937000000), e.timestamp);
    try std.testing.expectEqualStrings("claude-sonnet-4-20250514", e.model);
    try std.testing.expectEqual(@as(u64, 1000), e.input_tokens);
    try std.testing.expectEqual(@as(u64, 50), e.output_tokens);
    try std.testing.expectEqual(@as(u64, 100), e.cache_creation_tokens);
    try std.testing.expectEqual(@as(u64, 500), e.cache_read_tokens);
    try std.testing.expectApproxEqAbs(@as(f64, 0.05), e.cost_usd, 0.001);
    try std.testing.expectEqualStrings("msg-001", e.message_id);
    try std.testing.expectEqualStrings("req-001", e.request_id);
}

test "parseLine - line without cache tokens defaults to 0" {
    const line =
        \\{"timestamp":"2025-01-15T10:30:00.000Z","message":{"usage":{"input_tokens":500,"output_tokens":200},"model":"claude-opus-4","id":"msg-002"},"costUSD":0.10,"requestId":"req-002"}
    ;
    const entry = parseLine(std.testing.allocator, line, "sess-1", "/proj");
    try std.testing.expect(entry != null);
    const e = entry.?;
    defer {
        std.testing.allocator.free(e.model);
        std.testing.allocator.free(e.message_id);
        std.testing.allocator.free(e.request_id);
    }

    try std.testing.expectEqual(@as(u64, 0), e.cache_creation_tokens);
    try std.testing.expectEqual(@as(u64, 0), e.cache_read_tokens);
    try std.testing.expectEqual(@as(u64, 500), e.input_tokens);
    try std.testing.expectEqual(@as(u64, 200), e.output_tokens);
}

test "parseLine - line without costUSD defaults to 0.0" {
    const line =
        \\{"timestamp":"2025-01-15T10:30:00.000Z","message":{"usage":{"input_tokens":100,"output_tokens":20},"model":"claude-haiku-3","id":"msg-003"},"requestId":"req-003"}
    ;
    const entry = parseLine(std.testing.allocator, line, "sess-1", "/proj");
    try std.testing.expect(entry != null);
    const e = entry.?;
    defer {
        std.testing.allocator.free(e.model);
        std.testing.allocator.free(e.message_id);
        std.testing.allocator.free(e.request_id);
    }

    try std.testing.expectApproxEqAbs(@as(f64, 0.0), e.cost_usd, 0.001);
}

test "parseLine - isApiErrorMessage true returns null" {
    const line =
        \\{"timestamp":"2025-01-15T10:30:00.000Z","message":{"usage":{"input_tokens":100,"output_tokens":20},"model":"claude-haiku-3"},"isApiErrorMessage":true}
    ;
    const entry = parseLine(std.testing.allocator, line, "sess-1", "/proj");
    try std.testing.expect(entry == null);
}

test "parseLine - missing message.usage returns null" {
    const line =
        \\{"timestamp":"2025-01-15T10:30:00.000Z","message":{"model":"claude-haiku-3"}}
    ;
    const entry = parseLine(std.testing.allocator, line, "sess-1", "/proj");
    try std.testing.expect(entry == null);
}

test "parseLine - missing message.model returns null" {
    const line =
        \\{"timestamp":"2025-01-15T10:30:00.000Z","message":{"usage":{"input_tokens":100,"output_tokens":20}}}
    ;
    const entry = parseLine(std.testing.allocator, line, "sess-1", "/proj");
    try std.testing.expect(entry == null);
}

test "parseLine - invalid JSON returns null" {
    const entry = parseLine(std.testing.allocator, "not valid json {{{", "sess-1", "/proj");
    try std.testing.expect(entry == null);
}

test "parseLine - empty line returns null" {
    const entry = parseLine(std.testing.allocator, "", "sess-1", "/proj");
    try std.testing.expect(entry == null);
}

test "dedupKey - both IDs present returns concatenated key" {
    const key = dedupKey(std.testing.allocator, "msg-001", "req-001");
    try std.testing.expect(key != null);
    defer std.testing.allocator.free(key.?);
    try std.testing.expectEqualStrings("msg-001:req-001", key.?);
}

test "dedupKey - empty message_id returns null" {
    const key = dedupKey(std.testing.allocator, "", "req-001");
    try std.testing.expect(key == null);
}

test "dedupKey - empty request_id returns null" {
    const key = dedupKey(std.testing.allocator, "msg-001", "");
    try std.testing.expect(key == null);
}

test "parseLine - isApiErrorMessage false parses normally" {
    const line =
        \\{"timestamp":"2025-01-15T10:30:00.000Z","message":{"usage":{"input_tokens":100,"output_tokens":50},"model":"claude-sonnet-4-20250514","id":"msg-001"},"requestId":"req-001","isApiErrorMessage":false}
    ;
    const entry = parseLine(std.testing.allocator, line, "sess", "proj");
    try std.testing.expect(entry != null);
    const e = entry.?;
    defer {
        std.testing.allocator.free(e.model);
        std.testing.allocator.free(e.message_id);
        std.testing.allocator.free(e.request_id);
    }
    try std.testing.expectEqual(@as(u64, 100), e.input_tokens);
}

test "parseLine - unknown fields are tolerated" {
    const line =
        \\{"timestamp":"2025-01-15T10:30:00.000Z","message":{"usage":{"input_tokens":100,"output_tokens":50},"model":"claude-sonnet-4-20250514","id":"msg-001","content":[{"text":"hello"}]},"costUSD":0.01,"requestId":"req-001","cwd":"/some/path","sessionId":"sess-from-json","version":"1.0.0","unknownField":42}
    ;
    const entry = parseLine(std.testing.allocator, line, "sess", "proj");
    try std.testing.expect(entry != null);
    const e = entry.?;
    defer {
        std.testing.allocator.free(e.model);
        std.testing.allocator.free(e.message_id);
        std.testing.allocator.free(e.request_id);
    }
    try std.testing.expectEqual(@as(u64, 100), e.input_tokens);
}
