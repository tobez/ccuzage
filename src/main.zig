// ABOUTME: Entry point for the blazing CLI tool.
// ABOUTME: Parses command-line flags and dispatches to the appropriate action.
const std = @import("std");
const types = @import("types.zig");
const loader = @import("loader.zig");
const aggregate = @import("aggregate.zig");
const blocks_mod = @import("blocks.zig");
const json_output = @import("json_output.zig");
const statusline_mod = @import("statusline.zig");

const version = "blazing v0.1.0";

const help_text =
    \\blazing - Claude Code usage analytics
    \\
    \\Usage: blazing [command] [options]
    \\
    \\Commands:
    \\  daily      Daily token usage and costs (default)
    \\  weekly     Weekly aggregated reports
    \\  monthly    Monthly aggregated reports
    \\  session    Usage grouped by conversation
    \\  blocks     5-hour billing window analysis
    \\  statusline Real-time usage for Claude Code status bar
    \\
    \\Options:
    \\  --since YYYYMMDD    Start date filter
    \\  --until YYYYMMDD    End date filter
    \\  --json              JSON output (on by default)
    \\  --breakdown         Per-model cost breakdown
    \\  --timezone OFFSET   Timezone offset in minutes (e.g., 120 for +02:00)
    \\  --order asc|desc    Sort order (default: desc)
    \\  --project NAME      Filter to specific project
    \\  --instances         Group by project
    \\
    \\Blocks-specific:
    \\  --active            Show only current active block
    \\  --recent            Last 3 days + active
    \\  --session-length N  Custom block duration (hours, default: 5)
    \\  --token-limit N     Token quota warning threshold
    \\
    \\General:
    \\  --version           Print version and exit
    \\  --help              Print this help and exit
    \\
;

pub const ParseError = error{
    UnknownFlag,
    MissingValue,
    InvalidValue,
};

/// Parses CLI arguments (excluding program name) into CliOptions.
pub fn parseArgs(args: []const []const u8) ParseError!types.CliOptions {
    var opts = types.CliOptions.default;
    var i: usize = 0;

    while (i < args.len) {
        const arg = args[i];

        if (std.mem.eql(u8, arg, "--since")) {
            i += 1;
            if (i >= args.len) return ParseError.MissingValue;
            opts.since = args[i];
        } else if (std.mem.eql(u8, arg, "--until")) {
            i += 1;
            if (i >= args.len) return ParseError.MissingValue;
            opts.until = args[i];
        } else if (std.mem.eql(u8, arg, "--json")) {
            opts.json = true;
        } else if (std.mem.eql(u8, arg, "--breakdown")) {
            opts.breakdown = true;
        } else if (std.mem.eql(u8, arg, "--timezone")) {
            i += 1;
            if (i >= args.len) return ParseError.MissingValue;
            opts.timezone_offset_minutes = std.fmt.parseInt(i32, args[i], 10) catch return ParseError.InvalidValue;
        } else if (std.mem.eql(u8, arg, "--order")) {
            i += 1;
            if (i >= args.len) return ParseError.MissingValue;
            if (std.mem.eql(u8, args[i], "asc")) {
                opts.order = .asc;
            } else if (std.mem.eql(u8, args[i], "desc")) {
                opts.order = .desc;
            } else {
                return ParseError.InvalidValue;
            }
        } else if (std.mem.eql(u8, arg, "--project")) {
            i += 1;
            if (i >= args.len) return ParseError.MissingValue;
            opts.project = args[i];
        } else if (std.mem.eql(u8, arg, "--instances")) {
            opts.instances = true;
        } else if (std.mem.eql(u8, arg, "--active")) {
            opts.active = true;
        } else if (std.mem.eql(u8, arg, "--recent")) {
            opts.recent = true;
        } else if (std.mem.eql(u8, arg, "--session-length")) {
            i += 1;
            if (i >= args.len) return ParseError.MissingValue;
            opts.session_length = std.fmt.parseInt(u32, args[i], 10) catch return ParseError.InvalidValue;
        } else if (std.mem.eql(u8, arg, "--token-limit")) {
            i += 1;
            if (i >= args.len) return ParseError.MissingValue;
            opts.token_limit = std.fmt.parseInt(u64, args[i], 10) catch return ParseError.InvalidValue;
        } else if (std.mem.startsWith(u8, arg, "-")) {
            return ParseError.UnknownFlag;
        } else {
            // Non-flag argument: treat as command name
            if (std.mem.eql(u8, arg, "daily")) {
                opts.command = .daily;
            } else if (std.mem.eql(u8, arg, "weekly")) {
                opts.command = .weekly;
            } else if (std.mem.eql(u8, arg, "monthly")) {
                opts.command = .monthly;
            } else if (std.mem.eql(u8, arg, "session")) {
                opts.command = .session;
            } else if (std.mem.eql(u8, arg, "blocks")) {
                opts.command = .blocks;
            } else if (std.mem.eql(u8, arg, "statusline")) {
                opts.command = .statusline;
            } else {
                return ParseError.UnknownFlag;
            }
        }
        i += 1;
    }

    return opts;
}

