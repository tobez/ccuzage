// ABOUTME: Shared helpers for the `ccuzage context` subcommand.
// ABOUTME: Holds the token/window percentage rounding helper and the transcript tail scan.
const std = @import("std");
const scanner = @import("scanner.zig");
const pricing = @import("pricing.zig");
const loader = @import("loader.zig");

/// Percentage of `window` used by `tokens`, rounded to nearest. Window 0 → 0.
pub fn contextPercent(tokens: u64, window: u64) u64 {
    if (window == 0) return 0;
    return (tokens * 100 + window / 2) / window;
}

/// Context window for Claude Code's 1M-context model ids (e.g. "claude-opus-5[1m]").
const million_context_marker = "[1m]";
const million_context_window: u64 = 1_000_000;

/// Context window used when a model has no known context window.
const default_context_window: u64 = 200_000;

/// Context window size for a model name: the `[1m]` marker wins, then the
/// LiteLLM dynamic pricing table, then a default.
pub fn contextWindowFor(model_name: []const u8) u64 {
    if (std.mem.indexOf(u8, model_name, million_context_marker) != null) {
        return million_context_window;
    }
    if (pricing.lookupContextWindow(model_name)) |window| {
        return window;
    }
    return default_context_window;
}

pub const LastContext = struct {
    tokens: u64,
    model: []const u8, // allocator-owned; caller frees
};

pub const ContextError = error{NoUsage};

/// Absolute path of the transcript for `session_id`, if one exists.
/// Returned path is allocator-owned; caller frees. Null when not found.
pub fn findTranscript(
    io: std.Io,
    allocator: std.mem.Allocator,
    env: *const std.process.Environ.Map,
    session_id: []const u8,
) !?[]const u8 {
    const dirs = try loader.resolveDataDirs(allocator, env.get("CLAUDE_CONFIG_DIR"), env.get("HOME"));
    defer {
        for (dirs) |d| allocator.free(d);
        allocator.free(dirs);
    }

    const filename = try std.fmt.allocPrint(allocator, "{s}.jsonl", .{session_id});
    defer allocator.free(filename);

    for (dirs) |dir_path| {
        var dir = std.Io.Dir.openDirAbsolute(io, dir_path, .{ .iterate = true }) catch continue;
        defer dir.close(io);

        var it = dir.iterate();
        while (it.next(io) catch null) |entry| {
            if (entry.kind != .directory) continue;

            const candidate = try std.fs.path.join(allocator, &.{ dir_path, entry.name, filename });
            std.Io.Dir.accessAbsolute(io, candidate, .{}) catch {
                allocator.free(candidate);
                continue;
            };

            return candidate;
        }
    }

    return null;
}

const default_chunk_size: usize = 256 * 1024;

/// Tokens and model of the last qualifying assistant turn in a transcript.
pub fn lastContextTokens(
    io: std.Io,
    allocator: std.mem.Allocator,
    path: []const u8,
) !LastContext {
    return lastContextTokensChunked(io, allocator, path, default_chunk_size);
}

/// Tail-scans `path` in `chunk_size`-byte chunks, doubling and re-reading from
/// the file when the initial chunk holds no qualifying line, until either a
/// qualifying line is found or the whole file has been read.
fn lastContextTokensChunked(
    io: std.Io,
    allocator: std.mem.Allocator,
    path: []const u8,
    chunk_size: usize,
) !LastContext {
    var file = try std.Io.Dir.openFileAbsolute(io, path, .{});
    defer file.close(io);

    const file_size = (try file.stat(io)).size;

    var size: u64 = chunk_size;
    while (true) {
        const read_size: usize = @intCast(@min(size, file_size));
        const offset = file_size - read_size;

        const buf = try allocator.alloc(u8, read_size);
        defer allocator.free(buf);

        const n = try file.readPositionalAll(io, buf, offset);
        var chunk = buf[0..n];

        // A chunk that doesn't start at the file's beginning starts mid-line;
        // drop that partial first line.
        if (offset != 0) {
            if (std.mem.indexOfScalar(u8, chunk, '\n')) |nl| {
                chunk = chunk[nl + 1 ..];
            } else {
                chunk = chunk[0..0];
            }
        }

        if (try lastQualifyingInChunk(chunk, allocator)) |result| {
            return result;
        }

        if (offset == 0) return error.NoUsage;

        size *= 2;
    }
}

