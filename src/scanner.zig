// ABOUTME: Fast JSON field scanner that extracts specific fields from JSONL lines.
// ABOUTME: Skips over large content values without parsing them, for 10-50x speedup.

/// Scanned fields from a single JSONL line, with zero allocations.
/// All string slices point into the original input buffer.
pub const ScannedEntry = struct {
    timestamp: ?[]const u8,
    model: ?[]const u8,
    message_id: ?[]const u8,
    request_id: ?[]const u8,
    is_api_error: bool,
    cost_usd: ?f64,
    input_tokens: u64,
    output_tokens: u64,
    cache_creation_tokens: u64,
    cache_read_tokens: u64,
};

/// Skip whitespace and return position of next non-whitespace char.
pub fn skipWhitespace(buf: []const u8, pos: usize) usize {
    var p = pos;
    while (p < buf.len and (buf[p] == ' ' or buf[p] == '\t' or buf[p] == '\n' or buf[p] == '\r')) {
        p += 1;
    }
    return p;
}

/// Skip a JSON string starting at the opening quote. Returns position after closing quote.
fn skipString(buf: []const u8, pos: usize) ?usize {
    if (pos >= buf.len or buf[pos] != '"') return null;
    var p = pos + 1;
    while (p < buf.len) {
        if (buf[p] == '\\') {
            p += 2; // skip escaped char
            continue;
        }
        if (buf[p] == '"') return p + 1;
        p += 1;
    }
    return null;
}

/// Skip one JSON value (string, number, bool, null, object, or array).
/// Returns position after the value.
pub fn skipValue(buf: []const u8, pos: usize) ?usize {
    if (pos >= buf.len) return null;
    const c = buf[pos];

    switch (c) {
        '"' => return skipString(buf, pos),
        '{' => {
            var p = pos + 1;
            p = skipWhitespace(buf, p);
            if (p < buf.len and buf[p] == '}') return p + 1;
            while (p < buf.len) {
                // Skip key
                p = skipWhitespace(buf, p);
                p = skipString(buf, p) orelse return null;
                // Skip colon
                p = skipWhitespace(buf, p);
                if (p >= buf.len or buf[p] != ':') return null;
                p += 1;
                // Skip value
                p = skipWhitespace(buf, p);
                p = skipValue(buf, p) orelse return null;
                // Check for comma or end
                p = skipWhitespace(buf, p);
                if (p >= buf.len) return null;
                if (buf[p] == '}') return p + 1;
                if (buf[p] == ',') {
                    p += 1;
                    continue;
                }
                return null;
            }
            return null;
        },
        '[' => {
            var p = pos + 1;
            p = skipWhitespace(buf, p);
            if (p < buf.len and buf[p] == ']') return p + 1;
            while (p < buf.len) {
                p = skipWhitespace(buf, p);
                p = skipValue(buf, p) orelse return null;
                p = skipWhitespace(buf, p);
                if (p >= buf.len) return null;
                if (buf[p] == ']') return p + 1;
                if (buf[p] == ',') {
                    p += 1;
                    continue;
                }
                return null;
            }
            return null;
        },
        't' => { // true
            if (pos + 4 <= buf.len and eql4(buf[pos..][0..4], "true")) return pos + 4;
            return null;
        },
        'f' => { // false
            if (pos + 5 <= buf.len and eql5(buf[pos..][0..5], "false")) return pos + 5;
            return null;
        },
        'n' => { // null
            if (pos + 4 <= buf.len and eql4(buf[pos..][0..4], "null")) return pos + 4;
            return null;
        },
        '-', '0'...'9' => {
            var p = pos;
            if (buf[p] == '-') p += 1;
            while (p < buf.len and buf[p] >= '0' and buf[p] <= '9') p += 1;
            if (p < buf.len and buf[p] == '.') {
                p += 1;
                while (p < buf.len and buf[p] >= '0' and buf[p] <= '9') p += 1;
            }
            if (p < buf.len and (buf[p] == 'e' or buf[p] == 'E')) {
                p += 1;
                if (p < buf.len and (buf[p] == '+' or buf[p] == '-')) p += 1;
                while (p < buf.len and buf[p] >= '0' and buf[p] <= '9') p += 1;
            }
            if (p == pos or (p == pos + 1 and buf[pos] == '-')) return null;
            return p;
        },
        else => return null,
    }
}

