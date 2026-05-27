const std = @import("std");
const json = @import("std").json;
const CliError = @import("core").CliError;
const IPage = @import("core").IPage;
const GotoOptions = @import("core").GotoOptions;
const WaitOptions = @import("core").WaitOptions;
const CookieOptions = @import("core").CookieOptions;
const ScreenshotOptions = @import("core").ScreenshotOptions;
const SnapshotOptions = @import("core").SnapshotOptions;
const AutoScrollOptions = @import("core").AutoScrollOptions;
const TabInfo = @import("core").TabInfo;
const Cookie = @import("core").Cookie;
const InterceptedRequest = @import("core").InterceptedRequest;
const NetworkRequest = @import("core").NetworkRequest;
const DaemonClient = @import("client.zig").DaemonClient;
const dom = @import("dom.zig");

/// Recursively free a json.Value that was allocated with parseFromSliceLeaky.
fn freeJsonValue(allocator: std.mem.Allocator, val: json.Value) void {
    switch (val) {
        .string => |s| allocator.free(s),
        .array => |arr| {
            for (arr.items) |item| {
                freeJsonValue(allocator, item);
            }
            var mut_arr = arr;
            mut_arr.deinit();
        },
        .object => |obj| {
            var it = obj.iterator();
            while (it.next()) |entry| {
                allocator.free(entry.key_ptr.*);
                freeJsonValue(allocator, entry.value_ptr.*);
            }
            var mut_obj = obj;
            mut_obj.deinit(allocator);
        },
        else => {},
    }
}

/// Deep clone a json.Value so the caller owns it independently.
fn cloneJsonValue(allocator: std.mem.Allocator, val: json.Value) !json.Value {
    switch (val) {
        .null, .bool, .integer, .float, .number_string => return val,
        .string => |s| return .{ .string = try allocator.dupe(u8, s) },
        .array => |arr| {
            var items = std.ArrayListUnmanaged(json.Value){ .items = &.{}, .capacity = 0 };
            defer items.deinit(allocator);
            for (arr.items) |item| {
                try items.append(allocator, try cloneJsonValue(allocator, item));
            }
            return .{ .array = std.array_list.Managed(json.Value){ .items = items.items, .capacity = items.capacity, .allocator = allocator } };
        },
        .object => |obj| {
            var new_obj = json.ObjectMap.init(allocator, &[_][]const u8{}, &[_]json.Value{}) catch return error.OutOfMemory;
            errdefer new_obj.deinit(allocator);
            var it = obj.iterator();
            while (it.next()) |entry| {
                const key_copy = try allocator.dupe(u8, entry.key_ptr.*);
                const value_copy = try cloneJsonValue(allocator, entry.value_ptr.*);
                try new_obj.put(allocator, key_copy, value_copy);
            }
            return .{ .object = new_obj };
        },
    }
}

/// DaemonPage - IPage implementation via daemon communication
/// Communicates with the axum daemon on port 19825 which proxies commands to Chrome via CDP
pub const DaemonPageState = struct {
    allocator: std.mem.Allocator,
    client: *DaemonClient,
    owns_client: bool,
    tab_id: []const u8,
};

// ─── Helper ──────────────────────────────────────────────────────────

fn executeCommand(state: *DaemonPageState, action: []const u8, params: ?[]const u8) CliError!json.Value {
    const raw = state.client.executePageCommand(state.tab_id, action, params) catch |err| switch (err) {
        error.ConnectFailed => return CliError.BrowserConnect,
        error.HttpStatus => return CliError.Http,
        error.SendFailed, error.ReceiveFailed, error.ReadFailed => return CliError.Io,
        else => return CliError.Pipeline,
    };
    // Unwrap daemon response: {"ok":true,"data":...} → data
    // or {"ok":false,"error":"..."} → CliError
    return unwrapDaemonResponse(state.client.allocator, raw) catch |err| return err;
}

