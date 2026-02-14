// ABOUTME: Loads JSONL files, discovers them in Claude Code data directories, and deduplicates entries.
// ABOUTME: Provides file discovery, path extraction, and the full loading pipeline.
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

const ProjectAndSession = struct {
    project: []const u8,
    session_id: []const u8,
};

/// Extracts project name and session ID from a JSONL file path.
/// Expects paths like: .../projects/<project>/<session>.jsonl
/// Returns null if the path structure is invalid.
pub fn extractProjectAndSession(path: []const u8) ?ProjectAndSession {
    const marker = "projects/";
    const marker_pos = std.mem.indexOf(u8, path, marker) orelse return null;
    const after_marker = marker_pos + marker.len;

    // Everything after "projects/" — need at least one char for project and one for filename
    if (after_marker >= path.len) return null;

    // Find the last '/' — separates project path from filename
    const last_slash = std.mem.lastIndexOfScalar(u8, path, '/') orelse return null;

    // The last slash must be after the marker to have a project component
    if (last_slash <= after_marker) return null;
    // There must be something after the last slash for the filename
    if (last_slash + 1 >= path.len) return null;

    const project = path[after_marker..last_slash];
    const filename = path[last_slash + 1 ..];

    // Strip .jsonl extension
    if (!std.mem.endsWith(u8, filename, ".jsonl")) return null;
    const session_id = filename[0 .. filename.len - ".jsonl".len];
    if (session_id.len == 0) return null;

    return .{
        .project = project,
        .session_id = session_id,
    };
}

/// Discovers all .jsonl files in Claude Code's data directories.
/// Checks CLAUDE_CONFIG_DIR env var, then ~/.config/claude/projects/, then ~/.claude/projects/.
pub fn discoverJsonlFiles(allocator: std.mem.Allocator) ![][]const u8 {
    var files: std.ArrayList([]const u8) = .{};
    errdefer {
        for (files.items) |f| allocator.free(f);
        files.deinit(allocator);
    }

    // Collect candidate directories
    var dirs_to_check: std.ArrayList([]const u8) = .{};
    defer {
        for (dirs_to_check.items) |d| allocator.free(d);
        dirs_to_check.deinit(allocator);
    }

    // 1. CLAUDE_CONFIG_DIR environment variable (comma-separated)
    if (std.process.getEnvVarOwned(allocator, "CLAUDE_CONFIG_DIR")) |config_dir| {
        defer allocator.free(config_dir);
        var it = std.mem.splitScalar(u8, config_dir, ',');
        while (it.next()) |part| {
            const trimmed = std.mem.trim(u8, part, " ");
            if (trimmed.len == 0) continue;
            const dir_path = try std.fs.path.join(allocator, &.{ trimmed, "projects" });
            try dirs_to_check.append(allocator, dir_path);
        }
    } else |_| {}

    // 2. ~/.config/claude/projects/
    if (std.process.getEnvVarOwned(allocator, "HOME")) |home| {
        defer allocator.free(home);
        const config_projects = try std.fs.path.join(allocator, &.{ home, ".config", "claude", "projects" });
        try dirs_to_check.append(allocator, config_projects);

        // 3. ~/.claude/projects/
        const dot_claude_projects = try std.fs.path.join(allocator, &.{ home, ".claude", "projects" });
        try dirs_to_check.append(allocator, dot_claude_projects);
    } else |_| {}

    // Walk each directory
    for (dirs_to_check.items) |dir_path| {
        try collectJsonlFiles(allocator, dir_path, &files);
    }

    return files.toOwnedSlice(allocator);
}

/// Recursively collects .jsonl files from a directory.
fn collectJsonlFiles(allocator: std.mem.Allocator, dir_path: []const u8, files: *std.ArrayList([]const u8)) !void {
    var dir = std.fs.openDirAbsolute(dir_path, .{ .iterate = true }) catch return;
    defer dir.close();

    var walker = dir.walk(allocator) catch return;
    defer walker.deinit();

    while (walker.next() catch null) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.basename, ".jsonl")) continue;

        // Build full path: dir_path + "/" + entry.path
        const full_path = try std.fs.path.join(allocator, &.{ dir_path, entry.path });
        try files.append(allocator, full_path);
    }
}

