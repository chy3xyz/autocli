const std = @import("std");
const json = std.json;
const core = @import("core");
const CliError = core.CliError;
const IPage = core.IPage;
const GotoOptions = core.GotoOptions;
const WaitOptions = core.WaitOptions;
const Cookie = core.Cookie;
const CookieOptions = core.CookieOptions;
const ScreenshotOptions = core.ScreenshotOptions;
const SnapshotOptions = core.SnapshotOptions;
const AutoScrollOptions = core.AutoScrollOptions;
const TabInfo = core.TabInfo;
const InterceptedRequest = core.InterceptedRequest;
const NetworkRequest = core.NetworkRequest;

/// A mock IPage implementation that logs browser operations instead of
/// executing them. Used with the `--sandbox` flag to run adapter pipelines
/// without a real browser connection.
pub const SandboxPage = struct {
    io: std.Io,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, io: std.Io) SandboxPage {
        return .{ .io = io, .allocator = allocator };
    }

    fn log(_: *SandboxPage, comptime fmt: []const u8, args: anytype) void {
        std.log.info("[sandbox] " ++ fmt, args);
    }

    pub fn makeIPage(self: *SandboxPage) IPage {
        return .{
            .ptr = self,
            .vtable = &.{
                .goto = goto_,
                .url = url_,
                .title = title_,
                .content = content_,
                .evaluate = evaluate_,
                .wait_for_selector = waitForSelector_,
                .wait_for_navigation = waitForNavigation_,
                .wait_for_timeout = waitForTimeout_,
                .click = click_,
                .type_text = typeText_,
                .cookies = cookies_,
                .set_cookies = setCookies_,
                .screenshot = screenshot_,
                .snapshot = snapshot_,
                .auto_scroll = autoScroll_,
                .tabs = tabs_,
                .switch_tab = switchTab_,
                .close = close_,
                .intercept_requests = interceptRequests_,
                .get_intercepted_requests = getInterceptedRequests_,
                .get_network_requests = getNetworkRequests_,
            },
        };
    }

    fn goto_(ptr: *anyopaque, url: []const u8, _: ?GotoOptions) CliError!void {
        const self: *SandboxPage = @ptrCast(@alignCast(ptr));
        self.log("goto {s}", .{url});
    }

    fn url_(ptr: *anyopaque) CliError![]const u8 {
        const self: *SandboxPage = @ptrCast(@alignCast(ptr));
        self.log("url", .{});
        return self.allocator.dupe(u8, "https://sandbox.autocli") catch return CliError.OutOfMemory;
    }

    fn title_(ptr: *anyopaque) CliError![]const u8 {
        const self: *SandboxPage = @ptrCast(@alignCast(ptr));
        self.log("title", .{});
        return self.allocator.dupe(u8, "Sandbox") catch return CliError.OutOfMemory;
    }

    fn content_(ptr: *anyopaque) CliError![]const u8 {
        const self: *SandboxPage = @ptrCast(@alignCast(ptr));
        self.log("content", .{});
        return self.allocator.dupe(u8, "<html><body>Sandbox</body></html>") catch return CliError.OutOfMemory;
    }

    fn evaluate_(ptr: *anyopaque, expression: []const u8) CliError!json.Value {
        const self: *SandboxPage = @ptrCast(@alignCast(ptr));
        const limit = @min(expression.len, 200);
        self.log("evaluate: {s}{s}", .{
            expression[0..limit],
            if (expression.len > 200) "..." else "",
        });
        return parseSandboxJsExpression(self.allocator, expression);
    }

    fn waitForSelector_(ptr: *anyopaque, selector: []const u8, _: ?WaitOptions) CliError!void {
        const self: *SandboxPage = @ptrCast(@alignCast(ptr));
        self.log("wait_for_selector: {s}", .{selector});
    }

    fn waitForNavigation_(ptr: *anyopaque, _: ?WaitOptions) CliError!void {
        const self: *SandboxPage = @ptrCast(@alignCast(ptr));
        self.log("wait_for_navigation", .{});
    }

    fn waitForTimeout_(ptr: *anyopaque, ms: u64) CliError!void {
        const self: *SandboxPage = @ptrCast(@alignCast(ptr));
        self.log("wait_for_timeout: {d}ms", .{ms});
        const duration = std.Io.Duration.fromMilliseconds(@intCast(ms));
        std.Io.sleep(self.io, duration, .real) catch {};
    }

    fn click_(ptr: *anyopaque, selector: []const u8) CliError!void {
        const self: *SandboxPage = @ptrCast(@alignCast(ptr));
        self.log("click: {s}", .{selector});
    }

    fn typeText_(ptr: *anyopaque, selector: []const u8, text: []const u8) CliError!void {
        const self: *SandboxPage = @ptrCast(@alignCast(ptr));
        self.log("type: {s} -> {s}", .{ selector, text });
    }

    fn cookies_(ptr: *anyopaque, _: ?CookieOptions) CliError![]Cookie {
        const self: *SandboxPage = @ptrCast(@alignCast(ptr));
        return self.allocator.alloc(Cookie, 0) catch return CliError.OutOfMemory;
    }

    fn setCookies_(_: *anyopaque, _: []Cookie) CliError!void {}

    fn screenshot_(ptr: *anyopaque, _: ?ScreenshotOptions) CliError![]u8 {
        const self: *SandboxPage = @ptrCast(@alignCast(ptr));
        return self.allocator.alloc(u8, 0) catch return CliError.OutOfMemory;
    }

    fn snapshot_(ptr: *anyopaque, _: ?SnapshotOptions) CliError!json.Value {
        const self: *SandboxPage = @ptrCast(@alignCast(ptr));
        self.log("snapshot", .{});
        const obj = json.ObjectMap.init(self.allocator, &[_][]const u8{}, &[_]json.Value{}) catch return CliError.OutOfMemory;
        return json.Value{ .object = obj };
    }

    fn autoScroll_(ptr: *anyopaque, _: ?AutoScrollOptions) CliError!void {
        const self: *SandboxPage = @ptrCast(@alignCast(ptr));
        self.log("auto_scroll", .{});
    }

    fn tabs_(ptr: *anyopaque) CliError![]TabInfo {
        const self: *SandboxPage = @ptrCast(@alignCast(ptr));
        self.log("tabs", .{});
        return self.allocator.alloc(TabInfo, 0) catch return CliError.OutOfMemory;
    }

    fn switchTab_(ptr: *anyopaque, tab_id: []const u8) CliError!void {
        const self: *SandboxPage = @ptrCast(@alignCast(ptr));
        self.log("switch_tab: {s}", .{tab_id});
    }

    fn close_(ptr: *anyopaque) CliError!void {
        const self: *SandboxPage = @ptrCast(@alignCast(ptr));
        self.log("close", .{});
    }

    fn interceptRequests_(ptr: *anyopaque, url_pattern: []const u8) CliError!void {
        const self: *SandboxPage = @ptrCast(@alignCast(ptr));
        self.log("intercept_requests: {s}", .{url_pattern});
    }

    fn getInterceptedRequests_(ptr: *anyopaque) CliError![]InterceptedRequest {
        const self: *SandboxPage = @ptrCast(@alignCast(ptr));
        self.log("get_intercepted_requests", .{});
        return self.allocator.alloc(InterceptedRequest, 0) catch return CliError.OutOfMemory;
    }

    fn getNetworkRequests_(ptr: *anyopaque) CliError![]NetworkRequest {
        const self: *SandboxPage = @ptrCast(@alignCast(ptr));
        self.log("get_network_requests", .{});
        return self.allocator.alloc(NetworkRequest, 0) catch return CliError.OutOfMemory;
    }
};

