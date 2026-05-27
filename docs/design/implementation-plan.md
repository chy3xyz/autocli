# OpenCLI-RS Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Rewrite OpenCLI in Rust as a multi-crate workspace, preserving full feature parity with the TypeScript original (excluding Chrome extension).

**Architecture:** Workspace with 8 crates: core (data models), pipeline (YAML engine), browser (Daemon + CDP bridge), output (formatters), discovery (adapter loading), external (CLI pass-through), ai (explore/synthesize/cascade), cli (binary entry point). Adapters stored as YAML in `adapters/` directory, compiled into binary via `build.rs`.

**Tech Stack:** Rust 2021 edition, tokio, clap, reqwest, axum, serde, serde_json, serde_yaml, pest, tokio-tungstenite, comfy-table, colored, csv, htmd, thiserror.

**Design Spec:** `docs/design/opencli-rs-design.md`

---

## Phase 1: Foundation — Workspace + Core + Output + CLI Skeleton

### Task 1: Workspace Scaffolding

**Files:**
- Create: `Cargo.toml` (workspace root)
- Create: `crates/opencli-rs-core/Cargo.toml`
- Create: `crates/opencli-rs-core/src/lib.rs`
- Create: `crates/opencli-rs-pipeline/Cargo.toml`
- Create: `crates/opencli-rs-pipeline/src/lib.rs`
- Create: `crates/opencli-rs-browser/Cargo.toml`
- Create: `crates/opencli-rs-browser/src/lib.rs`
- Create: `crates/opencli-rs-output/Cargo.toml`
- Create: `crates/opencli-rs-output/src/lib.rs`
- Create: `crates/opencli-rs-discovery/Cargo.toml`
- Create: `crates/opencli-rs-discovery/src/lib.rs`
- Create: `crates/opencli-rs-external/Cargo.toml`
- Create: `crates/opencli-rs-external/src/lib.rs`
- Create: `crates/opencli-rs-ai/Cargo.toml`
- Create: `crates/opencli-rs-ai/src/lib.rs`
- Create: `crates/opencli-rs-cli/Cargo.toml`
- Create: `crates/opencli-rs-cli/src/main.rs`
- Create: `.gitignore`

- [ ] **Step 1: Create workspace root Cargo.toml**

```toml
[workspace]
resolver = "2"
members = [
    "crates/opencli-rs-core",
    "crates/opencli-rs-pipeline",
    "crates/opencli-rs-browser",
    "crates/opencli-rs-output",
    "crates/opencli-rs-discovery",
    "crates/opencli-rs-external",
    "crates/opencli-rs-ai",
    "crates/opencli-rs-cli",
]

[workspace.package]
version = "0.1.0"
edition = "2021"
license = "Apache-2.0"

[workspace.dependencies]
tokio = { version = "1", features = ["full"] }
serde = { version = "1", features = ["derive"] }
serde_json = "1"
serde_yaml = "0.9"
thiserror = "2"
anyhow = "1"
async-trait = "0.1"
tracing = "0.1"
tracing-subscriber = { version = "0.3", features = ["env-filter"] }
```

- [ ] **Step 2: Create all 8 crate directories with minimal Cargo.toml and lib.rs/main.rs**

Each crate gets a minimal `Cargo.toml` referencing `workspace.package` and an empty `src/lib.rs` (or `src/main.rs` for cli).

`crates/opencli-rs-core/Cargo.toml`:
```toml
[package]
name = "opencli-rs-core"
version.workspace = true
edition.workspace = true

[dependencies]
serde = { workspace = true }
serde_json = { workspace = true }
thiserror = { workspace = true }
async-trait = { workspace = true }
```

`crates/opencli-rs-pipeline/Cargo.toml`:
```toml
[package]
name = "opencli-rs-pipeline"
version.workspace = true
edition.workspace = true

[dependencies]
opencli-rs-core = { path = "../opencli-rs-core" }
serde = { workspace = true }
serde_json = { workspace = true }
serde_yaml = { workspace = true }
thiserror = { workspace = true }
async-trait = { workspace = true }
tokio = { workspace = true }
tracing = { workspace = true }
```

`crates/opencli-rs-browser/Cargo.toml`:
```toml
[package]
name = "opencli-rs-browser"
version.workspace = true
edition.workspace = true

[dependencies]
opencli-rs-core = { path = "../opencli-rs-core" }
serde = { workspace = true }
serde_json = { workspace = true }
thiserror = { workspace = true }
async-trait = { workspace = true }
tokio = { workspace = true }
tracing = { workspace = true }
reqwest = { version = "0.12", features = ["json"] }
tokio-tungstenite = { version = "0.24", features = ["native-tls"] }
axum = { version = "0.8", features = ["ws"] }
uuid = { version = "1", features = ["v4"] }
```

`crates/opencli-rs-output/Cargo.toml`:
```toml
[package]
name = "opencli-rs-output"
version.workspace = true
edition.workspace = true

[dependencies]
opencli-rs-core = { path = "../opencli-rs-core" }
serde = { workspace = true }
serde_json = { workspace = true }
serde_yaml = { workspace = true }
comfy-table = "7"
colored = "2"
csv = "1"
```

`crates/opencli-rs-discovery/Cargo.toml`:
```toml
[package]
name = "opencli-rs-discovery"
version.workspace = true
edition.workspace = true

[dependencies]
opencli-rs-core = { path = "../opencli-rs-core" }
opencli-rs-pipeline = { path = "../opencli-rs-pipeline" }
serde = { workspace = true }
serde_json = { workspace = true }
serde_yaml = { workspace = true }
thiserror = { workspace = true }
tracing = { workspace = true }
```

`crates/opencli-rs-external/Cargo.toml`:
```toml
[package]
name = "opencli-rs-external"
version.workspace = true
edition.workspace = true

[dependencies]
opencli-rs-core = { path = "../opencli-rs-core" }
serde = { workspace = true }
serde_json = { workspace = true }
serde_yaml = { workspace = true }
thiserror = { workspace = true }
tokio = { workspace = true }
tracing = { workspace = true }
```

`crates/opencli-rs-ai/Cargo.toml`:
```toml
[package]
name = "opencli-rs-ai"
version.workspace = true
edition.workspace = true

[dependencies]
opencli-rs-core = { path = "../opencli-rs-core" }
opencli-rs-browser = { path = "../opencli-rs-browser" }
opencli-rs-pipeline = { path = "../opencli-rs-pipeline" }
serde = { workspace = true }
serde_json = { workspace = true }
thiserror = { workspace = true }
async-trait = { workspace = true }
tokio = { workspace = true }
tracing = { workspace = true }
```

`crates/opencli-rs-cli/Cargo.toml`:
```toml
[package]
name = "opencli-rs"
version.workspace = true
edition.workspace = true

[[bin]]
name = "opencli-rs"
path = "src/main.rs"

[dependencies]
opencli-rs-core = { path = "../opencli-rs-core" }
opencli-rs-pipeline = { path = "../opencli-rs-pipeline" }
opencli-rs-browser = { path = "../opencli-rs-browser" }
opencli-rs-output = { path = "../opencli-rs-output" }
opencli-rs-discovery = { path = "../opencli-rs-discovery" }
opencli-rs-external = { path = "../opencli-rs-external" }
opencli-rs-ai = { path = "../opencli-rs-ai" }
serde = { workspace = true }
serde_json = { workspace = true }
tokio = { workspace = true }
tracing = { workspace = true }
tracing-subscriber = { workspace = true }
clap = { version = "4", features = ["derive"] }
```

- [ ] **Step 3: Create .gitignore**

```
/target
**/*.rs.bk
Cargo.lock
```

Note: `Cargo.lock` should be committed for binary projects. Remove it from `.gitignore` after first successful build.

- [ ] **Step 4: Verify workspace compiles**

Run: `cargo build`
Expected: Successful compilation with no errors.

- [ ] **Step 5: Commit**

```bash
git add -A
git commit -m "feat: scaffold opencli-rs workspace with 8 crates"
```

---

### Task 2: Core Data Models (`opencli-rs-core`)