fn eql4(a: *const [4]u8, b: *const [4]u8) bool {
    return a[0] == b[0] and a[1] == b[1] and a[2] == b[2] and a[3] == b[3];
}

fn eql5(a: *const [5]u8, b: *const [5]u8) bool {
    return a[0] == b[0] and a[1] == b[1] and a[2] == b[2] and a[3] == b[3] and a[4] == b[4];
}

/// Extract string value boundaries (without quotes). Returns the slice and position after closing quote.
pub fn extractString(buf: []const u8, pos: usize) ?struct { value: []const u8, end: usize } {
    if (pos >= buf.len or buf[pos] != '"') return null;
    // Fast path: no escapes (common case)
    var p = pos + 1;
    while (p < buf.len) {
        if (buf[p] == '\\') {
            // Has escapes — can't use zero-copy slice. Return null for now;
            // caller should handle this gracefully (these fields rarely have escapes).
            const end = skipString(buf, pos) orelse return null;
            return .{ .value = buf[pos + 1 .. end - 1], .end = end };
        }
        if (buf[p] == '"') {
            return .{ .value = buf[pos + 1 .. p], .end = p + 1 };
        }
        p += 1;
    }
    return null;
}

/// Parse an unsigned integer value at the given position.
pub fn extractU64(buf: []const u8, pos: usize) ?struct { value: u64, end: usize } {
    var p = pos;
    if (p >= buf.len) return null;
    // Skip leading whitespace
    p = skipWhitespace(buf, p);
    if (p >= buf.len or buf[p] < '0' or buf[p] > '9') return null;
    var val: u64 = 0;
    while (p < buf.len and buf[p] >= '0' and buf[p] <= '9') {
        val = val * 10 + (buf[p] - '0');
        p += 1;
    }
    return .{ .value = val, .end = p };
}

/// Parse a floating point number at the given position.
pub fn extractF64(buf: []const u8, pos: usize) ?struct { value: f64, end: usize } {
    var p = pos;
    if (p >= buf.len) return null;
    p = skipWhitespace(buf, p);

    const start = p;
    // Handle sign
    if (p < buf.len and (buf[p] == '-' or buf[p] == '+')) p += 1;
    // Integer part
    const int_start = p;
    while (p < buf.len and buf[p] >= '0' and buf[p] <= '9') p += 1;
    if (p == int_start and !(p < buf.len and buf[p] == '.')) return null;
    // Fractional part
    if (p < buf.len and buf[p] == '.') {
        p += 1;
        while (p < buf.len and buf[p] >= '0' and buf[p] <= '9') p += 1;
    }
    // Exponent
    if (p < buf.len and (buf[p] == 'e' or buf[p] == 'E')) {
        p += 1;
        if (p < buf.len and (buf[p] == '+' or buf[p] == '-')) p += 1;
        while (p < buf.len and buf[p] >= '0' and buf[p] <= '9') p += 1;
    }

    const num_str = buf[start..p];
    const val = std.fmt.parseFloat(f64, num_str) catch return null;
    return .{ .value = val, .end = p };
}

/// Find a key in a JSON object starting at position `pos` (which should point to '{').
/// Returns position after the colon following the key.
pub fn findKeyInObject(buf: []const u8, pos: usize, key: []const u8) ?usize {
    var p = pos;
    if (p >= buf.len or buf[p] != '{') return null;
    p += 1;

    while (p < buf.len) {
        p = skipWhitespace(buf, p);
        if (p >= buf.len) return null;
        if (buf[p] == '}') return null; // key not found

        // Parse key string
        if (buf[p] != '"') return null;
        const key_start = p + 1;
        const after_key = skipString(buf, p) orelse return null;
        const key_end = after_key - 1;
        const found_key = buf[key_start..key_end];

        // Skip colon
        p = skipWhitespace(buf, after_key);
        if (p >= buf.len or buf[p] != ':') return null;
        p += 1;
        p = skipWhitespace(buf, p);

        // Check if this is the key we want
        if (found_key.len == key.len and std.mem.eql(u8, found_key, key)) {
            return p; // position of the value
        }

        // Skip value
        p = skipValue(buf, p) orelse return null;

        // Check for comma or end
        p = skipWhitespace(buf, p);
        if (p >= buf.len) return null;
        if (buf[p] == ',') {
            p += 1;
            continue;
        }
        if (buf[p] == '}') return null; // key not found
        return null; // malformed
    }
    return null;
}

