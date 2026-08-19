# ccuzage

A fast CLI tool for analyzing Claude Code token usage and costs.

ccuzage reads the same JSONL session logs that Claude Code writes to
`~/.claude/projects/` and produces usage reports — daily, weekly, monthly,
per-session, or by billing block. Output is either Unicode tables (default) or
JSON.

Written in Zig. Single static binary, no runtime dependencies.

## Why

[ccusage](https://github.com/syakoo/ccusage) is a Node.js tool that does the
same thing. It works well but takes 10-15 seconds to produce a report for a
month of data. ccuzage produces the same reports in about 1 second.

This project was built as an experiment in rewriting a Node.js CLI tool in Zig
to see how far the performance gap goes when the workload is I/O-bound JSONL
parsing and aggregation.

## ccusage compatibility

ccuzage aims to match ccusage's output format and feature set for Claude Code
analysis. It does not currently support ccusage's other tools (Codex, OpenCode,
Amp, Pi-Agent).

Matching:

- Same data source (`~/.claude/projects/`)
- Same aggregation modes (daily, weekly, monthly, session)
- Same JSON output schema
- Same table layout and column names
- Same pricing data (bundled from LiteLLM)
- Billing block analysis (`blocks` command)

Different:

- Zig instead of Node.js — single 479KB binary, ~1s startup
- No npm/npx/bunx required
- Column detail levels (`--columns min/mid/full`)
- Claude Code only — no multi-tool support

## Usage

```text
ccuzage daily                    # today's usage in a table
ccuzage daily -s 20260201       # since February 1st
ccuzage daily -b                # per-model breakdown
ccuzage daily -c min            # minimal columns (tokens + cost)
ccuzage daily -j                # JSON output
ccuzage weekly                  # weekly aggregation
ccuzage monthly                 # monthly aggregation
ccuzage session                 # per-session usage
ccuzage blocks --recent         # billing blocks, last 3 days
ccuzage statusline              # one-line summary for status bars
ccuzage context                 # current session's context-window usage (percent)
```

Run `ccuzage --help` for all options.

## Installation

> **Note:** Installation instructions are a work in progress.

```bash
# Build from source (requires Zig 0.16+)
zig build -Doptimize=ReleaseFast
cp zig-out/bin/ccuzage ~/.local/bin/
```

## Contributing

Contributions and patches are welcome.

## Credits

This tool was written by Anton Berezin with the aid of Claude (Anthropic).

Based on [ccusage](https://github.com/syakoo/ccusage) by syakoo.