pub fn main() !void {
    var stdout_buffer: [4096]u8 = undefined;
    var stdout_writer = std.fs.File.stdout().writer(&stdout_buffer);
    const stdout = &stdout_writer.interface;

    const args = try std.process.argsAlloc(std.heap.smp_allocator);
    defer std.process.argsFree(std.heap.smp_allocator, args);

    // Check for --version and --help before full parsing
    for (args[1..]) |arg| {
        if (std.mem.eql(u8, arg, "--version")) {
            try stdout.print("{s}\n", .{version});
            try stdout.flush();
            return;
        } else if (std.mem.eql(u8, arg, "--help")) {
            try stdout.print("{s}", .{help_text});
            try stdout.flush();
            return;
        }
    }

    const opts = parseArgs(args[1..]) catch |err| {
        var stderr_buffer: [4096]u8 = undefined;
        var stderr_writer = std.fs.File.stderr().writer(&stderr_buffer);
        const stderr = &stderr_writer.interface;
        switch (err) {
            ParseError.UnknownFlag => try stderr.print("Error: unknown flag\n", .{}),
            ParseError.MissingValue => try stderr.print("Error: missing value for flag\n", .{}),
            ParseError.InvalidValue => try stderr.print("Error: invalid value for flag\n", .{}),
        }
        try stderr.flush();
        std.process.exit(1);
    };

    const allocator = std.heap.smp_allocator;

    // Statusline reads from stdin, not from usage data files
    if (opts.command == .statusline) {
        statusline_mod.runStatusline(allocator) catch {
            try stderr_print("Error: statusline failed\n");
            std.process.exit(1);
        };
        return;
    }

    // Load all entries
    const all_entries = loader.loadAllEntries(allocator) catch {
        try stderr_print("Error: failed to load usage data\n");
        std.process.exit(1);
    };

    // Filter by date range
    const date_filtered = aggregate.filterByDateRange(
        allocator,
        all_entries,
        opts.since,
        opts.until,
        opts.timezone_offset_minutes,
    ) catch {
        try stderr_print("Error: failed to filter by date range\n");
        std.process.exit(1);
    };

    // Filter by project (if --project set)
    const entries = if (opts.project) |project_name| blk: {
        var filtered: std.ArrayList(types.UsageEntry) = .{};
        for (date_filtered) |entry| {
            if (std.mem.eql(u8, entry.project, project_name)) {
                filtered.append(allocator, entry) catch {
                    try stderr_print("Error: failed to filter by project\n");
                    std.process.exit(1);
                };
            }
        }
        break :blk filtered.toOwnedSlice(allocator) catch {
            try stderr_print("Error: failed to filter by project\n");
            std.process.exit(1);
        };
    } else date_filtered;

    // Dispatch based on command
    const json_str: []u8 = switch (opts.command) {
        .daily, .monthly, .weekly => blk: {
            const aggregated = switch (opts.command) {
                .daily => aggregate.aggregateDaily(allocator, entries, opts.timezone_offset_minutes),
                .monthly => aggregate.aggregateMonthly(allocator, entries, opts.timezone_offset_minutes),
                .weekly => aggregate.aggregateWeekly(allocator, entries, opts.timezone_offset_minutes, 0),
                else => unreachable,
            } catch {
                try stderr_print("Error: aggregation failed\n");
                std.process.exit(1);
            };
            aggregate.sortAggregated(aggregated, opts.order);
            const totals = aggregate.calculateTotals(aggregated);

            const result = switch (opts.command) {
                .daily => json_output.reportToJson(allocator, "daily", "date", aggregated, totals),
                .monthly => json_output.reportToJson(allocator, "monthly", "month", aggregated, totals),
                .weekly => json_output.reportToJson(allocator, "weekly", "week", aggregated, totals),
                else => unreachable,
            } catch {
                try stderr_print("Error: JSON serialization failed\n");
                std.process.exit(1);
            };
            break :blk result;
        },
        .session => blk: {
            const sessions = aggregate.aggregateSession(allocator, entries, opts.timezone_offset_minutes) catch {
                try stderr_print("Error: session aggregation failed\n");
                std.process.exit(1);
            };
            aggregate.sortSessions(sessions, opts.order);
            const totals = aggregate.calculateSessionTotals(sessions);
            break :blk json_output.sessionToJson(allocator, sessions, totals) catch {
                try stderr_print("Error: JSON serialization failed\n");
                std.process.exit(1);
            };
        },
        .blocks => blk: {
            const now_ms = std.time.milliTimestamp();
            var all_blocks = blocks_mod.identifyBlocks(allocator, entries, opts.session_length, now_ms) catch {
                try stderr_print("Error: block identification failed\n");
                std.process.exit(1);
            };

            // Apply --active or --recent filters
            if (opts.active) {
                var filtered: std.ArrayList(types.SessionBlock) = .{};
                for (all_blocks) |block| {
                    if (block.is_active) {
                        filtered.append(allocator, block) catch {
                            try stderr_print("Error: block filtering failed\n");
                            std.process.exit(1);
                        };
                    }
                }
                all_blocks = filtered.toOwnedSlice(allocator) catch {
                    try stderr_print("Error: block filtering failed\n");
                    std.process.exit(1);
                };
            } else if (opts.recent) {
                const three_days_ms: i64 = 3 * 24 * 60 * 60 * 1000;
                const cutoff = now_ms - three_days_ms;
                var filtered: std.ArrayList(types.SessionBlock) = .{};
                for (all_blocks) |block| {
                    if (block.start_time >= cutoff or block.is_active) {
                        filtered.append(allocator, block) catch {
                            try stderr_print("Error: block filtering failed\n");
                            std.process.exit(1);
                        };
                    }
                }
                all_blocks = filtered.toOwnedSlice(allocator) catch {
                    try stderr_print("Error: block filtering failed\n");
                    std.process.exit(1);
                };
            }

            break :blk json_output.blocksToJson(allocator, all_blocks) catch {
                try stderr_print("Error: JSON serialization failed\n");
                std.process.exit(1);
            };
        },
        .statusline => unreachable, // handled above before entry loading
    };

    try stdout.print("{s}\n", .{json_str});
    try stdout.flush();
}