/// Unwrap the daemon/extension response envelope.
/// The extension returns {"id":"...","ok":true,"data":...} on success,
/// or {"id":"...","ok":false,"error":"..."} on failure.
/// This extracts the `data` field on success, or returns CliError.Pipeline on failure.
fn unwrapDaemonResponse(allocator: std.mem.Allocator, response: json.Value) CliError!json.Value {
    if (response != .object) return response; // not an envelope — pass through

    const obj = response.object;
    const ok_val = obj.get("ok");
    if (ok_val == null) return response; // no "ok" field — not an envelope

    const ok = switch (ok_val.?) {
        .bool => |b| b,
        else => return response,
    };

    if (!ok) {
        const err_msg = switch (obj.get("error") orelse .null) {
            .string => |s| s,
            else => "unknown daemon error",
        };
        std.log.err("daemon command failed: {s}", .{err_msg});
        return CliError.Pipeline;
    }

    // Extract data field — if absent, return null
    const data = obj.get("data") orelse return .null;
    // Deep-clone so the caller owns the value independently of the response
    return cloneJsonValue(allocator, data) catch return CliError.OutOfMemory;
}

// ─── IPage vtable methods ────────────────────────────────────────────

fn paramsJson(allocator: std.mem.Allocator, obj: json.ObjectMap) CliError![]const u8 {
    return std.json.Stringify.valueAlloc(allocator, json.Value{ .object = obj }, .{}) catch return CliError.Pipeline;
}

pub fn goto_(ptr: *anyopaque, url: []const u8, _: ?GotoOptions) CliError!void {
    const state: *DaemonPageState = @ptrCast(@alignCast(ptr));
    var obj = json.ObjectMap.empty;
    defer obj.deinit(state.client.allocator);
    try obj.put(state.client.allocator, "url", json.Value{ .string = url });
    const params_json = try paramsJson(state.client.allocator, obj);
    defer state.client.allocator.free(params_json);
    const result = try executeCommand(state, "goto", params_json);
    defer freeJsonValue(state.client.allocator, result);
}

pub fn url_(ptr: *anyopaque) CliError![]const u8 {
    const state: *DaemonPageState = @ptrCast(@alignCast(ptr));
    const result = try executeCommand(state, "url", null);
    defer freeJsonValue(state.client.allocator, result);
    return switch (result) {
        .string => |s| state.allocator.dupe(u8, s) catch return CliError.OutOfMemory,
        else => CliError.Pipeline,
    };
}

pub fn title_(ptr: *anyopaque) CliError![]const u8 {
    const state: *DaemonPageState = @ptrCast(@alignCast(ptr));
    const result = try executeCommand(state, "title", null);
    defer freeJsonValue(state.client.allocator, result);
    return switch (result) {
        .string => |s| state.allocator.dupe(u8, s) catch return CliError.OutOfMemory,
        else => CliError.Pipeline,
    };
}

pub fn content_(ptr: *anyopaque) CliError![]const u8 {
    const state: *DaemonPageState = @ptrCast(@alignCast(ptr));
    const result = try executeCommand(state, "content", null);
    defer freeJsonValue(state.client.allocator, result);
    return switch (result) {
        .string => |s| state.allocator.dupe(u8, s) catch return CliError.OutOfMemory,
        else => CliError.Pipeline,
    };
}

pub fn evaluate_(ptr: *anyopaque, expression: []const u8) CliError!json.Value {
    const state: *DaemonPageState = @ptrCast(@alignCast(ptr));
    var obj = json.ObjectMap.empty;
    defer obj.deinit(state.client.allocator);
    try obj.put(state.client.allocator, "expression", json.Value{ .string = expression });
    const params_json = try paramsJson(state.client.allocator, obj);
    defer state.client.allocator.free(params_json);
    return try executeCommand(state, "evaluate", params_json);
}