**Files:**
- Create: `crates/opencli-rs-core/src/strategy.rs`
- Create: `crates/opencli-rs-core/src/args.rs`
- Create: `crates/opencli-rs-core/src/command.rs`
- Create: `crates/opencli-rs-core/src/registry.rs`
- Create: `crates/opencli-rs-core/src/error.rs`
- Create: `crates/opencli-rs-core/src/page.rs`
- Create: `crates/opencli-rs-core/src/value_ext.rs`
- Modify: `crates/opencli-rs-core/src/lib.rs`

- [ ] **Step 1: Implement Strategy enum** (`strategy.rs`)

Maps to original `registry.ts` Strategy enum.

```rust
use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum Strategy {
    Public,
    Cookie,
    Header,
    Intercept,
    Ui,
}

impl Default for Strategy {
    fn default() -> Self {
        Self::Public
    }
}

impl Strategy {
    pub fn requires_browser(&self) -> bool {
        !matches!(self, Self::Public)
    }
}

impl std::fmt::Display for Strategy {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::Public => write!(f, "public"),
            Self::Cookie => write!(f, "cookie"),
            Self::Header => write!(f, "header"),
            Self::Intercept => write!(f, "intercept"),
            Self::Ui => write!(f, "ui"),
        }
    }
}
```

- [ ] **Step 2: Implement ArgDef and ArgType** (`args.rs`)

Maps to original `registry.ts` Arg interface.

```rust
use serde::{Deserialize, Serialize};
use serde_json::Value;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum ArgType {
    Str,
    Int,
    Number,
    Bool,
    #[serde(alias = "boolean")]
    Boolean,
}

impl Default for ArgType {
    fn default() -> Self {
        Self::Str
    }
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ArgDef {
    pub name: String,
    #[serde(rename = "type", default)]
    pub arg_type: ArgType,
    #[serde(default)]
    pub required: bool,
    #[serde(default)]
    pub positional: bool,
    #[serde(default)]
    pub description: Option<String>,
    #[serde(default)]
    pub choices: Option<Vec<String>>,
    #[serde(default)]
    pub default: Option<Value>,
}
```

- [ ] **Step 3: Implement CliCommand** (`command.rs`)

Maps to original `registry.ts` CliCommand interface. The `func` field uses a trait object for async functions.

```rust
use crate::{ArgDef, Strategy};
use serde::{Deserialize, Serialize};
use serde_json::Value;
use std::collections::HashMap;
use std::future::Future;
use std::pin::Pin;
use std::sync::Arc;

pub type CommandArgs = HashMap<String, Value>;

pub type AdapterFunc = Arc<
    dyn Fn(
            Option<Arc<dyn crate::IPage>>,
            CommandArgs,
        ) -> Pin<Box<dyn Future<Output = Result<Value, crate::CliError>> + Send>>
        + Send
        + Sync,
>;

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum NavigateBefore {
    Bool(bool),
    Url(String),
}

impl Default for NavigateBefore {
    fn default() -> Self {
        Self::Bool(true)
    }
}

#[derive(Clone)]
pub struct CliCommand {
    pub site: String,
    pub name: String,
    pub description: String,
    pub domain: Option<String>,
    pub strategy: Strategy,
    pub browser: bool,
    pub args: Vec<ArgDef>,
    pub columns: Vec<String>,
    pub pipeline: Option<Vec<Value>>,
    pub func: Option<AdapterFunc>,
    pub timeout_seconds: Option<u64>,
    pub navigate_before: NavigateBefore,
}

impl CliCommand {
    pub fn full_name(&self) -> String {
        format!("{} {}", self.site, self.name)
    }

    pub fn needs_browser(&self) -> bool {
        self.browser || self.strategy.requires_browser()
    }
}

impl std::fmt::Debug for CliCommand {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("CliCommand")
            .field("site", &self.site)
            .field("name", &self.name)
            .field("strategy", &self.strategy)
            .field("browser", &self.browser)
            .field("has_func", &self.func.is_some())
            .field("has_pipeline", &self.pipeline.is_some())
            .finish()
    }
}
```

- [ ] **Step 4: Implement Registry** (`registry.rs`)

Global command registry. Maps to original `globalThis.__opencli_registry__`.

```rust
use crate::CliCommand;
use std::collections::HashMap;

#[derive(Debug, Default)]
pub struct Registry {
    commands: HashMap<String, HashMap<String, CliCommand>>,
}

impl Registry {
    pub fn new() -> Self {
        Self::default()
    }

    pub fn register(&mut self, cmd: CliCommand) {
        self.commands
            .entry(cmd.site.clone())
            .or_default()
            .insert(cmd.name.clone(), cmd);
    }

    pub fn get(&self, site: &str, name: &str) -> Option<&CliCommand> {
        self.commands.get(site)?.get(name)
    }

    pub fn list_sites(&self) -> Vec<&str> {
        let mut sites: Vec<&str> = self.commands.keys().map(|s| s.as_str()).collect();
        sites.sort();
        sites
    }

    pub fn list_commands(&self, site: &str) -> Vec<&CliCommand> {
        self.commands
            .get(site)
            .map(|cmds| {
                let mut v: Vec<&CliCommand> = cmds.values().collect();
                v.sort_by(|a, b| a.name.cmp(&b.name));
                v
            })
            .unwrap_or_default()
    }

    pub fn all_commands(&self) -> Vec<&CliCommand> {
        let mut cmds: Vec<&CliCommand> = self
            .commands
            .values()
            .flat_map(|site_cmds| site_cmds.values())
            .collect();
        cmds.sort_by(|a, b| (&a.site, &a.name).cmp(&(&b.site, &b.name)));
        cmds
    }

    pub fn site_count(&self) -> usize {
        self.commands.len()
    }

    pub fn command_count(&self) -> usize {
        self.commands.values().map(|v| v.len()).sum()
    }
}
```

- [ ] **Step 5: Implement error types** (`error.rs`)

Maps to original `errors.ts`. Enhanced with error chain and multiple suggestions.

