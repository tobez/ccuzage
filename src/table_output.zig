// ABOUTME: Renders Unicode box-drawing tables for terminal output.
// ABOUTME: Provides a generic Table struct and per-command formatting functions.
const std = @import("std");
const types = @import("types.zig");
const statusline = @import("statusline.zig");
const date = @import("date.zig");

const Writer = std.io.Writer;

pub const MAX_COLS = 10;
pub const MAX_ROWS = 400;

pub const Alignment = enum { left, right };

pub const Column = struct {
    name: []const u8,
    alignment: Alignment,
};

pub const Table = struct {
    columns: [MAX_COLS]Column,
    col_count: u8,
    rows: [MAX_ROWS][MAX_COLS][]const u8,
    row_count: usize,
    separator_after: [MAX_ROWS]bool,

    pub fn init(columns: []const Column) Table {
        var t = Table{
            .columns = undefined,
            .col_count = @intCast(columns.len),
            .rows = undefined,
            .row_count = 0,
            .separator_after = [_]bool{false} ** MAX_ROWS,
        };
        for (columns, 0..) |col, i| {
            t.columns[i] = col;
        }
        // Zero out all row cells
        for (&t.rows) |*row| {
            row.* = [_][]const u8{""} ** MAX_COLS;
        }
        return t;
    }

    pub fn addRow(self: *Table, cells: []const []const u8) void {
        if (self.row_count >= MAX_ROWS) return;
        for (cells, 0..) |cell, i| {
            self.rows[self.row_count][i] = cell;
        }
        self.row_count += 1;
    }

    pub fn addSeparator(self: *Table) void {
        if (self.row_count > 0) {
            self.separator_after[self.row_count - 1] = true;
        }
    }

    fn calculateWidths(self: *const Table) [MAX_COLS]usize {
        var widths = [_]usize{0} ** MAX_COLS;
        const cols: usize = self.col_count;
        // Header widths
        for (0..cols) |c| {
            widths[c] = self.columns[c].name.len;
        }
        // Data widths
        for (0..self.row_count) |r| {
            for (0..cols) |c| {
                if (self.rows[r][c].len > widths[c]) {
                    widths[c] = self.rows[r][c].len;
                }
            }
        }
        return widths;
    }

    pub fn render(self: *const Table, w: *Writer) Writer.Error!void {
        const widths = self.calculateWidths();
        const cols: usize = self.col_count;

        // Top border: ┌──┬──┐
        try self.writeBorder(w, widths, "┌", "┬", "┐");

        // Header row
        try w.writeAll("│");
        for (0..cols) |c| {
            try w.writeByte(' ');
            try writePadded(w, self.columns[c].name, widths[c], self.columns[c].alignment);
            try w.writeAll(" │");
        }
        try w.writeByte('\n');

        // Header separator: ├──┼──┤
        try self.writeBorder(w, widths, "├", "┼", "┤");

        // Data rows
        for (0..self.row_count) |r| {
            try w.writeAll("│");
            for (0..cols) |c| {
                try w.writeByte(' ');
                try writePadded(w, self.rows[r][c], widths[c], self.columns[c].alignment);
                try w.writeAll(" │");
            }
            try w.writeByte('\n');

            if (self.separator_after[r]) {
                try self.writeBorder(w, widths, "├", "┼", "┤");
            }
        }

        // Bottom border: └──┴──┘
        try self.writeBorder(w, widths, "└", "┴", "┘");
    }

    fn writeBorder(self: *const Table, w: *Writer, widths: [MAX_COLS]usize, left: []const u8, mid: []const u8, right: []const u8) Writer.Error!void {
        try w.writeAll(left);
        for (0..self.col_count) |c| {
            // width + 2 for padding spaces
            for (0..widths[c] + 2) |_| {
                try w.writeAll("─");
            }
            if (c + 1 < self.col_count) {
                try w.writeAll(mid);
            }
        }
        try w.writeAll(right);
        try w.writeByte('\n');
    }

    fn writePadded(w: *Writer, text: []const u8, width: usize, alignment: Alignment) Writer.Error!void {
        const pad = if (width > text.len) width - text.len else 0;
        switch (alignment) {
            .right => {
                for (0..pad) |_| try w.writeByte(' ');
                try w.writeAll(text);
            },
            .left => {
                try w.writeAll(text);
                for (0..pad) |_| try w.writeByte(' ');
            },
        }
    }
};

/// Stack-based string pool for formatted cell values.
/// All slices returned by `fmt` and `put` are valid until the CellPool goes out of scope.
const CellPool = struct {
    buf: [64 * 1024]u8,
    pos: usize,

    fn init() CellPool {
        return .{ .buf = undefined, .pos = 0 };
    }

    /// Format a value into the pool and return a stable slice.
    fn fmt(self: *CellPool, comptime format: []const u8, args: anytype) []const u8 {
        const remaining = self.buf[self.pos..];
        const result = std.fmt.bufPrint(remaining, format, args) catch return "";
        self.pos += result.len;
        return result;
    }

    /// Store a literal string in the pool and return a stable slice.
    fn put(self: *CellPool, s: []const u8) []const u8 {
        if (self.pos + s.len > self.buf.len) return "";
        @memcpy(self.buf[self.pos..][0..s.len], s);
        const result = self.buf[self.pos..][0..s.len];
        self.pos += s.len;
        return result;
    }

    /// Format a token count with comma separators.
    fn fmtTokens(self: *CellPool, count: u64) []const u8 {
        var tmp: [32]u8 = undefined;
        const s = statusline.formatTokenCount(&tmp, count);
        return self.put(s);
    }

    /// Format a currency amount as $X.XX.
    fn fmtCurrency(self: *CellPool, amount: f64) []const u8 {
        var tmp: [32]u8 = undefined;
        const s = statusline.formatCurrency(&tmp, amount);
        return self.put(s);
    }
};