pub fn waitForSelector_(ptr: *anyopaque, selector: []const u8, _: ?WaitOptions) CliError!void {
    const state: *DaemonPageState = @ptrCast(@alignCast(ptr));
    var obj = json.ObjectMap.empty;
    defer obj.deinit(state.client.allocator);
    try obj.put(state.client.allocator, "selector", json.Value{ .string = selector });
    const params_json = try paramsJson(state.client.allocator, obj);
    defer state.client.allocator.free(params_json);
    const result = try executeCommand(state, "wait_for_selector", params_json);
    defer freeJsonValue(state.client.allocator, result);
}

pub fn waitForNavigation_(ptr: *anyopaque, _: ?WaitOptions) CliError!void {
    const state: *DaemonPageState = @ptrCast(@alignCast(ptr));
    const result = try executeCommand(state, "wait_for_navigation", null);
    defer freeJsonValue(state.client.allocator, result);
}

pub fn waitForTimeout_(ptr: *anyopaque, ms: u64) CliError!void {
    const state: *DaemonPageState = @ptrCast(@alignCast(ptr));
    var obj = json.ObjectMap.empty;
    defer obj.deinit(state.client.allocator);
    try obj.put(state.client.allocator, "ms", json.Value{ .integer = @intCast(ms) });
    const params_json = try paramsJson(state.client.allocator, obj);
    defer state.client.allocator.free(params_json);
    const result = try executeCommand(state, "wait_for_timeout", params_json);
    defer freeJsonValue(state.client.allocator, result);
}

pub fn click_(ptr: *anyopaque, selector: []const u8) CliError!void {
    const state: *DaemonPageState = @ptrCast(@alignCast(ptr));
    var obj = json.ObjectMap.empty;
    defer obj.deinit(state.client.allocator);
    try obj.put(state.client.allocator, "selector", json.Value{ .string = selector });
    const params_json = try paramsJson(state.client.allocator, obj);
    defer state.client.allocator.free(params_json);
    const result = try executeCommand(state, "click", params_json);
    defer freeJsonValue(state.client.allocator, result);
}

pub fn typeText_(ptr: *anyopaque, selector: []const u8, text: []const u8) CliError!void {
    const state: *DaemonPageState = @ptrCast(@alignCast(ptr));
    var obj = json.ObjectMap.empty;
    defer obj.deinit(state.client.allocator);
    try obj.put(state.client.allocator, "selector", json.Value{ .string = selector });
    try obj.put(state.client.allocator, "text", json.Value{ .string = text });
    const params_json = try paramsJson(state.client.allocator, obj);
    defer state.client.allocator.free(params_json);
    const result = try executeCommand(state, "type", params_json);
    defer freeJsonValue(state.client.allocator, result);
}

// ─── JSON parsing helpers ────────────────────────────────────────────

fn jsonStringOpt(allocator: std.mem.Allocator, val: ?json.Value) ?[]const u8 {
    return switch (val orelse return null) {
        .string => |s| allocator.dupe(u8, s) catch null,
        else => null,
    };
}

fn jsonBoolOpt(val: ?json.Value) ?bool {
    return switch (val orelse return null) {
        .bool => |b| b,
        else => null,
    };
}

fn jsonFloatOpt(val: ?json.Value) ?f64 {
    return switch (val orelse return null) {
        .float => |f| f,
        .integer => |i| @floatFromInt(i),
        else => null,
    };
}

fn jsonU16Opt(val: ?json.Value) ?u16 {
    return switch (val orelse return null) {
        .integer => |i| std.math.cast(u16, i),
        else => null,
    };
}

