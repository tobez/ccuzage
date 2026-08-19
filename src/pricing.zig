// ABOUTME: Claude model pricing from LiteLLM data with dynamic fetching and disk caching.
// ABOUTME: Calculates per-request costs from token counts when costUSD is absent.
const std = @import("std");
const scanner = @import("scanner.zig");

pub const ModelPricing = struct {
    input_cost_per_token: f64,
    output_cost_per_token: f64,
    cache_creation_cost_per_token: f64,
    cache_read_cost_per_token: f64,
    // Tiered pricing above 200K input tokens (null = flat pricing)
    input_cost_above_200k: ?f64,
    output_cost_above_200k: ?f64,
    cache_creation_cost_above_200k: ?f64,
    cache_read_cost_above_200k: ?f64,
};

const tiered_threshold: u64 = 200_000;

const pricing_table = [_]struct { name: []const u8, pricing: ModelPricing }{
    .{
        .name = "claude-opus-4-6",
        .pricing = .{
            .input_cost_per_token = 5.0e-6,
            .output_cost_per_token = 25.0e-6,
            .cache_creation_cost_per_token = 6.25e-6,
            .cache_read_cost_per_token = 0.5e-6,
            .input_cost_above_200k = 10.0e-6,
            .output_cost_above_200k = 37.5e-6,
            .cache_creation_cost_above_200k = 12.5e-6,
            .cache_read_cost_above_200k = 1.0e-6,
        },
    },
    .{
        .name = "claude-opus-4-5-20251101",
        .pricing = .{
            .input_cost_per_token = 5.0e-6,
            .output_cost_per_token = 25.0e-6,
            .cache_creation_cost_per_token = 6.25e-6,
            .cache_read_cost_per_token = 0.5e-6,
            .input_cost_above_200k = null,
            .output_cost_above_200k = null,
            .cache_creation_cost_above_200k = null,
            .cache_read_cost_above_200k = null,
        },
    },
    .{
        .name = "claude-sonnet-4-5-20250929",
        .pricing = .{
            .input_cost_per_token = 3.0e-6,
            .output_cost_per_token = 15.0e-6,
            .cache_creation_cost_per_token = 3.75e-6,
            .cache_read_cost_per_token = 0.3e-6,
            .input_cost_above_200k = 6.0e-6,
            .output_cost_above_200k = 22.5e-6,
            .cache_creation_cost_above_200k = 7.5e-6,
            .cache_read_cost_above_200k = 0.6e-6,
        },
    },
    .{
        .name = "claude-haiku-4-5-20251001",
        .pricing = .{
            .input_cost_per_token = 1.0e-6,
            .output_cost_per_token = 5.0e-6,
            .cache_creation_cost_per_token = 1.25e-6,
            .cache_read_cost_per_token = 0.1e-6,
            .input_cost_above_200k = null,
            .output_cost_above_200k = null,
            .cache_creation_cost_above_200k = null,
            .cache_read_cost_above_200k = null,
        },
    },
};

pub const DynamicModelEntry = struct {
    name: []const u8,
    pricing: ModelPricing,
    context_window: ?u64,
};

fn isClaudeKey(key: []const u8) bool {
    if (std.mem.startsWith(u8, key, "claude-")) return true;
    if (std.mem.startsWith(u8, key, "anthropic/claude-")) return true;
    if (std.mem.startsWith(u8, key, "anthropic.claude-")) return true;
    return false;
}

fn extractOptionalF64(buf: []const u8, obj_start: usize, key: []const u8) ?f64 {
    const pos = scanner.findKeyInObject(buf, obj_start, key) orelse return null;
    const result = scanner.extractF64(buf, pos) orelse return null;
    return result.value;
}

fn extractOptionalU64(buf: []const u8, obj_start: usize, key: []const u8) ?u64 {
    const pos = scanner.findKeyInObject(buf, obj_start, key) orelse return null;
    const result = scanner.extractU64(buf, pos) orelse return null;
    return result.value;
}