/// Shorten a model name by stripping "claude-" prefix and date suffixes.
/// "claude-opus-4-6" → "opus-4-6"
/// "claude-sonnet-4-5-20250929" → "sonnet-4-5"
/// "<synthetic>" → "<synthetic>"
fn shortenModelName(pool: *CellPool, name: []const u8) []const u8 {
    // Strip "claude-" prefix
    var s = name;
    if (std.mem.startsWith(u8, s, "claude-")) {
        s = s[7..];
    }
    // Strip date suffix (e.g., "-20250929", "-20251101")
    // Look for -YYYYMMDD at the end (9 chars: dash + 8 digits)
    if (s.len >= 9) {
        const suffix_start = s.len - 9;
        if (s[suffix_start] == '-') {
            var all_digits = true;
            for (s[suffix_start + 1 ..]) |c| {
                if (c < '0' or c > '9') {
                    all_digits = false;
                    break;
                }
            }
            if (all_digits) {
                s = s[0..suffix_start];
            }
        }
    }
    return pool.put(s);
}

/// Format a model list as multi-line "- name" entries for the first model,
/// returning just the first line. Additional model lines are added as separate rows.
fn formatFirstModel(pool: *CellPool, models: []const []const u8) []const u8 {
    if (models.len == 0) return "";
    return pool.fmt("- {s}", .{shortenModelName(pool, models[0])});
}

fn joinModels(pool: *CellPool, models: []const []const u8) []const u8 {
    if (models.len == 0) return "";
    const start = pool.pos;
    for (models, 0..) |m, i| {
        if (i > 0) {
            _ = pool.put(", ");
        }
        _ = shortenModelName(pool, m);
    }
    return pool.buf[start..pool.pos];
}

fn aggregatedColumns(period_label: []const u8, column_level: types.ColumnLevel) struct { cols: [MAX_COLS]Column, count: u8 } {
    var result: [MAX_COLS]Column = undefined;
    var n: u8 = 0;
    const L = Alignment.left;
    const R = Alignment.right;

    result[n] = .{ .name = period_label, .alignment = L };
    n += 1;
    result[n] = .{ .name = "Models", .alignment = L };
    n += 1;

    switch (column_level) {
        .full => {
            result[n] = .{ .name = "Input", .alignment = R };
            n += 1;
            result[n] = .{ .name = "Output", .alignment = R };
            n += 1;
            result[n] = .{ .name = "Cache Create", .alignment = R };
            n += 1;
            result[n] = .{ .name = "Cache Read", .alignment = R };
            n += 1;
            result[n] = .{ .name = "Total Tokens", .alignment = R };
            n += 1;
        },
        .mid => {
            result[n] = .{ .name = "Input", .alignment = R };
            n += 1;
            result[n] = .{ .name = "Output", .alignment = R };
            n += 1;
            result[n] = .{ .name = "Cache Read", .alignment = R };
            n += 1;
        },
        .min => {
            result[n] = .{ .name = "Total Tokens", .alignment = R };
            n += 1;
        },
    }

    result[n] = .{ .name = "Cost (USD)", .alignment = R };
    n += 1;

    return .{ .cols = result, .count = n };
}

/// Helper to add an aggregated data row with numbers based on column level.
fn addAggregatedRow(table: *Table, pool: *CellPool, column_level: types.ColumnLevel, period: []const u8, model: []const u8, in_tok: u64, out_tok: u64, cache_create: u64, cache_read: u64, cost: f64) void {
    const total = in_tok + out_tok + cache_create + cache_read;
    switch (column_level) {
        .full => table.addRow(&.{
            period, model,
            pool.fmtTokens(in_tok), pool.fmtTokens(out_tok),
            pool.fmtTokens(cache_create), pool.fmtTokens(cache_read),
            pool.fmtTokens(total), pool.fmtCurrency(cost),
        }),
        .mid => table.addRow(&.{
            period, model,
            pool.fmtTokens(in_tok), pool.fmtTokens(out_tok),
            pool.fmtTokens(cache_read), pool.fmtCurrency(cost),
        }),
        .min => table.addRow(&.{
            period, model,
            pool.fmtTokens(total), pool.fmtCurrency(cost),
        }),
    }
}

/// Helper to add a continuation row (empty period and numbers) for multi-line model display.
fn addModelContinuationRow(table: *Table, column_level: types.ColumnLevel, model: []const u8) void {
    switch (column_level) {
        .full => table.addRow(&.{ "", model, "", "", "", "", "", "" }),
        .mid => table.addRow(&.{ "", model, "", "", "", "" }),
        .min => table.addRow(&.{ "", model, "", "" }),
    }
}