fn parseStringHashMap(allocator: std.mem.Allocator, val: ?json.Value) !std.StringHashMap([]const u8) {
    var map = std.StringHashMap([]const u8).init(allocator);
    errdefer {
        var it = map.iterator();
        while (it.next()) |entry| {
            allocator.free(entry.key_ptr.*);
            allocator.free(entry.value_ptr.*);
        }
        map.deinit();
    }
    const obj = switch (val orelse return map) {
        .object => |o| o,
        else => return map,
    };
    var it = obj.iterator();
    while (it.next()) |entry| {
        const key = try allocator.dupe(u8, entry.key_ptr.*);
        errdefer allocator.free(key);
        const value = switch (entry.value_ptr.*) {
            .string => |s| try allocator.dupe(u8, s),
            else => try allocator.dupe(u8, ""),
        };
        try map.put(key, value);
    }
    return map;
}

pub fn cookies_(ptr: *anyopaque, _: ?CookieOptions) CliError![]Cookie {
    const state: *DaemonPageState = @ptrCast(@alignCast(ptr));
    const result = try executeCommand(state, "cookies", null);
    defer freeJsonValue(state.client.allocator, result);

    var list = std.ArrayList(Cookie).empty;
    errdefer {
        for (list.items) |*c| {
            state.allocator.free(c.name);
            state.allocator.free(c.value);
            if (c.domain) |d| state.allocator.free(d);
            if (c.path) |p| state.allocator.free(p);
            if (c.same_site) |s| state.allocator.free(s);
        }
        list.deinit(state.allocator);
    }

    switch (result) {
        .array => |arr| {
            for (arr.items) |item| {
                if (item != .object) continue;
                const obj = item.object;
                const name = switch (obj.get("name") orelse continue) {
                    .string => |s| try state.allocator.dupe(u8, s),
                    else => continue,
                };
                const value = switch (obj.get("value") orelse continue) {
                    .string => |s| try state.allocator.dupe(u8, s),
                    else => continue,
                };
                try list.append(state.allocator, Cookie{
                    .name = name,
                    .value = value,
                    .domain = jsonStringOpt(state.allocator, obj.get("domain")),
                    .path = jsonStringOpt(state.allocator, obj.get("path")),
                    .same_site = jsonStringOpt(state.allocator, obj.get("sameSite")),
                    .http_only = jsonBoolOpt(obj.get("httpOnly")),
                    .secure = jsonBoolOpt(obj.get("secure")),
                    .expires = jsonFloatOpt(obj.get("expires")),
                });
            }
        },
        else => {},
    }

    return try list.toOwnedSlice(state.allocator);
}

pub fn setCookies_(ptr: *anyopaque, cookies: []Cookie) CliError!void {
    const state: *DaemonPageState = @ptrCast(@alignCast(ptr));
    const cookies_json = std.json.Stringify.valueAlloc(state.client.allocator, cookies, .{}) catch {
        return CliError.Pipeline;
    };
    defer state.client.allocator.free(cookies_json);
    const result = try executeCommand(state, "set_cookies", cookies_json);
    defer freeJsonValue(state.client.allocator, result);
}

pub fn screenshot_(ptr: *anyopaque, _: ?ScreenshotOptions) CliError![]u8 {
    const state: *DaemonPageState = @ptrCast(@alignCast(ptr));
    const result = try executeCommand(state, "screenshot", null);
    defer freeJsonValue(state.client.allocator, result);
    return switch (result) {
        .string => |s| state.allocator.dupe(u8, s) catch return CliError.Pipeline,
        else => try state.allocator.dupe(u8, ""),
    };
}

pub fn snapshot_(ptr: *anyopaque, opts: ?SnapshotOptions) CliError!json.Value {
    const state: *DaemonPageState = @ptrCast(@alignCast(ptr));
    var obj = json.ObjectMap.empty;
    defer obj.deinit(state.client.allocator);
    if (opts) |o| {
        if (o.selector) |sel| {
            try obj.put(state.client.allocator, "selector", json.Value{ .string = sel });
        }
        try obj.put(state.client.allocator, "include_hidden", json.Value{ .bool = o.include_hidden });
    }
    const params_json = try paramsJson(state.client.allocator, obj);
    defer state.client.allocator.free(params_json);
    return try executeCommand(state, "snapshot", params_json);
}

