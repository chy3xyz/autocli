# AutoCLI Zig 架构文档 (ard.md)

## 1. 项目概述

将 Rust 实现的 AutoCLI 重写为 Zig 0.17.0。保持功能等价，利用 Zig 的 comptime 特性优化启动速度和二进制体积。

**目标**: 单一可执行文件，零运行时依赖，支持 55+ 站点的 333 个命令。

## 2. 模块分解

对应 Rust 的 workspace crates，Zig 项目使用以下模块结构：

```
src/
├── main.zig           # CLI 入口，参数解析，命令路由
├── core/
│   ├── mod.zig        # Strategy, CliCommand, Registry, Error
│   ├── strategy.zig   # public/cookie/header/intercept/ui
│   ├── command.zig    # CliCommand 结构体
│   ├── registry.zig   # 命令注册表
│   ├── error.zig      # 错误类型和图标
│   ├── page.zig       # IPage vtable 和选项结构
│   └── args.zig       # ArgDef, ArgType
├── pipeline/
│   ├── mod.zig        # executor, context
│   ├── executor.zig   # 步骤执行引擎
│   ├── context.zig    # PipelineContext
│   ├── step_registry.zig  # StepHandler vtable 注册
│   ├── steps/
│   │   ├── fetch.zig      # HTTP 请求
│   │   ├── browser.zig    # navigate, click, type, wait, evaluate...
│   │   ├── transform.zig  # select, map, filter, sort, limit
│   │   ├── intercept.zig  # 网络拦截
│   │   ├── tap.zig        # 状态管理桥接
│   │   └── download.zig   # 媒体/文章下载
│   └── template/
│       ├── mod.zig        # render_template, render_template_str
│       ├── parser.zig     # 表达式解析器（手写的 Pratt parser）
│       ├── evaluator.zig  # AST 求值
│       └── filters.zig    # 16 个内置过滤器
├── browser/
│   ├── mod.zig        # BrowserBridge
│   ├── daemon.zig     # HTTP daemon (port 19825)
│   ├── daemon_client.zig  # HTTP 客户端
│   ├── cdp.zig        # WebSocket CDP 协议
│   ├── page.zig       # DaemonPage, CdpPage 实现
│   ├── bridge.zig     # BrowserBridge 统一接口
│   ├── types.zig      # DaemonCommand, DaemonResult
│   ├── dom_helpers.zig    # DOM 工具
│   └── stealth.zig    # 反检测
├── output/
│   ├── mod.zig        # render 分发
│   ├── format.zig     # OutputFormat 枚举
│   ├── render.zig     # 主渲染逻辑
│   ├── table.zig      # ASCII 表格
│   ├── json.zig       # JSON 输出
│   ├── yaml.zig       # YAML 输出
│   ├── csv.zig        # CSV 输出
│   └── markdown.zig   # Markdown 表格
├── discovery/
│   ├── mod.zig        # 适配器发现
│   ├── yaml_parser.zig    # YAML → CliCommand
│   └── builtin.zig    # comptime 嵌入内置适配器
├── external/
│   ├── mod.zig        # 外部 CLI 加载和执行
│   └── loader.zig     # external-clis.yaml 解析
└── ai/
    ├── mod.zig        # AI 功能入口
    ├── explore.zig    # 网站 API 探测
    ├── generate.zig   # 适配器生成
    ├── cascade.zig    # 认证策略探测
    └── config.zig     # AI 配置和 token 管理
```

## 3. 关键设计决策

### 3.1 Trait → Vtable

Zig 没有 trait，使用 vtable + opaque pointer 模式：

```zig
// core/page.zig
pub const IPage = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        goto: *const fn (*anyopaque, []const u8, ?GotoOptions) Error!void,
        evaluate: *const fn (*anyopaque, []const u8) Error!Value,
        click: *const fn (*anyopaque, []const u8) Error!void,
        // ... 其他方法
        close: *const fn (*anyopaque) Error!void,
    };
};
```

### 3.2 async/await → 同步 + 线程池