/// Walks `chunk`'s lines last to first, returning the first qualifying one found.
fn lastQualifyingInChunk(chunk: []const u8, allocator: std.mem.Allocator) !?LastContext {
    var it = std.mem.splitBackwardsScalar(u8, chunk, '\n');
    while (it.next()) |line| {
        if (line.len == 0) continue;
        const entry = scanner.scanLine(line) orelse continue;
        if (entry.model == null or entry.is_api_error) continue;
        const tokens = entry.input_tokens + entry.cache_read_tokens + entry.cache_creation_tokens;
        if (tokens == 0) continue;
        return LastContext{
            .tokens = tokens,
            .model = try allocator.dupe(u8, entry.model.?),
        };
    }
    return null;
}

// =============================================================================
// Tests
// =============================================================================

test "contextPercent: exact 50 percent" {
    try std.testing.expectEqual(@as(u64, 50), contextPercent(100_000, 200_000));
}

test "contextPercent: tokens equal window returns 100" {
    try std.testing.expectEqual(@as(u64, 100), contextPercent(200_000, 200_000));
}

test "contextPercent: rounds down below the half boundary" {
    // 704 / 1000 = 70.4% -> 70
    try std.testing.expectEqual(@as(u64, 70), contextPercent(704, 1000));
}

test "contextPercent: rounds up above the half boundary" {
    // 706 / 1000 = 70.6% -> 71
    try std.testing.expectEqual(@as(u64, 71), contextPercent(706, 1000));
    // 15_000 / 200_000 = 7.5% -> 8
    try std.testing.expectEqual(@as(u64, 8), contextPercent(15_000, 200_000));
}

test "contextPercent: exact half boundary rounds up" {
    // 705 / 1000 = 70.5% -> 71
    try std.testing.expectEqual(@as(u64, 71), contextPercent(705, 1000));
}

test "contextPercent: window zero returns zero" {
    try std.testing.expectEqual(@as(u64, 0), contextPercent(1000, 0));
}

test "contextPercent: tokens zero returns zero" {
    try std.testing.expectEqual(@as(u64, 0), contextPercent(0, 200_000));
}

// =============================================================================
// lastContextTokens / lastContextTokensChunked
// =============================================================================

fn writeTranscript(tmp: *std.testing.TmpDir, sub_path: []const u8, content: []const u8) !void {
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = sub_path, .data = content });
}

test "lastContextTokensChunked: last line wins" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const line1 =
        \\{"timestamp":"2025-01-15T10:00:00.000Z","message":{"usage":{"input_tokens":1000,"output_tokens":50,"cache_creation_input_tokens":0,"cache_read_input_tokens":0},"model":"claude-sonnet-4-20250514","id":"msg-001"},"requestId":"req-001"}
    ;
    const line2 =
        \\{"timestamp":"2025-01-15T10:01:00.000Z","message":{"usage":{"input_tokens":2000,"output_tokens":80,"cache_creation_input_tokens":500,"cache_read_input_tokens":1500},"model":"claude-sonnet-4-20250514","id":"msg-002"},"requestId":"req-002"}
    ;
    const line3 =
        \\{"timestamp":"2025-01-15T10:02:00.000Z","message":{"usage":{"input_tokens":3000,"output_tokens":90,"cache_creation_input_tokens":200,"cache_read_input_tokens":800},"model":"claude-opus-4-20250514","id":"msg-003"},"requestId":"req-003"}
    ;
    const content = line1 ++ "\n" ++ line2 ++ "\n" ++ line3 ++ "\n";
    try writeTranscript(&tmp, "t.jsonl", content);

    const path = try tmp.dir.realPathFileAlloc(std.testing.io, "t.jsonl", allocator);
    defer allocator.free(path);

    const result = try lastContextTokensChunked(std.testing.io, allocator, path, 4096);
    defer allocator.free(result.model);

    try std.testing.expectEqual(@as(u64, 4000), result.tokens); // 3000 + 200 + 800
    try std.testing.expectEqualStrings("claude-opus-4-20250514", result.model);
}