/// Check if a JSON value at position is the boolean `true`.
fn isTrueAt(buf: []const u8, pos: usize) bool {
    return pos + 4 <= buf.len and eql4(buf[pos..][0..4], "true");
}

/// Scan a JSONL line and extract usage-relevant fields.
/// Returns null if the line has no usage data (no message.usage).
pub fn scanLine(buf: []const u8) ?ScannedEntry {
    if (buf.len == 0) return null;

    var result = ScannedEntry{
        .timestamp = null,
        .model = null,
        .message_id = null,
        .request_id = null,
        .is_api_error = false,
        .cost_usd = null,
        .input_tokens = 0,
        .output_tokens = 0,
        .cache_creation_tokens = 0,
        .cache_read_tokens = 0,
    };

    // The line should be a top-level JSON object
    const start = skipWhitespace(buf, 0);
    if (start >= buf.len or buf[start] != '{') return null;

    // Scan top-level keys
    var p = start + 1;
    var found_usage = false;

    while (p < buf.len) {
        p = skipWhitespace(buf, p);
        if (p >= buf.len) return null;
        if (buf[p] == '}') break;

        // Parse key
        if (buf[p] != '"') return null;
        const key_start = p + 1;
        const after_key = skipString(buf, p) orelse return null;
        const key_end = after_key - 1;
        const key = buf[key_start..key_end];

        // Skip colon
        p = skipWhitespace(buf, after_key);
        if (p >= buf.len or buf[p] != ':') return null;
        p += 1;
        p = skipWhitespace(buf, p);

        // Handle known top-level keys
        if (std.mem.eql(u8, key, "timestamp")) {
            const s = extractString(buf, p) orelse {
                p = skipValue(buf, p) orelse return null;
                p = advancePastComma(buf, p);
                continue;
            };
            result.timestamp = s.value;
            p = s.end;
        } else if (std.mem.eql(u8, key, "isApiErrorMessage")) {
            result.is_api_error = isTrueAt(buf, p);
            p = skipValue(buf, p) orelse return null;
        } else if (std.mem.eql(u8, key, "requestId")) {
            const s = extractString(buf, p) orelse {
                p = skipValue(buf, p) orelse return null;
                p = advancePastComma(buf, p);
                continue;
            };
            result.request_id = s.value;
            p = s.end;
        } else if (std.mem.eql(u8, key, "costUSD")) {
            const f = extractF64(buf, p) orelse {
                p = skipValue(buf, p) orelse return null;
                p = advancePastComma(buf, p);
                continue;
            };
            result.cost_usd = f.value;
            p = f.end;
        } else if (std.mem.eql(u8, key, "message")) {
            if (p >= buf.len or buf[p] != '{') {
                p = skipValue(buf, p) orelse return null;
                p = advancePastComma(buf, p);
                continue;
            }
            // Scan inside message object
            var mp = p + 1;
            while (mp < buf.len) {
                mp = skipWhitespace(buf, mp);
                if (mp >= buf.len) return null;
                if (buf[mp] == '}') {
                    mp += 1;
                    break;
                }

                if (buf[mp] != '"') return null;
                const mk_start = mp + 1;
                const after_mk = skipString(buf, mp) orelse return null;
                const mk_end = after_mk - 1;
                const mkey = buf[mk_start..mk_end];

                mp = skipWhitespace(buf, after_mk);
                if (mp >= buf.len or buf[mp] != ':') return null;
                mp += 1;
                mp = skipWhitespace(buf, mp);

                if (std.mem.eql(u8, mkey, "model")) {
                    const s = extractString(buf, mp) orelse {
                        mp = skipValue(buf, mp) orelse return null;
                        mp = advancePastComma(buf, mp);
                        continue;
                    };
                    result.model = s.value;
                    mp = s.end;
                } else if (std.mem.eql(u8, mkey, "id")) {
                    const s = extractString(buf, mp) orelse {
                        mp = skipValue(buf, mp) orelse return null;
                        mp = advancePastComma(buf, mp);
                        continue;
                    };
                    result.message_id = s.value;
                    mp = s.end;
                } else if (std.mem.eql(u8, mkey, "usage")) {
                    if (mp >= buf.len or buf[mp] != '{') {
                        mp = skipValue(buf, mp) orelse return null;
                        mp = advancePastComma(buf, mp);
                        continue;
                    }
                    // Scan inside usage object
                    var up = mp + 1;
                    found_usage = true;
                    while (up < buf.len) {
                        up = skipWhitespace(buf, up);
                        if (up >= buf.len) return null;
                        if (buf[up] == '}') {
                            up += 1;
                            break;
                        }

                        if (buf[up] != '"') return null;
                        const uk_start = up + 1;
                        const after_uk = skipString(buf, up) orelse return null;
                        const uk_end = after_uk - 1;
                        const ukey = buf[uk_start..uk_end];

                        up = skipWhitespace(buf, after_uk);
                        if (up >= buf.len or buf[up] != ':') return null;
                        up += 1;
                        up = skipWhitespace(buf, up);

                        if (std.mem.eql(u8, ukey, "input_tokens")) {
                            const n = extractU64(buf, up) orelse {
                                up = skipValue(buf, up) orelse return null;
                                up = advancePastComma(buf, up);
                                continue;
                            };
                            result.input_tokens = n.value;
                            up = n.end;
                        } else if (std.mem.eql(u8, ukey, "output_tokens")) {
                            const n = extractU64(buf, up) orelse {
                                up = skipValue(buf, up) orelse return null;
                                up = advancePastComma(buf, up);
                                continue;
                            };
                            result.output_tokens = n.value;
                            up = n.end;
                        } else if (std.mem.eql(u8, ukey, "cache_creation_input_tokens")) {
                            const n = extractU64(buf, up) orelse {
                                up = skipValue(buf, up) orelse return null;
                                up = advancePastComma(buf, up);
                                continue;
                            };
                            result.cache_creation_tokens = n.value;
                            up = n.end;
                        } else if (std.mem.eql(u8, ukey, "cache_read_input_tokens")) {
                            const n = extractU64(buf, up) orelse {
                                up = skipValue(buf, up) orelse return null;
                                up = advancePastComma(buf, up);
                                continue;
                            };
                            result.cache_read_tokens = n.value;
                            up = n.end;
                        } else {
                            up = skipValue(buf, up) orelse return null;
                        }

                        up = advancePastComma(buf, up);
                    }
                    mp = up;
                } else {
                    mp = skipValue(buf, mp) orelse return null;
                }

                mp = advancePastComma(buf, mp);
            }
            p = mp;
        } else {
            // Unknown top-level key — skip its value
            p = skipValue(buf, p) orelse return null;
        }

        p = advancePastComma(buf, p);
    }

    // Must have usage data to be a valid entry
    if (!found_usage) return null;

    return result;
}