/// Loads all usage entries from all discovered JSONL files.
/// Deduplication is per-file (within a session).
pub fn loadAllEntries(allocator: std.mem.Allocator) ![]types.UsageEntry {
    const file_paths = try discoverJsonlFiles(allocator);
    defer {
        for (file_paths) |p| allocator.free(p);
        allocator.free(file_paths);
    }

    var all_entries: std.ArrayList(types.UsageEntry) = .{};
    errdefer {
        for (all_entries.items) |e| {
            allocator.free(e.model);
            allocator.free(e.message_id);
            allocator.free(e.request_id);
        }
        all_entries.deinit(allocator);
    }

    for (file_paths) |file_path| {
        const ps = extractProjectAndSession(file_path) orelse continue;

        // Read the file
        const file = std.fs.openFileAbsolute(file_path, .{}) catch continue;
        defer file.close();
        const contents = file.readToEndAlloc(allocator, 256 * 1024 * 1024) catch continue;
        defer allocator.free(contents);

        // Split into lines
        var line_list: std.ArrayList([]const u8) = .{};
        defer line_list.deinit(allocator);

        var line_iter = std.mem.splitScalar(u8, contents, '\n');
        while (line_iter.next()) |line| {
            if (line.len == 0) continue;
            try line_list.append(allocator, line);
        }

        // Parse and dedup within this file
        const entries = try loadEntriesFromLines(allocator, line_list.items, ps.session_id, ps.project);

        // Append to combined list
        try all_entries.appendSlice(allocator, entries);
        allocator.free(entries); // Free the slice wrapper, entries are now in all_entries
    }

    return all_entries.toOwnedSlice(allocator);
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

test "extractProjectAndSession - basic path" {
    const result = extractProjectAndSession("/home/user/.config/claude/projects/myproject/abc-123.jsonl");
    try std.testing.expect(result != null);
    const r = result.?;
    try std.testing.expectEqualStrings("myproject", r.project);
    try std.testing.expectEqualStrings("abc-123", r.session_id);
}

test "extractProjectAndSession - nested project" {
    const result = extractProjectAndSession("/home/user/.claude/projects/deep/nested/project/session.jsonl");
    try std.testing.expect(result != null);
    const r = result.?;
    try std.testing.expectEqualStrings("deep/nested/project", r.project);
    try std.testing.expectEqualStrings("session", r.session_id);
}

test "extractProjectAndSession - no projects in path" {
    const result = extractProjectAndSession("/some/random/path/file.jsonl");
    try std.testing.expect(result == null);
}

test "extractProjectAndSession - path ending at projects/" {
    const result = extractProjectAndSession("/home/.config/claude/projects/");
    try std.testing.expect(result == null);
}

test "file reading and parsing integration" {
    const allocator = std.testing.allocator;

    // Create a temp directory structure: projects/testproj/
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    // Create nested directory for the JSONL file
    tmp.dir.makePath("projects/testproj") catch unreachable;

    // Write a JSONL file with a duplicate and a unique entry
    const line1 =
        \\{"timestamp":"2025-01-15T10:00:00.000Z","message":{"usage":{"input_tokens":100,"output_tokens":50},"model":"claude-sonnet-4-20250514","id":"msg-001"},"costUSD":0.01,"requestId":"req-001"}
    ;
    const line2 =
        \\{"timestamp":"2025-01-15T11:00:00.000Z","message":{"usage":{"input_tokens":200,"output_tokens":100},"model":"claude-sonnet-4-20250514","id":"msg-002"},"costUSD":0.02,"requestId":"req-002"}
    ;
    // Duplicate of line1
    const line1_dup =
        \\{"timestamp":"2025-01-15T10:05:00.000Z","message":{"usage":{"input_tokens":100,"output_tokens":50},"model":"claude-sonnet-4-20250514","id":"msg-001"},"costUSD":0.01,"requestId":"req-001"}
    ;

    const file_content = line1 ++ "\n" ++ line2 ++ "\n" ++ line1_dup ++ "\n";

    tmp.dir.writeFile(.{
        .sub_path = "projects/testproj/sess-abc.jsonl",
        .data = file_content,
    }) catch unreachable;

    // Read the file back and verify the pipeline
    const contents = try tmp.dir.readFileAlloc(allocator, "projects/testproj/sess-abc.jsonl", 1024 * 1024);
    defer allocator.free(contents);

    // Split into lines
    var line_list: std.ArrayList([]const u8) = .{};
    defer line_list.deinit(allocator);

    var line_iter = std.mem.splitScalar(u8, contents, '\n');
    while (line_iter.next()) |line| {
        if (line.len == 0) continue;
        try line_list.append(allocator, line);
    }

    try std.testing.expectEqual(@as(usize, 3), line_list.items.len);

    // Parse and dedup
    const entries = try loadEntriesFromLines(allocator, line_list.items, "sess-abc", "testproj");
    defer freeEntries(allocator, entries);

    // Should have 2 entries after dedup (line1 and line2, line1_dup removed)
    try std.testing.expectEqual(@as(usize, 2), entries.len);
}
