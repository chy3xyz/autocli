# AutoCLI (Zig Rewrite)

> A Zig 0.17.0 rewrite of [AutoCLI](https://github.com/nashsu/AutoCLI) — a blazing-fast CLI tool that scrapes data from 55+ websites in a single command.

**[中文文档](README.zh.md)**

## What is AutoCLI?

AutoCLI is a command-line tool that fetches structured data from websites using declarative YAML adapters. It supports 333+ commands across 55+ sites including Bilibili, Twitter/X, Reddit, YouTube, HackerNews, Zhihu, and more.

This repository contains a **complete rewrite in Zig**, replacing the original Rust implementation with:

- **Zero external dependencies** — uses only the Zig standard library
- **Single binary** — no runtime dependencies, no dynamic linking
- **Fast startup** — comptime adapter embedding, no runtime YAML parsing overhead
- **Memory safe** — explicit allocator discipline with debug leak detection

## Quick Start

### Prerequisites

- Zig 0.17.0 (`zig version` must report `0.17.x`)

### Build

```bash
zig build
```

The binary is output to `zig-out/bin/autocli`.

### Run

```bash
# List all available sites and commands
./zig-out/bin/autocli list

# Fetch Hacker News front page
./zig-out/bin/autocli hackernews front

# Search Bilibili
./zig-out/bin/autocli bilibili search "zig programming"

# Get a YouTube video transcript
./zig-out/bin/autocli youtube transcript "dQw4w9WgXcQ"

# Doctor — check environment
./zig-out/bin/autocli doctor
```

### Test

```bash
zig build test
```

## Architecture

See [ard.md](ard.md) for the full architecture document.

```
src/
├── main.zig              # CLI entry, arg parsing, command routing
├── core/                 # Strategy, CliCommand, Registry, Error, IPage vtable
├── pipeline/             # Pipeline engine: 14 step types, template expressions
│   ├── executor.zig      # Step execution with timeout & retry
│   ├── steps/
│   │   ├── fetch.zig     # HTTP request step
│   │   ├── browser.zig   # navigate, click, type, wait, evaluate
│   │   ├── transform.zig # select, map, filter, sort, limit
│   │   └── download.zig  # Media/article download
│   └── template/         # ${{ expression | filter }} template engine
├── browser/              # Browser bridge: Daemon, DaemonPage, CdpPage
│   ├── daemon.zig        # HTTP daemon (port 19825) + WebSocket to extension
│   ├── page.zig          # DaemonPage — IPage via daemon communication
│   ├── cdp.zig           # Direct CDP WebSocket client
│   └── sandbox.zig       # SandboxPage — mock browser for testing
├── output/               # Renderers: table, JSON, YAML, CSV, Markdown
├── discovery/            # YAML adapter parsing, compile-time embedding
├── external/             # External CLI loading and passthrough
└── ai/                   # AI-powered explore, synthesize, generate
```

### Key Design Decisions

| Decision | Rationale |
|----------|-----------|
| **Vtable interface (IPage)** | Zig has no traits; vtable + opaque pointer provides runtime polymorphism |
| **Sync I/O + threads** | Zig 0.17 removed async/await; std.http.Client is blocking |
| **Comptime adapter embedding** | YAML files embedded at compile time via build.zig, zero runtime file I/O |
| **Pratt parser for templates** | `${{ expression \| filter }}` syntax is simple enough for a hand-written parser |
| **std.json.Value** | Dynamic JSON type replaces serde_json::Value |

### Pipeline Steps (14 types)

| Step | Category | Description |
|------|----------|-------------|
| `fetch` | HTTP | GET/POST with headers, body, query params |
| `navigate` | Browser | URL navigation with settle time |
| `evaluate` | Browser | JavaScript evaluation in page context |
| `click` | Browser | CSS selector click |
| `type` | Browser | Text input into form fields |
| `wait` | Browser | Wait by time, selector, or text |
| `select` | Transform | Dot-path data extraction |
| `map` | Transform | Template-based field mapping |
| `filter` | Transform | Condition-based filtering |
| `sort` | Transform | Sort by field (asc/desc) |
| `limit` | Transform | Result count limiting |
| `intercept` | Browser | Network request interception |
| `tap` | Browser | State management bridge |
| `download` | HTTP | Media/article file download |

## Browser Extension

The `extension/` directory contains a Chrome extension that bridges the AutoCLI daemon to Chrome's debugging APIs. The extension:

- Connects to the local daemon via WebSocket (port 19825)
- Executes commands in isolated automation windows
- Supports the full CLI protocol (evaluate, navigate, click, type, cookies, screenshots, etc.)

### Build the extension

```bash
cd extension
npm install
npm run build
```

Load `extension/dist/` as an unpacked extension in Chrome.

## Adapters

Adapters are YAML files that define how to scrape a website. Each adapter specifies:

- **Strategy**: `public`, `cookie`, `header`, `intercept`, or `ui`
- **Pipeline**: A sequence of steps (fetch → evaluate → select → map → filter → sort → limit)
- **Columns**: Output field definitions
- **Args**: User-provided parameters with defaults

Example adapter (`adapters/hackernews/front.yaml`):

```yaml
site: hackernews
command: front
description: Hacker News front page
strategy: public
columns:
  - title
  - url
  - points
  - author
pipeline:
  - fetch: https://news.ycombinator.com
  - evaluate: |
      [...document.querySelectorAll('.titleline a')].map(a => ({
        title: a.textContent,
        url: a.href
      }))
  - select: data
```

## Configuration

| Path | Purpose |
|------|---------|
| `~/.autocli/adapters/` | User custom adapters |
| `~/.autocli/plugins/` | User plugins |
| `~/.autocli/config.json` | Auth tokens |
| `~/.autocli/external-clis.yaml` | External CLI registrations |

### Environment Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `AUTOCLI_VERBOSE` | - | Enable verbose output |
| `AUTOCLI_DAEMON_PORT` | `19825` | Daemon port |
| `OPENCLI_CDP_ENDPOINT` | - | Direct CDP endpoint (bypass daemon) |
| `OPENCLI_BROWSER_COMMAND_TIMEOUT` | `60` | Command timeout (seconds) |

## Development

```bash
# Build
zig build

# Run tests (269 passing)
zig build test

# Run with verbose output
AUTOCLI_VERBOSE=1 ./zig-out/bin/autocli hackernews front

# Start daemon mode (for browser extension)
./zig-out/bin/autocli --daemon
```

## License

MIT — Based on [OpenCLI](https://github.com/jackwener/opencli) by jackwener (Apache-2.0).