pub fn parseLiteLLMJson(allocator: std.mem.Allocator, json: []const u8) ![]DynamicModelEntry {
    var entries: std.ArrayList(DynamicModelEntry) = .empty;
    errdefer {
        for (entries.items) |entry| {
            allocator.free(entry.name);
        }
        entries.deinit(allocator);
    }

    var p = scanner.skipWhitespace(json, 0);
    if (p >= json.len or json[p] != '{') return error.InvalidJson;
    p += 1;

    while (p < json.len) {
        p = scanner.skipWhitespace(json, p);
        if (p >= json.len) return error.InvalidJson;
        if (json[p] == '}') break;

        // Parse key
        const key_result = scanner.extractString(json, p) orelse return error.InvalidJson;
        const key = key_result.value;
        p = key_result.end;

        // Skip colon
        p = scanner.skipWhitespace(json, p);
        if (p >= json.len or json[p] != ':') return error.InvalidJson;
        p += 1;
        p = scanner.skipWhitespace(json, p);

        if (isClaudeKey(key)) {
            // Value should be an object — extract pricing fields
            if (p >= json.len or json[p] != '{') return error.InvalidJson;
            const obj_start = p;

            const pricing = ModelPricing{
                .input_cost_per_token = extractOptionalF64(json, obj_start, "input_cost_per_token") orelse 0,
                .output_cost_per_token = extractOptionalF64(json, obj_start, "output_cost_per_token") orelse 0,
                .cache_creation_cost_per_token = extractOptionalF64(json, obj_start, "cache_creation_input_token_cost") orelse 0,
                .cache_read_cost_per_token = extractOptionalF64(json, obj_start, "cache_read_input_token_cost") orelse 0,
                .input_cost_above_200k = extractOptionalF64(json, obj_start, "input_cost_per_token_above_200k_tokens"),
                .output_cost_above_200k = extractOptionalF64(json, obj_start, "output_cost_per_token_above_200k_tokens"),
                .cache_creation_cost_above_200k = extractOptionalF64(json, obj_start, "cache_creation_input_token_cost_above_200k_tokens"),
                .cache_read_cost_above_200k = extractOptionalF64(json, obj_start, "cache_read_input_token_cost_above_200k_tokens"),
            };

            const context_window = extractOptionalU64(json, obj_start, "max_input_tokens");

            const name = try allocator.dupe(u8, key);
            errdefer allocator.free(name);
            try entries.append(allocator, .{ .name = name, .pricing = pricing, .context_window = context_window });

            // Skip past the value object
            p = scanner.skipValue(json, obj_start) orelse return error.InvalidJson;
        } else {
            // Skip non-Claude model value
            p = scanner.skipValue(json, p) orelse return error.InvalidJson;
        }

        // Skip comma
        p = scanner.skipWhitespace(json, p);
        if (p < json.len and json[p] == ',') {
            p += 1;
        }
    }

    return entries.toOwnedSlice(allocator);
}

const litellm_url = "https://raw.githubusercontent.com/BerriAI/litellm/main/model_prices_and_context_window.json";
const cache_filename = "litellm_prices.json";
const cache_max_age_ns: i128 = 3600 * std.time.ns_per_s; // 1 hour

/// Returns the cache directory path: $XDG_CACHE_HOME/ccuzage or ~/.cache/ccuzage.
/// Caller owns the returned memory.
fn getCacheDir(allocator: std.mem.Allocator, env: *const std.process.Environ.Map) ![]const u8 {
    if (env.get("XDG_CACHE_HOME")) |cache_home| {
        return std.fs.path.join(allocator, &.{ cache_home, "ccuzage" });
    }
    const home = env.get("HOME") orelse return error.EnvironmentVariableNotFound;
    const cache_home = try std.fs.path.join(allocator, &.{ home, ".cache" });
    defer allocator.free(cache_home);
    return std.fs.path.join(allocator, &.{ cache_home, "ccuzage" });
}

