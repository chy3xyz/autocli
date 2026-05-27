# AGENTS.md

## Project Overview

- **Goal**: Rewrite [AutoCLI](https://github.com/nashsu/AutoCLI) (Rust) in Zig 0.17.0
- **Current state**: Greenfield - no Zig code yet, reference implementation in `_def/AutoCLI/`

## Critical Rules

1. **Write `ard.md` BEFORE any code** — Architecture document must exist before implementation begins
2. **Zig version**: Use Zig 0.17.0 exactly (check with `zig version`)

## Reference Source

All implementation details come from `_def/AutoCLI/` — the Rust source of truth:

```
_def/AutoCLI/
├── crates/
│   ├── autocli-core/        # Strategy, CliCommand, Registry, IPage trait, Error
│   ├── autocli-pipeline/    # Pipeline engine: expressions, executor, 14 step types
│   ├── autocli-browser/     # Browser bridge: Daemon, DaemonPage, CdpPage
│   ├── autocli-output/      # Output: table, json, yaml, csv, markdown
│   ├── autocli-discovery/   # YAML parsing, compile-time embedding
│   ├── autocli-external/    # External CLI loading, passthrough
│   ├── autocli-ai/          # explore, synthesize, cascade, generate
│   └── autocli-cli/         # CLI entry: clap → execution
├── adapters/               # 333 YAML adapters (55 sites)
└── extension/              # Chrome extension for browser control
```

## Key Architecture Patterns

- **CLI Layer**: Dynamic subcommands via CLI framework (not clap — find Zig equivalent)
- **Pipeline Engine**: Declarative YAML → execution steps (fetch, evaluate, navigate, click, type, wait, select, map, filter, sort, limit, intercept, tap, download)
- **Template Expressions**: `${{ expression | filter }}` syntax for data transformation
- **Browser Bridge**: HTTP daemon (port 19825) + WebSocket CDP to Chrome extension
- **Authentication**: public → cookie → header → intercept → ui strategies

## Environment Variables (for reference)

```
OPENCLI_VERBOSE          # Enable verbose output
OPENCLI_DAEMON_PORT=19825
OPENCLI_CDP_ENDPOINT    # Bypass daemon
OPENCLI_BROWSER_COMMAND_TIMEOUT=60
OPENCLI_BROWSER_CONNECT_TIMEOUT=30
OPENCLI_BROWSER_EXPLORE_TIMEOUT=120
```

## Config Paths

```
~/.autocli/adapters/     # User custom adapters
~/.autocli/plugins/      # User plugins
~/.autocli/external-clis.yaml
~/.autocli/config.json   # Auth tokens
```

## Dependencies to Research

When implementing in Zig, find equivalents for:
- `reqwest` (HTTP client with connection pooling)
- `tokio` (async runtime)
- `pest` (PEG parser for template expressions)
- `axum` (HTTP daemon)
- `serde` / `serde_json` (serialization)
- Chrome DevTools Protocol (CDP) for browser control

## Commands

```bash
# Check Zig version (must be 0.17.0)
zig version

# Build (when build.zig exists)
zig build

# Test (when tests exist)
zig test
```

## Excluded from Rewrite

- The Chrome extension in `_def/AutoCLI/extension/` — keep as-is (TypeScript)
- Existing YAML adapters in `_def/AutoCLI/adapters/` — reuse directly