/// Writes an aggregated table (daily/weekly/monthly) to the writer.
pub fn writeAggregatedTable(
    w: *Writer,
    items: []const types.AggregatedUsage,
    totals: types.Totals,
    column_level: types.ColumnLevel,
    period_label: []const u8,
    breakdown: bool,
) Writer.Error!void {
    const col_def = aggregatedColumns(period_label, column_level);
    var table = Table.init(col_def.cols[0..col_def.count]);
    var pool = CellPool.init();

    for (items) |item| {
        if (breakdown) {
            // With breakdown: each model gets its own row with numbers
            for (item.model_breakdowns, 0..) |mb, mi| {
                const label = pool.fmt("- {s}", .{shortenModelName(&pool, mb.model_name)});
                const period = if (mi == 0) item.period else "";
                addAggregatedRow(&table, &pool, column_level, period, label, mb.input_tokens, mb.output_tokens, mb.cache_creation_tokens, mb.cache_read_tokens, mb.cost);
            }
        } else {
            // Without breakdown: period row with totals, models listed below
            const first_model = formatFirstModel(&pool, item.models_used);
            addAggregatedRow(&table, &pool, column_level, item.period, first_model, item.input_tokens, item.output_tokens, item.cache_creation_tokens, item.cache_read_tokens, item.total_cost);

            if (item.models_used.len > 1) {
                for (item.models_used[1..]) |model| {
                    const model_str = pool.fmt("- {s}", .{shortenModelName(&pool, model)});
                    addModelContinuationRow(&table, column_level, model_str);
                }
            }
        }

        table.addSeparator();
    }

    // Totals row
    addAggregatedRow(&table, &pool, column_level, "Total", "", totals.input_tokens, totals.output_tokens, totals.cache_creation_tokens, totals.cache_read_tokens, totals.total_cost);

    try table.render(w);
}

fn sessionColumns(column_level: types.ColumnLevel) struct { cols: [MAX_COLS]Column, count: u8 } {
    var result: [MAX_COLS]Column = undefined;
    var n: u8 = 0;
    const L = Alignment.left;
    const R = Alignment.right;

    result[n] = .{ .name = "Session", .alignment = L };
    n += 1;

    switch (column_level) {
        .full => {
            result[n] = .{ .name = "Models", .alignment = L };
            n += 1;
            result[n] = .{ .name = "Input", .alignment = R };
            n += 1;
            result[n] = .{ .name = "Output", .alignment = R };
            n += 1;
            result[n] = .{ .name = "Cache Create", .alignment = R };
            n += 1;
            result[n] = .{ .name = "Cache Read", .alignment = R };
            n += 1;
            result[n] = .{ .name = "Total Tokens", .alignment = R };
            n += 1;
            result[n] = .{ .name = "Cost (USD)", .alignment = R };
            n += 1;
        },
        .mid => {
            result[n] = .{ .name = "Models", .alignment = L };
            n += 1;
            result[n] = .{ .name = "Input", .alignment = R };
            n += 1;
            result[n] = .{ .name = "Output", .alignment = R };
            n += 1;
            result[n] = .{ .name = "Cache Read", .alignment = R };
            n += 1;
            result[n] = .{ .name = "Cost (USD)", .alignment = R };
            n += 1;
        },
        .min => {
            result[n] = .{ .name = "Models", .alignment = L };
            n += 1;
            result[n] = .{ .name = "Total Tokens", .alignment = R };
            n += 1;
            result[n] = .{ .name = "Cost (USD)", .alignment = R };
            n += 1;
        },
    }

    result[n] = .{ .name = "Project", .alignment = L };
    n += 1;
    result[n] = .{ .name = "Last Active", .alignment = L };
    n += 1;

    return .{ .cols = result, .count = n };
}

fn truncateSessionId(pool: *CellPool, session_id: []const u8) []const u8 {
    if (session_id.len <= 8) return session_id;
    return pool.put(session_id[session_id.len - 8 ..]);
}

fn projectBasename(path: []const u8) []const u8 {
    if (path.len == 0) return "";
    // Find last '/' that isn't trailing
    var end = path.len;
    while (end > 0 and path[end - 1] == '/') end -= 1;
    if (end == 0) return "/";
    var i = end;
    while (i > 0) : (i -= 1) {
        if (path[i - 1] == '/') return path[i..end];
    }
    return path[0..end];
}