fn parseSandboxJsExpression(allocator: std.mem.Allocator, expr: []const u8) CliError!json.Value {
    const trimmed = std.mem.trim(u8, expr, " \t\n\r");
    if (trimmed.len == 0) return .null;
    if (std.mem.startsWith(u8, trimmed, "({") or std.mem.startsWith(u8, trimmed, "{")) {
        return parseJsObject(allocator, trimmed);
    }
    if (std.mem.startsWith(u8, trimmed, "[")) {
        return parseJsArray(allocator, trimmed);
    }
    if (std.mem.startsWith(u8, trimmed, "(function")) {
        return extractReturnValueFromIIFE(allocator, trimmed);
    }
    return .null;
}

fn extractReturnValueFromIIFE(allocator: std.mem.Allocator, expr: []const u8) CliError!json.Value {
    const return_start = std.mem.indexOf(u8, expr, "return (") orelse return .null;
    var i = return_start + 8;
    while (i < expr.len and (expr[i] == ' ' or expr[i] == '\t' or expr[i] == '\n' or expr[i] == '\r')) i += 1;
    if (i >= expr.len) return .null;
    if (expr[i] == '(') i += 1;
    const first_char = expr[i];
    if (first_char == '{') {
        const end_pos = findMatchingBrace(expr, i) orelse return .null;
        const obj_str = expr[i..end_pos];
        const copied = allocator.dupe(u8, obj_str) catch return CliError.OutOfMemory;
        const result = parseJsObject(allocator, copied);
        allocator.free(copied);
        return result;
    }
    if (first_char == '[') {
        const end_pos = findMatchingBracket(expr, i) orelse return .null;
        const arr_str = expr[i..end_pos];
        const copied = allocator.dupe(u8, arr_str) catch return CliError.OutOfMemory;
        const result = parseJsArray(allocator, copied);
        allocator.free(copied);
        return result;
    }
    return .null;
}

