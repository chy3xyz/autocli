# Browser Bridge

AutoCLI controls browsers through a layered architecture: CLI → Daemon → Chrome Extension → CDP.

## Architecture

```
┌─────────────┐     HTTP POST      ┌─────────────┐     WebSocket      ┌─────────────────┐
│  CLI (Zig)  │ ─────────────────→ │   Daemon     │ ─────────────────→ │ Chrome Extension │
│             │ ←───────────────── │  (Zig HTTP)  │ ←───────────────── │   (TypeScript)   │
└─────────────┘     JSON resp      └─────────────┘     JSON msg       └────────┬────────┘
                                                                                │
                                                                         chrome.debugger
                                                                                │
                                                                       ┌────────▼────────┐
                                                                       │  Chrome Browser  │
                                                                       │  (Target Page)   │
                                                                       └─────────────────┘
```

## Components

### Daemon (`src/browser/daemon.zig`)

Long-running HTTP server + WebSocket bridge. Started via `autocli --daemon`.

**Endpoints:**

| Endpoint | Method | Description |
|----------|--------|-------------|
| `/ping` | GET | Health check (lightweight) |
| `/health` | GET | Full status (uptime, counts, extension status) |
| `/status` | GET | Extension connection status |
| `/command` | POST | Send command to extension |
| `/ext` | WebSocket | Extension connection |

**Port:** 19825 (configurable via `AUTOCLI_DAEMON_PORT`)

**Security:** `/command` requires `X-AutoCLI: 1` header.

**Protocol flow:**
1. CLI sends `POST /command` with JSON body `{"action":"evaluate","params":{"expression":"..."}}`
2. Daemon injects `id` field, forwards to extension via WebSocket
3. Extension executes command, responds with `{"id":"...","ok":true,"data":...}`
4. Daemon returns response to CLI

**Connection management:**
- One WebSocket connection at a time (single extension)
- CLI requests block up to 60s waiting for extension response
- `ResponseWaiter` uses mutex + polling (10ms intervals)

### DaemonPage (`src/browser/page.zig`)

Implements `IPage` by sending commands through the daemon's HTTP API.

```zig
pub const DaemonPageState = struct {
    allocator: std.mem.Allocator,
    client: *DaemonClient,
    owns_client: bool,
    tab_id: []const u8,
};
```

Each IPage method:
1. Builds a JSON params object
2. Calls `executeCommand(state, action, params_json)`
3. Unwraps the daemon response envelope (`{"ok":true,"data":...}`)
4. Returns the extracted data

### DaemonClient (`src/browser/client.zig`)

HTTP client for daemon communication. Uses `std.http.Client` (blocking).

Key methods:
- `isRunning()` — checks if daemon is up
- `isExtensionConnected()` — checks extension WebSocket status
- `sendJson(method, body)` — raw HTTP POST
- `executePageCommand(tab_id, action, params)` — full command round-trip

### CdpPage (`src/browser/cdp.zig`)

Direct Chrome DevTools Protocol client via WebSocket. Used when `OPENCLI_CDP_ENDPOINT` is set, bypassing the daemon entirely.

Supports:
- `Runtime.evaluate` — JS execution
- `Page.navigate` — navigation
- `Page.captureScreenshot` — screenshots
- `DOM.getDocument` / `DOM.querySelector` — DOM queries
- `Network.enable` / `Network.getResponseBody` — network interception

### SandboxPage (`src/browser/sandbox.zig`)

Mock browser for testing. Parses JavaScript expressions locally without connecting to any browser.

Used in:
- `--sandbox` flag mode
- Integration tests
- Adapters that only need simple JS expression parsing

Parses expressions like `({ status: 'ok' })` and `[...document.querySelectorAll('.item')]` into `json.Value` objects. Supports basic object/array literals, string values, and nested structures.

### BrowserBridge (`src/browser/bridge.zig`)

Auto-selects between Daemon and CDP based on configuration:

```zig
pub fn connect(self: *BrowserBridge) !IPage {
    // 1. If OPENCLI_CDP_ENDPOINT is set → CdpPage
    // 2. Otherwise → DaemonPage via DaemonClient
}
```

Waits up to `READY_TIMEOUT_MS` (10s) for the daemon to become available.

## Chrome Extension (`extension/`)

TypeScript Chrome extension (Manifest V3). Service worker connects to daemon via WebSocket.

### Actions

| Action | Description |
|--------|-------------|
| `exec` | Evaluate JavaScript in page |
| `navigate` | Navigate to URL |
| `tabs` | List/create/close/select tabs |
| `cookies` | Get/set cookies |
| `screenshot` | Capture viewport or full page |
| `close-window` | Close automation window |
| `cdp` | Raw CDP method call |
| `sessions` | List active automation sessions |
| `set-file-input` | Set files on `<input type="file">` |
| `read-article` | Extract article content (Readability) |

### CLI Protocol Adapter

The extension includes a protocol adapter (`normalizeCliCommand`) that translates Zig CLI commands to extension-native actions:

| CLI Action | Maps To | Implementation |
|------------|---------|---------------|
| `goto` | `navigate` | Direct URL |
| `evaluate` | `exec` | `params.expression` → `code` |
| `url` | `exec` | `window.location.href` |
| `title` | `exec` | `document.title` |
| `content` | `exec` | `document.documentElement.outerHTML` |
| `click` | `exec` | `document.querySelector(sel).click()` |
| `type` | `exec` | Set value + dispatch events |
| `wait_for_selector` | `exec` | rAF poll with 30s timeout |
| `wait_for_navigation` | `exec` | readyState/load listener |
| `wait_for_timeout` | `exec` | `setTimeout` promise |
| `snapshot` | `cdp` | `Accessibility.getFullAXTree` |
| `cookies` | `cookies` | Domain filter |
| `set_cookies` | `cdp` | `Network.setCookies` |
| `switch_tab` | `tabs` | `op: 'select'` |
| `close` | `tabs` | `op: 'close'` |

### Automation Windows

All browser operations happen in dedicated Chrome windows, isolated from the user's browsing session:
- Created on first command
- Auto-closed after 30s idle timeout
- Multiple workspaces supported (via `workspace` field)

## IPage Interface

The `IPage` vtable defines 19 methods:

```zig
pub const IPage = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    // Navigation
    fn goto(self, url, options)      // Navigate to URL
    fn url(self)                      // Get current URL
    fn title(self)                    // Get page title
    fn content(self)                  // Get page HTML

    // JavaScript
    fn evaluate(self, expression)     // Evaluate JS, return json.Value

    // Interaction
    fn click(self, selector)          // Click element
    fn type_text(self, selector, text) // Type into input

    // Waiting
    fn wait_for_selector(self, selector, options)
    fn wait_for_navigation(self, options)
    fn wait_for_timeout(self, ms)

    // Cookies
    fn cookies(self, options)         // Get cookies
    fn set_cookies(self, cookies)     // Set cookies

    // Capture
    fn screenshot(self, options)      // Base64 image
    fn snapshot(self, options)        // Accessibility tree

    // Tabs
    fn tabs(self)                     // List tabs
    fn switch_tab(self, tab_id)       // Switch to tab

    // Scrolling
    fn auto_scroll(self, options)     // Auto-scroll page

    // Network
    fn intercept_requests(self, pattern)
    fn get_intercepted_requests(self)
    fn get_network_requests(self)

    // Lifecycle
    fn close(self)                    // Close page/connection
};
```