/// Writes a session table to the writer.
pub fn writeSessionTable(
    w: *Writer,
    items: []const types.SessionUsage,
    totals: types.Totals,
    column_level: types.ColumnLevel,
    breakdown: bool,
) Writer.Error!void {
    const col_def = sessionColumns(column_level);
    var table = Table.init(col_def.cols[0..col_def.count]);
    var pool = CellPool.init();

    for (items) |item| {
        const session_str = truncateSessionId(&pool, item.session_id);
        const project_str = projectBasename(item.project_path);

        if (breakdown) {
            // With breakdown: each model gets its own row with numbers
            for (item.model_breakdowns, 0..) |mb, mi| {
                const mb_total = mb.input_tokens + mb.output_tokens +
                    mb.cache_creation_tokens + mb.cache_read_tokens;
                const label = pool.fmt("- {s}", .{shortenModelName(&pool, mb.model_name)});
                const sess = if (mi == 0) session_str else @as([]const u8, "");
                const proj = if (mi == 0) project_str else @as([]const u8, "");
                const act = if (mi == 0) item.last_activity else @as([]const u8, "");
                switch (column_level) {
                    .full => table.addRow(&.{ sess, label, pool.fmtTokens(mb.input_tokens), pool.fmtTokens(mb.output_tokens), pool.fmtTokens(mb.cache_creation_tokens), pool.fmtTokens(mb.cache_read_tokens), pool.fmtTokens(mb_total), pool.fmtCurrency(mb.cost), proj, act }),
                    .mid => table.addRow(&.{ sess, label, pool.fmtTokens(mb.input_tokens), pool.fmtTokens(mb.output_tokens), pool.fmtTokens(mb.cache_read_tokens), pool.fmtCurrency(mb.cost), proj, act }),
                    .min => table.addRow(&.{ sess, label, pool.fmtTokens(mb_total), pool.fmtCurrency(mb.cost), proj, act }),
                }
            }
        } else {
            // Without breakdown: single row per session with totals
            const total = item.input_tokens + item.output_tokens +
                item.cache_creation_tokens + item.cache_read_tokens;
            const models_str = joinModels(&pool, item.models_used);
            switch (column_level) {
                .full => table.addRow(&.{ session_str, models_str, pool.fmtTokens(item.input_tokens), pool.fmtTokens(item.output_tokens), pool.fmtTokens(item.cache_creation_tokens), pool.fmtTokens(item.cache_read_tokens), pool.fmtTokens(total), pool.fmtCurrency(item.total_cost), project_str, item.last_activity }),
                .mid => table.addRow(&.{ session_str, models_str, pool.fmtTokens(item.input_tokens), pool.fmtTokens(item.output_tokens), pool.fmtTokens(item.cache_read_tokens), pool.fmtCurrency(item.total_cost), project_str, item.last_activity }),
                .min => table.addRow(&.{ session_str, models_str, pool.fmtTokens(total), pool.fmtCurrency(item.total_cost), project_str, item.last_activity }),
            }
        }
    }

    // Totals row
    table.addSeparator();
    switch (column_level) {
        .full => table.addRow(&.{ "Total", "", pool.fmtTokens(totals.input_tokens), pool.fmtTokens(totals.output_tokens), pool.fmtTokens(totals.cache_creation_tokens), pool.fmtTokens(totals.cache_read_tokens), pool.fmtTokens(totals.total_tokens), pool.fmtCurrency(totals.total_cost), "", "" }),
        .mid => table.addRow(&.{ "Total", "", pool.fmtTokens(totals.input_tokens), pool.fmtTokens(totals.output_tokens), pool.fmtTokens(totals.cache_read_tokens), pool.fmtCurrency(totals.total_cost), "", "" }),
        .min => table.addRow(&.{ "Total", "", pool.fmtTokens(totals.total_tokens), pool.fmtCurrency(totals.total_cost), "", "" }),
    }

    try table.render(w);
}

fn formatBlockTime(pool: *CellPool, epoch_ms: i64, tz_offset: i32) []const u8 {
    const c = date.epochMillisToComponents(epoch_ms, tz_offset);
    return pool.fmt("{d:0>4}-{d:0>2}-{d:0>2} {d:0>2}:{d:0>2}", .{
        c.year, c.month, c.day, c.hour, c.minute,
    });
}

fn formatDuration(pool: *CellPool, start_ms: i64, end_ms: i64) []const u8 {
    const diff_ms = end_ms - start_ms;
    if (diff_ms < 0) return "0m";
    const total_mins: u64 = @intCast(@divTrunc(diff_ms, 60_000));
    const hours = total_mins / 60;
    const mins = total_mins % 60;
    if (hours > 0) {
        return pool.fmt("{d}h {d:0>2}m", .{ hours, mins });
    }
    return pool.fmt("{d}m", .{mins});
}

fn formatGapDuration(pool: *CellPool, start_ms: i64, end_ms: i64) []const u8 {
    const diff_ms = end_ms - start_ms;
    if (diff_ms < 0) return "(0m gap)";
    const total_mins: u64 = @intCast(@divTrunc(diff_ms, 60_000));
    const hours = total_mins / 60;
    const mins = total_mins % 60;
    if (hours > 0) {
        return pool.fmt("({d}h {d:0>2}m gap)", .{ hours, mins });
    }
    return pool.fmt("({d}m gap)", .{mins});
}

/// Writes a blocks table to the writer.
pub fn writeBlocksTable(
    w: *Writer,
    blocks: []const types.SessionBlock,
    token_limit: ?u64,
    tz_offset: i32,
) Writer.Error!void {
    var cols_buf: [MAX_COLS]Column = undefined;
    var n: u8 = 0;
    const L = Alignment.left;
    const R = Alignment.right;

    cols_buf[n] = .{ .name = "Block Start", .alignment = L };
    n += 1;
    cols_buf[n] = .{ .name = "Duration", .alignment = L };
    n += 1;
    cols_buf[n] = .{ .name = "Models", .alignment = L };
    n += 1;
    cols_buf[n] = .{ .name = "Tokens", .alignment = R };
    n += 1;
    cols_buf[n] = .{ .name = "Cost (USD)", .alignment = R };
    n += 1;
    if (token_limit != null) {
        cols_buf[n] = .{ .name = "%", .alignment = R };
        n += 1;
    }

    var table = Table.init(cols_buf[0..n]);
    var pool = CellPool.init();
    const has_limit = token_limit != null;

    for (blocks) |block| {
        if (block.is_gap) {
            const gap_str = formatGapDuration(&pool, block.start_time, block.end_time);
            if (has_limit) {
                table.addRow(&.{ gap_str, "", "", "", "", "" });
            } else {
                table.addRow(&.{ gap_str, "", "", "", "" });
            }
            continue;
        }

        const time_str = formatBlockTime(&pool, block.start_time, tz_offset);
        const actual_end = block.actual_end_time orelse block.end_time;
        const dur_str = if (block.is_active)
            pool.fmt("ACTIVE {s}", .{formatDuration(&pool, block.start_time, actual_end)})
        else
            formatDuration(&pool, block.start_time, actual_end);
        const models_str = joinModels(&pool, block.models);
        const tokens_str = pool.fmtTokens(block.totalTokens());
        const cost_str = pool.fmtCurrency(block.cost_usd);

        if (has_limit) {
            const pct = block.totalTokens() * 100 / token_limit.?;
            const pct_str = pool.fmt("{d}%", .{pct});
            table.addRow(&.{ time_str, dur_str, models_str, tokens_str, cost_str, pct_str });
        } else {
            table.addRow(&.{ time_str, dur_str, models_str, tokens_str, cost_str });
        }
    }

    try table.render(w);
}