fn findMatchingBrace(expr: []const u8, start: usize) ?usize {
    var depth: i32 = 1;
    var i = start;
    while (i < expr.len and depth > 0) {
        switch (expr[i]) {
            '{' => depth += 1,
            '}' => depth -= 1,
            '\'' => { i += 1; while (i < expr.len and expr[i] != '\'') i += 1; },
            '"' => { i += 1; while (i < expr.len and expr[i] != '"') i += 1; },
            else => {},
        }
        i += 1;
    }
    if (depth == 0) return i;
    return null;
}

fn findMatchingBracket(expr: []const u8, start: usize) ?usize {
    var depth: i32 = 1;
    var i = start;
    while (i < expr.len and depth > 0) {
        switch (expr[i]) {
            '[' => depth += 1,
            ']' => depth -= 1,
            '\'' => { i += 1; while (i < expr.len and expr[i] != '\'') i += 1; },
            '"' => { i += 1; while (i < expr.len and expr[i] != '"') i += 1; },
            else => {},
        }
        i += 1;
    }
    if (depth == 0) return i;
    return null;
}

fn parseJsObject(allocator: std.mem.Allocator, expr: []const u8) CliError!json.Value {
    var obj = json.ObjectMap.init(allocator, &[_][]const u8{}, &[_]json.Value{}) catch return CliError.OutOfMemory;
    errdefer obj.deinit(allocator);
    var i: usize = 0;
    const trimmed = std.mem.trim(u8, expr, " \t\n\r");
    if (std.mem.startsWith(u8, trimmed, "({")) i = 2 else if (std.mem.startsWith(u8, trimmed, "{")) i = 1;
    while (i < trimmed.len) {
        while (i < trimmed.len and (trimmed[i] == ' ' or trimmed[i] == '\t' or trimmed[i] == '\n' or trimmed[i] == '\r' or trimmed[i] == ',')) i += 1;
        if (i >= trimmed.len or trimmed[i] == '}' or trimmed[i] == ')') break;
        const key_start = i;
        while (i < trimmed.len and trimmed[i] != ':' and trimmed[i] != ' ' and trimmed[i] != '\t') i += 1;
        if (i >= trimmed.len) return .{ .object = obj };
        const key = trimmed[key_start..i];
        while (i < trimmed.len and trimmed[i] != ':') i += 1;
        if (i >= trimmed.len) return .{ .object = obj };
        i += 1;
        while (i < trimmed.len and (trimmed[i] == ' ' or trimmed[i] == '\t')) i += 1;
        const value_result = parseJsValue(allocator, trimmed, &i);
        const owned_key = allocator.dupe(u8, key) catch return CliError.OutOfMemory;
        obj.put(allocator, owned_key, value_result) catch return CliError.OutOfMemory;
    }
    return .{ .object = obj };
}