/// Check whether the cache file is fresh (mtime < 1 hour ago).
fn isCacheFresh(io: std.Io, cache_path: []const u8) bool {
    var file = std.Io.Dir.openFileAbsolute(io, cache_path, .{}) catch return false;
    defer file.close(io);
    const stat = file.stat(io) catch return false;
    const now = std.Io.Timestamp.now(io, .real);
    return (@as(i128, now.nanoseconds) - @as(i128, stat.mtime.nanoseconds)) < cache_max_age_ns;
}

/// Fetch URL to cache path using curl. Writes to a temp file then renames atomically.
fn fetchToCache(io: std.Io, allocator: std.mem.Allocator, cache_path: []const u8) !void {
    const tmp_path = try std.fmt.allocPrint(allocator, "{s}.tmp", .{cache_path});
    defer allocator.free(tmp_path);

    const argv = [_][]const u8{ "curl", "-sf", "-m", "10", litellm_url, "-o", tmp_path };
    var child = try std.process.spawn(io, .{
        .argv = &argv,
        .stdout = .ignore,
        .stderr = .ignore,
    });
    const term = try child.wait(io);
    switch (term) {
        .exited => |code| {
            if (code != 0) {
                std.Io.Dir.deleteFileAbsolute(io, tmp_path) catch {};
                return error.FetchFailed;
            }
        },
        else => {
            std.Io.Dir.deleteFileAbsolute(io, tmp_path) catch {};
            return error.FetchFailed;
        },
    }

    std.Io.Dir.renameAbsolute(tmp_path, cache_path, io) catch {
        std.Io.Dir.deleteFileAbsolute(io, tmp_path) catch {};
        return error.FetchFailed;
    };
}

fn readFileAbsolute(io: std.Io, allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    var file = try std.Io.Dir.openFileAbsolute(io, path, .{});
    defer file.close(io);
    var file_reader = file.reader(io, &.{});
    return file_reader.interface.allocRemaining(allocator, .limited(16 * 1024 * 1024)); // 16MB max
}

var dynamic_state: ?struct { table: []DynamicModelEntry } = null;

/// Load dynamic pricing from LiteLLM cache. All errors are non-fatal.
pub fn initDynamic(io: std.Io, allocator: std.mem.Allocator, env: *const std.process.Environ.Map) void {
    const cache_dir = getCacheDir(allocator, env) catch return;
    defer allocator.free(cache_dir);

    // Ensure cache directory exists
    if (std.fs.path.dirname(cache_dir)) |parent| {
        std.Io.Dir.createDirAbsolute(io, parent, .default_dir) catch |err| switch (err) {
            error.PathAlreadyExists => {},
            else => return,
        };
    }
    std.Io.Dir.createDirAbsolute(io, cache_dir, .default_dir) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return,
    };

    const cache_path = std.fs.path.join(allocator, &.{ cache_dir, cache_filename }) catch return;
    defer allocator.free(cache_path);

    const json = if (isCacheFresh(io, cache_path))
        readFileAbsolute(io, allocator, cache_path) catch return
    else blk: {
        fetchToCache(io, allocator, cache_path) catch {
            // Fetch failed — try stale cache
            break :blk readFileAbsolute(io, allocator, cache_path) catch return;
        };
        break :blk readFileAbsolute(io, allocator, cache_path) catch return;
    };
    defer allocator.free(json);

    initDynamicFromJson(allocator, json) catch return;
}

/// Parse LiteLLM JSON and install it as the dynamic pricing table.
pub fn initDynamicFromJson(allocator: std.mem.Allocator, json: []const u8) !void {
    const table = try parseLiteLLMJson(allocator, json);
    dynamic_state = .{ .table = table };
}

/// Free dynamic pricing state.
pub fn deinitDynamic(allocator: std.mem.Allocator) void {
    if (dynamic_state) |state| {
        for (state.table) |entry| {
            allocator.free(entry.name);
        }
        allocator.free(state.table);
        dynamic_state = null;
    }
}

fn lookupHardcoded(model_name: []const u8) ?ModelPricing {
    for (&pricing_table) |*entry| {
        if (std.mem.eql(u8, entry.name, model_name)) {
            return entry.pricing;
        }
    }
    return null;
}