```rust
use thiserror::Error;

#[derive(Debug, Error)]
pub enum CliError {
    #[error("{icon} Browser connection failed: {message}")]
    BrowserConnect {
        message: String,
        suggestions: Vec<String>,
        icon: &'static str,
        #[source]
        source: Option<Box<dyn std::error::Error + Send + Sync>>,
    },

    #[error("Adapter load failed: {message}")]
    AdapterLoad {
        message: String,
        suggestions: Vec<String>,
        #[source]
        source: Option<Box<dyn std::error::Error + Send + Sync>>,
    },

    #[error("Command execution failed: {message}")]
    CommandExecution {
        message: String,
        suggestions: Vec<String>,
        #[source]
        source: Option<Box<dyn std::error::Error + Send + Sync>>,
    },

    #[error("Configuration error: {message}")]
    Config {
        message: String,
        suggestions: Vec<String>,
    },

    #[error("{icon} Authentication required: {message}")]
    AuthRequired {
        message: String,
        suggestions: Vec<String>,
        icon: &'static str,
    },

    #[error("{icon} Timeout: {message}")]
    Timeout {
        message: String,
        suggestions: Vec<String>,
        icon: &'static str,
    },

    #[error("{icon} Invalid argument: {message}")]
    Argument {
        message: String,
        suggestions: Vec<String>,
        icon: &'static str,
    },

    #[error("Empty result: {message}")]
    EmptyResult {
        message: String,
        suggestions: Vec<String>,
    },

    #[error("Selector not found: {message}")]
    Selector {
        message: String,
        suggestions: Vec<String>,
    },

    #[error("Pipeline error: {message}")]
    Pipeline {
        message: String,
        suggestions: Vec<String>,
        #[source]
        source: Option<Box<dyn std::error::Error + Send + Sync>>,
    },

    #[error("IO error: {0}")]
    Io(#[from] std::io::Error),

    #[error("JSON error: {0}")]
    Json(#[from] serde_json::Error),

    #[error("YAML error: {0}")]
    Yaml(#[from] serde_yaml::Error),

    #[error("HTTP error: {0}")]
    Http(String),
}

impl CliError {
    pub fn code(&self) -> &'static str {
        match self {
            Self::BrowserConnect { .. } => "BROWSER_CONNECT",
            Self::AdapterLoad { .. } => "ADAPTER_LOAD",
            Self::CommandExecution { .. } => "COMMAND_EXEC",
            Self::Config { .. } => "CONFIG",
            Self::AuthRequired { .. } => "AUTH_REQUIRED",
            Self::Timeout { .. } => "TIMEOUT",
            Self::Argument { .. } => "ARGUMENT",
            Self::EmptyResult { .. } => "EMPTY_RESULT",
            Self::Selector { .. } => "SELECTOR",
            Self::Pipeline { .. } => "PIPELINE",
            Self::Io(_) => "IO",
            Self::Json(_) => "JSON",
            Self::Yaml(_) => "YAML",
            Self::Http(_) => "HTTP",
        }
    }

    pub fn icon(&self) -> &'static str {
        match self {
            Self::BrowserConnect { .. } => "🔌",
            Self::AuthRequired { .. } => "🔒",
            Self::Timeout { .. } => "⏱",
            Self::Argument { .. } => "❌",
            Self::EmptyResult { .. } => "📭",
            Self::Selector { .. } => "🔍",
            _ => "⚠️",
        }
    }

    pub fn suggestions(&self) -> &[String] {
        match self {
            Self::BrowserConnect { suggestions, .. }
            | Self::AdapterLoad { suggestions, .. }
            | Self::CommandExecution { suggestions, .. }
            | Self::Config { suggestions, .. }
            | Self::AuthRequired { suggestions, .. }
            | Self::Timeout { suggestions, .. }
            | Self::Argument { suggestions, .. }
            | Self::EmptyResult { suggestions, .. }
            | Self::Selector { suggestions, .. }
            | Self::Pipeline { suggestions, .. } => suggestions,
            _ => &[],
        }
    }

    // Convenience constructors
    pub fn browser_connect(msg: impl Into<String>) -> Self {
        Self::BrowserConnect {
            message: msg.into(),
            suggestions: vec![
                "Make sure Chrome is running with the OpenCLI extension installed".into(),
                "Run 'opencli-rs doctor' to diagnose connection issues".into(),
            ],
            icon: "🔌",
            source: None,
        }
    }

    pub fn argument(msg: impl Into<String>) -> Self {
        Self::Argument {
            message: msg.into(),
            suggestions: vec![],
            icon: "❌",
        }
    }

    pub fn timeout(msg: impl Into<String>) -> Self {
        Self::Timeout {
            message: msg.into(),
            suggestions: vec!["Try increasing timeout with OPENCLI_BROWSER_COMMAND_TIMEOUT".into()],
            icon: "⏱",
        }
    }

    pub fn auth_required(msg: impl Into<String>) -> Self {
        Self::AuthRequired {
            message: msg.into(),
            suggestions: vec!["Please login to the target site in your Chrome browser first".into()],
            icon: "🔒",
        }
    }

    pub fn empty_result(msg: impl Into<String>) -> Self {
        Self::EmptyResult {
            message: msg.into(),
            suggestions: vec![],
        }
    }

    pub fn command_execution(msg: impl Into<String>) -> Self {
        Self::CommandExecution {
            message: msg.into(),
            suggestions: vec![],
            source: None,
        }
    }

    pub fn pipeline(msg: impl Into<String>) -> Self {
        Self::Pipeline {
            message: msg.into(),
            suggestions: vec![],
            source: None,
        }
    }
}
```

- [ ] **Step 6: Implement IPage trait** (`page.rs`)

Maps to original `types.ts` IPage interface. This is the browser abstraction.

```rust
use async_trait::async_trait;
use serde::{Deserialize, Serialize};
use serde_json::Value;

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct GotoOptions {
    pub wait_until: Option<String>,
    pub timeout: Option<u64>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct CookieOptions {
    pub domain: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Cookie {
    pub name: String,
    pub value: String,
    pub domain: String,
    pub path: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct SnapshotOptions {
    pub max_depth: Option<usize>,
    pub viewport_expansion: Option<i32>,
}

#[derive(Debug, Clone, Copy, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum ScrollDirection {
    Up,
    Down,
    Left,
    Right,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct AutoScrollOptions {
    pub max_scrolls: Option<u32>,
    pub delay_ms: Option<u64>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct WaitOptions {
    pub time: Option<u64>,
    pub selector: Option<String>,
    pub text: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct TabInfo {
    pub id: Option<u64>,
    pub url: String,
    pub title: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct NetworkRequest {
    pub url: String,
    pub method: String,
    pub status: Option<u16>,
    pub content_type: Option<String>,
    pub body: Option<Value>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct InterceptedRequest {
    pub url: String,
    pub method: String,
    pub headers: std::collections::HashMap<String, String>,
    pub body: Option<Value>,
    pub response_body: Option<Value>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ScreenshotOptions {
    pub format: Option<String>,
    pub quality: Option<u32>,
    pub full_page: Option<bool>,
}

#[async_trait]
pub trait IPage: Send + Sync {
    async fn goto(&self, url: &str, options: Option<GotoOptions>) -> Result<(), crate::CliError>;
    async fn evaluate(&self, js: &str) -> Result<Value, crate::CliError>;
    async fn get_cookies(&self, opts: Option<CookieOptions>) -> Result<Vec<Cookie>, crate::CliError>;
    async fn snapshot(&self, opts: Option<SnapshotOptions>) -> Result<Value, crate::CliError>;
    async fn click(&self, selector: &str) -> Result<(), crate::CliError>;
    async fn type_text(&self, selector: &str, text: &str) -> Result<(), crate::CliError>;
    async fn press_key(&self, key: &str) -> Result<(), crate::CliError>;
    async fn wait(&self, options: WaitOptions) -> Result<(), crate::CliError>;
    async fn scroll(
        &self,
        direction: Option<ScrollDirection>,
        amount: Option<i32>,
    ) -> Result<(), crate::CliError>;
    async fn auto_scroll(&self, options: Option<AutoScrollOptions>) -> Result<(), crate::CliError>;
    async fn tabs(&self) -> Result<Vec<TabInfo>, crate::CliError>;
    async fn new_tab(&self) -> Result<(), crate::CliError>;
    async fn select_tab(&self, index: usize) -> Result<(), crate::CliError>;
    async fn close_tab(&self, index: Option<usize>) -> Result<(), crate::CliError>;
    async fn network_requests(&self) -> Result<Vec<NetworkRequest>, crate::CliError>;
    async fn screenshot(
        &self,
        options: Option<ScreenshotOptions>,
    ) -> Result<String, crate::CliError>;
    async fn install_interceptor(&self, pattern: &str) -> Result<(), crate::CliError>;
    async fn get_intercepted_requests(
        &self,
    ) -> Result<Vec<InterceptedRequest>, crate::CliError>;
}
```

- [ ] **Step 7: Implement Value extension helpers** (`value_ext.rs`)

Utility trait for convenient `serde_json::Value` operations used throughout the codebase.

```rust
use serde_json::Value;

pub trait ValueExt {
    fn as_str_or_default(&self) -> &str;
    fn get_path(&self, path: &str) -> Option<&Value>;
    fn is_empty_result(&self) -> bool;
    fn to_array(&self) -> Vec<&Value>;
}

impl ValueExt for Value {
    fn as_str_or_default(&self) -> &str {
        self.as_str().unwrap_or("")
    }

    fn get_path(&self, path: &str) -> Option<&Value> {
        let mut current = self;
        for part in path.split('.') {
            if let Ok(idx) = part.parse::<usize>() {
                current = current.get(idx)?;
            } else {
                current = current.get(part)?;
            }
        }
        Some(current)
    }

    fn is_empty_result(&self) -> bool {
        match self {
            Value::Null => true,
            Value::Array(arr) => arr.is_empty(),
            Value::Object(obj) => obj.is_empty(),
            Value::String(s) => s.is_empty(),
            _ => false,
        }
    }

    fn to_array(&self) -> Vec<&Value> {
        match self {
            Value::Array(arr) => arr.iter().collect(),
            Value::Null => vec![],
            other => vec![other],
        }
    }
}
```

- [ ] **Step 8: Wire up lib.rs with public exports**

