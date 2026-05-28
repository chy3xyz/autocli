# AutoCLI Zig — Technical Design Document

> Complete rewrite of [AutoCLI](https://github.com/nashsu/AutoCLI) (Rust) in Zig 0.17.0.
> Zero external dependencies. Single binary. Comptime adapter embedding.

---

## 1. Project Overview

AutoCLI is a CLI tool that fetches structured data from websites using declarative YAML adapters. It supports 333+ commands across 55+ sites including Bilibili, Twitter/X, Reddit, YouTube, HackerNews, and Zhihu.

The Zig rewrite replaces the original Rust implementation with:

- **Zero external dependencies** — uses only the Zig standard library
- **Single binary** — no runtime dependencies, no dynamic linking
- **Fast startup** — comptime adapter embedding, no runtime YAML parsing overhead
- **Memory safe** — explicit allocator discipline with debug leak detection

### Goals

1. Functional parity with the Rust version (adapters, pipeline, browser bridge)
2. Zero third-party packages — everything from `std`
3. All adapters compile into the binary (zero runtime file I/O for builtins)
4. Pass `zig build test` with zero memory leaks

### Non-Goals

- Async I/O (Zig 0.17 removed async/await; all I/O is blocking)
- Chrome extension rewrite (extension stays TypeScript)
- Runtime plugin loading (future work)

---

## 2. Module Architecture

```
src/
├── main.zig              Entry point, arg parsing, signal handling, command routing
├── core/                 Shared types: CliCommand, IPage, CliError, Strategy, ArgDef
├── pipeline/             Step execution engine + template expression engine
│   ├── steps/            14 step type implementations
│   └── template/         ${{ expression | filter }} Pratt parser + 16 filters
├── browser/              Browser bridge: Daemon, DaemonPage, CdpPage, SandboxPage
├── output/               5 renderers: table, JSON, YAML, CSV, Markdown
├── discovery/            YAML adapter parser, comptime embedding, user adapter loader
├── external/             External CLI passthrough (gh, docker, kubectl)
├── ai/                   AI-powered explore, synthesize, cascade, generate
└── cli/                  Built-in commands: list, doctor, help, auth, search, generate, read
```

### Module Dependency Graph

```
main.zig
 ├── core          (shared types)
 ├── cli           (builtin commands)
 │   ├── core
 │   ├── external
 │   ├── ai
 │   └── discovery
 ├── pipeline      (step execution)
 │   ├── core
 │   └── template
 ├── browser       (browser bridge)
 │   └── core
 ├── output        (renderers)
 │   └── core
 ├── discovery     (adapter loading)
 │   └── core
 └── external      (CLI passthrough)
     └── core
```

All modules depend on `core`. No circular dependencies.

---

## 3. Core Module (`src/core/`)

### 3.1 CliCommand

The central data structure representing a parsed adapter:

```zig
pub const CliCommand = struct {
    site: []const u8,
    name: []const u8,
    description: []const u8,
    domain: ?[]const u8 = null,
    strategy: Strategy = .public,
    browser: bool = false,
    args: []const ArgDef = &.{},
    columns: []const []const u8 = &.{},
    pipeline: ?[]const json.Value = null,
    navigate_before: NavigateBefore = .{ .bool = true },
};
```

- `pipeline` is `null` for metadata-only operations (e.g., `list`)
- `navigate_before` controls pre-navigation: `true` = navigate to domain, `false` = skip, string = specific URL

### 3.2 Strategy

```zig
pub const Strategy = enum {
    public,      // No auth, HTTP-only fetch
    cookie,      // Attach stored cookies
    header,      // Inject Authorization header
    intercept,   // Capture cookies from browser session
    ui,          // Requires user interaction in browser
};
```

`requiresBrowser()` returns `true` for all except `public`.

### 3.3 IPage (Browser Interface)

Zig has no trait system. Browser operations use a vtable + opaque pointer pattern:

```zig
pub const IPage = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        goto: *const fn (*anyopaque, []const u8, ?GotoOptions) CliError!void,
        url: *const fn (*anyopaque) CliError![]const u8,
        title: *const fn (*anyopaque) CliError![]const u8,
        content: *const fn (*anyopaque) CliError![]const u8,
        evaluate: *const fn (*anyopaque, []const u8) CliError!json.Value,
        click: *const fn (*anyopaque, []const u8) CliError!void,
        type_text: *const fn (*anyopaque, []const u8, []const u8) CliError!void,
        wait_for_selector: *const fn (*anyopaque, []const u8, ?WaitOptions) CliError!void,
        wait_for_navigation: *const fn (*anyopaque, ?WaitOptions) CliError!void,
        wait_for_timeout: *const fn (*anyopaque, u64) CliError!void,
        cookies: *const fn (*anyopaque, ?CookieOptions) CliError![]Cookie,
        set_cookies: *const fn (*anyopaque, []Cookie) CliError!void,
        screenshot: *const fn (*anyopaque, ?ScreenshotOptions) CliError![]u8,
        snapshot: *const fn (*anyopaque, ?SnapshotOptions) CliError!json.Value,
        auto_scroll: *const fn (*anyopaque, ?AutoScrollOptions) CliError!void,
        tabs: *const fn (*anyopaque) CliError![]TabInfo,
        switch_tab: *const fn (*anyopaque, []const u8) CliError!void,
        close: *const fn (*anyopaque) CliError!void,
        intercept_requests: *const fn (*anyopaque, []const u8) CliError!void,
        get_intercepted_requests: *const fn (*anyopaque) CliError![]InterceptedRequest,
        get_network_requests: *const fn (*anyopaque) CliError![]NetworkRequest,
    };
};
```

Three implementations:
- **DaemonPage** — communicates with Chrome extension via HTTP daemon
- **CdpPage** — direct Chrome DevTools Protocol WebSocket
- **SandboxPage** — mock browser for testing (parses JS locally)

### 3.4 CliError

```zig
pub const CliError = error{
    BrowserConnect,      // Cannot connect to browser/daemon
    AdapterLoad,         // Adapter file not found or unreadable
    CommandExecution,    // Command execution failed
    Config,              // Configuration error
    AuthRequired,        // Authentication needed
    Timeout,             // Operation timed out
    Argument,            // Invalid CLI argument
    EmptyResult,         // Pipeline returned no data
    Selector,            // CSS selector not found
    Pipeline,            // Pipeline step failed
    Http,                // HTTP request failed
    Io,                  // I/O error
    Json,                // JSON parse error
    Yaml,                // YAML parse error
    OutOfMemory,         // Allocation failed
    ExternalCli,         // External CLI error
};
```

Each error has an associated icon (emoji) and numeric code for user-facing output.

### 3.5 ArgDef

```zig
pub const ArgDef = struct {
    name: []const u8,
    arg_type: ArgType,        // .str, .int, .number, .bool, .boolean
    required: bool = false,
    positional: bool = false,
    description: ?[]const u8 = null,
    choices: ?[][]const u8 = null,
    default: ?json.Value = null,
};
```

---

## 4. Pipeline Engine (`src/pipeline/`)

### 4.1 Execution Model

```zig
pub fn executePipeline(
    allocator: std.mem.Allocator,
    io: std.Io,
    page: ?IPage,
    pipeline: []const json.Value,
    args: std.StringHashMap(json.Value),
    registry: *const StepRegistry,
    options: PipelineOptions,
    metrics: ?*ExecutionMetrics,
) CliError!json.Value
```

Steps execute sequentially. Each step receives the previous step's output as `data`. Intermediate values are freed after each step — all transform steps clone their outputs to ensure independent ownership.

```
data = null
for each step in pipeline:
    new_data = step.execute(allocator, io, page, params, data, args)
    freeJsonValue(data)     // free previous intermediate
    data = new_data
return data
```

### 4.2 Step Registry

Steps register via a vtable:

```zig
pub const StepHandler = struct {
    ptr: *anyopaque,
    vtable: *const struct {
        name: *const fn (*anyopaque) []const u8,
        execute: *const fn (...) CliError!json.Value,
        isBrowserStep: *const fn (*anyopaque) bool,
    },
};
```

Four registration functions:

| Function | Steps Registered |
|----------|-----------------|
| `registerFetchSteps()` | `fetch` |
| `registerTransformSteps()` | `select`, `map`, `filter`, `sort`, `limit` |
| `registerBrowserSteps()` | `navigate`, `evaluate`, `click`, `type`, `wait` |
| `registerDownloadSteps()` | `download` |

### 4.3 Step Types (14)

**HTTP:**
- `fetch` — GET/POST with headers, body, query params. Supports cookie/header auth.

**Browser (require IPage):**
- `navigate` — URL navigation with settle time
- `evaluate` — JavaScript evaluation in page context
- `click` — CSS selector click
- `type` — Text input into form fields
- `wait` — Wait by time, selector, or text
- `intercept` — Network request interception
- `tap` — State management bridge

**Transform (in-memory, no I/O):**
- `select` — Dot-path data extraction (clones result)
- `map` — Template-based field mapping
- `filter` — Condition-based filtering (clones matching items)
- `sort` — Sort by field, asc/desc (clones items)
- `limit` — Result count limiting (clones items)

**Download:**
- `download` — File/media download via HTTP

### 4.4 Memory Ownership

Transform steps (`select`, `filter`, `sort`, `limit`) all clone their outputs. This ensures the pipeline owns every intermediate value independently. The executor can safely free old `data` after each step without risk of use-after-free.

```zig
// select — clones the traversed value
const result = traversePath(data, segments);
return cloneJsonValue(allocator, result);

// filter — clones matching items
if (isTruthy(val)) {
    const cloned = try cloneJsonValue(allocator, item);
    try results.append(cloned);
}
```

---

## 5. Template Engine (`src/pipeline/template/`)

### 5.1 Syntax

```
${{ expression }}
${{ expression | filter }}
${{ expression | filter: arg1, arg2 }}
```

### 5.2 Parser

Hand-written Pratt parser (recursive descent with precedence climbing). No external PEG parser dependency.

**Expression types:**
- String literals: `"hello"`
- Identifiers: `args.q`, `item.title`
- Dot-path access: `data.items.0.title`
- Pipe filters: `item.name | uppercase`

### 5.3 Filters

16 built-in filters implemented in `applyFilter()`:

| Filter | Input | Args | Output | Description |
|--------|-------|------|--------|-------------|
| `uppercase` | string | — | string | Uppercase |
| `lowercase` | string | — | string | Lowercase |
| `trim` | string | — | string | Strip whitespace |
| `replace` | string | old, new | string | String replace |
| `split` | string | delim | array | Split string |
| `join` | array | delim | string | Join array |
| `contains` | string | sub | bool | Substring check |
| `startsWith` | string | prefix | bool | Prefix check |
| `endsWith` | string | suffix | bool | Suffix check |
| `default` | any | fallback | any | Fallback if null/empty |
| `length` | string/array | — | integer | Count chars/items |
| `first` | array | — | any | First element |
| `last` | array | — | any | Last element |
| `reverse` | array | — | array | Reverse order |
| `unique` | array | — | array | Deduplicate |
| `json` | any | — | string | JSON stringify |

### 5.4 Template Context

```zig
pub const TemplateContext = struct {
    args: std.StringHashMap(json.Value),
    data: json.Value,
    item: json.Value,
    index: usize,
};
```

- `args` — user-provided + default arguments from adapter
- `data` — current pipeline data (output of previous step)
- `item` — current array item (inside `map`/`filter` iteration)
- `index` — current array index

---

## 6. Browser Bridge (`src/browser/`)

### 6.1 Architecture

```
CLI ──HTTP──→ Daemon ──WebSocket──→ Chrome Extension ──CDP──→ Chrome Browser
```

### 6.2 Daemon (`daemon.zig`)

HTTP server + WebSocket bridge on port 19825.

**Endpoints:**
- `GET /ping` — lightweight health check
- `GET /health` — full status (uptime, request count, command count, pending, extension status)
- `GET /status` — extension connection boolean
- `POST /command` — send command to extension (requires `X-AutoCLI: 1` header)
- `WS /ext` — extension WebSocket connection

**Request flow:**
1. CLI sends `POST /command` with JSON body
2. Daemon generates or extracts `id` field
3. Daemon creates `ResponseWaiter`, registers in `pending` map
4. Daemon forwards command to extension via WebSocket
5. Extension responds with `{"id":"...","ok":true,"data":...}`
6. Daemon matches response to waiter by `id`, signals
7. Daemon returns response to CLI

**Connection management:**
- Single WebSocket connection (one extension at a time)
- 60s timeout per command
- 100 max concurrent HTTP connections

### 6.3 DaemonPage (`page.zig`)

Implements `IPage` by sending HTTP commands to the daemon. Each method:
1. Builds JSON params
2. Calls `executeCommand(state, action, params_json)`
3. Unwraps daemon response envelope via `unwrapDaemonResponse()`
4. Returns extracted `data` field

`unwrapDaemonResponse()` handles:
- `{"ok":true,"data":...}` → returns `data` (deep-cloned)
- `{"ok":false,"error":"..."}` → returns `CliError.Pipeline`
- Non-envelope format → pass through as-is

### 6.4 CdpPage (`cdp.zig`)

Direct Chrome DevTools Protocol client. Connects via WebSocket to Chrome's debugging port.

Used when `OPENCLI_CDP_ENDPOINT` is set, bypassing the daemon.

Supports: `Runtime.evaluate`, `Page.navigate`, `Page.captureScreenshot`, `DOM.getDocument`, `DOM.querySelector`, `Network.enable`, `Network.getResponseBody`.

### 6.5 SandboxPage (`sandbox.zig`)

Mock browser for testing. No network connection.

Parses JavaScript expressions locally:
- Object literals: `({ key: 'value' })` → `json.Value{ .object = ... }`
- Array literals: `[1, 2, 3]` → `json.Value{ .array = ... }`
- String/number literals
- Nested structures

Used by `--sandbox` flag and integration tests.

### 6.6 BrowserBridge (`bridge.zig`)

Auto-selects connection method:

```zig
pub fn connect(self: *BrowserBridge) !IPage {
    // 1. If OPENCLI_CDP_ENDPOINT set → CdpPage
    // 2. Otherwise → DaemonPage via DaemonClient
}
```

Waits up to 10s for daemon availability.

---

## 7. Discovery Module (`src/discovery/`)

### 7.1 Adapter Loading Priority

1. `~/.autocli/adapters/{site}/{command}.yaml` (user, runtime)
2. `adapters/{site}/{command}.yaml` (builtin, comptime-embedded)

User adapters override builtins with the same site+command.

### 7.2 Comptime Embedding

`build.zig` generates `src/discovery/builtin_adapters.zig` at compile time:

```zig
pub const adapters = [_]BuiltinAdapter{
    .{ .path = "antigravity/dump.yaml", .content = "site: antigravity\n..." },
    .{ .path = "bilibili/hot.yaml", .content = "..." },
    // ... all 345 adapters
};
```

Zero runtime file I/O for built-in adapters.

### 7.3 YAML Parser (`yaml.zig`)

Hand-written YAML parser (not spec-compliant). Handles the subset needed for adapters:
- Key-value pairs
- Nested objects (indented)
- Arrays (`- item`)
- Multi-line strings (`|` and `>`)
- Template expressions (`${{ ... }}`)

### 7.4 User Adapter Loader (`user.zig`)

Scans `~/.autocli/adapters/` at runtime:
- Nested format: `~/.autocli/adapters/{site}/{command}.yaml`
- Flat format: `~/.autocli/adapters/{site}_{command}.yaml`

---

## 8. Output Module (`src/output/`)

### 8.1 Renderers

| Format | File | Description |
|--------|------|-------------|
| `table` | `table.zig` | ASCII table with column alignment |
| `json` | `json.zig` | Pretty-printed JSON array |
| `yaml` | `yaml.zig` | YAML-like output (custom, not spec-compliant) |
| `csv` | `csv.zig` | RFC 4180 CSV with header row |
| `markdown` | `markdown.zig` | Markdown table |

### 8.2 Render Pipeline

```zig
pub fn render(
    allocator: std.mem.Allocator,
    data: json.Value,
    options: RenderOptions,    // format, columns, title, elapsed_ms, source, footer_extra
) ![]u8
```

1. Normalize input to array of objects
2. Extract column names from first object or `options.columns`
3. Render using format-specific renderer
4. Return allocated string

---

## 9. CLI Module (`src/cli/`)

### 9.1 Argument Parsing (`args.zig`)

Hand-written argument parser. No clap dependency.

```zig
pub const CliArgs = struct {
    site: ?[]const u8,
    command: ?[]const u8,
    format: ?[]const u8,
    limit: ?i64,
    output: ?[]const u8,
    verbose: bool,
    version_flag: bool,
    sandbox: bool,
    step: bool,
    daemon: bool,
    extra_args: std.StringHashMap([]const u8),
};
```

Supports: `--flag`, `--key=value`, `--key value`, positional args, `--` separator.

### 9.2 Built-in Commands (`commands.zig`)

| Command | Description |
|---------|-------------|
| `list` | List sites and commands (fast metadata path) |
| `doctor` | Environment diagnostics |
| `help` | Show usage |
| `completion` | Shell completion generation |
| `auth` | Token management |
| `search` | Search adapters by keyword |
| `generate` | AI-powered adapter generation |
| `read` | Display parsed adapter structure |

### 9.3 External CLI Passthrough (`external.zig`)

Detects and forwards to registered external CLIs (gh, docker, kubectl). Registration stored in `~/.autocli/external-clis.yaml`.

---

## 10. AI Module (`src/ai/`)

| File | Function | Description |
|------|----------|-------------|
| `explore.zig` | `explore` | Probe website APIs, discover endpoints |
| `generate.zig` | `generate` | Generate adapter YAML from exploration results |
| `cascade.zig` | `cascade` | Detect auth strategies (public → cookie → header → ui) |
| `client.zig` | HTTP client | Communication with AI API |
| `config.zig` | Config | AI endpoint, token, model configuration |

---

## 11. Build System (`build.zig`)

### 11.1 Module Creation

Each module is created with `b.createModule()` and linked via `addImport()`:

```zig
const core_mod = b.createModule(.{
    .root_source_file = b.path("src/core/mod.zig"),
    .target = target,
    .optimize = optimize,
});
pipeline_mod.addImport("core", core_mod);
```

### 11.2 Comptime Adapter Generation

`generateBuiltinAdapters()` scans `adapters/` directory at build time:
1. Recursively finds all `.yaml` files
2. Sorts for deterministic output
3. Generates `src/discovery/builtin_adapters.zig` with string literal content
4. Escapes special characters (`\`, `"`, `\n`, `\r`, `\t`)

### 11.3 Test Targets

| Target | Source | Dependencies |
|--------|--------|-------------|
| `core_tests` | `src/core/mod.zig` | — |
| `pipeline_tests` | `src/pipeline/mod.zig` | core |
| `output_tests` | `src/output/mod.zig` | core |
| `discovery_tests` | `src/discovery/mod.zig` | core |
| `security_tests` | `src/core/security.zig` | — |
| `integration_tests` | `src/tests/integration.zig` | core, pipeline, browser |

All tests run via `zig build test`. 269 passing, zero memory leaks.

---

## 12. Cross-Platform Support

Zig's cross-compilation targets:

| Target | Status | Binary Size |
|--------|--------|-------------|
| `aarch64-macos` | ✅ Primary dev platform | ~856 KB |
| `x86_64-macos` | ✅ Cross-compiled | ~856 KB |
| `x86_64-linux-musl` | ✅ Static binary | ~856 KB |
| `aarch64-linux-musl` | ✅ Static binary | ~856 KB |
| `x86_64-windows-gnu` | ⚠️ Untested | — |

All Linux binaries are statically linked (musl). No glibc dependency.

---

## 13. Chrome Extension (`extension/`)

TypeScript Chrome extension (Manifest V3). Not rewritten in Zig — stays as-is.

### 13.1 Protocol

Extension connects to daemon via WebSocket on port 19825.

**Native actions:** `exec`, `navigate`, `tabs`, `cookies`, `screenshot`, `close-window`, `cdp`, `sessions`, `set-file-input`, `read-article`

**CLI protocol adapter:** `normalizeCliCommand()` translates Zig CLI actions (`goto`, `evaluate`, `click`, `type`, `url`, `title`, `content`, `wait_for_*`, `cookies`, `set_cookies`, `snapshot`, `auto_scroll`, `switch_tab`, `close`, `intercept_requests`, `get_intercepted_requests`, `get_network_requests`) to native actions.

### 13.2 Automation Windows

All operations happen in dedicated Chrome windows, isolated from user browsing. Auto-closed after 30s idle.

---

## 14. Future Work

- [ ] Runtime plugin loading (`~/.autocli/plugins/`)
- [ ] Adapter hot-reload (watch `~/.autocli/adapters/`)
- [ ] Windows support
- [ ] Rate limiting for API adapters
- [ ] Adapter caching / ETags
- [ ] Streaming output for large results
- [ ] Web UI for adapter management