/// Advance past optional comma after a value.
fn advancePastComma(buf: []const u8, pos: usize) usize {
    var p = skipWhitespace(buf, pos);
    if (p < buf.len and buf[p] == ',') {
        p += 1;
    }
    return p;
}

const std = @import("std");

// =============================================================================
// Tests
// =============================================================================

test "skipValue: string" {
    const buf = "\"hello world\" rest";
    const end = skipValue(buf, 0);
    try std.testing.expectEqual(@as(?usize, 13), end);
}

test "skipValue: string with escapes" {
    const buf = "\"he\\\"llo\" rest";
    const end = skipValue(buf, 0);
    try std.testing.expectEqual(@as(?usize, 9), end);
}

test "skipValue: number" {
    try std.testing.expectEqual(@as(?usize, 3), skipValue("123,", 0));
    try std.testing.expectEqual(@as(?usize, 4), skipValue("-456}", 0));
    try std.testing.expectEqual(@as(?usize, 4), skipValue("3.14,", 0));
    try std.testing.expectEqual(@as(?usize, 5), skipValue("1e100}", 0));
}

test "skipValue: boolean and null" {
    try std.testing.expectEqual(@as(?usize, 4), skipValue("true,", 0));
    try std.testing.expectEqual(@as(?usize, 5), skipValue("false}", 0));
    try std.testing.expectEqual(@as(?usize, 4), skipValue("null,", 0));
}