Zig 0.17.0 已移除 async/await。采用同步 I/O + 线程池策略：
- HTTP 请求: 使用 `std.http.Client`（阻塞式）
- Browser 操作: 通过 HTTP/WebSocket 与 daemon 通信（同步）
- 并发 fetch: 使用 `std.Thread` 手动管理并发

### 3.3 comptime 适配器嵌入

替代 Rust 的 `build.rs` + `include!` 宏：

```zig
// discovery/builtin.zig
const builtin_adapters = blk: {
    @setEvalBranchQuota(100000);
    const adapters_dir = "../_def/AutoCLI/adapters";
    // comptime 读取目录，生成适配器数组
    break :blk // ... 生成的数组
};
```

### 3.4 JSON Value 类型

使用 `std.json.Value` 作为动态数据类型，替代 Rust 的 `serde_json::Value`。

### 3.5 错误处理

Zig 的错误联合类型替代 Rust 的 `thiserror`：

```zig
pub const Error = error{
    BrowserConnect,
    AdapterLoad,
    CommandExecution,
    Config,
    AuthRequired,
    Timeout,
    Argument,
    EmptyResult,
    Selector,
    Pipeline,
    Http,
    Io,
    Json,
    Yaml,
};
```

## 4. 数据流

```
User Input
    ↓
main.zig (arg parsing)
    ↓
Registry (discover adapters)
    ↓
Route to: built-in / adapter / external CLI
    ↓
Adapter → execute_command()
    ↓
Pipeline Executor (sequential steps)
    ↓
    ├─ fetch → HTTP client
    ├─ browser steps → BrowserBridge → Daemon/CDP
    └─ transform → in-memory data manipulation
    ↓
Output Renderer (table/json/yaml/csv/md)
    ↓
stdout
```

## 5. 依赖选择

| Rust 依赖 | Zig 替代方案 | 说明 |
|-----------|-------------|------|
| clap | 手写参数解析 | Zig 标准库 `std.process.args` + 手动解析 |
| serde_json | std.json | Zig 0.17.0 内置 JSON 解析/序列化 |
| serde_yaml | 手写 YAML 解析器 | 仅解析适配器 YAML，功能有限，可手写 |
| reqwest | std.http.Client | Zig 标准库 HTTP 客户端 |
| tokio | std.Thread | 同步 I/O + 线程池 |
| pest | 手写 Pratt Parser | 模板表达式语法简单，手写 parser 更轻量 |
| axum | std.http.Server | Zig 标准库 HTTP server（daemon 用） |
| tungstenite | 手写 WebSocket | CDP 通信用，协议简单可手写 |
| tracing | std.log | Zig 标准库日志 |

**结论**: 零外部依赖，全部使用 Zig 标准库 + 手写解析器。

## 6. Pipeline Steps（14 种）

| Step | Category | Params | Browser |
|------|----------|--------|---------|
| fetch | HTTP | URL string / {url, method, headers, body, params} | No |
| evaluate | Browser | JS expression string | Yes |
| navigate | Browser | URL string / {url, settleMs} | Yes |
| click | Browser | CSS selector string | Yes |
| type | Browser | {selector, text} | Yes |
| wait | Browser | seconds / {time, selector, text} | Yes |
| select | Transform | dotted path string | No |
| map | Transform | object with template values | No |
| filter | Transform | condition string | No |
| sort | Transform | field string / {by, order} | No |
| limit | Transform | number / template string | No |
| intercept | Browser | {pattern} | Yes |
| tap | Browser | {action, url} | Yes |
| download | Download | {type, output, quality} | Yes |

## 7. Template 表达式语法

使用手写 Pratt parser 替代 pest PEG parser。

**语法支持**:
- 变量: `args.limit`, `item.title`, `index`
- 属性访问: `item.author.name`
- 数组索引: `data[0].name`
- 算术: `+`, `-`, `*`, `/`, `%`
- 比较: `>`, `<`, `>=`, `<=`, `==`, `!=`
- 逻辑: `&&`, `||`, `!`
- 三元: `condition ? true_expr : false_expr`
- 管道过滤器: `expr | filter(args)`
- 函数调用: `Math.min(a, b)`