pub fn autoScroll_(ptr: *anyopaque, opts: ?AutoScrollOptions) CliError!void {
    const state: *DaemonPageState = @ptrCast(@alignCast(ptr));
    const max_scrolls = if (opts) |o| if (o.max_scrolls) |m| m else 3 else 3;
    var obj = json.ObjectMap.empty;
    defer obj.deinit(state.client.allocator);
    try obj.put(state.client.allocator, "max_scrolls", json.Value{ .integer = @intCast(max_scrolls) });
    const params_json = try paramsJson(state.client.allocator, obj);
    defer state.client.allocator.free(params_json);
    _ = try executeCommand(state, "auto_scroll", params_json);
}

pub fn tabs_(ptr: *anyopaque) CliError![]TabInfo {
    const state: *DaemonPageState = @ptrCast(@alignCast(ptr));
    const result = try executeCommand(state, "tabs", null);
    defer freeJsonValue(state.client.allocator, result);

    var list = std.ArrayList(TabInfo).empty;
    errdefer {
        for (list.items) |*t| {
            state.allocator.free(t.id);
            state.allocator.free(t.url);
            if (t.title) |title| state.allocator.free(title);
        }
        list.deinit(state.allocator);
    }

    switch (result) {
        .array => |arr| {
            for (arr.items) |item| {
                if (item != .object) continue;
                const obj = item.object;
                const id = switch (obj.get("id") orelse continue) {
                    .string => |s| try state.allocator.dupe(u8, s),
                    else => continue,
                };
                const url = switch (obj.get("url") orelse continue) {
                    .string => |s| try state.allocator.dupe(u8, s),
                    else => continue,
                };
                try list.append(state.allocator, TabInfo{
                    .id = id,
                    .url = url,
                    .title = jsonStringOpt(state.allocator, obj.get("title")),
                });
            }
        },
        else => {},
    }

    return try list.toOwnedSlice(state.allocator);
}

pub fn switchTab_(ptr: *anyopaque, new_tab_id: []const u8) CliError!void {
    const state: *DaemonPageState = @ptrCast(@alignCast(ptr));
    var obj = json.ObjectMap.empty;
    defer obj.deinit(state.client.allocator);
    try obj.put(state.client.allocator, "tab_id", json.Value{ .string = new_tab_id });
    const params_json = try paramsJson(state.client.allocator, obj);
    defer state.client.allocator.free(params_json);
    _ = try executeCommand(state, "switch_tab", params_json);
}

pub fn interceptRequests_(ptr: *anyopaque, url_pattern: []const u8) CliError!void {
    const state: *DaemonPageState = @ptrCast(@alignCast(ptr));
    var obj = json.ObjectMap.empty;
    defer obj.deinit(state.client.allocator);
    try obj.put(state.client.allocator, "url_pattern", json.Value{ .string = url_pattern });
    const params_json = try paramsJson(state.client.allocator, obj);
    defer state.client.allocator.free(params_json);
    _ = try executeCommand(state, "intercept_requests", params_json);
}

fn freeInterceptedRequest(allocator: std.mem.Allocator, req: *InterceptedRequest) void {
    allocator.free(req.url);
    allocator.free(req.method);
    if (req.body) |b| allocator.free(b);
    var hit = req.headers.iterator();
    while (hit.next()) |e| {
        allocator.free(e.key_ptr.*);
        allocator.free(e.value_ptr.*);
    }
    req.headers.deinit();
}