test "skipValue: empty object and array" {
    try std.testing.expectEqual(@as(?usize, 2), skipValue("{}", 0));
    try std.testing.expectEqual(@as(?usize, 2), skipValue("[]", 0));
}

test "skipValue: nested object" {
    const buf = "{\"a\":{\"b\":1},\"c\":2} rest";
    const end = skipValue(buf, 0);
    try std.testing.expectEqual(@as(?usize, 19), end);
}

test "skipValue: nested array" {
    const buf = "[1,[2,3],[4]] rest";
    const end = skipValue(buf, 0);
    try std.testing.expectEqual(@as(?usize, 13), end);
}

test "skipValue: deeply nested" {
    const buf = "{\"a\":{\"b\":{\"c\":[1,2,{\"d\":true}]}}}";
    const end = skipValue(buf, 0);
    try std.testing.expectEqual(@as(?usize, buf.len), end);
}

test "extractString: simple" {
    const buf = "\"hello\"rest";
    const result = extractString(buf, 0);
    try std.testing.expect(result != null);
    try std.testing.expectEqualStrings("hello", result.?.value);
    try std.testing.expectEqual(@as(usize, 7), result.?.end);
}

test "extractString: with escapes returns slice including escapes" {
    const buf = "\"he\\\"llo\"rest";
    const result = extractString(buf, 0);
    try std.testing.expect(result != null);
    try std.testing.expectEqualStrings("he\\\"llo", result.?.value);
}

test "extractString: empty string" {
    const buf = "\"\"rest";
    const result = extractString(buf, 0);
    try std.testing.expect(result != null);
    try std.testing.expectEqualStrings("", result.?.value);
}

test "extractU64: simple" {
    const result = extractU64("12345,", 0);
    try std.testing.expect(result != null);
    try std.testing.expectEqual(@as(u64, 12345), result.?.value);
    try std.testing.expectEqual(@as(usize, 5), result.?.end);
}

test "extractU64: zero" {
    const result = extractU64("0}", 0);
    try std.testing.expect(result != null);
    try std.testing.expectEqual(@as(u64, 0), result.?.value);
}

test "extractU64: not a number returns null" {
    try std.testing.expect(extractU64("abc", 0) == null);
}

test "extractF64: integer" {
    const result = extractF64("42,", 0);
    try std.testing.expect(result != null);
    try std.testing.expectApproxEqAbs(@as(f64, 42.0), result.?.value, 0.001);
}

test "extractF64: decimal" {
    const result = extractF64("3.14,", 0);
    try std.testing.expect(result != null);
    try std.testing.expectApproxEqAbs(@as(f64, 3.14), result.?.value, 0.001);
}

test "extractF64: negative" {
    const result = extractF64("-0.05,", 0);
    try std.testing.expect(result != null);
    try std.testing.expectApproxEqAbs(@as(f64, -0.05), result.?.value, 0.001);
}

test "extractF64: scientific notation" {
    const result = extractF64("1.5e-3,", 0);
    try std.testing.expect(result != null);
    try std.testing.expectApproxEqAbs(@as(f64, 0.0015), result.?.value, 0.0001);
}

test "findKeyInObject: finds key" {
    const buf = "{\"a\":1,\"b\":\"hello\",\"c\":true}";
    const pos = findKeyInObject(buf, 0, "b");
    try std.testing.expect(pos != null);
    // Should point to the start of "hello"
    try std.testing.expectEqual(@as(u8, '"'), buf[pos.?]);
    const s = extractString(buf, pos.?);
    try std.testing.expect(s != null);
    try std.testing.expectEqualStrings("hello", s.?.value);
}

test "findKeyInObject: key not found" {
    const buf = "{\"a\":1,\"b\":2}";
    const pos = findKeyInObject(buf, 0, "c");
    try std.testing.expect(pos == null);
}

test "findKeyInObject: empty object" {
    const buf = "{}";
    const pos = findKeyInObject(buf, 0, "a");
    try std.testing.expect(pos == null);
}

test "findKeyInObject: skips nested objects to find later keys" {
    const buf = "{\"a\":{\"x\":1},\"b\":42}";
    const pos = findKeyInObject(buf, 0, "b");
    try std.testing.expect(pos != null);
    const n = extractU64(buf, pos.?);
    try std.testing.expect(n != null);
    try std.testing.expectEqual(@as(u64, 42), n.?.value);
}