/// Writes project-grouped aggregated tables.
/// Items are grouped by their .project field. Each group gets a header and its own table.
/// A grand totals table is printed at the end.
pub fn writeProjectGroupedTable(
    w: *Writer,
    items: []const types.AggregatedUsage,
    totals: types.Totals,
    column_level: types.ColumnLevel,
    period_label: []const u8,
    breakdown: bool,
) Writer.Error!void {
    // Collect unique projects in order of first appearance
    var seen: [256][]const u8 = undefined;
    var seen_count: usize = 0;

    for (items) |item| {
        const proj = item.project orelse continue;
        var found = false;
        for (seen[0..seen_count]) |s| {
            if (std.mem.eql(u8, s, proj)) {
                found = true;
                break;
            }
        }
        if (!found and seen_count < 256) {
            seen[seen_count] = proj;
            seen_count += 1;
        }
    }

    // Render a table per project
    for (seen[0..seen_count], 0..) |proj, pi| {
        if (pi > 0) try w.writeByte('\n');
        try w.print("Project: {s}\n", .{proj});

        // Count items for this project
        var count: usize = 0;
        for (items) |item| {
            const ip = item.project orelse continue;
            if (std.mem.eql(u8, ip, proj)) count += 1;
        }

        // Build per-project items slice (using a small inline buffer)
        var proj_items: [MAX_ROWS]types.AggregatedUsage = undefined;
        var proj_count: usize = 0;
        var proj_totals = types.Totals{
            .input_tokens = 0,
            .output_tokens = 0,
            .cache_creation_tokens = 0,
            .cache_read_tokens = 0,
            .total_tokens = 0,
            .total_cost = 0.0,
        };

        for (items) |item| {
            const ip = item.project orelse continue;
            if (std.mem.eql(u8, ip, proj)) {
                proj_items[proj_count] = item;
                proj_count += 1;
                proj_totals.input_tokens += item.input_tokens;
                proj_totals.output_tokens += item.output_tokens;
                proj_totals.cache_creation_tokens += item.cache_creation_tokens;
                proj_totals.cache_read_tokens += item.cache_read_tokens;
                proj_totals.total_tokens += item.input_tokens + item.output_tokens +
                    item.cache_creation_tokens + item.cache_read_tokens;
                proj_totals.total_cost += item.total_cost;
            }
        }

        try writeAggregatedTable(w, proj_items[0..proj_count], proj_totals, column_level, period_label, breakdown);
    }

    // Grand totals
    if (seen_count > 1) {
        try w.writeAll("\nTotals (all projects):\n");
        var pool = CellPool.init();
        const grand_cols = [_]Column{
            .{ .name = "Total", .alignment = .left },
            .{ .name = "Cost", .alignment = .right },
        };
        var grand_table = Table.init(&grand_cols);
        grand_table.addRow(&.{ "", pool.fmtCurrency(totals.total_cost) });
        try grand_table.render(w);
    }
}

// =============================================================================
// Tests
// =============================================================================

const testing = std.testing;

fn renderToString(table: *const Table) ![]u8 {
    var aw: std.Io.Writer.Allocating = .init(testing.allocator);
    errdefer aw.deinit();
    try table.render(&aw.writer);
    return aw.toOwnedSlice();
}

test "Table: column widths from headers" {
    const cols = [_]Column{
        .{ .name = "Name", .alignment = .left },
        .{ .name = "Amount", .alignment = .right },
    };
    var t = Table.init(&cols);
    t.addRow(&.{ "A", "1" });

    const widths = t.calculateWidths();
    try testing.expectEqual(@as(usize, 4), widths[0]); // "Name" = 4
    try testing.expectEqual(@as(usize, 6), widths[1]); // "Amount" = 6
}

test "Table: column widths from data" {
    const cols = [_]Column{
        .{ .name = "X", .alignment = .left },
        .{ .name = "Y", .alignment = .right },
    };
    var t = Table.init(&cols);
    t.addRow(&.{ "Hello World", "99" });

    const widths = t.calculateWidths();
    try testing.expectEqual(@as(usize, 11), widths[0]); // "Hello World" = 11
    try testing.expectEqual(@as(usize, 2), widths[1]); // "99" > "Y"
}

test "Table: render simple table" {
    const cols = [_]Column{
        .{ .name = "Name", .alignment = .left },
        .{ .name = "Cost", .alignment = .right },
    };
    var t = Table.init(&cols);
    t.addRow(&.{ "Jan", "$1.50" });
    t.addRow(&.{ "Feb", "$12.00" });

    const output = try renderToString(&t);
    defer testing.allocator.free(output);

    const expected =
        \\┌──────┬────────┐
        \\│ Name │   Cost │
        \\├──────┼────────┤
        \\│ Jan  │  $1.50 │
        \\│ Feb  │ $12.00 │
        \\└──────┴────────┘
        \\
    ;
    try testing.expectEqualStrings(expected, output);
}