fn stderr_print(msg: []const u8) !void {
    var stderr_buffer: [4096]u8 = undefined;
    var stderr_writer = std.fs.File.stderr().writer(&stderr_buffer);
    const stderr = &stderr_writer.interface;
    try stderr.writeAll(msg);
    try stderr.flush();
}

// =============================================================================
// Tests
// =============================================================================

test "parseArgs: no args returns defaults" {
    const opts = try parseArgs(&[_][]const u8{});
    try std.testing.expectEqual(types.Command.daily, opts.command);
    try std.testing.expectEqual(true, opts.json);
    try std.testing.expectEqual(types.SortOrder.desc, opts.order);
    try std.testing.expectEqual(@as(u32, 5), opts.session_length);
    try std.testing.expectEqual(@as(?[]const u8, null), opts.since);
    try std.testing.expectEqual(@as(?[]const u8, null), opts.until);
    try std.testing.expectEqual(false, opts.breakdown);
    try std.testing.expectEqual(false, opts.instances);
    try std.testing.expectEqual(false, opts.active);
    try std.testing.expectEqual(false, opts.recent);
    try std.testing.expectEqual(@as(?u64, null), opts.token_limit);
    try std.testing.expectEqual(@as(?[]const u8, null), opts.project);
}

test "parseArgs: command only" {
    const opts = try parseArgs(&[_][]const u8{"monthly"});
    try std.testing.expectEqual(types.Command.monthly, opts.command);
}