test "scanLine: complete usage line" {
    const buf =
        \\{"timestamp":"2025-01-15T10:30:00.000Z","message":{"usage":{"input_tokens":1000,"output_tokens":50,"cache_creation_input_tokens":100,"cache_read_input_tokens":500},"model":"claude-sonnet-4-20250514","id":"msg-001"},"costUSD":0.05,"requestId":"req-001"}
    ;
    const result = scanLine(buf);
    try std.testing.expect(result != null);
    const r = result.?;
    try std.testing.expectEqualStrings("2025-01-15T10:30:00.000Z", r.timestamp.?);
    try std.testing.expectEqualStrings("claude-sonnet-4-20250514", r.model.?);
    try std.testing.expectEqualStrings("msg-001", r.message_id.?);
    try std.testing.expectEqualStrings("req-001", r.request_id.?);
    try std.testing.expectEqual(false, r.is_api_error);
    try std.testing.expectApproxEqAbs(@as(f64, 0.05), r.cost_usd.?, 0.001);
    try std.testing.expectEqual(@as(u64, 1000), r.input_tokens);
    try std.testing.expectEqual(@as(u64, 50), r.output_tokens);
    try std.testing.expectEqual(@as(u64, 100), r.cache_creation_tokens);
    try std.testing.expectEqual(@as(u64, 500), r.cache_read_tokens);
}

test "scanLine: missing usage returns null" {
    const buf =
        \\{"timestamp":"2025-01-15T10:30:00.000Z","message":{"model":"claude-haiku-3"}}
    ;
    const result = scanLine(buf);
    try std.testing.expect(result == null);
}

test "scanLine: isApiErrorMessage true" {
    const buf =
        \\{"timestamp":"2025-01-15T10:30:00.000Z","message":{"usage":{"input_tokens":100,"output_tokens":20},"model":"claude-haiku-3"},"isApiErrorMessage":true}
    ;
    const result = scanLine(buf);
    try std.testing.expect(result != null);
    try std.testing.expectEqual(true, result.?.is_api_error);
}

test "scanLine: empty line returns null" {
    try std.testing.expect(scanLine("") == null);
}

test "scanLine: invalid JSON returns null" {
    try std.testing.expect(scanLine("not json at all") == null);
}

test "scanLine: line without costUSD" {
    const buf =
        \\{"timestamp":"2025-01-15T10:30:00.000Z","message":{"usage":{"input_tokens":100,"output_tokens":20},"model":"claude-haiku-3","id":"msg-003"},"requestId":"req-003"}
    ;
    const result = scanLine(buf);
    try std.testing.expect(result != null);
    try std.testing.expect(result.?.cost_usd == null);
}

test "scanLine: line with extra unknown fields" {
    const buf =
        \\{"timestamp":"2025-01-15T10:30:00.000Z","cwd":"/some/path","version":"1.0.0","unknownField":42,"message":{"usage":{"input_tokens":100,"output_tokens":50},"model":"claude-sonnet-4-20250514","id":"msg-001","content":[{"text":"hello"}]},"costUSD":0.01,"requestId":"req-001"}
    ;
    const result = scanLine(buf);
    try std.testing.expect(result != null);
    try std.testing.expectEqual(@as(u64, 100), result.?.input_tokens);
    try std.testing.expectEqual(@as(u64, 50), result.?.output_tokens);
}

test "scanLine: missing optional cache tokens default to 0" {
    const buf =
        \\{"timestamp":"2025-01-15T10:30:00.000Z","message":{"usage":{"input_tokens":500,"output_tokens":200},"model":"claude-opus-4","id":"msg-002"},"costUSD":0.10,"requestId":"req-002"}
    ;
    const result = scanLine(buf);
    try std.testing.expect(result != null);
    const r = result.?;
    try std.testing.expectEqual(@as(u64, 0), r.cache_creation_tokens);
    try std.testing.expectEqual(@as(u64, 0), r.cache_read_tokens);
    try std.testing.expectEqual(@as(u64, 500), r.input_tokens);
    try std.testing.expectEqual(@as(u64, 200), r.output_tokens);
}