test "lastContextTokensChunked: trailing synthetic error line skipped" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const line1 =
        \\{"timestamp":"2025-01-15T10:00:00.000Z","message":{"usage":{"input_tokens":1200,"output_tokens":40,"cache_creation_input_tokens":100,"cache_read_input_tokens":700},"model":"claude-sonnet-4-20250514","id":"msg-001"},"requestId":"req-001"}
    ;
    const line2 =
        \\{"timestamp":"2025-01-15T10:05:00.000Z","message":{"usage":{"input_tokens":0,"output_tokens":0,"cache_creation_input_tokens":0,"cache_read_input_tokens":0},"model":"<synthetic>"},"isApiErrorMessage":true}
    ;
    const content = line1 ++ "\n" ++ line2 ++ "\n";
    try writeTranscript(&tmp, "t.jsonl", content);

    const path = try tmp.dir.realPathFileAlloc(std.testing.io, "t.jsonl", allocator);
    defer allocator.free(path);

    const result = try lastContextTokensChunked(std.testing.io, allocator, path, 4096);
    defer allocator.free(result.model);

    try std.testing.expectEqual(@as(u64, 2000), result.tokens); // 1200 + 100 + 700
    try std.testing.expectEqualStrings("claude-sonnet-4-20250514", result.model);
}

test "lastContextTokensChunked: duplicate usage lines - last wins, no double counting" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const line_a =
        \\{"timestamp":"2025-01-15T10:00:00.000Z","message":{"usage":{"input_tokens":1000,"output_tokens":50,"cache_creation_input_tokens":200,"cache_read_input_tokens":300},"model":"claude-sonnet-4-20250514","id":"msg-001"},"requestId":"req-001"}
    ;
    const line_b =
        \\{"timestamp":"2025-01-15T10:00:01.000Z","message":{"usage":{"input_tokens":1000,"output_tokens":50,"cache_creation_input_tokens":200,"cache_read_input_tokens":300},"model":"claude-sonnet-4-20250514","id":"msg-001"},"requestId":"req-001"}
    ;
    const content = line_a ++ "\n" ++ line_b ++ "\n";
    try writeTranscript(&tmp, "t.jsonl", content);

    const path = try tmp.dir.realPathFileAlloc(std.testing.io, "t.jsonl", allocator);
    defer allocator.free(path);

    const result = try lastContextTokensChunked(std.testing.io, allocator, path, 4096);
    defer allocator.free(result.model);

    try std.testing.expectEqual(@as(u64, 1500), result.tokens); // 1000 + 200 + 300, not doubled
}

test "lastContextTokensChunked: boundary straddle drops partial first line and doubles chunk" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const line1 =
        \\{"timestamp":"2025-01-15T10:00:00.000Z","message":{"usage":{"input_tokens":900,"output_tokens":30,"cache_creation_input_tokens":100,"cache_read_input_tokens":234},"model":"claude-sonnet-4-20250514","id":"msg-001"},"requestId":"req-001"}
    ;
    const line2 =
        \\{"timestamp":"2025-01-15T10:05:00.000Z","message":{"usage":{"input_tokens":0,"output_tokens":0},"model":"<synthetic>"},"isApiErrorMessage":true}
    ;
    const content = line1 ++ "\n" ++ line2 ++ "\n";
    try writeTranscript(&tmp, "t.jsonl", content);

    const path = try tmp.dir.realPathFileAlloc(std.testing.io, "t.jsonl", allocator);
    defer allocator.free(path);

    // Small enough that the first read lands entirely inside line2, well past line1.
    const result = try lastContextTokensChunked(std.testing.io, allocator, path, 40);
    defer allocator.free(result.model);

    try std.testing.expectEqual(@as(u64, 1234), result.tokens); // 900 + 100 + 234
    try std.testing.expectEqualStrings("claude-sonnet-4-20250514", result.model);
}

test "lastContextTokensChunked: empty file returns NoUsage" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try writeTranscript(&tmp, "empty.jsonl", "");
    const path = try tmp.dir.realPathFileAlloc(std.testing.io, "empty.jsonl", allocator);
    defer allocator.free(path);

    try std.testing.expectError(error.NoUsage, lastContextTokensChunked(std.testing.io, allocator, path, 4096));
}

test "lastContextTokensChunked: only non-qualifying lines returns NoUsage" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const line1 =
        \\{"timestamp":"2025-01-15T10:00:00.000Z","message":{"usage":{"input_tokens":0,"output_tokens":0},"model":"<synthetic>"},"isApiErrorMessage":true}
    ;
    const line2 =
        \\{"timestamp":"2025-01-15T10:01:00.000Z","message":{"model":"claude-sonnet-4-20250514"}}
    ;
    const content = line1 ++ "\n" ++ line2 ++ "\n";
    try writeTranscript(&tmp, "t.jsonl", content);

    const path = try tmp.dir.realPathFileAlloc(std.testing.io, "t.jsonl", allocator);
    defer allocator.free(path);

    try std.testing.expectError(error.NoUsage, lastContextTokensChunked(std.testing.io, allocator, path, 4096));
}