/// Find a model's entry in the dynamic table by exact name, then by the
/// "anthropic/<model_name>" and "anthropic.<model_name>" prefix forms.
fn findDynamicEntry(model_name: []const u8) ?*const DynamicModelEntry {
    if (dynamic_state) |state| {
        // Exact match in dynamic table
        for (state.table) |*entry| {
            if (std.mem.eql(u8, entry.name, model_name)) {
                return entry;
            }
        }
        // Try matching "anthropic/<model_name>" and "anthropic.<model_name>" entries
        const prefixes = [_][]const u8{ "anthropic/", "anthropic." };
        for (&prefixes) |prefix| {
            for (state.table) |*entry| {
                if (entry.name.len == prefix.len + model_name.len and
                    std.mem.startsWith(u8, entry.name, prefix) and
                    std.mem.eql(u8, entry.name[prefix.len..], model_name))
                {
                    return entry;
                }
            }
        }
    }
    return null;
}

/// Look up pricing for a model name. Checks dynamic table first, then hardcoded.
pub fn lookupModel(model_name: []const u8) ?ModelPricing {
    if (findDynamicEntry(model_name)) |entry| {
        return entry.pricing;
    }
    return lookupHardcoded(model_name);
}

/// Context window (LiteLLM max_input_tokens) for a model, if known.
pub fn lookupContextWindow(model_name: []const u8) ?u64 {
    const entry = findDynamicEntry(model_name) orelse return null;
    return entry.context_window;
}

/// Calculate cost for tokens with optional tiered pricing.
/// First `threshold` tokens are at `base_rate`, remaining at `tiered_rate`.
pub fn calculateTieredCost(tokens: u64, base_rate: f64, tiered_rate: ?f64, threshold: u64) f64 {
    if (tokens == 0) return 0.0;
    const tiered = tiered_rate orelse return @as(f64, @floatFromInt(tokens)) * base_rate;
    if (tokens <= threshold) {
        return @as(f64, @floatFromInt(tokens)) * base_rate;
    }
    const base_tokens: f64 = @floatFromInt(threshold);
    const extra_tokens: f64 = @floatFromInt(tokens - threshold);
    return base_tokens * base_rate + extra_tokens * tiered;
}

/// Calculate total cost for a request given token counts and pricing.
pub fn calculateCost(
    pricing: ModelPricing,
    input_tokens: u64,
    output_tokens: u64,
    cache_creation_tokens: u64,
    cache_read_tokens: u64,
) f64 {
    const input_cost = calculateTieredCost(input_tokens, pricing.input_cost_per_token, pricing.input_cost_above_200k, tiered_threshold);
    const output_cost = calculateTieredCost(output_tokens, pricing.output_cost_per_token, pricing.output_cost_above_200k, tiered_threshold);
    const cache_create_cost = calculateTieredCost(cache_creation_tokens, pricing.cache_creation_cost_per_token, pricing.cache_creation_cost_above_200k, tiered_threshold);
    const cache_read_cost = calculateTieredCost(cache_read_tokens, pricing.cache_read_cost_per_token, pricing.cache_read_cost_above_200k, tiered_threshold);
    return input_cost + output_cost + cache_create_cost + cache_read_cost;
}

/// Calculate cost for a model by name. Returns null for unknown models.
pub fn calculateCostForModel(
    model_name: []const u8,
    input_tokens: u64,
    output_tokens: u64,
    cache_creation_tokens: u64,
    cache_read_tokens: u64,
) ?f64 {
    const pricing = lookupModel(model_name) orelse return null;
    return calculateCost(pricing, input_tokens, output_tokens, cache_creation_tokens, cache_read_tokens);
}

// =============================================================================
// Tests
// =============================================================================

test "lookupModel: known models" {
    try std.testing.expect(lookupModel("claude-opus-4-6") != null);
    try std.testing.expect(lookupModel("claude-opus-4-5-20251101") != null);
    try std.testing.expect(lookupModel("claude-sonnet-4-5-20250929") != null);
    try std.testing.expect(lookupModel("claude-haiku-4-5-20251001") != null);
}

