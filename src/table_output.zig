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
            try writePadded(w, self.columns[c].name, widths[c], .left);
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

fn joinModels(pool: *CellPool, models: []const []const u8) []const u8 {
    if (models.len == 0) return "";
    const start = pool.pos;
    for (models, 0..) |m, i| {
        if (i > 0) {
            _ = pool.put(", ");
        }
        _ = pool.put(m);
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
            result[n] = .{ .name = "Total", .alignment = R };
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

    result[n] = .{ .name = "Cost", .alignment = R };
    n += 1;

    return .{ .cols = result, .count = n };
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
        const total = item.input_tokens + item.output_tokens +
            item.cache_creation_tokens + item.cache_read_tokens;
        const models_str = joinModels(&pool, item.models_used);

        switch (column_level) {
            .full => table.addRow(&.{
                item.period,
                models_str,
                pool.fmtTokens(item.input_tokens),
                pool.fmtTokens(item.output_tokens),
                pool.fmtTokens(item.cache_creation_tokens),
                pool.fmtTokens(item.cache_read_tokens),
                pool.fmtTokens(total),
                pool.fmtCurrency(item.total_cost),
            }),
            .mid => table.addRow(&.{
                item.period,
                models_str,
                pool.fmtTokens(item.input_tokens),
                pool.fmtTokens(item.output_tokens),
                pool.fmtTokens(item.cache_read_tokens),
                pool.fmtCurrency(item.total_cost),
            }),
            .min => table.addRow(&.{
                item.period,
                models_str,
                pool.fmtTokens(total),
                pool.fmtCurrency(item.total_cost),
            }),
        }

        if (breakdown) {
            for (item.model_breakdowns) |mb| {
                const mb_total = mb.input_tokens + mb.output_tokens +
                    mb.cache_creation_tokens + mb.cache_read_tokens;
                const label = pool.fmt("  \xe2\x94\x94\xe2\x94\x80 {s}", .{mb.model_name});
                switch (column_level) {
                    .full => table.addRow(&.{
                        label,
                        "",
                        pool.fmtTokens(mb.input_tokens),
                        pool.fmtTokens(mb.output_tokens),
                        pool.fmtTokens(mb.cache_creation_tokens),
                        pool.fmtTokens(mb.cache_read_tokens),
                        pool.fmtTokens(mb_total),
                        pool.fmtCurrency(mb.cost),
                    }),
                    .mid => table.addRow(&.{
                        label,
                        "",
                        pool.fmtTokens(mb.input_tokens),
                        pool.fmtTokens(mb.output_tokens),
                        pool.fmtTokens(mb.cache_read_tokens),
                        pool.fmtCurrency(mb.cost),
                    }),
                    .min => table.addRow(&.{
                        label,
                        "",
                        pool.fmtTokens(mb_total),
                        pool.fmtCurrency(mb.cost),
                    }),
                }
            }
        }
    }

    // Totals row
    table.addSeparator();
    switch (column_level) {
        .full => table.addRow(&.{
            "Total",
            "",
            pool.fmtTokens(totals.input_tokens),
            pool.fmtTokens(totals.output_tokens),
            pool.fmtTokens(totals.cache_creation_tokens),
            pool.fmtTokens(totals.cache_read_tokens),
            pool.fmtTokens(totals.total_tokens),
            pool.fmtCurrency(totals.total_cost),
        }),
        .mid => table.addRow(&.{
            "Total",
            "",
            pool.fmtTokens(totals.input_tokens),
            pool.fmtTokens(totals.output_tokens),
            pool.fmtTokens(totals.cache_read_tokens),
            pool.fmtCurrency(totals.total_cost),
        }),
        .min => table.addRow(&.{
            "Total",
            "",
            pool.fmtTokens(totals.total_tokens),
            pool.fmtCurrency(totals.total_cost),
        }),
    }

    try table.render(w);
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
        \\│ Name │ Cost   │
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
    try testing.expect(std.mem.indexOf(u8, output, "Cost") != null);
    try testing.expect(std.mem.indexOf(u8, output, "1,550") != null);
    try testing.expect(std.mem.indexOf(u8, output, "$1.50") != null);
    try testing.expect(std.mem.indexOf(u8, output, "opus") != null);
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
    // Has breakdown rows with └─ prefix
    try testing.expect(std.mem.indexOf(u8, output, "\xe2\x94\x94\xe2\x94\x80 opus") != null);
    try testing.expect(std.mem.indexOf(u8, output, "\xe2\x94\x94\xe2\x94\x80 sonnet") != null);
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
