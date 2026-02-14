// ABOUTME: Entry point for the blazing CLI tool.
// ABOUTME: Parses command-line flags and dispatches to the appropriate action.
const std = @import("std");

const version = "blazing v0.1.0";

pub fn main() !void {
    var stdout_buffer: [4096]u8 = undefined;
    var stdout_writer = std.fs.File.stdout().writer(&stdout_buffer);
    const stdout = &stdout_writer.interface;

    const args = try std.process.argsAlloc(std.heap.smp_allocator);
    defer std.process.argsFree(std.heap.smp_allocator, args);

    if (args.len <= 1) {
        try stdout.print("{s}\n", .{version});
        try stdout.flush();
        return;
    }

    for (args[1..]) |arg| {
        if (std.mem.eql(u8, arg, "--version")) {
            try stdout.print("{s}\n", .{version});
            try stdout.flush();
            return;
        } else if (std.mem.eql(u8, arg, "--help")) {
            try stdout.print(
                \\{s}
                \\
                \\Usage: blazing [options]
                \\
                \\Options:
                \\  --version  Print version and exit
                \\  --help     Print this help and exit
                \\
            , .{version});
            try stdout.flush();
            return;
        }
    }

    try stdout.print("{s}\n", .{version});
    try stdout.flush();
}

test "module compiles" {
    // Verify this module and its dependencies compile successfully.
    _ = version;
}

test {
    _ = @import("date.zig");
    _ = @import("types.zig");
    _ = @import("parser.zig");
    _ = @import("loader.zig");
    _ = @import("aggregate.zig");
    _ = @import("json_output.zig");
}