```rust
// crates/opencli-rs-core/src/lib.rs
pub mod strategy;
pub mod args;
pub mod command;
pub mod registry;
pub mod error;
pub mod page;
pub mod value_ext;

pub use strategy::Strategy;
pub use args::{ArgDef, ArgType};
pub use command::{AdapterFunc, CliCommand, CommandArgs, NavigateBefore};
pub use registry::Registry;
pub use error::CliError;
pub use page::*;
pub use value_ext::ValueExt;
```

- [ ] **Step 9: Verify compilation**

Run: `cargo build -p opencli-rs-core`
Expected: Successful compilation.

- [ ] **Step 10: Write unit tests for Registry**

Add to `crates/opencli-rs-core/src/registry.rs`:

```rust
#[cfg(test)]
mod tests {
    use super::*;
    use crate::{Strategy, CliCommand, NavigateBefore};

    fn test_cmd(site: &str, name: &str) -> CliCommand {
        CliCommand {
            site: site.into(),
            name: name.into(),
            description: format!("{} {}", site, name),
            domain: None,
            strategy: Strategy::Public,
            browser: false,
            args: vec![],
            columns: vec![],
            pipeline: None,
            func: None,
            timeout_seconds: None,
            navigate_before: NavigateBefore::default(),
        }
    }

    #[test]
    fn test_register_and_get() {
        let mut reg = Registry::new();
        reg.register(test_cmd("hackernews", "top"));
        assert!(reg.get("hackernews", "top").is_some());
        assert!(reg.get("hackernews", "missing").is_none());
    }

    #[test]
    fn test_list_sites() {
        let mut reg = Registry::new();
        reg.register(test_cmd("bilibili", "hot"));
        reg.register(test_cmd("hackernews", "top"));
        let sites = reg.list_sites();
        assert_eq!(sites, vec!["bilibili", "hackernews"]);
    }

    #[test]
    fn test_command_count() {
        let mut reg = Registry::new();
        reg.register(test_cmd("hn", "top"));
        reg.register(test_cmd("hn", "best"));
        reg.register(test_cmd("reddit", "hot"));
        assert_eq!(reg.site_count(), 2);
        assert_eq!(reg.command_count(), 3);
    }
}
```

- [ ] **Step 11: Run tests**

Run: `cargo test -p opencli-rs-core`
Expected: All tests pass.

- [ ] **Step 12: Commit**

```bash
git add crates/opencli-rs-core/
git commit -m "feat(core): implement core data models — Strategy, ArgDef, CliCommand, Registry, CliError, IPage trait"
```

---

### Task 3: Output System (`opencli-rs-output`)

**Files:**
- Create: `crates/opencli-rs-output/src/format.rs`
- Create: `crates/opencli-rs-output/src/table.rs`
- Create: `crates/opencli-rs-output/src/json.rs`
- Create: `crates/opencli-rs-output/src/yaml.rs`
- Create: `crates/opencli-rs-output/src/csv_out.rs`
- Create: `crates/opencli-rs-output/src/markdown.rs`
- Create: `crates/opencli-rs-output/src/render.rs`
- Modify: `crates/opencli-rs-output/src/lib.rs`

Maps to original `output.ts`. Supports 5 formats: table, json, yaml, csv, markdown.

- [ ] **Step 1: Implement OutputFormat and RenderOptions** (`format.rs`)

```rust
use std::time::Duration;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum OutputFormat {
    Table,
    Json,
    Yaml,
    Csv,
    Markdown,
}

impl std::str::FromStr for OutputFormat {
    type Err = String;
    fn from_str(s: &str) -> Result<Self, Self::Err> {
        match s.to_lowercase().as_str() {
            "table" => Ok(Self::Table),
            "json" => Ok(Self::Json),
            "yaml" => Ok(Self::Yaml),
            "csv" => Ok(Self::Csv),
            "md" | "markdown" => Ok(Self::Markdown),
            _ => Err(format!("Unknown format: {}. Use: table, json, yaml, csv, md", s)),
        }
    }
}

impl Default for OutputFormat {
    fn default() -> Self {
        Self::Table
    }
}

#[derive(Debug, Default)]
pub struct RenderOptions {
    pub format: OutputFormat,
    pub columns: Option<Vec<String>>,
    pub title: Option<String>,
    pub elapsed: Option<Duration>,
    pub source: Option<String>,
    pub footer_extra: Option<String>,
}
```

- [ ] **Step 2: Implement each formatter** (`table.rs`, `json.rs`, `yaml.rs`, `csv_out.rs`, `markdown.rs`)

Each formatter takes `data: &Value` and `columns: Option<&[String]>` and returns `String`.

- `table.rs`: Uses `comfy-table` for ASCII table rendering with column auto-width
- `json.rs`: `serde_json::to_string_pretty`
- `yaml.rs`: `serde_yaml::to_string`
- `csv_out.rs`: Uses `csv` crate with RFC 4180 compliance
- `markdown.rs`: Generates `| col1 | col2 |` markdown table

- [ ] **Step 3: Implement render() entry point** (`render.rs`)

Routes to the correct formatter, adds footer (elapsed time, source, etc.), prints with colors.

```rust
use crate::format::{OutputFormat, RenderOptions};
use serde_json::Value;

pub fn render(data: &Value, opts: &RenderOptions) -> String {
    let body = match opts.format {
        OutputFormat::Table => crate::table::render_table(data, opts.columns.as_deref()),
        OutputFormat::Json => crate::json::render_json(data),
        OutputFormat::Yaml => crate::yaml::render_yaml(data),
        OutputFormat::Csv => crate::csv_out::render_csv(data, opts.columns.as_deref()),
        OutputFormat::Markdown => crate::markdown::render_markdown(data, opts.columns.as_deref()),
    };

    let mut output = body;

    // Footer
    let mut footer_parts = vec![];
    if let Some(elapsed) = opts.elapsed {
        footer_parts.push(format!("({:.1}s)", elapsed.as_secs_f64()));
    }
    if let Some(source) = &opts.source {
        footer_parts.push(source.clone());
    }
    if let Some(extra) = &opts.footer_extra {
        footer_parts.push(extra.clone());
    }
    if !footer_parts.is_empty() {
        output.push_str(&format!("\n{}", footer_parts.join(" · ")));
    }

    output
}
```

- [ ] **Step 4: Wire up lib.rs**

- [ ] **Step 5: Write tests for each formatter**

Test with array of objects, single object, empty array, scalar values.

- [ ] **Step 6: Run tests**

Run: `cargo test -p opencli-rs-output`
Expected: All tests pass.

- [ ] **Step 7: Commit**

```bash
git add crates/opencli-rs-output/
git commit -m "feat(output): implement 5-format output system — table, json, yaml, csv, markdown"
```

---

### Task 4: CLI Skeleton (`opencli-rs-cli`)

**Files:**
- Modify: `crates/opencli-rs-cli/src/main.rs`
- Create: `crates/opencli-rs-cli/src/execution.rs`
- Create: `crates/opencli-rs-cli/src/args.rs`

Minimal CLI entry point that can discover adapters, build subcommands, and route to execution. At this stage, only PUBLIC/non-browser commands will work.

- [ ] **Step 1: Implement basic main.rs with clap**

Sets up tokio runtime, initializes tracing, creates Registry, builds dynamic clap subcommands from discovered adapters, routes to `execute_command`.

- [ ] **Step 2: Implement args.rs — argument validation and coercion**

Maps to original `execution.ts` `coerceAndValidateArgs`. Converts string inputs to typed values based on ArgDef.

- [ ] **Step 3: Implement execution.rs — command execution orchestration**

Maps to original `execution.ts`. For now, only supports pipeline execution (no browser). Browser support comes in Phase 4.

- [ ] **Step 4: Verify end-to-end: `cargo run -- --help` shows available commands**

- [ ] **Step 5: Commit**

```bash
git add crates/opencli-rs-cli/
git commit -m "feat(cli): implement CLI skeleton with clap dynamic subcommands and execution routing"
```

---

## Phase 2: Pipeline Engine

### Task 5: Template Expression Engine (`opencli-rs-pipeline`)