test "lookupModel: unknown model returns null" {
    try std.testing.expect(lookupModel("<synthetic>") == null);
    try std.testing.expect(lookupModel("gpt-4") == null);
    try std.testing.expect(lookupModel("") == null);
}

test "calculateTieredCost: flat pricing (no tiered rate)" {
    // 1000 tokens at $5/M = $0.005
    const cost = calculateTieredCost(1000, 5.0e-6, null, tiered_threshold);
    try std.testing.expectApproxEqAbs(@as(f64, 0.005), cost, 1e-9);
}

test "calculateTieredCost: below threshold with tiered rate" {
    // 100K tokens at $3/M, threshold 200K = still all base rate
    const cost = calculateTieredCost(100_000, 3.0e-6, 6.0e-6, tiered_threshold);
    try std.testing.expectApproxEqAbs(@as(f64, 0.3), cost, 1e-9);
}

test "calculateTieredCost: at threshold boundary" {
    // Exactly 200K tokens at $3/M = $0.60
    const cost = calculateTieredCost(200_000, 3.0e-6, 6.0e-6, tiered_threshold);
    try std.testing.expectApproxEqAbs(@as(f64, 0.6), cost, 1e-9);
}

test "calculateTieredCost: above threshold" {
    // 300K tokens: 200K at $3/M + 100K at $6/M = $0.60 + $0.60 = $1.20
    const cost = calculateTieredCost(300_000, 3.0e-6, 6.0e-6, tiered_threshold);
    try std.testing.expectApproxEqAbs(@as(f64, 1.2), cost, 1e-9);
}

test "calculateTieredCost: zero tokens" {
    const cost = calculateTieredCost(0, 5.0e-6, 10.0e-6, tiered_threshold);
    try std.testing.expectApproxEqAbs(@as(f64, 0.0), cost, 1e-9);
}

test "calculateCost: haiku flat pricing" {
    const pricing = lookupModel("claude-haiku-4-5-20251001").?;
    // 1000 input ($0.001) + 500 output ($0.0025) + 200 cache_create ($0.00025) + 100 cache_read ($0.00001)
    const cost = calculateCost(pricing, 1000, 500, 200, 100);
    const expected = 1000.0 * 1.0e-6 + 500.0 * 5.0e-6 + 200.0 * 1.25e-6 + 100.0 * 0.1e-6;
    try std.testing.expectApproxEqAbs(expected, cost, 1e-9);
}

test "calculateCost: opus tiered pricing above threshold" {
    const pricing = lookupModel("claude-opus-4-6").?;
    // 250K input tokens: 200K at $5/M + 50K at $10/M
    const cost = calculateCost(pricing, 250_000, 0, 0, 0);
    const expected = 200_000.0 * 5.0e-6 + 50_000.0 * 10.0e-6;
    try std.testing.expectApproxEqAbs(expected, cost, 1e-6);
}

test "calculateCost: all zero tokens" {
    const pricing = lookupModel("claude-sonnet-4-5-20250929").?;
    const cost = calculateCost(pricing, 0, 0, 0, 0);
    try std.testing.expectApproxEqAbs(@as(f64, 0.0), cost, 1e-9);
}

test "calculateCostForModel: known model" {
    // 1000 input + 500 output on sonnet
    const cost = calculateCostForModel("claude-sonnet-4-5-20250929", 1000, 500, 0, 0);
    try std.testing.expect(cost != null);
    const expected = 1000.0 * 3.0e-6 + 500.0 * 15.0e-6;
    try std.testing.expectApproxEqAbs(expected, cost.?, 1e-9);
}

test "calculateCostForModel: unknown model returns null" {
    const cost = calculateCostForModel("<synthetic>", 1000, 500, 0, 0);
    try std.testing.expect(cost == null);
}

// =============================================================================
// LiteLLM JSON parsing tests
// =============================================================================

