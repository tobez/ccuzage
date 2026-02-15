# Journal - February 2026

## 2026-02-14: Blazing project kickoff

### Project

Blazing — a Zig clone of ccusage (Claude Code usage analyzer).

### Key decisions

- **Pricing**: Calculate from LiteLLM token pricing when `costUSD` absent (always in practice). See `src/pricing.zig`.
- **Architecture**: Monolithic single-pass with arena allocator. Load all entries, aggregate with hash maps.
- **Output**: JSON-first. Human-readable tables are future work.
- **Name**: "blazing" (from project directory name).

### ccusage observations

- Original is TypeScript by ryoppippi, repo at github.com/ryoppippi/ccusage
- Test suite is thin — mostly fixture files, no comprehensive unit tests to port
- Core algorithms: JSONL parsing with dedup, date grouping, 5-hour billing blocks
- Uses Valibot for schema validation, LiteLLM for pricing
- Monorepo with multiple apps (ccusage, codex, opencode, etc.)

## 2026-02-15: Performance, pricing, and flag shortcuts

### Changes

- **Short flags**: Added -s/-u/-j/-o/-b/-z/-p/-i matching ccusage
- **Scanner**: Replaced `std.json.parseFromSlice` with manual `scanner.zig` — 4x speedup (3s → 0.8s user)
- **Pricing**: Hardcoded LiteLLM Claude pricing in `pricing.zig`, calculates costs from token counts

### Scanner design insight

The key to performance is `skipValue()` which tracks brace/bracket nesting to jump over multi-MB content fields without processing them. Zero allocations — all strings are slices into the input buffer. `parseLine` then dupes the 3 strings it needs.