**Files:**
- Create: `crates/opencli-rs-pipeline/src/template/mod.rs`
- Create: `crates/opencli-rs-pipeline/src/template/parser.rs`
- Create: `crates/opencli-rs-pipeline/src/template/evaluator.rs`
- Create: `crates/opencli-rs-pipeline/src/template/filters.rs`
- Create: `crates/opencli-rs-pipeline/src/template/expr.pest`
- Modify: `crates/opencli-rs-pipeline/Cargo.toml` (add `pest`, `pest_derive`)

Maps to original `pipeline/template.ts`. This is the `${{ expr }}` engine.

- [ ] **Step 1: Define PEG grammar** (`expr.pest`)

Grammar for the expression language supporting: variable access, arithmetic, comparison, logical ops, pipe filters, ternary, string literals, array indexing.

- [ ] **Step 2: Implement parser** (`parser.rs`)

Parse `${{ expr }}` patterns in strings. Returns AST nodes.

- [ ] **Step 3: Implement evaluator** (`evaluator.rs`)

Walk the AST, evaluate against a `TemplateContext { args, data, item, index }`. Returns `serde_json::Value`.

- [ ] **Step 4: Implement filters** (`filters.rs`)

All 16 built-in filters: `default`, `join`, `upper`, `lower`, `trim`, `truncate`, `replace`, `keys`, `length`, `first`, `last`, `json`, `slugify`, `sanitize`, `ext`, `basename`.

- [ ] **Step 5: Implement render_template() public API** (`mod.rs`)

```rust
pub struct TemplateContext {
    pub args: HashMap<String, Value>,
    pub data: Value,
    pub item: Value,
    pub index: usize,
}

/// Renders ${{ expr }} templates in a string or value.
/// Full expression: "${{ args.limit }}" → typed Value
/// Partial interpolation: "hello ${{ name }}" → String
pub fn render_template(template: &Value, ctx: &TemplateContext) -> Result<Value, CliError>;
pub fn render_template_str(template: &str, ctx: &TemplateContext) -> Result<Value, CliError>;
```

- [ ] **Step 6: Write comprehensive tests**

Test cases from original `template.ts`:
- Variable access: `${{ args.limit }}` → 20
- Nested path: `${{ item.author.name }}` → "Alice"
- Arithmetic: `${{ index + 1 }}` → 1 (when index=0)
- Comparison: `${{ item.score > 10 }}` → true
- Pipe filters: `${{ item.title | truncate(30) }}`
- Fallback: `${{ item.subtitle || "N/A" }}`
- Partial interpolation: `"https://api.com/${{ item.id }}.json"`
- Complex: `${{ Math.min(args.limit + 10, 50) }}`

- [ ] **Step 7: Run tests**

Run: `cargo test -p opencli-rs-pipeline`
Expected: All tests pass.

- [ ] **Step 8: Commit**

```bash
git add crates/opencli-rs-pipeline/
git commit -m "feat(pipeline): implement template expression engine with pest parser and 16 filters"
```

---

### Task 6: Pipeline Executor + Step Registry

**Files:**
- Create: `crates/opencli-rs-pipeline/src/executor.rs`
- Create: `crates/opencli-rs-pipeline/src/context.rs`
- Create: `crates/opencli-rs-pipeline/src/step_registry.rs`
- Modify: `crates/opencli-rs-pipeline/src/lib.rs`

Maps to original `pipeline/executor.ts` and `pipeline/registry.ts`.

- [ ] **Step 1: Implement PipelineContext** (`context.rs`)

Holds mutable `data` state that flows through steps.

- [ ] **Step 2: Implement StepHandler trait and StepRegistry** (`step_registry.rs`)

```rust
#[async_trait]
pub trait StepHandler: Send + Sync {
    fn name(&self) -> &'static str;
    async fn execute(
        &self,
        page: Option<&dyn IPage>,
        params: &Value,
        data: &Value,
        args: &HashMap<String, Value>,
    ) -> Result<Value, CliError>;
}

pub struct StepRegistry {
    handlers: HashMap<String, Box<dyn StepHandler>>,
}
```

- [ ] **Step 3: Implement execute_pipeline** (`executor.rs`)

Sequential step execution with retry logic for browser steps (max 2 retries).

- [ ] **Step 4: Write tests with mock steps**

- [ ] **Step 5: Commit**

```bash
git add crates/opencli-rs-pipeline/
git commit -m "feat(pipeline): implement pipeline executor with step registry and retry logic"
```

---

### Task 7: Transform Steps (select, map, filter, sort, limit)

**Files:**
- Create: `crates/opencli-rs-pipeline/src/steps/mod.rs`
- Create: `crates/opencli-rs-pipeline/src/steps/transform.rs`

Maps to original `pipeline/steps/transform.ts`.

- [ ] **Step 1: Implement select step** — JSONPath-like navigation (`data.results[0].items`)
- [ ] **Step 2: Implement map step** — Transform each item using templates
- [ ] **Step 3: Implement filter step** — Keep items where template evaluates to truthy
- [ ] **Step 4: Implement sort step** — Sort by field, asc/desc
- [ ] **Step 5: Implement limit step** — Take first N items
- [ ] **Step 6: Register all steps in StepRegistry**
- [ ] **Step 7: Write tests for each step**

```rust
// Example test for map step:
#[tokio::test]
async fn test_map_step() {
    let data = json!([{"title": "Hello", "score": 42}]);
    let params = json!({
        "rank": "${{ index + 1 }}",
        "title": "${{ item.title }}",
        "score": "${{ item.score }}"
    });
    let result = map_handler.execute(None, &params, &data, &args).await.unwrap();
    assert_eq!(result, json!([{"rank": 1, "title": "Hello", "score": 42}]));
}
```

- [ ] **Step 8: Run tests**

Run: `cargo test -p opencli-rs-pipeline`
Expected: All tests pass.

- [ ] **Step 9: Commit**

```bash
git add crates/opencli-rs-pipeline/
git commit -m "feat(pipeline): implement transform steps — select, map, filter, sort, limit"
```

---

### Task 8: Fetch Step

**Files:**
- Create: `crates/opencli-rs-pipeline/src/steps/fetch.rs`
- Modify: `crates/opencli-rs-pipeline/Cargo.toml` (add `reqwest`)

Maps to original `pipeline/steps/fetch.ts`. HTTP requests with per-item concurrent execution.

- [ ] **Step 1: Implement single-URL fetch** — Direct HTTP GET/POST with template rendering
- [ ] **Step 2: Implement per-item fetch** — When data is array and URL contains `${{ item }}`, concurrent requests via `FuturesUnordered` (concurrency limit 10)
- [ ] **Step 3: Implement browser-mode fetch** — When page is available, batch all URLs into a single `evaluate()` call (matching original optimization)
- [ ] **Step 4: Support template rendering for URL, headers, params, body**
- [ ] **Step 5: Write tests (use httpbin or mock server)**
- [ ] **Step 6: Commit**

```bash
git add crates/opencli-rs-pipeline/
git commit -m "feat(pipeline): implement fetch step with per-item concurrency and browser-mode batching"
```

---

## Phase 3: Adapter Discovery + Migration

### Task 9: YAML Adapter Parser + build.rs Embedding

**Files:**
- Create: `crates/opencli-rs-discovery/src/yaml_parser.rs`
- Create: `crates/opencli-rs-discovery/src/builtin.rs`
- Create: `crates/opencli-rs-discovery/build.rs`
- Create: `adapters/` directory (copy YAMLs from original project)
- Modify: `crates/opencli-rs-discovery/src/lib.rs`

- [ ] **Step 1: Implement YAML adapter parser** (`yaml_parser.rs`)

Parse YAML adapter files into `CliCommand`. Handle the YAML schema: site, name, description, domain, strategy, browser, args (map format), columns, pipeline.

```rust
pub fn parse_yaml_adapter(content: &str) -> Result<CliCommand, CliError> {
    let raw: Value = serde_yaml::from_str(content)?;
    // Extract fields, convert args map to Vec<ArgDef>, etc.
}
```

- [ ] **Step 2: Implement build.rs for compile-time embedding**

Scans `adapters/` directory, generates a Rust source file with `include_str!` for each YAML.

- [ ] **Step 3: Implement builtin adapter registration** (`builtin.rs`)