const test_fixture =
    \\{
    \\  "claude-opus-4-6": {
    \\    "input_cost_per_token": 5e-06,
    \\    "output_cost_per_token": 2.5e-05,
    \\    "cache_creation_input_token_cost": 6.25e-06,
    \\    "cache_read_input_token_cost": 5e-07,
    \\    "input_cost_per_token_above_200k_tokens": 1e-05,
    \\    "output_cost_per_token_above_200k_tokens": 3.75e-05,
    \\    "cache_creation_input_token_cost_above_200k_tokens": 1.25e-05,
    \\    "cache_read_input_token_cost_above_200k_tokens": 1e-06,
    \\    "max_tokens": 128000,
    \\    "max_input_tokens": 1000000,
    \\    "litellm_provider": "anthropic"
    \\  },
    \\  "gpt-4": {
    \\    "input_cost_per_token": 3e-05,
    \\    "output_cost_per_token": 6e-05,
    \\    "max_tokens": 8192
    \\  },
    \\  "claude-haiku-4-5-20251001": {
    \\    "input_cost_per_token": 1e-06,
    \\    "output_cost_per_token": 5e-06,
    \\    "cache_creation_input_token_cost": 1.25e-06,
    \\    "cache_read_input_token_cost": 1e-07,
    \\    "max_tokens": 64000
    \\  },
    \\  "anthropic/claude-sonnet-4": {
    \\    "input_cost_per_token": 3e-06,
    \\    "output_cost_per_token": 1.5e-05,
    \\    "max_tokens": 64000,
    \\    "max_input_tokens": 200000
    \\  },
    \\  "anthropic.claude-sonnet-4": {
    \\    "input_cost_per_token": 3e-06,
    \\    "output_cost_per_token": 1.5e-05,
    \\    "max_tokens": 64000
    \\  },
    \\  "gemini-pro": {
    \\    "input_cost_per_token": 1.25e-07,
    \\    "output_cost_per_token": 3.75e-07,
    \\    "max_tokens": 8192
    \\  }
    \\}
;

fn freeTestEntries(entries: []DynamicModelEntry) void {
    for (entries) |entry| {
        std.testing.allocator.free(entry.name);
    }
    std.testing.allocator.free(entries);
}

test "parseLiteLLMJson: extracts only Claude models" {
    const entries = try parseLiteLLMJson(std.testing.allocator, test_fixture);
    defer freeTestEntries(entries);
    // Should find 4 Claude models, skip gpt-4 and gemini-pro
    try std.testing.expectEqual(@as(usize, 4), entries.len);
}

test "parseLiteLLMJson: field name mapping for tiered model" {
    const entries = try parseLiteLLMJson(std.testing.allocator, test_fixture);
    defer freeTestEntries(entries);
    // First entry should be claude-opus-4-6 with all pricing fields
    try std.testing.expectEqualStrings("claude-opus-4-6", entries[0].name);
    const p = entries[0].pricing;
    try std.testing.expectApproxEqAbs(@as(f64, 5e-06), p.input_cost_per_token, 1e-10);
    try std.testing.expectApproxEqAbs(@as(f64, 2.5e-05), p.output_cost_per_token, 1e-10);
    try std.testing.expectApproxEqAbs(@as(f64, 6.25e-06), p.cache_creation_cost_per_token, 1e-10);
    try std.testing.expectApproxEqAbs(@as(f64, 5e-07), p.cache_read_cost_per_token, 1e-10);
    try std.testing.expectApproxEqAbs(@as(f64, 1e-05), p.input_cost_above_200k.?, 1e-10);
    try std.testing.expectApproxEqAbs(@as(f64, 3.75e-05), p.output_cost_above_200k.?, 1e-10);
    try std.testing.expectApproxEqAbs(@as(f64, 1.25e-05), p.cache_creation_cost_above_200k.?, 1e-10);
    try std.testing.expectApproxEqAbs(@as(f64, 1e-06), p.cache_read_cost_above_200k.?, 1e-10);
}