fn parseJsArray(allocator: std.mem.Allocator, expr: []const u8) CliError!json.Value {
    var items = std.ArrayListUnmanaged(json.Value){ .items = &.{}, .capacity = 0 };
    defer items.deinit(allocator);
    var i: usize = 1;
    while (i < expr.len) {
        while (i < expr.len and (expr[i] == ' ' or expr[i] == '\t' or expr[i] == '\n' or expr[i] == '\r' or expr[i] == ',')) i += 1;
        if (i >= expr.len or expr[i] == ']') break;
        const value = parseJsValue(allocator, expr, &i);
        items.append(allocator, value) catch return CliError.OutOfMemory;
    }
    return .{ .array = std.array_list.Managed(json.Value){ .items = items.items, .capacity = items.capacity, .allocator = allocator } };
}

fn parseJsValue(allocator: std.mem.Allocator, expr: []const u8, i: *usize) json.Value {
    while (i.* < expr.len and (expr[i.*] == ' ' or expr[i.*] == '\t')) i.* += 1;
    if (i.* >= expr.len) return .null;
    switch (expr[i.*]) {
        '{' => {
            const start = i.*;
            var depth: i32 = 1;
            i.* += 1;
            while (i.* < expr.len and depth > 0) {
                if (expr[i.*] == '{') depth += 1;
                if (expr[i.*] == '}') depth -= 1;
                i.* += 1;
            }
            const obj_str = expr[start..i.*];
            return parseJsObject(allocator, obj_str) catch return .null;
        },
        '[' => {
            const start = i.*;
            var depth: i32 = 1;
            i.* += 1;
            while (i.* < expr.len and depth > 0) {
                if (expr[i.*] == '[') depth += 1;
                if (expr[i.*] == ']') depth -= 1;
                i.* += 1;
            }
            const arr_str = expr[start..i.*];
            return parseJsArray(allocator, arr_str) catch return .null;
        },
        '\'' => {
            i.* += 1;
            const start = i.*;
            while (i.* < expr.len and expr[i.*] != '\'') i.* += 1;
            const str_val = expr[start..i.*];
            if (i.* < expr.len) i.* += 1;
            const owned = allocator.dupe(u8, str_val) catch return .null;
            return .{ .string = owned };
        },
        '"' => {
            i.* += 1;
            const start = i.*;
            while (i.* < expr.len and expr[i.*] != '"') i.* += 1;
            const str_val = expr[start..i.*];
            if (i.* < expr.len) i.* += 1;
            const owned = allocator.dupe(u8, str_val) catch return .null;
            return .{ .string = owned };
        },
        't', 'f' => {
            if (i.* + 4 <= expr.len and std.mem.eql(u8, expr[i.*..i.* + 4], "true")) {
                i.* += 4;
                return .{ .bool = true };
            }
            if (i.* + 5 <= expr.len and std.mem.eql(u8, expr[i.*..i.* + 5], "false")) {
                i.* += 5;
                return .{ .bool = false };
            }
            return .null;
        },
        'n' => {
            if (i.* + 4 <= expr.len and std.mem.eql(u8, expr[i.*..i.* + 4], "null")) {
                i.* += 4;
                return .null;
            }
            return .null;
        },
        else => {
            const start = i.*;
            while (i.* < expr.len and expr[i.*] != ',' and expr[i.*] != '}' and expr[i.*] != ']' and expr[i.*] != ' ' and expr[i.*] != '\t' and expr[i.*] != '\n' and expr[i.*] != '\r') i.* += 1;
            const num_str = expr[start..i.*];
            if (num_str.len > 0) {
                if (std.mem.indexOf(u8, num_str, ".") != null) {
                    const f = std.fmt.parseFloat(f64, num_str) catch return .null;
                    return .{ .float = f };
                } else {
                    const n = std.fmt.parseInt(i64, num_str, 10) catch return .null;
                    return .{ .integer = n };
                }
            }
            return .null;
        },
    }
}