test "Table: render with separator before totals" {
    const cols = [_]Column{
        .{ .name = "Date", .alignment = .left },
        .{ .name = "Total", .alignment = .right },
    };
    var t = Table.init(&cols);
    t.addRow(&.{ "2026-01", "100" });
    t.addRow(&.{ "2026-02", "200" });
    t.addSeparator();
    t.addRow(&.{ "Total", "300" });

    const output = try renderToString(&t);
    defer testing.allocator.free(output);

    const expected =
        \\┌─────────┬───────┐
        \\│ Date    │ Total │
        \\├─────────┼───────┤
        \\│ 2026-01 │   100 │
        \\│ 2026-02 │   200 │
        \\├─────────┼───────┤
        \\│ Total   │   300 │
        \\└─────────┴───────┘
        \\
    ;
    try testing.expectEqualStrings(expected, output);
}

test "Table: empty table renders headers only" {
    const cols = [_]Column{
        .{ .name = "A", .alignment = .left },
        .{ .name = "B", .alignment = .left },
    };
    const t = Table.init(&cols);

    const output = try renderToString(&t);
    defer testing.allocator.free(output);

    const expected =
        \\┌───┬───┐
        \\│ A │ B │
        \\├───┼───┤
        \\└───┴───┘
        \\
    ;
    try testing.expectEqualStrings(expected, output);
}

fn writeToString(comptime writeFn: anytype, args: anytype) ![]u8 {
    var aw: std.Io.Writer.Allocating = .init(testing.allocator);
    errdefer aw.deinit();
    try @call(.auto, writeFn, .{&aw.writer} ++ args);
    return aw.toOwnedSlice();
}

test "writeAggregatedTable: min columns" {
    const models_used = [_][]const u8{"opus"};
    const items = [_]types.AggregatedUsage{
        .{
            .period = "2026-02",
            .input_tokens = 1000,
            .output_tokens = 200,
            .cache_creation_tokens = 50,
            .cache_read_tokens = 300,
            .total_cost = 1.50,
            .models_used = &models_used,
            .model_breakdowns = &.{},
            .project = null,
        },
    };
    const totals = types.Totals{
        .input_tokens = 1000,
        .output_tokens = 200,
        .cache_creation_tokens = 50,
        .cache_read_tokens = 300,
        .total_tokens = 1550,
        .total_cost = 1.50,
    };

    const output = try writeToString(writeAggregatedTable, .{ &items, totals, .min, "Month", false });
    defer testing.allocator.free(output);

    // Verify structure: 4 columns, has totals separator
    try testing.expect(std.mem.indexOf(u8, output, "Month") != null);
    try testing.expect(std.mem.indexOf(u8, output, "Models") != null);
    try testing.expect(std.mem.indexOf(u8, output, "Total Tokens") != null);
    try testing.expect(std.mem.indexOf(u8, output, "Cost (USD)") != null);
    try testing.expect(std.mem.indexOf(u8, output, "1,550") != null);
    try testing.expect(std.mem.indexOf(u8, output, "$1.50") != null);
    // Models shown with "- " prefix
    try testing.expect(std.mem.indexOf(u8, output, "- opus") != null);
    // Should NOT have Input/Output/Cache columns
    try testing.expect(std.mem.indexOf(u8, output, "Input") == null);
    try testing.expect(std.mem.indexOf(u8, output, "Output") == null);
}

test "writeAggregatedTable: full columns with breakdown" {
    const models_used = [_][]const u8{ "opus", "sonnet" };
    const breakdowns = [_]types.ModelBreakdown{
        .{ .model_name = "opus", .input_tokens = 700, .output_tokens = 100, .cache_creation_tokens = 30, .cache_read_tokens = 200, .cost = 1.00 },
        .{ .model_name = "sonnet", .input_tokens = 300, .output_tokens = 100, .cache_creation_tokens = 20, .cache_read_tokens = 100, .cost = 0.50 },
    };
    const items = [_]types.AggregatedUsage{
        .{
            .period = "2026-02-15",
            .input_tokens = 1000,
            .output_tokens = 200,
            .cache_creation_tokens = 50,
            .cache_read_tokens = 300,
            .total_cost = 1.50,
            .models_used = &models_used,
            .model_breakdowns = &breakdowns,
            .project = null,
        },
    };
    const totals = types.Totals{
        .input_tokens = 1000,
        .output_tokens = 200,
        .cache_creation_tokens = 50,
        .cache_read_tokens = 300,
        .total_tokens = 1550,
        .total_cost = 1.50,
    };

    const output = try writeToString(writeAggregatedTable, .{ &items, totals, .full, "Date", true });
    defer testing.allocator.free(output);

    // Has all full columns
    try testing.expect(std.mem.indexOf(u8, output, "Input") != null);
    try testing.expect(std.mem.indexOf(u8, output, "Output") != null);
    try testing.expect(std.mem.indexOf(u8, output, "Cache Create") != null);
    try testing.expect(std.mem.indexOf(u8, output, "Cache Read") != null);
    // Has breakdown rows with "- " prefix and numbers
    try testing.expect(std.mem.indexOf(u8, output, "- opus") != null);
    try testing.expect(std.mem.indexOf(u8, output, "- sonnet") != null);
    // Breakdown rows have per-model numbers
    try testing.expect(std.mem.indexOf(u8, output, "700") != null);
    try testing.expect(std.mem.indexOf(u8, output, "300") != null);
}