test "lastContextTokensChunked: model is allocator-owned and freeable" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const line1 =
        \\{"timestamp":"2025-01-15T10:00:00.000Z","message":{"usage":{"input_tokens":500,"output_tokens":20,"cache_creation_input_tokens":0,"cache_read_input_tokens":0},"model":"claude-haiku-3","id":"msg-001"},"requestId":"req-001"}
    ;
    const content = line1 ++ "\n";
    try writeTranscript(&tmp, "t.jsonl", content);

    const path = try tmp.dir.realPathFileAlloc(std.testing.io, "t.jsonl", allocator);
    defer allocator.free(path);

    const result = try lastContextTokensChunked(std.testing.io, allocator, path, 4096);
    try std.testing.expectEqualStrings("claude-haiku-3", result.model);
    allocator.free(result.model);
}

test "lastContextTokens: default-chunk wrapper finds the qualifying line" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const line1 =
        \\{"timestamp":"2025-01-15T10:00:00.000Z","message":{"usage":{"input_tokens":100,"output_tokens":10,"cache_creation_input_tokens":0,"cache_read_input_tokens":50},"model":"claude-sonnet-4-20250514","id":"msg-001"},"requestId":"req-001"}
    ;
    const content = line1 ++ "\n";
    try writeTranscript(&tmp, "t.jsonl", content);

    const path = try tmp.dir.realPathFileAlloc(std.testing.io, "t.jsonl", allocator);
    defer allocator.free(path);

    const result = try lastContextTokens(std.testing.io, allocator, path);
    defer allocator.free(result.model);

    try std.testing.expectEqual(@as(u64, 150), result.tokens); // 100 + 50
    try std.testing.expectEqualStrings("claude-sonnet-4-20250514", result.model);
}

// =============================================================================
// contextWindowFor
// =============================================================================

const context_window_test_fixture =
    \\{
    \\  "claude-opus-5": {
    \\    "input_cost_per_token": 5e-06,
    \\    "output_cost_per_token": 2.5e-05,
    \\    "max_input_tokens": 1000000
    \\  },
    \\  "claude-opus-5[1m]": {
    \\    "input_cost_per_token": 5e-06,
    \\    "output_cost_per_token": 2.5e-05,
    \\    "max_input_tokens": 50000
    \\  },
    \\  "claude-sonnet-4-5": {
    \\    "input_cost_per_token": 3e-06,
    \\    "output_cost_per_token": 1.5e-05,
    \\    "max_input_tokens": 200000
    \\  },
    \\  "claude-haiku-4-5": {
    \\    "input_cost_per_token": 1e-06,
    \\    "output_cost_per_token": 5e-06
    \\  }
    \\}
;

test "contextWindowFor: [1m] marker wins over dynamic table" {
    try pricing.initDynamicFromJson(std.testing.allocator, context_window_test_fixture);
    defer pricing.deinitDynamic(std.testing.allocator);

    // The dynamic table has an entry for the exact "claude-opus-5[1m]" key
    // with a conflicting (smaller) max_input_tokens; the marker must win anyway.
    try std.testing.expectEqual(@as(u64, 1_000_000), contextWindowFor("claude-opus-5[1m]"));
}

test "contextWindowFor: dynamic table hit returns its max_input_tokens" {
    try pricing.initDynamicFromJson(std.testing.allocator, context_window_test_fixture);
    defer pricing.deinitDynamic(std.testing.allocator);

    try std.testing.expectEqual(@as(u64, 1_000_000), contextWindowFor("claude-opus-5"));
    try std.testing.expectEqual(@as(u64, 200_000), contextWindowFor("claude-sonnet-4-5"));
}

test "contextWindowFor: model absent from table falls back to default" {
    try pricing.initDynamicFromJson(std.testing.allocator, context_window_test_fixture);
    defer pricing.deinitDynamic(std.testing.allocator);

    try std.testing.expectEqual(@as(u64, 200_000), contextWindowFor("claude-nonexistent"));
}