pub fn getInterceptedRequests_(ptr: *anyopaque) CliError![]InterceptedRequest {
    const state: *DaemonPageState = @ptrCast(@alignCast(ptr));
    const result = try executeCommand(state, "get_intercepted_requests", null);
    defer freeJsonValue(state.client.allocator, result);

    var list = std.ArrayList(InterceptedRequest).empty;
    errdefer {
        for (list.items) |*req| freeInterceptedRequest(state.allocator, req);
        list.deinit(state.allocator);
    }

    switch (result) {
        .array => |arr| {
            for (arr.items) |item| {
                if (item != .object) continue;
                const obj = item.object;
                const url = switch (obj.get("url") orelse continue) {
                    .string => |s| try state.allocator.dupe(u8, s),
                    else => continue,
                };
                const method = switch (obj.get("method") orelse continue) {
                    .string => |s| try state.allocator.dupe(u8, s),
                    else => continue,
                };
                const headers = try parseStringHashMap(state.allocator, obj.get("headers"));
                const body = jsonStringOpt(state.allocator, obj.get("body"));
                try list.append(state.allocator, InterceptedRequest{
                    .url = url,
                    .method = method,
                    .headers = headers,
                    .body = body,
                });
            }
        },
        else => {},
    }

    return try list.toOwnedSlice(state.allocator);
}

fn freeNetworkRequest(allocator: std.mem.Allocator, req: *NetworkRequest) void {
    allocator.free(req.url);
    allocator.free(req.method);
    if (req.body) |b| allocator.free(b);
    if (req.response_body) |b| allocator.free(b);
    var hit = req.headers.iterator();
    while (hit.next()) |e| {
        allocator.free(e.key_ptr.*);
        allocator.free(e.value_ptr.*);
    }
    req.headers.deinit();
}

pub fn getNetworkRequests_(ptr: *anyopaque) CliError![]NetworkRequest {
    const state: *DaemonPageState = @ptrCast(@alignCast(ptr));
    const result = try executeCommand(state, "get_network_requests", null);
    defer freeJsonValue(state.client.allocator, result);

    var list = std.ArrayList(NetworkRequest).empty;
    errdefer {
        for (list.items) |*req| freeNetworkRequest(state.allocator, req);
        list.deinit(state.allocator);
    }

    switch (result) {
        .array => |arr| {
            for (arr.items) |item| {
                if (item != .object) continue;
                const obj = item.object;
                const url = switch (obj.get("url") orelse continue) {
                    .string => |s| try state.allocator.dupe(u8, s),
                    else => continue,
                };
                const method = switch (obj.get("method") orelse continue) {
                    .string => |s| try state.allocator.dupe(u8, s),
                    else => continue,
                };
                const headers = try parseStringHashMap(state.allocator, obj.get("headers"));
                const body = jsonStringOpt(state.allocator, obj.get("body"));
                const response_body = jsonStringOpt(state.allocator, obj.get("responseBody"));
                const status = jsonU16Opt(obj.get("status"));
                try list.append(state.allocator, NetworkRequest{
                    .url = url,
                    .method = method,
                    .headers = headers,
                    .body = body,
                    .status = status,
                    .response_body = response_body,
                });
            }
        },
        else => {},
    }

    return try list.toOwnedSlice(state.allocator);
}

// ─── IPage constructor ───────────────────────────────────────────────

pub fn makeIPage(allocator: std.mem.Allocator, client: *DaemonClient, owns_client: bool, tab_id: []const u8) !IPage {
    const state = try allocator.create(DaemonPageState);
    errdefer allocator.destroy(state);
    state.* = .{
        .allocator = allocator,
        .client = client,
        .owns_client = owns_client,
        .tab_id = try allocator.dupe(u8, tab_id),
    };
    return .{
        .ptr = state,
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

pub fn close_(ptr: *anyopaque) CliError!void {
    const state: *DaemonPageState = @ptrCast(@alignCast(ptr));
    _ = state.client.executePageCommand(state.tab_id, "close", null) catch |err| {
        std.log.warn("page.close failed: {s}", .{@errorName(err)});
    };
    state.allocator.free(state.tab_id);
    if (state.owns_client) {
        state.client.deinit();
        state.allocator.destroy(state.client);
    }
    state.allocator.destroy(state);
}
