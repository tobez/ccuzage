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