```rust
pub fn discover_builtin_adapters(registry: &mut Registry) -> Result<(), CliError> {
    for (path, content) in BUILTIN_ADAPTERS {
        let cmd = parse_yaml_adapter(content)?;
        registry.register(cmd);
    }
    Ok(())
}
```

- [ ] **Step 4: Write tests — parse a sample YAML adapter correctly**
- [ ] **Step 5: Commit**

```bash
git add crates/opencli-rs-discovery/ adapters/
git commit -m "feat(discovery): implement YAML adapter parser with compile-time embedding via build.rs"
```

---

### Task 10: User Adapter + Plugin Discovery

**Files:**
- Create: `crates/opencli-rs-discovery/src/user.rs`
- Create: `crates/opencli-rs-discovery/src/plugin.rs`
- Modify: `crates/opencli-rs-discovery/src/lib.rs`

- [ ] **Step 1: Implement user adapter scanning** (`user.rs`)

Scan `~/.opencli-rs/adapters/**/*.yaml` at runtime, parse and register.

- [ ] **Step 2: Implement plugin discovery** (`plugin.rs`)

Scan `~/.opencli-rs/plugins/`, load plugin manifests.

- [ ] **Step 3: Test with mock directories**
- [ ] **Step 4: Commit**

```bash
git add crates/opencli-rs-discovery/
git commit -m "feat(discovery): implement runtime user adapter and plugin discovery"
```

---

### Task 11: Migrate Pure YAML Adapters

**Files:**
- Create: `adapters/hackernews/*.yaml` (8 files)
- Create: `adapters/devto/*.yaml` (3 files)
- Create: `adapters/lobsters/*.yaml` (4 files)
- Create: `adapters/stackoverflow/*.yaml` (4 files)
- Create: `adapters/steam/*.yaml` (1 file)
- Create: `adapters/v2ex/*.yaml` (8 YAML files)
- Create: `adapters/reddit/*.yaml` (7 YAML files)
- Create: `adapters/linux-do/*.yaml` (6 files)
- Create: `adapters/xueqiu/*.yaml` (7 files)
- Create: `adapters/zhihu/*.yaml` (2 YAML files)
- Create: `adapters/facebook/*.yaml` (10 files)
- Create: `adapters/instagram/*.yaml` (14 files)
- Create: `adapters/tiktok/*.yaml` (15 files)
- Create: `adapters/jike/*.yaml` (3 YAML files)
- Create: `adapters/jimeng/*.yaml` (2 files)
- Create: `adapters/xiaohongshu/*.yaml` (2 YAML files)
- Create: `adapters/bilibili/hot.yaml` (1 file)
- Create: `adapters/douban/*.yaml` (2 YAML files)

Copy all pure YAML adapters from original project, adjusting any TypeScript-specific expressions in templates to be compatible with the Rust expression engine.

- [ ] **Step 1: Copy all hackernews YAML adapters** (top, best, new, show, jobs, ask, search, user)
- [ ] **Step 2: Copy devto, lobsters, stackoverflow, steam YAML adapters**
- [ ] **Step 3: Copy v2ex, reddit, linux-do YAML adapters**
- [ ] **Step 4: Copy xueqiu, zhihu YAML adapters**
- [ ] **Step 5: Copy facebook, instagram, tiktok YAML adapters**
- [ ] **Step 6: Copy jike, jimeng, xiaohongshu, bilibili, douban YAML adapters**
- [ ] **Step 7: Verify all adapters parse correctly**

Run: `cargo test -p opencli-rs-discovery -- --test parse_all_builtin`
Expected: All YAML adapters parse without error.

- [ ] **Step 8: Commit**

```bash
git add adapters/
git commit -m "feat(adapters): migrate all pure YAML adapters from original project (87 files)"
```

---

### Task 12: Migrate TS Adapters → YAML Pipeline

Convert TypeScript adapters that primarily use `page.evaluate(js)` into YAML adapters with `evaluate` pipeline steps.

**Files:**
- Create/modify adapters in `adapters/` for sites that were TS-only:
  bilibili, bloomberg, douban, google, weibo, weread, wikipedia, youtube,
  xiaoyuzhou, apple-podcasts, arxiv, bbc, hf, medium, sinablog, substack,
  yahoo-finance, sinafinance, barchart, etc.

- [ ] **Step 1: Migrate bilibili TS adapters** (me, feed, search, ranking, dynamic, favorite, following, history, user-videos, download, subtitle)

For each adapter: extract the `page.evaluate(js)` JS code → put in YAML pipeline `evaluate` step.

Example conversion:
```yaml
# adapters/bilibili/me.yaml (converted from bilibili/me.ts)
site: bilibili
name: me
description: 我的 Bilibili 个人信息
domain: www.bilibili.com
strategy: cookie

args: []
columns: [name, uid, level]

pipeline:
  - evaluate: |
      (async () => {
        const resp = await fetch('https://api.bilibili.com/x/web-interface/nav', { credentials: 'include' });
        const json = await resp.json();
        const d = json.data;
        return { name: d.uname, uid: d.mid, level: d.level_info.current_level };
      })()
```

- [ ] **Step 2: Migrate bloomberg adapters** (news, markets, tech, politics, opinions, economics, businessweek, industries, main, feeds)
- [ ] **Step 3: Migrate douban TS adapters** (book-hot, movie-hot, marks, reviews, search)
- [ ] **Step 4: Migrate google adapters** (search, news, trends, suggest)
- [ ] **Step 5: Migrate weibo, weread, wikipedia, youtube adapters**
- [ ] **Step 6: Migrate xiaoyuzhou, apple-podcasts, arxiv, medium adapters**
- [ ] **Step 7: Migrate bbc, hf, sinablog, substack, sinafinance adapters**
- [ ] **Step 8: Migrate barchart, yahoo-finance, smzdm, reuters, linkedin adapters**
- [ ] **Step 9: Migrate twitter adapters** (25 commands: timeline, search, post, like, follow, etc.)
- [ ] **Step 10: Migrate xiaohongshu TS adapters** (search, user, creator-*, publish, download)
- [ ] **Step 11: Migrate remaining social/chat adapters** (reddit TS, jike TS, weixin, coupang, ctrip)
- [ ] **Step 12: Migrate desktop app adapters** (cursor, chatgpt, chatwise, codex, doubao, doubao-app, discord-app, notion)
- [ ] **Step 13: Migrate boss, chaoxing, grok, yollomi adapters**
- [ ] **Step 14: Migrate antigravity adapters** (serve, send, read, new, dump, etc.)
- [ ] **Step 15: Verify all migrated adapters parse correctly**

Run: `cargo test -p opencli-rs-discovery`

- [ ] **Step 16: Commit**

```bash
git add adapters/
git commit -m "feat(adapters): migrate all TS adapters to YAML pipeline format"
```

---

### Task 13: Integration Test — Public API Commands End-to-End

**Files:**
- Create: `tests/integration/public_commands.rs`
- Modify: `Cargo.toml` (add integration test)

- [ ] **Step 1: Write E2E test for hackernews top**

```rust
#[tokio::test]
async fn test_hackernews_top() {
    // Load registry, find "hackernews top", execute pipeline, verify output has rank/title/score/author columns
}
```

- [ ] **Step 2: Write E2E test for output formats** (json, yaml, csv, md)
- [ ] **Step 3: Run tests**
- [ ] **Step 4: Commit**

```bash
git add tests/
git commit -m "test: add end-to-end integration tests for public API commands"
```

---

## Phase 4: Browser Bridge

### Task 14: Daemon Client (`opencli-rs-browser`)

**Files:**
- Create: `crates/opencli-rs-browser/src/daemon_client.rs`
- Create: `crates/opencli-rs-browser/src/types.rs`
- Modify: `crates/opencli-rs-browser/src/lib.rs`

Maps to original `browser/daemon-client.ts`. HTTP client for communicating with the Daemon.

- [ ] **Step 1: Implement DaemonCommand and DaemonResult types** (`types.rs`)

```rust
#[derive(Debug, Serialize)]
pub struct DaemonCommand {
    pub id: String,
    pub action: String,       // exec, navigate, tabs, cookies, screenshot, close-window, sessions
    pub code: Option<String>,
    pub url: Option<String>,
    pub workspace: Option<String>,
    pub tab_id: Option<u64>,
    pub format: Option<String>,
}

#[derive(Debug, Deserialize)]
pub struct DaemonResult {
    pub id: String,
    pub ok: bool,
    pub data: Option<Value>,
    pub error: Option<String>,
}
```

