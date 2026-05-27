# CLI Reference

## Usage

```
autocli <site> <command> [options]
autocli <builtin> [options]
```

## Built-in Commands

### `list`

List all available sites and commands.

```bash
autocli list              # List all sites
autocli list hackernews   # List commands for a site
```

Uses fast metadata path — no YAML parsing, just reads adapter names.

### `doctor`

Run environment diagnostics.

```bash
autocli doctor
```

Checks:
- Zig version
- Daemon running status
- Extension connection
- Config directory existence
- Adapter count

### `help`

Show help message.

```bash
autocli help
autocli --help
```

### `completion`

Generate shell completions.

```bash
autocli completion bash   # Bash completions
autocli completion zsh    # Zsh completions
autocli completion fish   # Fish completions
```

### `search`

Search adapters by keyword.

```bash
autocli search bilibili
autocli search "video download"
```

### `auth`

Manage authentication tokens.

```bash
autocli auth status               # Show auth status
autocli auth set <site> <token>   # Set a token
autocli auth remove <site>        # Remove a token
```

Tokens are stored in `~/.autocli/config.json`.

### `read`

Read an adapter file and display its parsed structure.

```bash
autocli read hackernews front
```

### `generate`

Generate an adapter YAML file using AI.

```bash
autocli generate https://example.com
```

## Global Options

| Flag | Short | Description |
|------|-------|-------------|
| `--help` | `-h` | Show help |
| `--version` | `-v` | Show version |
| `--format <fmt>` | `-f` | Output format: `table`, `json`, `yaml`, `csv`, `md` |
| `--limit <n>` | `-l` | Limit number of results |
| `--output <file>` | `-o` | Write output to file instead of stdout |
| `--verbose` | | Enable verbose logging (or set `AUTOCLI_VERBOSE=1`) |
| `--sandbox` | | Use mock browser (no real browser needed) |
| `--step` | | Interactive step-by-step pipeline execution |

## Daemon Mode

```bash
autocli --daemon                    # Start daemon on default port (19825)
AUTOCLI_DAEMON_PORT=8080 autocli --daemon   # Custom port
```

The daemon is required for browser-based adapters. It bridges CLI commands to the Chrome extension via WebSocket.

## Output Formats

### `table` (default)

ASCII table with column alignment.

```
┌─────────────────────┬──────────────────────────┬────────┬──────────┐
│ title               │ url                      │ points │ author   │
├─────────────────────┼──────────────────────────┼────────┼──────────┤
│ Show HN: Zig 0.17   │ https://ziglang.org      │ 342    │ andrewrk  │
│ Why Rust is slow    │ https://example.com      │ 127    │ steve     │
└─────────────────────┴──────────────────────────┴────────┴──────────┘
```

### `json`

Pretty-printed JSON array.

```json
[
  {
    "title": "Show HN: Zig 0.17",
    "url": "https://ziglang.org",
    "points": 342,
    "author": "andrewrk"
  }
]
```

### `yaml`

YAML-like output (not spec-compliant, uses Zig's custom renderer).

```yaml
- title: Show HN: Zig 0.17
  url: https://ziglang.org
  points: 342
  author: andrewrk
```

### `csv`

RFC 4180 compliant CSV with header row.

```csv
title,url,points,author
"Show HN: Zig 0.17","https://ziglang.org",342,andrewrk
```

### `markdown`

Markdown table.

```markdown
| title | url | points | author |
|-------|-----|--------|--------|
| Show HN: Zig 0.17 | https://ziglang.org | 342 | andrewrk |
```

## Examples

```bash
# Basic usage
autocli hackernews front
autocli bilibili hot --limit 5
autocli youtube transcript "dQw4w9WgXcQ"

# JSON output
autocli hackernews top --format json

# Save to file
autocli reddit programming --format csv --output stories.csv

# Verbose mode
AUTOCLI_VERBOSE=1 autocli hackernews front

# Sandbox mode (no browser)
autocli --sandbox test jsonplaceholder

# Step-by-step debugging
autocli --step bilibili hot
```

## Exit Codes

| Code | Meaning |
|------|---------|
| 0 | Success |
| 1 | General error (adapter not found, parse error, etc.) |
| 130 | Interrupted by signal (SIGINT/SIGTERM) |
