const std = @import("std");
const json = @import("std").json;
const CliError = @import("core").CliError;
const IPage = @import("core").IPage;
const StepHandler = @import("../registry.zig").StepHandler;
const StepRegistry = @import("../registry.zig").StepRegistry;
const TemplateContext = @import("../template/mod.zig").TemplateContext;
const renderTemplateStr = @import("../template/mod.zig").renderTemplateStr;
const freeJsonValue = @import("../executor.zig").freeJsonValue;
const renderTemplate = @import("../template/mod.zig").renderTemplate;

/// Escape a string for safe inclusion in JS template literals (backtick strings).
fn escapeJsTemplateLiteral(allocator: std.mem.Allocator, s: []const u8) ![]const u8 {
    var count: usize = 0;
    var i: usize = 0;
    while (i < s.len) : (i += 1) {
        if (s[i] == '\\' or s[i] == '`') {
            count += 1;
        } else if (s[i] == '$' and i + 1 < s.len and s[i + 1] == '{') {
            count += 1;
            i += 1;
        }
    }
    if (count == 0) return try allocator.dupe(u8, s);
    const buf = try allocator.alloc(u8, s.len + count);
    var j: usize = 0;
    i = 0;
    while (i < s.len) : (i += 1) {
        if (s[i] == '\\' or s[i] == '`') {
            buf[j] = '\\';
            j += 1;
            buf[j] = s[i];
            j += 1;
        } else if (s[i] == '$' and i + 1 < s.len and s[i + 1] == '{') {
            buf[j] = '\\';
            j += 1;
            buf[j] = '$';
            j += 1;
            i += 1;
            buf[j] = '{';
            j += 1;
        } else {
            buf[j] = s[i];
            j += 1;
        }
    }
    return buf;
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

fn requirePage(page: ?IPage) CliError!IPage {
    return page orelse return CliError.Pipeline;
}

fn defaultCtx(data: json.Value, args: std.StringHashMap(json.Value)) TemplateContext {
    return TemplateContext{
        .args = args,
        .data = data,
        .item = .null,
        .index = 0,
    };
}

fn renderStrParam(params: json.Value, data: json.Value, args: std.StringHashMap(json.Value), allocator: std.mem.Allocator) CliError![]const u8 {
    const raw = switch (params) {
        .string => |s| s,
        else => return CliError.Pipeline,
    };
    const ctx = defaultCtx(data, args);
    const rendered = try renderTemplateStr(raw, ctx, allocator);
    return switch (rendered) {
        .string => |s| s,
        else => {
            freeJsonValue(allocator, rendered);
            return CliError.Pipeline;
        },
    };
}

/// Escape a string for safe inclusion in single-quoted JS strings.
fn escapeJsStringSingle(allocator: std.mem.Allocator, s: []const u8) ![]const u8 {
    var count: usize = 0;
    for (s) |c| {
        if (c == '\\' or c == '\'') count += 1;
    }
    if (count == 0) return try allocator.dupe(u8, s);
    const buf = try allocator.alloc(u8, s.len + count);
    var i: usize = 0;
    for (s) |c| {
        if (c == '\\' or c == '\'') {
            buf[i] = '\\';
            i += 1;
        }
        buf[i] = c;
        i += 1;
    }
    return buf;
}

/// Escape a string for safe inclusion in double-quoted JS strings.
fn escapeJsStringDouble(allocator: std.mem.Allocator, s: []const u8) ![]const u8 {
    var count: usize = 0;
    for (s) |c| {
        switch (c) {
            '\\', '"', '\n', '\r', '\t' => count += 1,
            else => {},
        }
    }
    if (count == 0) return try allocator.dupe(u8, s);
    const buf = try allocator.alloc(u8, s.len + count);
    var i: usize = 0;
    for (s) |c| {
        switch (c) {
            '\\', '"', '\n', '\r', '\t' => {
                buf[i] = '\\';
                i += 1;
                buf[i] = switch (c) {
                    '\n' => 'n',
                    '\r' => 'r',
                    '\t' => 't',
                    else => c,
                };
                i += 1;
            },
            else => { buf[i] = c; i += 1; },
        }
    }
    return buf;
}

// ---------------------------------------------------------------------------
// NavigateStep
// ---------------------------------------------------------------------------

pub const NavigateStep = struct {
    pub fn name(_: *anyopaque) []const u8 {
        return "navigate";
    }

    pub fn execute(
        _: *anyopaque,
        allocator: std.mem.Allocator,
        io: std.Io,
        page: ?IPage,
        params: json.Value,
        data: json.Value,
        args: std.StringHashMap(json.Value),
    ) CliError!json.Value {
        const pg = try requirePage(page);
        const ctx = defaultCtx(data, args);

        // Parse URL and optional settleMs
        var url: []const u8 = "";
        var url_owned = false;
        var settle_ms: ?u64 = null;

        switch (params) {
            // navigate: "https://example.com"
            .string => |s| {
                const rendered = try renderTemplateStr(s, ctx, allocator);
                url = switch (rendered) {
                    .string => |u| u,
                    else => {
                        freeJsonValue(allocator, rendered);
                        return CliError.Pipeline;
                    },
                };
                url_owned = true;
            },
            // navigate: { url: "...", settleMs: 2000 }
            .object => |obj| {
                const url_val = obj.get("url") orelse return CliError.Pipeline;
                const url_str = switch (url_val) {
                    .string => |s| s,
                    else => return CliError.Pipeline,
                };
                const rendered = try renderTemplateStr(url_str, ctx, allocator);
                url = switch (rendered) {
                    .string => |u| u,
                    else => {
                        freeJsonValue(allocator, rendered);
                        return CliError.Pipeline;
                    },
                };
                url_owned = true;
                if (obj.get("settleMs")) |ms_val| {
                    settle_ms = switch (ms_val) {
                        .integer => |n| if (n < 0) null else @as(u64, @intCast(n)),
                        .float => |n| if (n < 0) null else @as(u64, @intFromFloat(n)),
                        else => null,
                    };
                }
            },
            else => return CliError.Pipeline,
        }
        defer if (url_owned) allocator.free(url);

        try pg.goto(url, null);

        if (settle_ms) |ms| {
            std.Io.sleep(io, std.Io.Duration.fromMilliseconds(@intCast(ms)), .real) catch |err| {
                std.log.warn("navigate settle sleep failed: {s}", .{@errorName(err)});
            };
        } else {
            // Auto-detect: wait for network idle + DOM stable via JS
            const wait_js =
                \\new Promise((resolve) => {
                \\    let lastActivity = Date.now();
                \\    let checkCount = 0;
                \\    const observer = new MutationObserver(() => { lastActivity = Date.now(); });
                \\    observer.observe(document.body || document.documentElement, {
                \\        childList: true, subtree: true, attributes: true
                \\    });
                \\    let lastResourceCount = performance.getEntriesByType('resource').length;
                \\    const check = () => {
                \\        const now = Date.now();
                \\        const currentResources = performance.getEntriesByType('resource').length;
                \\        if (currentResources !== lastResourceCount) {
                \\            lastActivity = now;
                \\            lastResourceCount = currentResources;
                \\        }
                \\        checkCount++;
                \\        if ((now - lastActivity > 1500 && checkCount > 5) || checkCount > 60) {
                \\            observer.disconnect();
                \\            resolve(true);
                \\        } else {
                \\            setTimeout(check, 250);
                \\        }
                \\    };
                \\    setTimeout(check, 500);
                \\})
            ;
            const wait_result = try pg.evaluate(wait_js);
            defer freeJsonValue(allocator, wait_result);
        }

        return data;
    }

    pub fn isBrowserStep(_: *anyopaque) bool {
        return true;
    }

    pub fn handler() StepHandler {
        return .{
            .ptr = undefined,
            .vtable = &.{
                .name = name,
                .execute = execute,
                .isBrowserStep = isBrowserStep,
            },
        };
    }
};

// ---------------------------------------------------------------------------
// ClickStep
// ---------------------------------------------------------------------------

pub const ClickStep = struct {
    pub fn name(_: *anyopaque) []const u8 {
        return "click";
    }

    pub fn execute(
        _: *anyopaque,
        allocator: std.mem.Allocator,
        _: std.Io,
        page: ?IPage,
        params: json.Value,
        data: json.Value,
        args: std.StringHashMap(json.Value),
    ) CliError!json.Value {
        const pg = try requirePage(page);
        const selector = try renderStrParam(params, data, args, allocator);
        defer allocator.free(selector);
        try pg.click(selector);
        return data;
    }

    pub fn isBrowserStep(_: *anyopaque) bool {
        return true;
    }

    pub fn handler() StepHandler {
        return .{
            .ptr = undefined,
            .vtable = &.{
                .name = name,
                .execute = execute,
                .isBrowserStep = isBrowserStep,
            },
        };
    }
};

// ---------------------------------------------------------------------------
// TypeStep
// ---------------------------------------------------------------------------

pub const TypeStep = struct {
    pub fn name(_: *anyopaque) []const u8 {
        return "type";
    }

    pub fn execute(
        _: *anyopaque,
        allocator: std.mem.Allocator,
        _: std.Io,
        page: ?IPage,
        params: json.Value,
        data: json.Value,
        args: std.StringHashMap(json.Value),
    ) CliError!json.Value {
        const pg = try requirePage(page);
        const ctx = defaultCtx(data, args);

        const selector: []const u8 = switch (params) {
            .object => |obj| blk: {
                const sel_raw = switch (obj.get("selector") orelse return CliError.Pipeline) {
                    .string => |s| s,
                    else => return CliError.Pipeline,
                };
                const rendered = try renderTemplateStr(sel_raw, ctx, allocator);
                break :blk switch (rendered) {
                    .string => |s| s,
                    else => {
                        freeJsonValue(allocator, rendered);
                        return CliError.Pipeline;
                    },
                };
            },
            else => return CliError.Pipeline,
        };
        defer allocator.free(selector);

        const text: []const u8 = switch (params) {
            .object => |obj| blk: {
                const text_raw = switch (obj.get("text") orelse return CliError.Pipeline) {
                    .string => |s| s,
                    else => return CliError.Pipeline,
                };
                const rendered = try renderTemplateStr(text_raw, ctx, allocator);
                break :blk switch (rendered) {
                    .string => |s| s,
                    else => {
                        freeJsonValue(allocator, rendered);
                        return CliError.Pipeline;
                    },
                };
            },
            else => return CliError.Pipeline,
        };
        defer allocator.free(text);

        try pg.typeText(selector, text);
        return data;
    }

    pub fn isBrowserStep(_: *anyopaque) bool {
        return true;
    }

    pub fn handler() StepHandler {
        return .{
            .ptr = undefined,
            .vtable = &.{
                .name = name,
                .execute = execute,
                .isBrowserStep = isBrowserStep,
            },
        };
    }
};

// ---------------------------------------------------------------------------
// WaitStep
// ---------------------------------------------------------------------------

pub const WaitStep = struct {
    pub fn name(_: *anyopaque) []const u8 {
        return "wait";
    }

    pub fn execute(
        _: *anyopaque,
        allocator: std.mem.Allocator,
        _: std.Io,
        page: ?IPage,
        params: json.Value,
        data: json.Value,
        _: std.StringHashMap(json.Value),
    ) CliError!json.Value {
        const pg = try requirePage(page);

        switch (params) {
            // wait: 2 (seconds — matching original opencli convention)
            .integer => |n| {
                if (n < 0) return CliError.Pipeline;
                const ms = @as(u64, @intCast(n)) * 1000;
                try pg.waitForTimeout(ms);
            },
            .float => |f| {
                if (f < 0) return CliError.Pipeline;
                const ms = @as(u64, @intFromFloat(f * 1000.0));
                try pg.waitForTimeout(ms);
            },
            .object => |obj| {
                if (obj.get("time")) |time_val| {
                    const secs = switch (time_val) {
                        .integer => |n| @as(f64, @floatFromInt(n)),
                        .float => |f| f,
                        else => return CliError.Pipeline,
                    };
                    const ms = @as(u64, @intFromFloat(secs * 1000.0));
                    try pg.waitForTimeout(ms);
                } else if (obj.get("selector")) |sel_val| {
                    const selector = switch (sel_val) {
                        .string => |s| s,
                        else => return CliError.Pipeline,
                    };
                    try pg.waitForSelector(selector, null);
                } else if (obj.get("text")) |text_val| {
                    const text = switch (text_val) {
                        .string => |s| s,
                        else => return CliError.Pipeline,
                    };
                    const esc_text = try escapeJsStringDouble(allocator, text);
                    defer allocator.free(esc_text);
                    // Wait for text by polling innerText
                    const js = try std.fmt.allocPrint(allocator,
                        \\new Promise((resolve, reject) => {{
                        \\    const timeout = setTimeout(() => reject(new Error('Timeout waiting for text')), 30000);
                        \\    const check = () => {{
                        \\        if (document.body.innerText.includes("{s}")) {{
                        \\            clearTimeout(timeout);
                        \\            resolve(true);
                        \\        }} else {{
                        \\            requestAnimationFrame(check);
                        \\        }}
                        \\    }};
                        \\    check();
                        \\}})
                    , .{esc_text});
                    defer allocator.free(js);
                    const text_result = try pg.evaluate(js);
                    defer freeJsonValue(allocator, text_result);
                } else {
                    return CliError.Pipeline;
                }
            },
            else => return CliError.Pipeline,
        }

        return data;
    }

    pub fn isBrowserStep(_: *anyopaque) bool {
        return true;
    }

    pub fn handler() StepHandler {
        return .{
            .ptr = undefined,
            .vtable = &.{
                .name = name,
                .execute = execute,
                .isBrowserStep = isBrowserStep,
            },
        };
    }
};

// ---------------------------------------------------------------------------
// PressStep
// ---------------------------------------------------------------------------

pub const PressStep = struct {
    pub fn name(_: *anyopaque) []const u8 {
        return "press";
    }

    pub fn execute(
        _: *anyopaque,
        allocator: std.mem.Allocator,
        _: std.Io,
        page: ?IPage,
        params: json.Value,
        data: json.Value,
        args: std.StringHashMap(json.Value),
    ) CliError!json.Value {
        const pg = try requirePage(page);
        const key = try renderStrParam(params, data, args, allocator);
        defer allocator.free(key);
        const esc_key = try escapeJsStringSingle(allocator, key);
        defer allocator.free(esc_key);
        const js = try std.fmt.allocPrint(allocator,
            \\document.dispatchEvent(new KeyboardEvent('keydown', {{ key: '{s}', bubbles: true }}));
            \\document.dispatchEvent(new KeyboardEvent('keyup', {{ key: '{s}', bubbles: true }}));
        , .{ esc_key, esc_key });
        defer allocator.free(js);
        const key_result = try pg.evaluate(js);
        defer freeJsonValue(allocator, key_result);
        return data;
    }

    pub fn isBrowserStep(_: *anyopaque) bool {
        return true;
    }

    pub fn handler() StepHandler {
        return .{
            .ptr = undefined,
            .vtable = &.{
                .name = name,
                .execute = execute,
                .isBrowserStep = isBrowserStep,
            },
        };
    }
};

// ---------------------------------------------------------------------------
// EvaluateStep
// ---------------------------------------------------------------------------

pub const EvaluateStep = struct {
    pub fn name(_: *anyopaque) []const u8 {
        return "evaluate";
    }

    pub fn execute(
        _: *anyopaque,
        allocator: std.mem.Allocator,
        _: std.Io,
        page: ?IPage,
        params: json.Value,
        data: json.Value,
        args: std.StringHashMap(json.Value),
    ) CliError!json.Value {
        const pg = try requirePage(page);
        const js = try renderStrParam(params, data, args, allocator);
        defer allocator.free(js);

        // Inject `args` and `data` as local variables so JS code can reference them
        // directly without ${{ }} template syntax
        // NOTE: We can't json.stringify the StringHashMap directly because it contains
        // allocator vtable function pointers. Build a JSON object from the entries instead.
        var args_obj = try json.ObjectMap.init(allocator, &[_][]const u8{}, &[_]json.Value{});
        errdefer args_obj.deinit(allocator);
        var args_it = args.iterator();
        while (args_it.next()) |entry| {
            try args_obj.put(allocator, entry.key_ptr.*, entry.value_ptr.*);
        }

        var aw = std.Io.Writer.Allocating.init(allocator);
        defer aw.deinit();
        json.fmt(json.Value{ .object = args_obj }, .{}).format(&aw.writer) catch return CliError.Json;
        const args_json = try aw.toOwnedSlice();
        defer allocator.free(args_json);
        args_obj.deinit(allocator);

        aw = std.Io.Writer.Allocating.init(allocator);
        defer aw.deinit();
        json.fmt(data, .{}).format(&aw.writer) catch return CliError.Json;
        const data_json = try aw.toOwnedSlice();
        defer allocator.free(data_json);

        const wrapped_js = try std.fmt.allocPrint(allocator,
            "(function() {{ const args = {s}; const data = {s}; return ({s}); }})()",
            .{ args_json, data_json, js },
        );
        defer allocator.free(wrapped_js);

        const result = try pg.evaluate(wrapped_js);
        return result;
    }

    pub fn isBrowserStep(_: *anyopaque) bool {
        return true;
    }

    pub fn handler() StepHandler {
        return .{
            .ptr = undefined,
            .vtable = &.{
                .name = name,
                .execute = execute,
                .isBrowserStep = isBrowserStep,
            },
        };
    }
};

// ---------------------------------------------------------------------------
// SnapshotStep
// ---------------------------------------------------------------------------

pub const SnapshotStep = struct {
    pub fn name(_: *anyopaque) []const u8 {
        return "snapshot";
    }

    pub fn execute(
        _: *anyopaque,
        _allocator: std.mem.Allocator,
        _: std.Io,
        page: ?IPage,
        params: json.Value,
        data: json.Value,
        _: std.StringHashMap(json.Value),
    ) CliError!json.Value {
        _ = _allocator;
        const pg = try requirePage(page);

        const opts = switch (params) {
            .object => |obj| SnapshotOptions{
                .selector = if (obj.get("selector")) |sel| switch (sel) {
                    .string => |s| s,
                    else => null,
                } else null,
                .include_hidden = if (obj.get("include_hidden")) |v|
                    switch (v) {
                        .bool => |b| b,
                        else => false,
                    }
                else
                    false,
            },
            .null => SnapshotOptions{},
            else => SnapshotOptions{},
        };

        const result = try pg.snapshot(if (params == .object) opts else null);
        if (result == .null) return data;
        return result;
    }

    pub fn isBrowserStep(_: *anyopaque) bool {
        return true;
    }

    pub fn handler() StepHandler {
        return .{
            .ptr = undefined,
            .vtable = &.{
                .name = name,
                .execute = execute,
                .isBrowserStep = isBrowserStep,
            },
        };
    }
};

const SnapshotOptions = @import("core").SnapshotOptions;

// ---------------------------------------------------------------------------
// ScreenshotStep
// ---------------------------------------------------------------------------

pub const ScreenshotStep = struct {
    pub fn name(_: *anyopaque) []const u8 {
        return "screenshot";
    }

    pub fn execute(
        _: *anyopaque,
        allocator: std.mem.Allocator,
        _: std.Io,
        page: ?IPage,
        params: json.Value,
        _: json.Value,
        _: std.StringHashMap(json.Value),
    ) CliError!json.Value {
        const pg = try requirePage(page);

        const opts = switch (params) {
            .object => |obj| ScreenshotOptions{
                .full_page = if (obj.get("full_page")) |v|
                    switch (v) {
                        .bool => |b| b,
                        else => false,
                    }
                else
                    false,
                .selector = if (obj.get("selector")) |sel| switch (sel) {
                    .string => |s| s,
                    else => null,
                } else null,
                .path = if (obj.get("path")) |p| switch (p) {
                    .string => |s| s,
                    else => null,
                } else null,
            },
            .null => ScreenshotOptions{},
            else => ScreenshotOptions{},
        };

        const bytes = try pg.screenshot(if (params == .object) opts else null);

        // Encode to base64
        const b64_len = std.base64.standard.Encoder.calcSize(bytes.len);
        const b64 = try allocator.alloc(u8, b64_len);
        _ = std.base64.standard.Encoder.encode(b64, bytes);
        allocator.free(bytes);

        return .{ .string = b64 };
    }

    pub fn isBrowserStep(_: *anyopaque) bool {
        return true;
    }

    pub fn handler() StepHandler {
        return .{
            .ptr = undefined,
            .vtable = &.{
                .name = name,
                .execute = execute,
                .isBrowserStep = isBrowserStep,
            },
        };
    }
};

const ScreenshotOptions = @import("core").ScreenshotOptions;

// ---------------------------------------------------------------------------
// ScrollStep
// ---------------------------------------------------------------------------

pub const ScrollStep = struct {
    pub fn name(_: *anyopaque) []const u8 {
        return "scroll";
    }

    pub fn execute(
        _: *anyopaque,
        _allocator: std.mem.Allocator,
        _: std.Io,
        page: ?IPage,
        params: json.Value,
        data: json.Value,
        _: std.StringHashMap(json.Value),
    ) CliError!json.Value {
        _ = _allocator;
        const pg = try requirePage(page);

        const count: u32 = switch (params) {
            .integer => |n| @as(u32, @intCast(n)),
            .float => |f| @as(u32, @intFromFloat(f)),
            .null => 3,
            else => 3,
        };

        const scroll_opts = AutoScrollOptions{
            .max_scrolls = count,
            .delay_ms = 300,
        };
        try pg.autoScroll(scroll_opts);
        return data;
    }

    pub fn isBrowserStep(_: *anyopaque) bool {
        return true;
    }

    pub fn handler() StepHandler {
        return .{
            .ptr = undefined,
            .vtable = &.{
                .name = name,
                .execute = execute,
                .isBrowserStep = isBrowserStep,
            },
        };
    }
};

const AutoScrollOptions = @import("core").AutoScrollOptions;

// ---------------------------------------------------------------------------
// TapStep
// ---------------------------------------------------------------------------

pub const TapStep = struct {
    pub fn name(_: *anyopaque) []const u8 {
        return "tap";
    }

    pub fn execute(
        _: *anyopaque,
        allocator: std.mem.Allocator,
        _: std.Io,
        page: ?IPage,
        params: json.Value,
        data: json.Value,
        args: std.StringHashMap(json.Value),
    ) CliError!json.Value {
        const pg = try requirePage(page);

        // Tap params must be an object
        const obj = switch (params) {
            .object => |o| o,
            else => return CliError.Pipeline,
        };

        const ctx = defaultCtx(data, args);

        // Extract store name (required)
        const store_name_raw = switch (obj.get("store") orelse return CliError.Pipeline) {
            .string => |s| s,
            else => return CliError.Pipeline,
        };
        const store_name_rendered = try renderTemplateStr(store_name_raw, ctx, allocator);
        const store_name = switch (store_name_rendered) {
            .string => |s| s,
            else => {
                freeJsonValue(allocator, store_name_rendered);
                return CliError.Pipeline;
            },
        };
        defer allocator.free(store_name);

        // Extract action name (required)
        const action_name_raw = switch (obj.get("action") orelse return CliError.Pipeline) {
            .string => |s| s,
            else => return CliError.Pipeline,
        };
        const action_name_rendered = try renderTemplateStr(action_name_raw, ctx, allocator);
        const action_name = switch (action_name_rendered) {
            .string => |s| s,
            else => {
                freeJsonValue(allocator, action_name_rendered);
                return CliError.Pipeline;
            },
        };
        defer allocator.free(action_name);

        // Extract capture URL pattern
        const capture_pattern_raw = if (obj.get("capture")) |v|
            switch (v) {
                .string => |s| s,
                else => "",
            }
        else if (obj.get("url")) |v|
            switch (v) {
                .string => |s| s,
                else => "",
            }
        else
            "";

        // Build the tap JS with escaped strings
        const esc_pattern = try escapeJsStringDouble(allocator, capture_pattern_raw);
        defer allocator.free(esc_pattern);
        const esc_store = try escapeJsStringDouble(allocator, store_name);
        defer allocator.free(esc_store);
        const esc_action = try escapeJsStringDouble(allocator, action_name);
        defer allocator.free(esc_action);

        const js = try std.fmt.allocPrint(allocator,
            \\(async () => {{
            \\  let captured = null;
            \\  let promiseResolve;
            \\  const capturePromise = new Promise(r => {{ promiseResolve = r; }});
            \\  const capturePattern = "{s}";
            \\
            \\  const origFetch = window.fetch;
            \\  window.fetch = async function(...fetchArgs) {{
            \\    const resp = await origFetch.apply(this, fetchArgs);
            \\    try {{
            \\      const url = typeof fetchArgs[0] === 'string' ? fetchArgs[0]
            \\        : fetchArgs[0] instanceof Request ? fetchArgs[0].url : String(fetchArgs[0]);
            \\      if (capturePattern && url.includes(capturePattern) && !captured) {{
            \\        try {{ captured = await resp.clone().json(); promiseResolve(); }} catch {{}}
            \\      }}
            \\    }} catch {{}}
            \\    return resp;
            \\  }};
            \\
            \\  try {{
            \\    // Find Pinia store
            \\    let store = null;
            \\    try {{
            \\      const app = document.querySelector('#app');
            \\      const pinia = app?.__vue_app__?.config?.globalProperties?.$pinia;
            \\      if (pinia?._s) store = pinia._s.get("{s}");
            \\    }} catch {{}}
            \\    if (!store) return {{ error: 'Store not found: {s}' }};
            \\    if (typeof store["{s}"] !== 'function') {{
            \\      return {{ error: 'Action not found on store' }};
            \\    }}
            \\    await store["{s}"]();
            \\    // Wait for capture
            \\    const timeoutPromise = new Promise(r => setTimeout(r, 5000));
            \\    await Promise.race([capturePromise, timeoutPromise]);
            \\  }} finally {{
            \\    window.fetch = origFetch;
            \\  }}
            \\
            \\  if (!captured) return {{ error: 'No response captured for: ' + capturePattern }};
            \\  return captured;
            \\}})()
        , .{ esc_pattern, esc_store, esc_store, esc_action, esc_action });
        defer allocator.free(js);

        const result = try pg.evaluate(js);

        // Check if result contains error
        if (result == .object) {
            const r_obj = result.object;
            if (r_obj.get("error")) |err_val| {
                if (err_val == .string) {
                    freeJsonValue(allocator, result);
                    return CliError.Pipeline;
                }
            }
        }

        return result;
    }

    pub fn isBrowserStep(_: *anyopaque) bool {
        return true;
    }

    pub fn handler() StepHandler {
        return .{
            .ptr = undefined,
            .vtable = &.{
                .name = name,
                .execute = execute,
                .isBrowserStep = isBrowserStep,
            },
        };
    }
};

// ---------------------------------------------------------------------------
// Registration
// ---------------------------------------------------------------------------

// ---------------------------------------------------------------------------
// InterceptStep
// ---------------------------------------------------------------------------

pub const InterceptStep = struct {
    pub fn name(_: *anyopaque) []const u8 {
        return "intercept";
    }

    pub fn execute(
        _: *anyopaque,
        _allocator: std.mem.Allocator,
        _: std.Io,
        page: ?IPage,
        params: json.Value,
        data: json.Value,
        _: std.StringHashMap(json.Value),
    ) CliError!json.Value {
        _ = _allocator;
        const pg = try requirePage(page);
        const obj = switch (params) {
            .object => |o| o,
            else => return CliError.Pipeline,
        };

        const url_pattern = switch (obj.get("url_pattern") orelse obj.get("urlPattern") orelse return CliError.Pipeline) {
            .string => |s| s,
            else => return CliError.Pipeline,
        };

        try pg.interceptRequests(url_pattern);
        return data;
    }

    pub fn isBrowserStep(_: *anyopaque) bool {
        return true;
    }

    pub fn handler() StepHandler {
        return .{
            .ptr = undefined,
            .vtable = &.{
                .name = name,
                .execute = execute,
                .isBrowserStep = isBrowserStep,
            },
        };
    }
};

// ---------------------------------------------------------------------------
// CollectStep
// ---------------------------------------------------------------------------

pub const CollectStep = struct {
    pub fn name(_: *anyopaque) []const u8 {
        return "collect";
    }

    pub fn execute(
        _: *anyopaque,
        allocator: std.mem.Allocator,
        _: std.Io,
        page: ?IPage,
        params: json.Value,
        _: json.Value,
        _: std.StringHashMap(json.Value),
    ) CliError!json.Value {
        const pg = try requirePage(page);

        const obj = switch (params) {
            .object => |o| o,
            else => return CliError.Pipeline,
        };

        // Optional JS parse function
        const parse_js = if (obj.get("parse")) |v| switch (v) {
            .string => |s| s,
            else => null,
        } else null;

        // Retrieve intercepted requests via JS evaluation
        const retrieve_js =
            \\(function() {
            \\  const reqs = window.__autocli_intercepted__ || [];
            \\  return reqs.map(r => ({
            \\    url: r.url,
            \\    method: r.method,
            \\    headers: r.headers,
            \\    body: r.body
            \\  }));
            \\})()
        ;

        var result = try pg.evaluate(retrieve_js);

        // If a parse function is provided, run it against the collected data
        if (parse_js) |parse| {
            defer freeJsonValue(allocator, result);
            const esc_parse = try escapeJsTemplateLiteral(allocator, parse);
            defer allocator.free(esc_parse);
            const parse_wrapper = std.fmt.allocPrint(allocator,
                \\(function(data) {{
                \\  const fnBody = `{s}`;
                \\  const parseFn = new Function('data', fnBody);
                \\  return parseFn(data);
                \\}})({s})
            , .{ esc_parse, retrieve_js }) catch return CliError.Pipeline;
            defer allocator.free(parse_wrapper);
            result = try pg.evaluate(parse_wrapper);
        }

        return result;
    }

    pub fn isBrowserStep(_: *anyopaque) bool {
        return true;
    }

    pub fn handler() StepHandler {
        return .{
            .ptr = undefined,
            .vtable = &.{
                .name = name,
                .execute = execute,
                .isBrowserStep = isBrowserStep,
            },
        };
    }
};

// ---------------------------------------------------------------------------
// Registration
// ---------------------------------------------------------------------------

pub fn registerBrowserSteps(registry: *StepRegistry) !void {
    try registry.register(NavigateStep.handler());
    try registry.register(ClickStep.handler());
    try registry.register(TypeStep.handler());
    try registry.register(WaitStep.handler());
    try registry.register(PressStep.handler());
    try registry.register(EvaluateStep.handler());
    try registry.register(SnapshotStep.handler());
    try registry.register(ScreenshotStep.handler());
    try registry.register(ScrollStep.handler());
    try registry.register(TapStep.handler());
    try registry.register(InterceptStep.handler());
    try registry.register(CollectStep.handler());
}