- [ ] **Step 2: Implement DaemonClient** (`daemon_client.rs`)

```rust
pub struct DaemonClient {
    base_url: String,
    client: reqwest::Client,
}

impl DaemonClient {
    pub fn new(port: u16) -> Self;
    pub async fn send_command(&self, cmd: DaemonCommand) -> Result<Value, CliError>;
    pub async fn is_running(&self) -> bool;
    pub async fn is_extension_connected(&self) -> bool;
    // Retry: up to 4 attempts, exponential backoff
    // Timeout: 30s per command
}
```

- [ ] **Step 3: Write tests with mock HTTP server**
- [ ] **Step 4: Commit**

```bash
git add crates/opencli-rs-browser/
git commit -m "feat(browser): implement DaemonClient HTTP client with retry and connection pooling"
```

---

### Task 15: DaemonPage — IPage over HTTP

**Files:**
- Create: `crates/opencli-rs-browser/src/page.rs`
- Create: `crates/opencli-rs-browser/src/dom_helpers.rs`
- Create: `crates/opencli-rs-browser/src/stealth.rs`

Maps to original `browser/page.ts`. Implements IPage trait by sending commands to Daemon.

- [ ] **Step 1: Implement DaemonPage struct**

```rust
pub struct DaemonPage {
    client: DaemonClient,
    workspace: String,
    tab_id: RwLock<Option<u64>>,
}
```

- [ ] **Step 2: Implement IPage trait for DaemonPage**

Each method constructs a `DaemonCommand` and sends via client. Maps all IPage methods to daemon actions.

- [ ] **Step 3: Implement dom_helpers.rs** — JS code templates for click, type, scroll, etc.

Port the JavaScript code strings from original `browser/dom-helpers.ts`.

- [ ] **Step 4: Implement stealth.rs** — Anti-detection JS injection

Port stealth scripts from original `browser/stealth.ts`.

- [ ] **Step 5: Write tests**
- [ ] **Step 6: Commit**

```bash
git add crates/opencli-rs-browser/
git commit -m "feat(browser): implement DaemonPage (IPage over HTTP) with DOM helpers and stealth"
```

---

### Task 16: Daemon Server

**Files:**
- Create: `crates/opencli-rs-browser/src/daemon.rs`
- Create: `crates/opencli-rs-browser/src/daemon/server.rs`
- Create: `crates/opencli-rs-browser/src/daemon/ws_handler.rs`
- Create: `crates/opencli-rs-browser/src/daemon/command_queue.rs`

Maps to original `daemon.ts`. HTTP + WebSocket server that bridges CLI and Chrome extension.

- [ ] **Step 1: Implement HTTP server with axum**

Endpoints:
- `POST /command` — Accept commands from CLI, queue for extension
- `GET /status` — Return daemon status + extension connection state
- `GET /health` — Health check

Security: Origin check, `X-OpenCLI` header validation, 1MB body limit.

- [ ] **Step 2: Implement WebSocket handler** (`ws_handler.rs`)

`/ext` endpoint for Chrome extension connection. Protocol:
- Extension connects → daemon tracks connection
- CLI sends command → daemon forwards via WebSocket → extension executes → returns result
- Heartbeat: ping every 15s

- [ ] **Step 3: Implement command queue** (`command_queue.rs`)

Request queuing with 120s timeout. Commands wait for extension response.

- [ ] **Step 4: Implement idle shutdown** — 5 minute auto-exit when no commands

- [ ] **Step 5: Write tests**
- [ ] **Step 6: Commit**

```bash
git add crates/opencli-rs-browser/
git commit -m "feat(browser): implement Daemon server with HTTP + WebSocket bridge"
```

---

### Task 17: BrowserBridge — Daemon Factory

**Files:**
- Create: `crates/opencli-rs-browser/src/bridge.rs`
- Modify: `crates/opencli-rs-browser/src/lib.rs`

Maps to original `browser/mcp.ts`. Manages daemon lifecycle and provides IPage instances.

- [ ] **Step 1: Implement BrowserBridge**

```rust
pub struct BrowserBridge {
    port: u16,
    daemon_process: Option<Child>,
}

impl BrowserBridge {
    pub async fn connect(&mut self, opts: Option<ConnectOptions>) -> Result<Box<dyn IPage>, CliError>;
    pub async fn close(&mut self) -> Result<(), CliError>;
    // connect() flow:
    // 1. Check if daemon already running (GET /health)
    // 2. If not → spawn daemon as child process
    // 3. Wait for daemon ready (poll /health, 10s timeout)
    // 4. Check extension connected (GET /status)
    // 5. Return DaemonPage
}
```

- [ ] **Step 2: Write tests**
- [ ] **Step 3: Commit**

```bash
git add crates/opencli-rs-browser/
git commit -m "feat(browser): implement BrowserBridge daemon factory with auto-spawn"
```

---

### Task 18: CDP Direct Connection

**Files:**
- Create: `crates/opencli-rs-browser/src/cdp.rs`

Maps to original `browser/cdp.ts`. Direct WebSocket CDP connection (when `OPENCLI_CDP_ENDPOINT` is set).

- [ ] **Step 1: Implement CdpPage**

```rust
pub struct CdpPage {
    ws: WebSocketStream,
    target_id: String,
}

impl CdpPage {
    pub async fn connect(endpoint: &str) -> Result<Self, CliError>;
    // Connects to CDP /json endpoint, selects suitable target, attaches debugger
}
```

- [ ] **Step 2: Implement IPage trait for CdpPage**

Each method sends CDP commands via WebSocket (Runtime.evaluate, Page.navigate, etc.)

- [ ] **Step 3: Write tests**
- [ ] **Step 4: Commit**

```bash
git add crates/opencli-rs-browser/
git commit -m "feat(browser): implement CdpPage for direct CDP WebSocket connection"
```

---

### Task 19: Browser Pipeline Steps

**Files:**
- Create: `crates/opencli-rs-pipeline/src/steps/browser.rs`
- Create: `crates/opencli-rs-pipeline/src/steps/intercept.rs`
- Create: `crates/opencli-rs-pipeline/src/steps/tap.rs`
- Create: `crates/opencli-rs-pipeline/src/steps/download.rs`
- Modify: `crates/opencli-rs-pipeline/src/steps/mod.rs`

- [ ] **Step 1: Implement browser steps** — navigate, click, type, wait, press, snapshot, evaluate

Each step delegates to the `IPage` trait methods.

- [ ] **Step 2: Implement intercept step** — Install network interceptor, collect matching requests

- [ ] **Step 3: Implement tap step** — Store action bridge (Pinia/Vuex)

Port the JS injection code from original `pipeline/steps/tap.ts`.

- [ ] **Step 4: Implement download step** — Media and article download

- [ ] **Step 5: Register all steps in StepRegistry**

- [ ] **Step 6: Write tests**
- [ ] **Step 7: Commit**

```bash
git add crates/opencli-rs-pipeline/
git commit -m "feat(pipeline): implement browser steps — navigate, click, type, evaluate, intercept, tap, download"
```

---

### Task 20: DOM Snapshot Engine

**Files:**
- Create: `crates/opencli-rs-browser/src/dom_snapshot.rs`
- Create: `crates/opencli-rs-browser/src/tabs.rs`

Maps to original `browser/dom-snapshot.ts` and `browser/tabs.ts`.

- [ ] **Step 1: Implement DOM snapshot** — Multi-layer pruning, viewport expansion, max depth, dedup, LLM-friendly output

Port the JS code that runs in browser to capture and prune DOM tree.

- [ ] **Step 2: Implement tab management** — List, create, select, close tabs

- [ ] **Step 3: Write tests**
- [ ] **Step 4: Commit**

```bash
git add crates/opencli-rs-browser/
git commit -m "feat(browser): implement DOM snapshot engine and tab management"
```

---

### Task 21: Wire Browser into CLI Execution

