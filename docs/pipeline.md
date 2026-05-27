# Pipeline Engine

The pipeline engine is AutoCLI's core execution model. Each adapter defines a pipeline — a sequence of steps that transform raw web data into structured output.

## Execution Model

```zig
pub fn executePipeline(
    allocator: std.mem.Allocator,
    io: std.Io,
    page: ?IPage,                    // null for non-browser pipelines
    pipeline: []const json.Value,    // step definitions from YAML
    args: std.StringHashMap(json.Value),  // user-provided + default args
    registry: *const StepRegistry,   // step handler lookup
    options: PipelineOptions,        // timeout, step-mode
    metrics: ?*ExecutionMetrics,     // optional timing/stats
) CliError!json.Value
```

Steps execute sequentially. Each step receives the previous step's output as input. The final step's output is the pipeline result.

```
data = null
for each step in pipeline:
    data = step.execute(allocator, io, page, params, data, args)
return data
```

Intermediate values are freed after each step. All transform steps clone their outputs to ensure the pipeline owns every value independently.

## Step Registry

Steps register via a vtable pattern:

```zig
pub const StepHandler = struct {
    ptr: *anyopaque,
    vtable: *const struct {
        name: *const fn (*anyopaque) []const u8,
        execute: *const fn (*anyopaque, Allocator, Io, ?IPage, json.Value, json.Value, StringHashMap) CliError!json.Value,
        isBrowserStep: *const fn (*anyopaque) bool,
    },
};
```

Four registration functions:

| Function | Steps | Browser? |
|----------|-------|----------|
| `registerFetchSteps()` | `fetch` | No |
| `registerTransformSteps()` | `select`, `map`, `filter`, `sort`, `limit` | No |
| `registerBrowserSteps()` | `navigate`, `evaluate`, `click`, `type`, `wait` | Yes |
| `registerDownloadSteps()` | `download` | No |

## Step Types

### HTTP Steps

#### `fetch`

Performs HTTP requests via `std.http.Client`.

```yaml
# Simple GET
- fetch: https://api.example.com/data

# Full request
- fetch:
    url: https://api.example.com/data
    method: POST
    headers:
      Content-Type: application/json
      Authorization: "Bearer ${{ args.token }}"
    body: '{"query": "${{ args.q }}"}'
    params:
      page: "1"
```

**Auth strategies:**
- `public` — no auth headers
- `cookie` — attaches stored cookies
- `header` — injects `Authorization` header from config
- `intercept` — captures cookies from browser session

**Returns:** Response body as string (HTML, JSON, etc.)

### Browser Steps

All browser steps require a connected browser (Chrome extension via daemon, or direct CDP).

#### `navigate`

```yaml
- navigate: https://example.com
# or
- navigate:
    url: https://example.com
    settleMs: 2000  # wait after navigation
```

#### `evaluate`

Executes JavaScript in the page context.

```yaml
- evaluate: "document.title"
# or complex expressions
- evaluate: |
    [...document.querySelectorAll('.item')].map(el => ({
      title: el.querySelector('h2').textContent,
      link: el.querySelector('a').href
    }))
```

**Returns:** The evaluated JavaScript value (parsed as JSON).

#### `click`

```yaml
- click: ".load-more-button"
```

#### `type`

```yaml
- type:
    selector: "#search-input"
    text: "${{ args.q }}"
```

#### `wait`

```yaml
- wait: 2                    # wait 2 seconds
- wait:
    selector: ".results"     # wait for element
- wait:
    text: "Loading complete" # wait for text
```

### Transform Steps

All transform steps operate on in-memory JSON data. No network or browser access.

#### `select`

Extracts a value using dot-path notation.

```yaml
- select: data.items           # nested access
- select: "0.title"            # array index + field
- select: data                 # pass-through
```

Returns a cloned value (deep copy) so the pipeline owns the result.

#### `map`

Applies template expressions to each array item.

```yaml
- map:
    title: "${{ item.title | uppercase }}"
    url: "${{ item.url }}"
    score: "${{ item.score | default: '0' }}"
```

#### `filter`

Filters array items by condition.

```yaml
- filter: "${{ item.score > 10 }}"
- filter: "${{ item.title | contains: 'Zig' }}"
```

#### `sort`

Sorts array items.

```yaml
- sort: points                      # ascending by default
- sort:
    by: points
    order: desc
```

#### `limit`

Limits result count.

```yaml
- limit: 10
- limit: "${{ args.limit }}"
```

### Download Steps

#### `download`

Downloads files/media from URLs.

```yaml
- download:
    url: "${{ item.download_url }}"
    output: "${{ item.filename }}"
```

## Template Expressions

The template engine parses `${{ expression | filter }}` syntax using a hand-written Pratt parser.

### Expression Types

| Type | Example | Result |
|------|---------|--------|
| Literal string | `"hello"` | `"hello"` |
| Identifier | `args.q` | Variable lookup |
| Property access | `item.title` | Dot-path traversal |
| Array index | `items.0` | Index access |
| Pipe filter | `item.name \| uppercase` | Apply filter |

### Built-in Filters (16)

| Filter | Usage | Description |
|--------|-------|-------------|
| `uppercase` | `s \| uppercase` | Uppercase string |
| `lowercase` | `s \| lowercase` | Lowercase string |
| `trim` | `s \| trim` | Strip whitespace |
| `default` | `s \| default: "N/A"` | Fallback value |
| `join` | `arr \| join: ", "` | Join array |
| `split` | `s \| split: ","` | Split string |
| `replace` | `s \| replace: "old", "new"` | String replace |
| `contains` | `s \| contains: "sub"` | Boolean check |
| `startsWith` | `s \| startsWith: "http"` | Prefix check |
| `endsWith` | `s \| endsWith: ".json"` | Suffix check |
| `length` | `arr \| length` | Count items |
| `first` | `arr \| first` | First element |
| `last` | `arr \| last` | Last element |
| `reverse` | `arr \| reverse` | Reverse order |
| `unique` | `arr \| unique` | Deduplicate |
| `json` | `obj \| json` | JSON stringify |

### Template Context

Each template evaluation has access to:

| Variable | Description |
|----------|-------------|
| `args` | User-provided + default arguments |
| `data` | Current pipeline data (output of previous step) |
| `item` | Current array item (inside `map`/`filter`) |
| `index` | Current array index (inside `map`/`filter`) |

## Execution Metrics

When enabled, the pipeline tracks:

```zig
pub const ExecutionMetrics = struct {
    total_steps: usize,
    total_duration_ms: u64,
    browser_retries: usize,
    step_counts: std.StringHashMap(usize),  // step_name → count
};
```

Use `--step` flag for interactive step-by-step execution (prompts before each step).

## Retry Logic

Browser steps retry up to 3 times on failure (configurable via `MAX_BROWSER_ATTEMPTS`). Non-browser steps execute once. Retries are tracked in `ExecutionMetrics.browser_retries`.

## Timeout

Global pipeline timeout defaults to 120 seconds (`DEFAULT_TIMEOUT_MS`). Configurable via `OPENCLI_BROWSER_COMMAND_TIMEOUT` environment variable (in seconds). Checked before each step execution.