test "parseArgs: command with flags" {
    const opts = try parseArgs(&[_][]const u8{ "blocks", "--active", "--session-length", "3" });
    try std.testing.expectEqual(types.Command.blocks, opts.command);
    try std.testing.expectEqual(true, opts.active);
    try std.testing.expectEqual(@as(u32, 3), opts.session_length);
}

test "parseArgs: date range flags" {
    const opts = try parseArgs(&[_][]const u8{ "--since", "20250101", "--until", "20250131" });
    try std.testing.expectEqualStrings("20250101", opts.since.?);
    try std.testing.expectEqualStrings("20250131", opts.until.?);
    try std.testing.expectEqual(types.Command.daily, opts.command);
}

test "parseArgs: order flag" {
    const opts = try parseArgs(&[_][]const u8{ "monthly", "--order", "asc" });
    try std.testing.expectEqual(types.Command.monthly, opts.command);
    try std.testing.expectEqual(types.SortOrder.asc, opts.order);
}

test "parseArgs: timezone flag" {
    const opts = try parseArgs(&[_][]const u8{ "--timezone", "120" });
    try std.testing.expectEqual(@as(i32, 120), opts.timezone_offset_minutes);
}

test "parseArgs: unknown flag returns error" {
    const result = parseArgs(&[_][]const u8{"--unknown"});
    try std.testing.expectError(ParseError.UnknownFlag, result);
}

test "parseArgs: project and instances flags" {
    const opts = try parseArgs(&[_][]const u8{ "daily", "--project", "myproj", "--instances" });
    try std.testing.expectEqual(types.Command.daily, opts.command);
    try std.testing.expectEqualStrings("myproj", opts.project.?);
    try std.testing.expectEqual(true, opts.instances);
}

test "parseArgs: missing value for --since returns error" {
    const result = parseArgs(&[_][]const u8{"--since"});
    try std.testing.expectError(ParseError.MissingValue, result);
}

test "parseArgs: invalid order value returns error" {
    const result = parseArgs(&[_][]const u8{ "--order", "random" });
    try std.testing.expectError(ParseError.InvalidValue, result);
}

test "parseArgs: all commands are recognized" {
    const commands = [_]struct { name: []const u8, expected: types.Command }{
        .{ .name = "daily", .expected = .daily },
        .{ .name = "weekly", .expected = .weekly },
        .{ .name = "monthly", .expected = .monthly },
        .{ .name = "session", .expected = .session },
        .{ .name = "blocks", .expected = .blocks },
        .{ .name = "statusline", .expected = .statusline },
    };
    for (commands) |cmd| {
        const opts = try parseArgs(&[_][]const u8{cmd.name});
        try std.testing.expectEqual(cmd.expected, opts.command);
    }
}

test "parseArgs: token-limit flag" {
    const opts = try parseArgs(&[_][]const u8{ "blocks", "--token-limit", "500000" });
    try std.testing.expectEqual(types.Command.blocks, opts.command);
    try std.testing.expectEqual(@as(?u64, 500000), opts.token_limit);
}

test "parseArgs: recent flag" {
    const opts = try parseArgs(&[_][]const u8{ "blocks", "--recent" });
    try std.testing.expectEqual(true, opts.recent);
}

test "parseArgs: negative timezone offset" {
    const opts = try parseArgs(&[_][]const u8{ "--timezone", "-300" });
    try std.testing.expectEqual(@as(i32, -300), opts.timezone_offset_minutes);
}

test {
    _ = @import("date.zig");
    _ = @import("types.zig");
    _ = @import("parser.zig");
    _ = @import("loader.zig");
    _ = @import("aggregate.zig");
    _ = @import("json_output.zig");
    _ = @import("blocks.zig");
    _ = @import("statusline.zig");
}