test "writeAggregatedTable: mid columns" {
    const items = [_]types.AggregatedUsage{
        .{
            .period = "2026-W07",
            .input_tokens = 500,
            .output_tokens = 100,
            .cache_creation_tokens = 25,
            .cache_read_tokens = 150,
            .total_cost = 0.75,
            .models_used = &.{},
            .model_breakdowns = &.{},
            .project = null,
        },
    };
    const totals = types.Totals{
        .input_tokens = 500,
        .output_tokens = 100,
        .cache_creation_tokens = 25,
        .cache_read_tokens = 150,
        .total_tokens = 775,
        .total_cost = 0.75,
    };

    const output = try writeToString(writeAggregatedTable, .{ &items, totals, .mid, "Week", false });
    defer testing.allocator.free(output);

    // Mid has Input, Output, Cache Read but NOT Cache Create or Total column
    try testing.expect(std.mem.indexOf(u8, output, "Input") != null);
    try testing.expect(std.mem.indexOf(u8, output, "Output") != null);
    try testing.expect(std.mem.indexOf(u8, output, "Cache Read") != null);
    try testing.expect(std.mem.indexOf(u8, output, "Cache Create") == null);
}

test "shortenModelName: strips claude prefix and date suffix" {
    var pool = CellPool.init();
    try testing.expectEqualStrings("opus-4-6", shortenModelName(&pool, "claude-opus-4-6"));
    try testing.expectEqualStrings("sonnet-4-5", shortenModelName(&pool, "claude-sonnet-4-5-20250929"));
    try testing.expectEqualStrings("haiku-4-5", shortenModelName(&pool, "claude-haiku-4-5-20251001"));
    try testing.expectEqualStrings("<synthetic>", shortenModelName(&pool, "<synthetic>"));
    try testing.expectEqualStrings("opus-4-5", shortenModelName(&pool, "claude-opus-4-5-20251101"));
}

test "projectBasename: typical path" {
    try testing.expectEqualStrings("myproject", projectBasename("/home/user/myproject"));
}

test "projectBasename: trailing slash" {
    try testing.expectEqualStrings("myproject", projectBasename("/home/user/myproject/"));
}

test "projectBasename: root" {
    try testing.expectEqualStrings("/", projectBasename("/"));
}

test "projectBasename: empty" {
    try testing.expectEqualStrings("", projectBasename(""));
}

test "projectBasename: no slash" {
    try testing.expectEqualStrings("myproject", projectBasename("myproject"));
}

test "writeSessionTable: full columns" {
    const models_used = [_][]const u8{"opus"};
    const items = [_]types.SessionUsage{
        .{
            .session_id = "abc-def-1234-5678",
            .project_path = "/home/user/myproject",
            .input_tokens = 1000,
            .output_tokens = 200,
            .cache_creation_tokens = 50,
            .cache_read_tokens = 300,
            .total_cost = 1.50,
            .last_activity = "2026-02-15",
            .models_used = &models_used,
            .model_breakdowns = &.{},
        },
    };
    const totals = types.Totals{
        .input_tokens = 1000,
        .output_tokens = 200,
        .cache_creation_tokens = 50,
        .cache_read_tokens = 300,
        .total_tokens = 1550,
        .total_cost = 1.50,
    };

    const output = try writeToString(writeSessionTable, .{ &items, totals, .full, false });
    defer testing.allocator.free(output);

    // Has session columns
    try testing.expect(std.mem.indexOf(u8, output, "Session") != null);
    try testing.expect(std.mem.indexOf(u8, output, "Project") != null);
    try testing.expect(std.mem.indexOf(u8, output, "Last Active") != null);
    // Truncated session ID (last 8 chars)
    try testing.expect(std.mem.indexOf(u8, output, "234-5678") != null);
    // Project basename
    try testing.expect(std.mem.indexOf(u8, output, "myproject") != null);
    // Date
    try testing.expect(std.mem.indexOf(u8, output, "2026-02-15") != null);
    // Has token columns
    try testing.expect(std.mem.indexOf(u8, output, "Input") != null);
    try testing.expect(std.mem.indexOf(u8, output, "Cost") != null);
}

test "writeSessionTable: min columns" {
    const items = [_]types.SessionUsage{
        .{
            .session_id = "short",
            .project_path = "/proj",
            .input_tokens = 500,
            .output_tokens = 100,
            .cache_creation_tokens = 0,
            .cache_read_tokens = 0,
            .total_cost = 0.50,
            .last_activity = "2026-02-15",
            .models_used = &.{},
            .model_breakdowns = &.{},
        },
    };
    const totals = types.Totals{
        .input_tokens = 500,
        .output_tokens = 100,
        .cache_creation_tokens = 0,
        .cache_read_tokens = 0,
        .total_tokens = 600,
        .total_cost = 0.50,
    };

    const output = try writeToString(writeSessionTable, .{ &items, totals, .min, false });
    defer testing.allocator.free(output);

    // Min mode: Session, Models, Total Tokens, Cost, Project, Last Active
    try testing.expect(std.mem.indexOf(u8, output, "Session") != null);
    try testing.expect(std.mem.indexOf(u8, output, "Total Tokens") != null);
    try testing.expect(std.mem.indexOf(u8, output, "Project") != null);
    // Should NOT have Input/Output columns
    try testing.expect(std.mem.indexOf(u8, output, "Input") == null);
    try testing.expect(std.mem.indexOf(u8, output, "Cache Read") == null);
    // Short session ID used as-is
    try testing.expect(std.mem.indexOf(u8, output, "short") != null);
}

