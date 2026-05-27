# AutoCLI Architecture

> Zig 0.17.0 rewrite of [AutoCLI](https://github.com/nashsu/AutoCLI). Zero external dependencies, single binary, comptime adapter embedding.

## Overview

AutoCLI is a CLI tool that fetches structured data from 55+ websites using declarative YAML adapters. The Zig rewrite replaces the original Rust implementation while maintaining functional parity.

```
User Input
    ↓
main.zig ─── arg parsing, command routing
    ↓
Discovery ── load adapters (builtin comptime + user ~/.autocli/)
    ↓
Route to: builtin command / adapter pipeline / external CLI
    ↓
Pipeline Executor ── sequential step execution
    ├─ fetch    → std.http.Client (blocking)
    ├─ browser  → Daemon WebSocket → Chrome Extension → CDP
    ├─ transform → in-memory data manipulation
    └─ download → std.http.Client
    ↓
Output Renderer ── table / json / yaml / csv / markdown
    ↓
stdout (or --output file)
```

## Module Map

```
src/
├── main.zig              (492 lines)  CLI entry, arg parsing, signal handling
├── core/
│   ├── mod.zig                        Re-exports
│   ├── command.zig         (129)      CliCommand struct, pipeline type
│   ├── strategy.zig         (27)      Strategy enum (public/cookie/header/intercept/ui)
│   ├── error.zig            (65)      CliError error set, error icons/codes
│   ├── ipage.zig           (187)      IPage vtable interface + options structs
│   ├── argdef.zig           (31)      ArgDef, ArgType enums
│   ├── registry.zig        (246)      CliCommand registry, CLI metadata generation
│   ├── security.zig        (153)      Path traversal protection, safe URL checks
│   └── http.zig             (95)      HTTP client helpers, logging, timeouts
├── pipeline/
│   ├── mod.zig                         Re-exports
│   ├── executor.zig        (299)      Pipeline execution engine, metrics
│   ├── context.zig          (14)      PipelineContext struct
│   ├── registry.zig         (79)      StepHandler vtable, StepRegistry
│   ├── steps/
│   │   ├── fetch.zig       (712)      HTTP GET/POST, header/cookie auth
│   │   ├── browser.zig    (1095)      navigate/click/type/wait/evaluate/intercept
│   │   ├── transform.zig   (524)      select/map/filter/sort/limit
│   │   └── download.zig    (536)      File/media download
│   └── template/
│       ├── mod.zig        (1618)      ${{ expr | filter }} engine, Pratt parser
│       └── tests.zig       (259)      Template unit tests
├── browser/
│   ├── mod.zig                         Re-exports
│   ├── daemon.zig          (481)      HTTP daemon + WebSocket bridge
│   ├── page.zig            (603)      DaemonPage — IPage via daemon
│   ├── client.zig          (210)      DaemonClient — HTTP client to daemon
│   ├── cdp.zig             (886)      Direct CDP WebSocket client
│   ├── bridge.zig          (293)      BrowserBridge — auto-select daemon/CDP
│   ├── sandbox.zig         (370)      SandboxPage — mock browser for testing
│   ├── dom.zig             (449)      DOM traversal helpers
│   ├── stealth.zig          (57)      Anti-detection patches
│   └── types.zig            (50)      DaemonCommand, DaemonResult types
├── output/
│   ├── mod.zig                         Re-exports
│   ├── format.zig           (73)      OutputFormat enum
│   ├── render.zig           (52)      render() dispatcher
│   ├── table.zig           (178)      ASCII table renderer
│   ├── json.zig             (41)      JSON pretty-print
│   ├── yaml.zig             (80)      YAML-like output
│   ├── csv.zig              (55)      CSV renderer
│   └── markdown.zig        (107)      Markdown table renderer
├── discovery/
│   ├── mod.zig                         Re-exports
│   ├── yaml.zig            (455)      YAML → CliCommand parser
│   ├── builtin.zig         (229)      Comptime adapter listing
│   ├── builtin_adapters.zig            Generated: comptime-embedded adapters
│   └── user.zig            (170)      ~/.autocli/adapters/ loader
├── external/
│   └── mod.zig             (299)      External CLI passthrough
├── ai/
│   ├── mod.zig             (287)      AI explore/synthesize/generate
│   ├── explore.zig        (1341)      Website API exploration
│   ├── generate.zig        (229)      Adapter generation
│   ├── cascade.zig         (161)      Auth strategy detection
│   ├── client.zig          (296)      AI API client
│   └── config.zig           (58)      AI configuration
├── cli/
│   ├── mod.zig                          Re-exports
│   ├── args.zig            (207)      CLI argument parser
│   ├── commands.zig        (807)      Built-in commands (list/doctor/help/auth/search/generate/read)
│   ├── external.zig        (200)      External CLI detection and passthrough
│   └── i18n.zig             (30)      Internationalization stub
└── tests/
    └── integration.zig     (262)      Integration tests
```

**Total: ~15,400 lines of Zig** (excluding adapters and tests)

## Key Design Decisions

### Vtable Interface (IPage)

Zig has no trait/interface system. Browser operations use a vtable + opaque pointer pattern:

```zig
pub const IPage = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        goto: *const fn (*anyopaque, []const u8, ?GotoOptions) Error!void,
        evaluate: *const fn (*anyopaque, []const u8) Error!Value,
        click: *const fn (*anyopaque, []const u8) Error!void,
        // ... 19 methods total
        close: *const fn (*anyopaque) Error!void,
    };
};
```

Three implementations exist:
- **DaemonPage** — communicates with Chrome extension via local daemon
- **CdpPage** — direct Chrome DevTools Protocol WebSocket
- **SandboxPage** — mock browser for testing (parses JS expressions locally)

### Sync I/O + Threads

Zig 0.17 removed async/await. All I/O is blocking:
- HTTP: `std.http.Client` (blocking)
- Browser: WebSocket to daemon (blocking)
- Concurrency: `std.Thread` for parallel fetches

### Comptime Adapter Embedding

`build.zig` scans `adapters/` at compile time and generates `src/discovery/builtin_adapters.zig` as a string literal array. Zero runtime file I/O for built-in adapters. User adapters in `~/.autocli/adapters/` override builtins at runtime.

### Memory Management

All heap allocations go through explicit allocators. Debug builds use `std.testing.allocator` (or `std.heap.DebugAllocator`) which tracks leaks. The codebase passes `zig build test` with zero leaks.

Key ownership rules:
- Pipeline steps own their output values (clone when borrowing)
- `freeJsonValue()` recursively frees keys + values + nested structures
- `cloneJsonValue()` deep-copies for independent ownership
- Intermediate pipeline data freed after each step

### Error Handling

Zig error unions replace Rust's `Result`:

```zig
pub const CliError = error{
    BrowserConnect, AdapterLoad, CommandExecution, Config,
    AuthRequired, Timeout, Argument, EmptyResult, Selector,
    Pipeline, Http, Io, Json, Yaml, OutOfMemory,
};
```

## Data Flow Example

```
$ autocli hackernews front --format json

1. main.zig: parse args → site="hackernews", command="front"
2. discovery: find adapter → adapters/hackernews/front.yaml
3. yaml.zig: parse YAML → CliCommand{ strategy=.public, pipeline=[fetch, evaluate, select] }
4. executor: create StepRegistry, register fetch/transform/browser steps
5. Step 0 (fetch): GET https://news.ycombinator.com → HTML string
6. Step 1 (evaluate): sandbox parse JS expression → JSON array of objects
7. Step 2 (select): traverse "data" path → filtered array
8. output: render as JSON → stdout
```

## Configuration Paths

| Path | Purpose |
|------|---------|
| `~/.autocli/adapters/` | User custom adapters (override builtins) |
| `~/.autocli/plugins/` | User plugins |
| `~/.autocli/config.json` | Auth tokens |
| `~/.autocli/external-clis.yaml` | External CLI registrations |

## Environment Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `AUTOCLI_VERBOSE` | (unset) | Enable verbose logging |
| `AUTOCLI_DAEMON_PORT` | `19825` | Daemon HTTP+WebSocket port |
| `OPENCLI_DAEMON_PORT` | `19825` | Legacy alias |
| `OPENCLI_CDP_ENDPOINT` | (unset) | Direct CDP WebSocket URL (bypass daemon) |
| `OPENCLI_BROWSER_COMMAND_TIMEOUT` | `60` | Per-command timeout in seconds |
| `OPENCLI_BROWSER_CONNECT_TIMEOUT` | `30` | Browser connection timeout |
| `OPENCLI_BROWSER_EXPLORE_TIMEOUT` | `120` | AI explore timeout |
