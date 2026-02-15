// ABOUTME: Hardcoded Claude model pricing table from LiteLLM data.
// ABOUTME: Calculates per-request costs from token counts when costUSD is absent.
const std = @import("std");

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

/// Look up pricing for a model name. Returns null for unknown models.
pub fn lookupModel(model_name: []const u8) ?ModelPricing {
    for (&pricing_table) |*entry| {
        if (std.mem.eql(u8, entry.name, model_name)) {
            return entry.pricing;
        }
    }
    return null;
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