**Files:**
- Modify: `crates/opencli-rs-cli/src/execution.rs`
- Modify: `crates/opencli-rs-cli/src/main.rs`

Connect the browser bridge into the command execution flow.

- [ ] **Step 1: Add browser session management to execution.rs**

```rust
async fn execute_command(cmd: &CliCommand, kwargs: CommandArgs) -> Result<Value, CliError> {
    if cmd.needs_browser() {
        let mut bridge = BrowserBridge::new(daemon_port());
        let page = bridge.connect(None).await?;
        // Pre-navigate if domain is set
        if let Some(domain) = &cmd.domain {
            page.goto(&format!("https://{}", domain), None).await?;
        }
        let result = run_command(cmd, Some(page.as_ref()), kwargs).await?;
        bridge.close().await?;
        Ok(result)
    } else {
        run_command(cmd, None, kwargs).await
    }
}
```

- [ ] **Step 2: Add timeout control** — `tokio::time::timeout` wrapping command execution

- [ ] **Step 3: Add CDP mode detection** — Check `OPENCLI_CDP_ENDPOINT` env var

- [ ] **Step 4: Test with a browser-dependent adapter**
- [ ] **Step 5: Commit**

```bash
git add crates/opencli-rs-cli/
git commit -m "feat(cli): wire browser bridge into command execution with timeout and CDP support"
```

---

## Phase 5: External CLI + AI Capabilities

### Task 22: External CLI Management (`opencli-rs-external`)

**Files:**
- Create: `crates/opencli-rs-external/src/registry.rs`
- Create: `crates/opencli-rs-external/src/executor.rs`
- Create: `crates/opencli-rs-external/src/installer.rs`
- Create: `resources/external-clis.yaml`
- Modify: `crates/opencli-rs-external/src/lib.rs`

Maps to original `external.ts` + `external-clis.yaml`.

- [ ] **Step 1: Copy external-clis.yaml to resources/**

Contains: gh, obsidian, readwise, kubectl, docker, gws.

- [ ] **Step 2: Implement ExternalCli struct and loader** (`registry.rs`)

Parse built-in + user (`~/.opencli-rs/external-clis.yaml`) registries.

- [ ] **Step 3: Implement binary detection and execution** (`executor.rs`)

`which` equivalent + `tokio::process::Command` for pass-through execution. Shell operator validation (reject `&&`, `|`, `;`, `$()`).

- [ ] **Step 4: Implement installer** (`installer.rs`)

Platform-aware install command execution (brew, apt, etc.)

- [ ] **Step 5: Write tests**
- [ ] **Step 6: Commit**

```bash
git add crates/opencli-rs-external/ resources/
git commit -m "feat(external): implement external CLI management — loading, detection, execution, installation"
```

---

### Task 23: AI — Explore (API Discovery)

**Files:**
- Create: `crates/opencli-rs-ai/src/explore.rs`
- Create: `crates/opencli-rs-ai/src/types.rs`
- Modify: `crates/opencli-rs-ai/src/lib.rs`

Maps to original `explore.ts`.

- [ ] **Step 1: Implement ExploreManifest and related types** (`types.rs`)

```rust
pub struct ExploreManifest {
    pub url: String,
    pub endpoints: Vec<DiscoveredEndpoint>,
    pub framework: Option<String>,
    pub store: Option<String>,
    pub auth_indicators: Vec<String>,
}

pub struct DiscoveredEndpoint {
    pub url: String,
    pub method: String,
    pub content_type: Option<String>,
    pub fields: Vec<FieldInfo>,
    pub confidence: f64,
    pub auth_level: Strategy,
}
```

- [ ] **Step 2: Implement explore function**

```rust
pub async fn explore(
    page: &dyn IPage,
    url: &str,
    options: ExploreOptions,
) -> Result<ExploreManifest, CliError>;
```

Flow: navigate → auto-scroll → capture network traffic → analyze JSON responses → detect framework → infer auth → identify fields.

- [ ] **Step 3: Write tests**
- [ ] **Step 4: Commit**

```bash
git add crates/opencli-rs-ai/
git commit -m "feat(ai): implement explore — API discovery with framework detection and auth inference"
```

---

### Task 24: AI — Synthesize + Cascade + Generate

**Files:**
- Create: `crates/opencli-rs-ai/src/synthesize.rs`
- Create: `crates/opencli-rs-ai/src/cascade.rs`
- Create: `crates/opencli-rs-ai/src/generate.rs`
- Modify: `crates/opencli-rs-ai/src/lib.rs`

- [ ] **Step 1: Implement synthesize** — Generate YAML adapter candidates from explore results
- [ ] **Step 2: Implement cascade** — Auto-probe auth strategy (PUBLIC → COOKIE → HEADER → INTERCEPT → UI)
- [ ] **Step 3: Implement generate** — One-shot: explore → synthesize → register
- [ ] **Step 4: Write tests**
- [ ] **Step 5: Commit**

```bash
git add crates/opencli-rs-ai/
git commit -m "feat(ai): implement synthesize, cascade, and generate commands"
```

---

## Phase 6: Polish + Complete

### Task 25: Built-in Commands (doctor, completion)

**Files:**
- Create: `crates/opencli-rs-cli/src/commands/mod.rs`
- Create: `crates/opencli-rs-cli/src/commands/doctor.rs`
- Create: `crates/opencli-rs-cli/src/commands/completion.rs`
- Modify: `crates/opencli-rs-cli/Cargo.toml` (add `clap_complete`)

- [ ] **Step 1: Implement doctor command** — Diagnose: Chrome running? Extension installed? Daemon reachable? External CLIs available?
- [ ] **Step 2: Implement shell completion** — Using `clap_complete` for bash/zsh/fish
- [ ] **Step 3: Register built-in commands in clap**
- [ ] **Step 4: Commit**

```bash
git add crates/opencli-rs-cli/
git commit -m "feat(cli): implement doctor diagnostics and shell completion"
```

---

### Task 26: Comprehensive Testing

**Files:**
- Create: `tests/smoke/adapter_smoke.rs`
- Create: `tests/integration/browser_commands.rs`
- Create: `tests/integration/external_cli.rs`
- Create: `tests/integration/output_formats.rs`

- [ ] **Step 1: Adapter smoke test** — All adapters load and register without error
- [ ] **Step 2: Output format tests** — Each format renders correctly for various data shapes
- [ ] **Step 3: Browser command tests** (require Chrome + extension)
- [ ] **Step 4: External CLI tests** (mock binaries)
- [ ] **Step 5: Run full test suite**

Run: `cargo test --workspace`
Expected: All tests pass.

- [ ] **Step 6: Commit**

```bash
git add tests/
git commit -m "test: add comprehensive smoke, integration, and output format tests"
```

---

### Task 27: Build Configuration + Release

**Files:**
- Create: `.cargo/config.toml`
- Create: `Makefile` or `justfile`
- Modify: `Cargo.toml` (release profile)

- [ ] **Step 1: Configure release profile**

```toml
[profile.release]
lto = true
codegen-units = 1
strip = true
```

- [ ] **Step 2: Create build scripts for cross-compilation targets**

- macOS (aarch64-apple-darwin, x86_64-apple-darwin)
- Linux (x86_64-unknown-linux-musl)
- Windows (x86_64-pc-windows-msvc)

- [ ] **Step 3: Verify release build**

Run: `cargo build --release`
Expected: Single binary at `target/release/opencli-rs`, size ~10-15MB.

- [ ] **Step 4: Commit**

```bash
git add .cargo/ Cargo.toml Makefile
git commit -m "build: add release profile and cross-compilation configuration"
```

---

## Summary

| Phase | Tasks | Description |
|-------|-------|-------------|
| 1 | 1-4 | Foundation: Workspace + Core + Output + CLI Skeleton |
| 2 | 5-8 | Pipeline Engine: Template + Executor + Steps |
| 3 | 9-13 | Adapter Discovery + Migration (all 57+ sites) |
| 4 | 14-21 | Browser Bridge: Daemon + CDP + IPage + Browser Steps |
| 5 | 22-24 | External CLI + AI Capabilities |
| 6 | 25-27 | Polish: Doctor, Completion, Tests, Release |

Total: **27 tasks**, each with multiple steps and a git commit.