test "writeBlocksTable: basic block" {
    const models = [_][]const u8{"opus"};
    const blocks = [_]types.SessionBlock{
        .{
            .id = "2026-02-15T10:00:00.000Z",
            .start_time = 1739610000000, // 2026-02-15T10:00:00Z
            .end_time = 1739628000000, // 2026-02-15T15:00:00Z
            .actual_end_time = 1739617200000, // 2026-02-15T12:00:00Z
            .is_active = false,
            .is_gap = false,
            .entry_count = 5,
            .input_tokens = 5000,
            .output_tokens = 1000,
            .cache_creation_tokens = 200,
            .cache_read_tokens = 800,
            .cost_usd = 0.50,
            .models = &models,
            .burn_rate = null,
            .projection = null,
        },
    };

    const output = try writeToString(writeBlocksTable, .{ &blocks, @as(?u64, null), @as(i32, 0) });
    defer testing.allocator.free(output);

    // Has block columns
    try testing.expect(std.mem.indexOf(u8, output, "Block Start") != null);
    try testing.expect(std.mem.indexOf(u8, output, "Duration") != null);
    try testing.expect(std.mem.indexOf(u8, output, "Models") != null);
    try testing.expect(std.mem.indexOf(u8, output, "Tokens") != null);
    try testing.expect(std.mem.indexOf(u8, output, "Cost") != null);
    // No % column without token_limit
    try testing.expect(std.mem.indexOf(u8, output, " % ") == null);
    // Has formatted data
    try testing.expect(std.mem.indexOf(u8, output, "7,000") != null); // total tokens
    try testing.expect(std.mem.indexOf(u8, output, "$0.50") != null);
    try testing.expect(std.mem.indexOf(u8, output, "opus") != null);
    try testing.expect(std.mem.indexOf(u8, output, "2h") != null); // 2 hour duration
}

test "writeBlocksTable: with gap and active block" {
    const models = [_][]const u8{"sonnet"};
    const blocks = [_]types.SessionBlock{
        .{
            .id = "gap",
            .start_time = 1739600000000,
            .end_time = 1739610000000,
            .actual_end_time = null,
            .is_active = false,
            .is_gap = true,
            .entry_count = 0,
            .input_tokens = 0,
            .output_tokens = 0,
            .cache_creation_tokens = 0,
            .cache_read_tokens = 0,
            .cost_usd = 0.0,
            .models = &.{},
            .burn_rate = null,
            .projection = null,
        },
        .{
            .id = "2026-02-15T12:00:00.000Z",
            .start_time = 1739617200000,
            .end_time = 1739635200000,
            .actual_end_time = 1739621700000,
            .is_active = true,
            .is_gap = false,
            .entry_count = 10,
            .input_tokens = 3000,
            .output_tokens = 500,
            .cache_creation_tokens = 100,
            .cache_read_tokens = 400,
            .cost_usd = 0.30,
            .models = &models,
            .burn_rate = null,
            .projection = null,
        },
    };

    const output = try writeToString(writeBlocksTable, .{ &blocks, @as(?u64, null), @as(i32, 0) });
    defer testing.allocator.free(output);

    // Has gap indicator
    try testing.expect(std.mem.indexOf(u8, output, "gap)") != null);
    // Has ACTIVE indicator
    try testing.expect(std.mem.indexOf(u8, output, "ACTIVE") != null);
}

test "writeBlocksTable: with token limit shows percentage column" {
    const models = [_][]const u8{"opus"};
    const blocks = [_]types.SessionBlock{
        .{
            .id = "2026-02-15T10:00:00.000Z",
            .start_time = 1739610000000,
            .end_time = 1739628000000,
            .actual_end_time = 1739617200000,
            .is_active = false,
            .is_gap = false,
            .entry_count = 5,
            .input_tokens = 25000,
            .output_tokens = 5000,
            .cache_creation_tokens = 1000,
            .cache_read_tokens = 4000,
            .cost_usd = 2.50,
            .models = &models,
            .burn_rate = null,
            .projection = null,
        },
    };

    const output = try writeToString(writeBlocksTable, .{ &blocks, @as(?u64, 100000), @as(i32, 0) });
    defer testing.allocator.free(output);

    // Has % column header
    try testing.expect(std.mem.indexOf(u8, output, "%") != null);
    // 35000 out of 100000 = 35%
    try testing.expect(std.mem.indexOf(u8, output, "35%") != null);
}

test "writeProjectGroupedTable: groups by project" {
    const items = [_]types.AggregatedUsage{
        .{
            .period = "2026-02-15",
            .input_tokens = 100,
            .output_tokens = 10,
            .cache_creation_tokens = 0,
            .cache_read_tokens = 0,
            .total_cost = 0.01,
            .models_used = &.{},
            .model_breakdowns = &.{},
            .project = "project-a",
        },
        .{
            .period = "2026-02-15",
            .input_tokens = 200,
            .output_tokens = 20,
            .cache_creation_tokens = 0,
            .cache_read_tokens = 0,
            .total_cost = 0.02,
            .models_used = &.{},
            .model_breakdowns = &.{},
            .project = "project-b",
        },
    };
    const totals = types.Totals{
        .input_tokens = 300,
        .output_tokens = 30,
        .cache_creation_tokens = 0,
        .cache_read_tokens = 0,
        .total_tokens = 330,
        .total_cost = 0.03,
    };

    const output = try writeToString(writeProjectGroupedTable, .{ &items, totals, .min, "Date", false });
    defer testing.allocator.free(output);

    // Has project headers
    try testing.expect(std.mem.indexOf(u8, output, "Project: project-a") != null);
    try testing.expect(std.mem.indexOf(u8, output, "Project: project-b") != null);
    // Has grand totals
    try testing.expect(std.mem.indexOf(u8, output, "Totals (all projects)") != null);
    try testing.expect(std.mem.indexOf(u8, output, "$0.03") != null);
}