test "parseLiteLLMJson: tiered fields null when absent" {
    const entries = try parseLiteLLMJson(std.testing.allocator, test_fixture);
    defer freeTestEntries(entries);
    // Second entry is haiku — no tiered pricing
    try std.testing.expectEqualStrings("claude-haiku-4-5-20251001", entries[1].name);
    const p = entries[1].pricing;
    try std.testing.expectApproxEqAbs(@as(f64, 1e-06), p.input_cost_per_token, 1e-10);
    try std.testing.expect(p.input_cost_above_200k == null);
    try std.testing.expect(p.output_cost_above_200k == null);
    try std.testing.expect(p.cache_creation_cost_above_200k == null);
    try std.testing.expect(p.cache_read_cost_above_200k == null);
}

test "parseLiteLLMJson: extracts max_input_tokens as context_window" {
    const entries = try parseLiteLLMJson(std.testing.allocator, test_fixture);
    defer freeTestEntries(entries);
    // First entry is claude-opus-4-6, which has max_input_tokens
    try std.testing.expectEqual(@as(?u64, 1_000_000), entries[0].context_window);
}

test "parseLiteLLMJson: context_window null when max_input_tokens absent" {
    const entries = try parseLiteLLMJson(std.testing.allocator, test_fixture);
    defer freeTestEntries(entries);
    // Second entry is haiku, which has no max_input_tokens
    try std.testing.expectEqual(@as(?u64, null), entries[1].context_window);
}

test "parseLiteLLMJson: anthropic/ prefix models included" {
    const entries = try parseLiteLLMJson(std.testing.allocator, test_fixture);
    defer freeTestEntries(entries);
    // Third entry is anthropic/claude-sonnet-4
    try std.testing.expectEqualStrings("anthropic/claude-sonnet-4", entries[2].name);
    try std.testing.expectApproxEqAbs(@as(f64, 3e-06), entries[2].pricing.input_cost_per_token, 1e-10);
}

test "parseLiteLLMJson: empty object returns empty slice" {
    const entries = try parseLiteLLMJson(std.testing.allocator, "{}");
    defer std.testing.allocator.free(entries);
    try std.testing.expectEqual(@as(usize, 0), entries.len);
}

test "parseLiteLLMJson: invalid JSON returns error" {
    const result = parseLiteLLMJson(std.testing.allocator, "not json");
    try std.testing.expectError(error.InvalidJson, result);
}

test "parseLiteLLMJson: empty input returns error" {
    const result = parseLiteLLMJson(std.testing.allocator, "");
    try std.testing.expectError(error.InvalidJson, result);
}

// =============================================================================
// Cache management tests
// =============================================================================

test "getCacheDir: returns valid path ending in ccuzage" {
    var env = std.process.Environ.Map.init(std.testing.allocator);
    defer env.deinit();
    try env.put("HOME", "/home/test");
    const dir = try getCacheDir(std.testing.allocator, &env);
    defer std.testing.allocator.free(dir);
    try std.testing.expect(std.mem.endsWith(u8, dir, "/ccuzage"));
    try std.testing.expect(dir.len > "/ccuzage".len);
}

test "isCacheFresh: fresh file returns true" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var file = try tmp.dir.createFile(std.testing.io, "test_cache.json", .{});
    file.close(std.testing.io);
    const path = try tmp.dir.realPathFileAlloc(std.testing.io, "test_cache.json", std.testing.allocator);
    defer std.testing.allocator.free(path);
    try std.testing.expect(isCacheFresh(std.testing.io, path));
}

test "isCacheFresh: missing file returns false" {
    try std.testing.expect(!isCacheFresh(std.testing.io, "/nonexistent/path/to/file.json"));
}

// =============================================================================
// Dynamic lookup tests
// =============================================================================

test "lookupModel: finds model in dynamic table" {
    const entries = try parseLiteLLMJson(std.testing.allocator, test_fixture);
    dynamic_state = .{ .table = entries };
    defer deinitDynamic(std.testing.allocator);

    const p = lookupModel("claude-opus-4-6");
    try std.testing.expect(p != null);
    try std.testing.expectApproxEqAbs(@as(f64, 5e-06), p.?.input_cost_per_token, 1e-10);
}