test "contextWindowFor: entry without max_input_tokens falls back to default" {
    try pricing.initDynamicFromJson(std.testing.allocator, context_window_test_fixture);
    defer pricing.deinitDynamic(std.testing.allocator);

    try std.testing.expectEqual(@as(u64, 200_000), contextWindowFor("claude-haiku-4-5"));
}

// =============================================================================
// findTranscript
// =============================================================================

fn tmpRootPath(tmp: *std.testing.TmpDir, allocator: std.mem.Allocator) ![]u8 {
    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const len = try tmp.dir.realPath(std.testing.io, &buf);
    return allocator.dupe(u8, buf[0..len]);
}

test "findTranscript: finds the transcript under the sole data dir" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(std.testing.io, "projects/some-project");
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "projects/some-project/sess-abc.jsonl", .data = "" });

    const root = try tmpRootPath(&tmp, allocator);
    defer allocator.free(root);

    var env = std.process.Environ.Map.init(allocator);
    defer env.deinit();
    try env.put("CLAUDE_CONFIG_DIR", root);

    const result = try findTranscript(std.testing.io, allocator, &env, "sess-abc");
    try std.testing.expect(result != null);
    defer allocator.free(result.?);

    const expected = try std.fs.path.join(allocator, &.{ root, "projects", "some-project", "sess-abc.jsonl" });
    defer allocator.free(expected);
    try std.testing.expectEqualStrings(expected, result.?);
}

test "findTranscript: no matching session id anywhere returns null" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(std.testing.io, "projects/some-project");
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "projects/some-project/sess-abc.jsonl", .data = "" });

    const root = try tmpRootPath(&tmp, allocator);
    defer allocator.free(root);

    var env = std.process.Environ.Map.init(allocator);
    defer env.deinit();
    try env.put("CLAUDE_CONFIG_DIR", root);

    const result = try findTranscript(std.testing.io, allocator, &env, "sess-does-not-exist");
    try std.testing.expect(result == null);
}

test "findTranscript: finds the transcript in the second of two data dirs" {
    const allocator = std.testing.allocator;
    var tmpA = std.testing.tmpDir(.{});
    defer tmpA.cleanup();
    var tmpB = std.testing.tmpDir(.{});
    defer tmpB.cleanup();

    try tmpA.dir.createDirPath(std.testing.io, "projects/other-project");
    try tmpB.dir.createDirPath(std.testing.io, "projects/some-project");
    try tmpB.dir.writeFile(std.testing.io, .{ .sub_path = "projects/some-project/sess-abc.jsonl", .data = "" });

    const rootA = try tmpRootPath(&tmpA, allocator);
    defer allocator.free(rootA);
    const rootB = try tmpRootPath(&tmpB, allocator);
    defer allocator.free(rootB);

    const combined = try std.fmt.allocPrint(allocator, "{s},{s}", .{ rootA, rootB });
    defer allocator.free(combined);

    var env = std.process.Environ.Map.init(allocator);
    defer env.deinit();
    try env.put("CLAUDE_CONFIG_DIR", combined);

    const result = try findTranscript(std.testing.io, allocator, &env, "sess-abc");
    try std.testing.expect(result != null);
    defer allocator.free(result.?);

    const expected = try std.fs.path.join(allocator, &.{ rootB, "projects", "some-project", "sess-abc.jsonl" });
    defer allocator.free(expected);
    try std.testing.expectEqualStrings(expected, result.?);
}

test "findTranscript: nonexistent data dir in the list is skipped, not an error" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(std.testing.io, "projects/some-project");
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "projects/some-project/sess-abc.jsonl", .data = "" });

    const root = try tmpRootPath(&tmp, allocator);
    defer allocator.free(root);

    const combined = try std.fmt.allocPrint(allocator, "/nonexistent-ccuzage-test-dir-xyz,{s}", .{root});
    defer allocator.free(combined);

    var env = std.process.Environ.Map.init(allocator);
    defer env.deinit();
    try env.put("CLAUDE_CONFIG_DIR", combined);

    const result = try findTranscript(std.testing.io, allocator, &env, "sess-abc");
    try std.testing.expect(result != null);
    defer allocator.free(result.?);

    const expected = try std.fs.path.join(allocator, &.{ root, "projects", "some-project", "sess-abc.jsonl" });
    defer allocator.free(expected);
    try std.testing.expectEqualStrings(expected, result.?);
}