**16 个内置过滤器**:
`default`, `join`, `upper`, `lower`, `trim`, `truncate`, `replace`, `keys`, `length`, `first`, `last`, `json`, `slugify`, `sanitize`, `ext`, `basename`

## 8. Browser Bridge 架构

```
CLI Process
    ├─ spawn daemon subprocess (--daemon)
    └─ BrowserBridge (HTTP client)
            ↓ HTTP (port 19825)
    Daemon (std.http.Server)
            ↓ WebSocket
    Chrome Extension (CDP)
            ↓ chrome.debugger API
    Chrome Browser
```

**IPage 方法**: goto, url, title, content, evaluate, wait_for_selector, wait_for_timeout, click, type_text, cookies, set_cookies, screenshot, snapshot, auto_scroll, tabs, switch_tab, close, intercept_requests, get_intercepted_requests, get_network_requests

## 9. 实现顺序

### Phase 1: 基础框架
1. `build.zig` - 项目配置
2. `core/` - Strategy, Error, ArgDef, CliCommand, Registry
3. `output/` - OutputFormat, RenderOptions, 基础 render

### Phase 2: Pipeline 核心
4. `pipeline/template/` - Parser, Evaluator, Filters
5. `pipeline/context.zig` - PipelineContext
6. `pipeline/step_registry.zig` - StepHandler vtable
7. `pipeline/steps/transform.zig` - select, map, filter, sort, limit
8. `pipeline/steps/fetch.zig` - HTTP fetch
9. `pipeline/executor.zig` - 步骤执行引擎

### Phase 3: Browser 支持
10. `browser/types.zig` - Daemon 协议类型
11. `browser/daemon.zig` - HTTP daemon
12. `browser/daemon_client.zig` - HTTP 客户端
13. `browser/cdp.zig` - CDP WebSocket 客户端
14. `browser/page.zig` - DaemonPage, CdpPage
15. `browser/bridge.zig` - BrowserBridge
16. `pipeline/steps/browser.zig` - navigate, click, type, wait, evaluate...

### Phase 4: 适配器发现
17. `discovery/yaml_parser.zig` - YAML 解析
18. `discovery/builtin.zig` - comptime 适配器嵌入
19. `discovery/mod.zig` - 发现逻辑

### Phase 5: CLI 和集成
20. `external/` - 外部 CLI 透传
21. `ai/` - explore, generate, cascade
22. `main.zig` - CLI 入口，动态子命令，built-in 命令

## 10. 技术难点

### 10.1 YAML 解析
适配器 YAML 结构简单且固定，手写递归下降解析器比引入外部库更轻量。

### 10.2 comptime 文件系统读取
Zig 的 `@embedFile` 只能嵌入单个文件。需要使用 `build.zig` 在构建时生成包含所有适配器的 Zig 源文件。

### 10.3 HTTP Daemon
使用 `std.http.Server` 实现简单的 HTTP daemon，处理 ping、version check、shutdown 等端点。

### 10.4 CDP WebSocket
Chrome DevTools Protocol 基于 JSON-RPC over WebSocket。需要手写 WebSocket 帧解析和 CDP 消息封装。

## 11. 配置和环境

**环境变量**:
- `OPENCLI_VERBOSE` - 启用详细输出
- `OPENCLI_DAEMON_PORT` - Daemon 端口（默认 19825）
- `OPENCLI_CDP_ENDPOINT` - 直接 CDP 端点
- `OPENCLI_BROWSER_*_TIMEOUT` - 各种超时

**配置路径**:
- `~/.autocli/adapters/` - 用户自定义适配器
- `~/.autocli/config.json` - 认证 token
- `~/.autocli/external-clis.yaml` - 外部 CLI 注册

## 12. 测试策略

- 单元测试: 每个模块的 `test` 块
- 集成测试: 使用 mock IPage 测试 pipeline
- 端到端测试: 针对 public API 命令（hackernews, devto 等）

## 13. 二进制优化

参考 Rust 的 release 配置：
- LTO (Link Time Optimization): Zig 的 `-flto`
- 单 codegen unit: `-fno-emit-bin` 后手动链接
- Strip symbols: `--strip`
- 目标: < 5MB 单一静态二进制文件
