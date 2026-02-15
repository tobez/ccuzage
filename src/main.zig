// ABOUTME: Entry point for the blazing CLI tool.
// ABOUTME: Parses command-line flags and dispatches to the appropriate action.
const std = @import("std");
const types = @import("types.zig");
const loader = @import("loader.zig");
const aggregate = @import("aggregate.zig");
const date = @import("date.zig");
const blocks_mod = @import("blocks.zig");
const json_output = @import("json_output.zig");
const statusline_mod = @import("statusline.zig");
const table_output = @import("table_output.zig");
const pricing = @import("pricing.zig");

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
    \\  -s, --since YYYYMMDD    Start date filter
    \\  -u, --until YYYYMMDD    End date filter
    \\  -j, --json              JSON output
    \\  -c, --columns LEVEL     Column detail: min, mid, full (default: full)
    \\  -b, --breakdown         Per-model cost breakdown
    \\  -z, --timezone OFFSET   Timezone offset in minutes (default: system timezone)
    \\  -o, --order asc|desc    Sort order (default: desc)
    \\  -p, --project NAME      Filter to specific project
    \\  -i, --instances         Group by project
    \\
    \\Blocks-specific:
    \\  --active            Show only current active block
    \\  --recent            Last 3 days + active
    \\  --session-length N  Custom block duration (hours, default: 5)
    \\  --token-limit N     Token quota warning threshold
    \\
    \\Statusline-specific:
    \\  -B, --visual-burn-rate MODE  Burn rate display: off, emoji, text, emoji-text (default: off)
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

        if (std.mem.eql(u8, arg, "--since") or std.mem.eql(u8, arg, "-s")) {
            i += 1;
            if (i >= args.len) return ParseError.MissingValue;
            opts.since = args[i];
        } else if (std.mem.eql(u8, arg, "--until") or std.mem.eql(u8, arg, "-u")) {
            i += 1;
            if (i >= args.len) return ParseError.MissingValue;
            opts.until = args[i];
        } else if (std.mem.eql(u8, arg, "--json") or std.mem.eql(u8, arg, "-j")) {
            opts.json = true;
        } else if (std.mem.eql(u8, arg, "--columns") or std.mem.eql(u8, arg, "-c")) {
            i += 1;
            if (i >= args.len) return ParseError.MissingValue;
            if (std.mem.eql(u8, args[i], "min")) {
                opts.column_level = .min;
            } else if (std.mem.eql(u8, args[i], "mid")) {
                opts.column_level = .mid;
            } else if (std.mem.eql(u8, args[i], "full")) {
                opts.column_level = .full;
            } else {
                return ParseError.InvalidValue;
            }
        } else if (std.mem.eql(u8, arg, "--breakdown") or std.mem.eql(u8, arg, "-b")) {
            opts.breakdown = true;
        } else if (std.mem.eql(u8, arg, "--timezone") or std.mem.eql(u8, arg, "-z")) {
            i += 1;
            if (i >= args.len) return ParseError.MissingValue;
            opts.timezone_offset_minutes = std.fmt.parseInt(i32, args[i], 10) catch return ParseError.InvalidValue;
        } else if (std.mem.eql(u8, arg, "--order") or std.mem.eql(u8, arg, "-o")) {
            i += 1;
            if (i >= args.len) return ParseError.MissingValue;
            if (std.mem.eql(u8, args[i], "asc")) {
                opts.order = .asc;
            } else if (std.mem.eql(u8, args[i], "desc")) {
                opts.order = .desc;
            } else {
                return ParseError.InvalidValue;
            }
        } else if (std.mem.eql(u8, arg, "--project") or std.mem.eql(u8, arg, "-p")) {
            i += 1;
            if (i >= args.len) return ParseError.MissingValue;
            opts.project = args[i];
        } else if (std.mem.eql(u8, arg, "--instances") or std.mem.eql(u8, arg, "-i")) {
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
        } else if (std.mem.eql(u8, arg, "--visual-burn-rate") or std.mem.eql(u8, arg, "-B")) {
            i += 1;
            if (i >= args.len) return ParseError.MissingValue;
            if (std.mem.eql(u8, args[i], "off")) {
                opts.burn_rate_visual = .off;
            } else if (std.mem.eql(u8, args[i], "emoji")) {
                opts.burn_rate_visual = .emoji;
            } else if (std.mem.eql(u8, args[i], "text")) {
                opts.burn_rate_visual = .text;
            } else if (std.mem.eql(u8, args[i], "emoji-text")) {
                opts.burn_rate_visual = .emoji_text;
            } else {
                return ParseError.InvalidValue;
            }
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

    const tz_offset: i32 = opts.timezone_offset_minutes orelse date.getLocalTimezoneOffset();
    const allocator = std.heap.smp_allocator;

    pricing.initDynamic(allocator);

    // Statusline reads from stdin, not from usage data files
    if (opts.command == .statusline) {
        statusline_mod.runStatusline(allocator, tz_offset, opts.session_length, opts.burn_rate_visual) catch {
            try stderr_print("Error: statusline failed\n");
            std.process.exit(1);
        };
        return;
    }

    // Compute file-level time filter from --since/--until
    var time_filter = loader.FileTimeFilter{};
    if (opts.since) |since| {
        if (date.filterDateToEpochMs(since)) |epoch_ms| {
            // Start of since date in user's timezone, converted to UTC nanoseconds
            const utc_ms = epoch_ms - @as(i64, tz_offset) * 60_000;
            time_filter.since_cutoff_ns = @as(i128, utc_ms) * 1_000_000;
        }
    }
    if (opts.until) |until| {
        if (date.filterDateToEpochMs(until)) |epoch_ms| {
            // End of until date = start of next day in user's timezone, converted to UTC nanoseconds
            const utc_ms = epoch_ms + 86_400_000 - @as(i64, tz_offset) * 60_000;
            time_filter.until_cutoff_ns = @as(i128, utc_ms) * 1_000_000;
        }
    }

    // Load all entries, skipping files outside the date range
    const all_entries = loader.loadAllEntries(allocator, time_filter) catch {
        try stderr_print("Error: failed to load usage data\n");
        std.process.exit(1);
    };

    // Filter by date range
    const date_filtered = aggregate.filterByDateRange(
        allocator,
        all_entries,
        opts.since,
        opts.until,
        tz_offset,
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
    switch (opts.command) {
        .daily, .monthly, .weekly => {
            const aggregated = switch (opts.command) {
                .daily => aggregate.aggregateDaily(allocator, entries, tz_offset, opts.instances),
                .monthly => aggregate.aggregateMonthly(allocator, entries, tz_offset, opts.instances),
                .weekly => aggregate.aggregateWeekly(allocator, entries, tz_offset, 0, opts.instances),
                else => unreachable,
            } catch {
                try stderr_print("Error: aggregation failed\n");
                std.process.exit(1);
            };
            aggregate.sortAggregated(aggregated, opts.order);
            const totals = aggregate.calculateTotals(aggregated);

            if (opts.json) {
                const json_str = if (opts.instances)
                    switch (opts.command) {
                        .daily => json_output.projectGroupedToJson(allocator, "daily", "date", aggregated, totals),
                        .monthly => json_output.projectGroupedToJson(allocator, "monthly", "month", aggregated, totals),
                        .weekly => json_output.projectGroupedToJson(allocator, "weekly", "week", aggregated, totals),
                        else => unreachable,
                    } catch {
                        try stderr_print("Error: JSON serialization failed\n");
                        std.process.exit(1);
                    }
                else
                    switch (opts.command) {
                        .daily => json_output.reportToJson(allocator, "daily", "date", aggregated, totals),
                        .monthly => json_output.reportToJson(allocator, "monthly", "month", aggregated, totals),
                        .weekly => json_output.reportToJson(allocator, "weekly", "week", aggregated, totals),
                        else => unreachable,
                    } catch {
                        try stderr_print("Error: JSON serialization failed\n");
                        std.process.exit(1);
                    };
                try stdout.print("{s}\n", .{json_str});
            } else {
                const period_label: []const u8 = switch (opts.command) {
                    .daily => "Date",
                    .weekly => "Week",
                    .monthly => "Month",
                    else => unreachable,
                };
                if (opts.instances) {
                    table_output.writeProjectGroupedTable(stdout, aggregated, totals, opts.column_level, period_label, opts.breakdown) catch {
                        try stderr_print("Error: table rendering failed\n");
                        std.process.exit(1);
                    };
                } else {
                    table_output.writeAggregatedTable(stdout, aggregated, totals, opts.column_level, period_label, opts.breakdown) catch {
                        try stderr_print("Error: table rendering failed\n");
                        std.process.exit(1);
                    };
                }
            }
        },
        .session => {
            const sessions = aggregate.aggregateSession(allocator, entries, tz_offset) catch {
                try stderr_print("Error: session aggregation failed\n");
                std.process.exit(1);
            };
            aggregate.sortSessions(sessions, opts.order);
            const totals = aggregate.calculateSessionTotals(sessions);

            if (opts.json) {
                const json_str = json_output.sessionToJson(allocator, sessions, totals) catch {
                    try stderr_print("Error: JSON serialization failed\n");
                    std.process.exit(1);
                };
                try stdout.print("{s}\n", .{json_str});
            } else {
                table_output.writeSessionTable(stdout, sessions, totals, opts.column_level, opts.breakdown) catch {
                    try stderr_print("Error: table rendering failed\n");
                    std.process.exit(1);
                };
            }
        },
        .blocks => {
            const now_ms = std.time.milliTimestamp();
            var all_blocks = blocks_mod.identifyBlocks(allocator, entries, opts.session_length, now_ms) catch {
                try stderr_print("Error: block identification failed\n");
                std.process.exit(1);
            };

            // Apply --active or --recent filters
            if (opts.active) {
                all_blocks = @constCast(blocks_mod.filterActive(allocator, all_blocks) catch {
                    try stderr_print("Error: block filtering failed\n");
                    std.process.exit(1);
                });
            } else if (opts.recent) {
                all_blocks = @constCast(blocks_mod.filterRecent(allocator, all_blocks, now_ms, 3) catch {
                    try stderr_print("Error: block filtering failed\n");
                    std.process.exit(1);
                });
            }

            if (opts.json) {
                const json_str = json_output.blocksToJson(allocator, all_blocks) catch {
                    try stderr_print("Error: JSON serialization failed\n");
                    std.process.exit(1);
                };
                try stdout.print("{s}\n", .{json_str});
            } else {
                table_output.writeBlocksTable(stdout, all_blocks, opts.token_limit, tz_offset) catch {
                    try stderr_print("Error: table rendering failed\n");
                    std.process.exit(1);
                };
            }
        },
        .statusline => unreachable, // handled above before entry loading
    }

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
    try std.testing.expectEqual(false, opts.json);
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
    try std.testing.expectEqual(@as(?i32, 120), opts.timezone_offset_minutes);
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
    try std.testing.expectEqual(@as(?i32, -300), opts.timezone_offset_minutes);
}

test "parseArgs: short flag -s for --since" {
    const opts = try parseArgs(&[_][]const u8{ "-s", "20250101" });
    try std.testing.expectEqualStrings("20250101", opts.since.?);
}

test "parseArgs: short flag -u for --until" {
    const opts = try parseArgs(&[_][]const u8{ "-u", "20250131" });
    try std.testing.expectEqualStrings("20250131", opts.until.?);
}

test "parseArgs: short flag -j for --json" {
    const opts = try parseArgs(&[_][]const u8{"-j"});
    try std.testing.expectEqual(true, opts.json);
}

test "parseArgs: short flag -o for --order" {
    const opts = try parseArgs(&[_][]const u8{ "-o", "asc" });
    try std.testing.expectEqual(types.SortOrder.asc, opts.order);
}

test "parseArgs: short flag -b for --breakdown" {
    const opts = try parseArgs(&[_][]const u8{"-b"});
    try std.testing.expectEqual(true, opts.breakdown);
}

test "parseArgs: short flag -z for --timezone" {
    const opts = try parseArgs(&[_][]const u8{ "-z", "120" });
    try std.testing.expectEqual(@as(?i32, 120), opts.timezone_offset_minutes);
}

test "parseArgs: short flag -p for --project" {
    const opts = try parseArgs(&[_][]const u8{ "-p", "myproj" });
    try std.testing.expectEqualStrings("myproj", opts.project.?);
}

test "parseArgs: short flag -i for --instances" {
    const opts = try parseArgs(&[_][]const u8{"-i"});
    try std.testing.expectEqual(true, opts.instances);
}

test "parseArgs: --columns min" {
    const opts = try parseArgs(&[_][]const u8{ "--columns", "min" });
    try std.testing.expectEqual(types.ColumnLevel.min, opts.column_level);
}

test "parseArgs: -c mid" {
    const opts = try parseArgs(&[_][]const u8{ "-c", "mid" });
    try std.testing.expectEqual(types.ColumnLevel.mid, opts.column_level);
}

test "parseArgs: --columns full" {
    const opts = try parseArgs(&[_][]const u8{ "--columns", "full" });
    try std.testing.expectEqual(types.ColumnLevel.full, opts.column_level);
}

test "parseArgs: --columns invalid value returns error" {
    const result = parseArgs(&[_][]const u8{ "--columns", "huge" });
    try std.testing.expectError(ParseError.InvalidValue, result);
}

test "parseArgs: -c missing value returns error" {
    const result = parseArgs(&[_][]const u8{"-c"});
    try std.testing.expectError(ParseError.MissingValue, result);
}

test "parseArgs: default column_level is full" {
    const opts = try parseArgs(&[_][]const u8{});
    try std.testing.expectEqual(types.ColumnLevel.full, opts.column_level);
}

test "parseArgs: mixed short and long flags" {
    const opts = try parseArgs(&[_][]const u8{ "daily", "-s", "20250101", "--until", "20250131", "-b" });
    try std.testing.expectEqual(types.Command.daily, opts.command);
    try std.testing.expectEqualStrings("20250101", opts.since.?);
    try std.testing.expectEqualStrings("20250131", opts.until.?);
    try std.testing.expectEqual(true, opts.breakdown);
}

test "parseArgs: short flag -s missing value returns error" {
    const result = parseArgs(&[_][]const u8{"-s"});
    try std.testing.expectError(ParseError.MissingValue, result);
}

test "parseArgs: --visual-burn-rate emoji" {
    const opts = try parseArgs(&[_][]const u8{ "statusline", "--visual-burn-rate", "emoji" });
    try std.testing.expectEqual(types.BurnRateVisual.emoji, opts.burn_rate_visual);
}

test "parseArgs: -B text" {
    const opts = try parseArgs(&[_][]const u8{ "statusline", "-B", "text" });
    try std.testing.expectEqual(types.BurnRateVisual.text, opts.burn_rate_visual);
}

test "parseArgs: --visual-burn-rate emoji-text" {
    const opts = try parseArgs(&[_][]const u8{ "--visual-burn-rate", "emoji-text" });
    try std.testing.expectEqual(types.BurnRateVisual.emoji_text, opts.burn_rate_visual);
}

test "parseArgs: --visual-burn-rate invalid value returns error" {
    const result = parseArgs(&[_][]const u8{ "--visual-burn-rate", "sparkles" });
    try std.testing.expectError(ParseError.InvalidValue, result);
}

test "parseArgs: -B missing value returns error" {
    const result = parseArgs(&[_][]const u8{"-B"});
    try std.testing.expectError(ParseError.MissingValue, result);
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
    _ = @import("table_output.zig");
    _ = @import("integration_test.zig");
    _ = @import("scanner.zig");
    _ = @import("pricing.zig");
}