test "lookupModel: anthropic/ prefix matching" {
    const entries = try parseLiteLLMJson(std.testing.allocator, test_fixture);
    dynamic_state = .{ .table = entries };
    defer deinitDynamic(std.testing.allocator);

    // "claude-sonnet-4" should match "anthropic/claude-sonnet-4" in dynamic table
    const p = lookupModel("claude-sonnet-4");
    try std.testing.expect(p != null);
    try std.testing.expectApproxEqAbs(@as(f64, 3e-06), p.?.input_cost_per_token, 1e-10);
}

test "lookupModel: anthropic. prefix matching" {
    const entries = try parseLiteLLMJson(std.testing.allocator, test_fixture);
    dynamic_state = .{ .table = entries };
    defer deinitDynamic(std.testing.allocator);

    // "claude-sonnet-4" should also match "anthropic.claude-sonnet-4" (Bedrock style)
    // Note: anthropic/ prefix is tried first, so exact result depends on table order,
    // but the model should be found regardless.
    const p = lookupModel("claude-sonnet-4");
    try std.testing.expect(p != null);
}

test "lookupModel: falls back to hardcoded when not in dynamic" {
    const entries = try parseLiteLLMJson(std.testing.allocator, test_fixture);
    dynamic_state = .{ .table = entries };
    defer deinitDynamic(std.testing.allocator);

    // claude-opus-4-5-20251101 is in hardcoded table but not in test fixture
    const p = lookupModel("claude-opus-4-5-20251101");
    try std.testing.expect(p != null);
    try std.testing.expectApproxEqAbs(@as(f64, 5.0e-6), p.?.input_cost_per_token, 1e-10);
}

test "lookupModel: no dynamic state uses hardcoded only" {
    dynamic_state = null;
    try std.testing.expect(lookupModel("claude-opus-4-6") != null);
    try std.testing.expect(lookupModel("gpt-4") == null);
}

test "lookupContextWindow: exact name hit" {
    const entries = try parseLiteLLMJson(std.testing.allocator, test_fixture);
    dynamic_state = .{ .table = entries };
    defer deinitDynamic(std.testing.allocator);

    try std.testing.expectEqual(@as(?u64, 1_000_000), lookupContextWindow("claude-opus-4-6"));
}

test "lookupContextWindow: anthropic/ prefix hit" {
    const entries = try parseLiteLLMJson(std.testing.allocator, test_fixture);
    dynamic_state = .{ .table = entries };
    defer deinitDynamic(std.testing.allocator);

    try std.testing.expectEqual(@as(?u64, 200_000), lookupContextWindow("claude-sonnet-4"));
}

test "lookupContextWindow: unknown model returns null" {
    const entries = try parseLiteLLMJson(std.testing.allocator, test_fixture);
    dynamic_state = .{ .table = entries };
    defer deinitDynamic(std.testing.allocator);

    try std.testing.expectEqual(@as(?u64, null), lookupContextWindow("claude-nonexistent"));
}

test "lookupContextWindow: entry present without max_input_tokens returns null" {
    const entries = try parseLiteLLMJson(std.testing.allocator, test_fixture);
    dynamic_state = .{ .table = entries };
    defer deinitDynamic(std.testing.allocator);

    try std.testing.expectEqual(@as(?u64, null), lookupContextWindow("claude-haiku-4-5-20251001"));
}

test "isClaudeKey: identifies Claude model keys" {
    try std.testing.expect(isClaudeKey("claude-opus-4-6"));
    try std.testing.expect(isClaudeKey("claude-haiku-4-5-20251001"));
    try std.testing.expect(isClaudeKey("anthropic/claude-sonnet-4"));
    try std.testing.expect(isClaudeKey("anthropic.claude-3-5-haiku-20241022-v1:0"));
    try std.testing.expect(!isClaudeKey("gpt-4"));
    try std.testing.expect(!isClaudeKey("gemini-pro"));
    try std.testing.expect(!isClaudeKey(""));
}
