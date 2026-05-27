const std = @import("std");
const json = @import("std").json;
const CliError = @import("core").CliError;
const IPage = @import("core").IPage;
const StepHandler = @import("../registry.zig").StepHandler;
const StepRegistry = @import("../registry.zig").StepRegistry;
const TemplateContext = @import("../template/mod.zig").TemplateContext;
const renderTemplate = @import("../template/mod.zig").renderTemplate;
const renderTemplateStr = @import("../template/mod.zig").renderTemplateStr;
const freeJsonValue = @import("../executor.zig").freeJsonValue;

const JsonArray = std.array_list.Managed(json.Value);

// ---------------------------------------------------------------------------
// URL encoding
// ---------------------------------------------------------------------------

/// Percent-encode a string for URL query parameters.
/// Caller owns returned memory.
fn urlEncode(allocator: std.mem.Allocator, s: []const u8) ![]const u8 {
    var count: usize = 0;
    for (s) |c| {
        if (!isUrlSafe(c)) count += 2; // %XX adds 2 extra chars
    }
    if (count == 0) return try allocator.dupe(u8, s);

    const buf = try allocator.alloc(u8, s.len + count);
    var i: usize = 0;
    for (s) |c| {
        if (isUrlSafe(c)) {
            buf[i] = c;
            i += 1;
        } else {
            buf[i] = '%';
            buf[i + 1] = std.fmt.digits2(c)[0];
            buf[i + 2] = std.fmt.digits2(c)[1];
            i += 3;
        }
    }
    return buf;
}

fn isUrlSafe(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '-' or c == '_' or c == '.' or c == '~';
}

/// Append query parameters from a JSON object to a URL.
fn appendQueryParams(
    allocator: std.mem.Allocator,
    url: []const u8,
    query_obj: json.Value,
    ctx: TemplateContext,
) ![]const u8 {
    if (query_obj != .object) return try allocator.dupe(u8, url);
    const obj = query_obj.object;
    if (obj.count() == 0) return try allocator.dupe(u8, url);

    var pairs = std.ArrayList(u8).empty;
    defer pairs.deinit(allocator);

    var it = obj.iterator();
    while (it.next()) |entry| {
        const key = entry.key_ptr.*;
        const rendered = renderTemplate(entry.value_ptr.*, ctx, allocator) catch continue;
        defer freeJsonValue(allocator, rendered);
        const val_str = switch (rendered) {
            .string => |s| s,
            .integer => |n| try std.fmt.allocPrint(allocator, "{d}", .{n}),
            .float => |n| try std.fmt.allocPrint(allocator, "{d}", .{n}),
            .bool => |b| if (b) "true" else "false",
            .null => continue,
            else => try std.fmt.allocPrint(allocator, "{}", .{rendered}),
        };
        defer if (rendered != .string and rendered != .bool and rendered != .null) allocator.free(val_str);

        const esc_key = try urlEncode(allocator, key);
        defer allocator.free(esc_key);
        const esc_val = try urlEncode(allocator, val_str);
        defer allocator.free(esc_val);

        if (pairs.items.len > 0) try pairs.appendSlice(allocator, "&");
        try pairs.appendSlice(allocator, esc_key);
        try pairs.appendSlice(allocator, "=");
        try pairs.appendSlice(allocator, esc_val);
    }

    if (pairs.items.len == 0) return try allocator.dupe(u8, url);

    const separator = if (std.mem.indexOf(u8, url, "?")) |_| "&" else "?";
    return std.fmt.allocPrint(allocator, "{s}{s}{s}", .{ url, separator, pairs.items });
}

// ---------------------------------------------------------------------------
// HTTP method
// ---------------------------------------------------------------------------

const HttpMethod = enum {
    GET, POST, PUT, PATCH, DELETE, HEAD, OPTIONS,

    pub fn fromString(s: []const u8) ?HttpMethod {
        inline for (.{ "GET", "POST", "PUT", "PATCH", "DELETE", "HEAD", "OPTIONS" }) |m| {
            if (std.mem.eql(u8, s, m)) return @field(HttpMethod, m);
        }
        return null;
    }

    fn toHttpMethod(self: HttpMethod) std.http.Method {
        return switch (self) {
            inline else => |h| @field(std.http.Method, @tagName(h)),
        };
    }
};

// ---------------------------------------------------------------------------
// Fetch step state
// ---------------------------------------------------------------------------

pub const FetchStepState = struct {
    allocator: std.mem.Allocator,
    client: std.http.Client,
};

// ---------------------------------------------------------------------------
// Per-item URL detection
// ---------------------------------------------------------------------------

/// Check if a URL string references `item` (per-item mode)
fn isPerItemUrl(url: []const u8) bool {
    var rest = url;
    while (std.mem.indexOf(u8, rest, "${{")) |pos| {
        const after_marker = rest[pos + 3 ..];
        if (std.mem.indexOf(u8, after_marker, "}}")) |end| {
            const expr = after_marker[0..end];
            if (containsItemRef(expr)) return true;
            rest = after_marker[end + 2 ..];
        } else break;
    }
    return false;
}

fn containsItemRef(expr: []const u8) bool {
    const trimmed = std.mem.trim(u8, expr, " ");
    var idx: usize = 0;
    while (std.mem.indexOfPos(u8, trimmed, idx, "item")) |pos| {
        // Check char before "item"
        if (pos > 0) {
            const prev = trimmed[pos - 1];
            if (std.ascii.isAlphanumeric(prev) or prev == '_') {
                idx = pos + 1;
                continue;
            }
        }
        // Check char after "item"
        const after_pos = pos + 4;
        if (after_pos < trimmed.len) {
            const next = trimmed[after_pos];
            if (std.ascii.isAlphanumeric(next) or next == '_') {
                idx = pos + 1;
                continue;
            }
        }
        return true;
    }
    return false;
}

// ---------------------------------------------------------------------------
// FetchStep
// ---------------------------------------------------------------------------

pub const FetchStep = struct {
    state: *FetchStepState,

    pub fn name(_: *anyopaque) []const u8 {
        return "fetch";
    }

    pub fn execute(
        ptr: *anyopaque,
        allocator: std.mem.Allocator,
        _: std.Io,
        _: ?IPage,
        params: json.Value,
        data: json.Value,
        args: std.StringHashMap(json.Value),
    ) CliError!json.Value {
        const state: *FetchStepState = @ptrCast(@alignCast(ptr));

        // Extract URL template from params
        const url_template: []const u8 = switch (params) {
            .string => |s| s,
            .object => |obj| blk: {
                const url_val = obj.get("url") orelse return CliError.Pipeline;
                break :blk switch (url_val) {
                    .string => |s| s,
                    else => return CliError.Pipeline,
                };
            },
            else => return CliError.Pipeline,
        };

        const method: HttpMethod = switch (params) {
            .string => .GET,
            .object => |obj| blk: {
                const m = obj.get("method") orelse break :blk .GET;
                const ms = switch (m) { .string => |s| s, else => break :blk .GET };
                break :blk HttpMethod.fromString(ms) orelse .GET;
            },
            else => .GET,
        };

        // Check for per-item mode: data is array AND url references item
        const is_array = data == .array;
        const has_item_ref = isPerItemUrl(url_template);

        if (is_array and has_item_ref) {
            // Per-item fetch: iterate over each item, fetch per item
            return fetchPerItem(state, method, params, data, args, allocator);
        }

        // Single fetch
        const ctx = TemplateContext{
            .args = args,
            .data = data,
            .item = data,
            .index = 0,
        };

        const rendered_params = try renderTemplate(params, ctx, allocator);
        const url = extractUrl(rendered_params) orelse return CliError.Pipeline;
        defer freeJsonValue(allocator, rendered_params);

        // Append query params if present
        var final_url = url;
        if (params == .object and params.object.get("params") != null) {
            final_url = try appendQueryParams(allocator, url, params.object.get("params").?, ctx);
        } else {
            final_url = try allocator.dupe(u8, url);
        }
        defer allocator.free(final_url);

        return try doFetch(state, method, final_url, null, null);
    }

    pub fn isBrowserStep(_: *anyopaque) bool {
        return false;
    }

    pub fn handler(state: *FetchStepState) StepHandler {
        return .{
            .ptr = @ptrFromInt(@intFromPtr(state)),
            .vtable = &StepHandler.VTable{
                .name = name,
                .execute = execute,
                .isBrowserStep = isBrowserStep,
            },
        };
    }
};

// ---------------------------------------------------------------------------
// Per-item fetch
// ---------------------------------------------------------------------------

fn fetchPerItem(
    state: *FetchStepState,
    method: HttpMethod,
    params: json.Value,
    data: json.Value,
    args: std.StringHashMap(json.Value),
    allocator: std.mem.Allocator,
) CliError!json.Value {
    const items = data.array.items;

    // Sequential for single item (no overhead)
    if (items.len <= 1) {
        var results = JsonArray.init(allocator);
        errdefer results.deinit();

        for (items, 0..) |item, index_val| {
            var body_template: ?[]const u8 = null;
            if (params == .object) {
                if (params.object.get("body")) |b| {
                    body_template = switch (b) { .string => |s| s, else => null };
                }
            }

            const ctx = TemplateContext{
                .args = args,
                .data = data,
                .item = item,
                .index = index_val,
            };

            const rendered_params = try renderTemplate(params, ctx, allocator);

            const url: []const u8 = switch (rendered_params) {
                .string => |s| s,
                .object => |obj| blk: {
                    const url_val = obj.get("url") orelse return CliError.Pipeline;
                    break :blk switch (url_val) {
                        .string => |s| s,
                        else => return CliError.Pipeline,
                    };
                },
                else => return CliError.Pipeline,
            };
            defer freeJsonValue(allocator, rendered_params);

            var final_url = url;
            if (params == .object and params.object.get("params") != null) {
                final_url = try appendQueryParams(allocator, url, params.object.get("params").?, ctx);
            } else {
                final_url = try allocator.dupe(u8, url);
            }
            defer allocator.free(final_url);

            const fetched = try doFetch(state, method, final_url, null, body_template);
            try results.append(fetched);
        }

        return .{ .array = results };
    }

    // Concurrent fetch for multiple items (max 10 parallel)
    var item_params = try allocator.alloc(FetchItemParams, items.len);
    defer {
        for (item_params) |p| {
            if (p.owned_url) allocator.free(p.url);
        }
        allocator.free(item_params);
    }

    for (items, 0..) |item, index_val| {
        var body_template: ?[]const u8 = null;
        if (params == .object) {
            if (params.object.get("body")) |b| {
                body_template = switch (b) { .string => |s| s, else => null };
            }
        }

        const ctx = TemplateContext{
            .args = args,
            .data = data,
            .item = item,
            .index = index_val,
        };

        const rendered_params = try renderTemplate(params, ctx, allocator);

        const url: []const u8 = switch (rendered_params) {
            .string => |s| s,
            .object => |obj| blk: {
                const url_val = obj.get("url") orelse return CliError.Pipeline;
                break :blk switch (url_val) {
                    .string => |s| s,
                    else => return CliError.Pipeline,
                };
            },
            else => return CliError.Pipeline,
        };
        defer freeJsonValue(allocator, rendered_params);

        var final_url = url;
        if (params == .object and params.object.get("params") != null) {
            final_url = try appendQueryParams(allocator, url, params.object.get("params").?, ctx);
        } else {
            final_url = try allocator.dupe(u8, url);
        }
        item_params[index_val] = .{ .url = final_url, .body = body_template, .owned_url = true };
    }

    const results = try allocator.alloc(json.Value, items.len);
    @memset(results, .null);
    errdefer {
        for (results) |r| {
            if (r != .null) freeJsonValue(allocator, r);
        }
        allocator.free(results);
    }

    const errors = try allocator.alloc(?CliError, items.len);
    @memset(errors, null);
    defer allocator.free(errors);

    // Sequential per-item fetch (std.http.Client is not thread-safe)
    for (0..items.len) |idx| {
        const ctx = FetchWorkerCtx{
            .allocator = allocator,
            .client = &state.client,
            .method = method,
            .url = item_params[idx].url,
            .body = item_params[idx].body,
            .results = results,
            .errors = errors,
            .index = idx,
        };
        fetchWorker(ctx);
        if (errors[idx]) |err| return err;
    }

    var result_list = JsonArray.init(allocator);
    errdefer result_list.deinit();
    for (results) |r| {
        try result_list.append(r);
    }
    allocator.free(results);

    return .{ .array = result_list };
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

fn extractUrl(rendered_params: json.Value) ?[]const u8 {
    return switch (rendered_params) {
        .string => |s| s,
        .object => |obj| blk: {
            const url_val = obj.get("url") orelse break :blk null;
            break :blk switch (url_val) {
                .string => |s| s,
                else => null,
            };
        },
        else => null,
    };
}

// ---------------------------------------------------------------------------
// doFetch - Core HTTP request
// ---------------------------------------------------------------------------

const HTTP_CONNECT_TIMEOUT_MS: u32 = 30_000;

fn doFetchWithClient(
    allocator: std.mem.Allocator,
    client: *std.http.Client,
    method: HttpMethod,
    url: []const u8,
    extra_headers: ?[]const std.http.Header,
    body: ?[]const u8,
) CliError!json.Value {
    const uri = std.Uri.parse(url) catch return CliError.Pipeline;
    if (!@import("core").validateFetchUrl(uri)) return CliError.Pipeline;

    const headers_slice: []const std.http.Header = if (extra_headers) |h| h else &.{};
    const options: std.http.Client.RequestOptions = .{
        .extra_headers = headers_slice,
        .redirect_behavior = .not_allowed,
        .headers = .{
            .accept_encoding = .{ .override = "identity" },
        },
    };

    const http_util = @import("core").http_util;
    const retry_cfg = http_util.RetryConfig{};

    var attempt: u32 = 0;
    var log_state = http_util.HttpLogState{
        .enabled = http_util.http_logging_enabled,
        .method = @tagName(method.toHttpMethod()),
        .url = url,
        .start_ts = std.Io.Timestamp.now(client.io, .real),
        .attempt = &attempt,
    };
    defer log_state.log(client.io);

    const deadline_ms: u64 = 60_000;
    const start_ts = std.Io.Timestamp.now(client.io, .real);

    while (true) {
        const elapsed_ms = @divFloor(std.Io.Timestamp.now(client.io, .real).nanoseconds - start_ts.nanoseconds, std.time.ns_per_ms);
        if (elapsed_ms > deadline_ms) {
            return CliError.Timeout;
        }

        // 1. Create request
        var req = @import("core").requestWithTimeout(client, method.toHttpMethod(), uri, options, HTTP_CONNECT_TIMEOUT_MS) catch |err| {
            std.log.err("fetch HTTP err={s} url={s}", .{ @errorName(err), url });
            if (attempt >= retry_cfg.max_retries or !http_util.isRetryableHttpError(err)) {
                return switch (err) {
                    error.Timeout => CliError.Timeout,
                    else => CliError.Http,
                };
            }
            http_util.logRetry("fetch", attempt, retry_cfg.max_retries, err);
            http_util.backoffSleep(client.io, retry_cfg.base_delay_ms, attempt, retry_cfg.max_delay_ms);
            attempt += 1;
            continue;
        };

        // 2. Send body
        if (body) |b| {
            http_util.logBody("request", b, 512);
        }
        const send_ok = blk: {
            if (body) |b| {
                req.transfer_encoding = .{ .content_length = b.len };
                var bw = req.sendBodyUnflushed(&.{}) catch break :blk false;
                _ = bw.writer.writeAll(b) catch break :blk false;
                _ = bw.end() catch break :blk false;
                if (req.connection) |conn| {
                    _ = conn.flush() catch break :blk false;
                } else break :blk false;
            } else {
                req.sendBodiless() catch break :blk false;
            }
            break :blk true;
        };
        if (!send_ok) {
            req.deinit();
            if (attempt >= retry_cfg.max_retries) return CliError.Http;
            http_util.logRetry("fetch", attempt, retry_cfg.max_retries, error.Http);
            http_util.backoffSleep(client.io, retry_cfg.base_delay_ms, attempt, retry_cfg.max_delay_ms);
            attempt += 1;
            continue;
        }

        // 3. Receive head
        var redirect_buffer: [8192]u8 = undefined;
        var response = req.receiveHead(&redirect_buffer) catch |err| {
            req.deinit();
            if (attempt >= retry_cfg.max_retries or !http_util.isRetryableHttpError(err)) return CliError.Http;
            http_util.logRetry("fetch", attempt, retry_cfg.max_retries, err);
            http_util.backoffSleep(client.io, retry_cfg.base_delay_ms, attempt, retry_cfg.max_delay_ms);
            attempt += 1;
            continue;
        };

        const status = @intFromEnum(response.head.status);
        if (http_util.isRetryableStatus(status)) {
            req.deinit();
            if (attempt >= retry_cfg.max_retries) return CliError.Http;
            http_util.logRetry("fetch", attempt, retry_cfg.max_retries, error.Http);
            http_util.backoffSleep(client.io, retry_cfg.base_delay_ms, attempt, retry_cfg.max_delay_ms);
            attempt += 1;
            continue;
        }
        if (status < 200 or status >= 300) {
            req.deinit();
            return CliError.Http;
        }

        // 4. Read body and parse JSON
        var transfer_buffer: [64]u8 = undefined;
        const reader = response.reader(&transfer_buffer);
        const body_text = reader.allocRemaining(allocator, @as(std.Io.Limit, @enumFromInt(1024 * 1024))) catch {
            req.deinit();
            return CliError.Http;
        };
        defer allocator.free(body_text);

        const parsed = json.parseFromSliceLeaky(json.Value, allocator, body_text, .{}) catch {
            req.deinit();
            return CliError.Pipeline;
        };
        log_state.recordStatus(status);
        req.deinit();
        return parsed;
    }
}

fn doFetch(
    state: *FetchStepState,
    method: HttpMethod,
    url: []const u8,
    extra_headers: ?[]const std.http.Header,
    body: ?[]const u8,
) CliError!json.Value {
    return doFetchWithClient(state.allocator, &state.client, method, url, extra_headers, body);
}

const FetchItemParams = struct {
    url: []const u8,
    body: ?[]const u8,
    owned_url: bool,
};

const FetchWorkerCtx = struct {
    allocator: std.mem.Allocator,
    client: *std.http.Client,
    method: HttpMethod,
    url: []const u8,
    body: ?[]const u8,
    results: []json.Value,
    errors: []?CliError,
    index: usize,
};

fn fetchWorker(ctx: FetchWorkerCtx) void {
    const result = doFetchWithClient(ctx.allocator, ctx.client, ctx.method, ctx.url, null, ctx.body);
    if (result) |val| {
        ctx.results[ctx.index] = val;
    } else |err| {
        ctx.errors[ctx.index] = err;
    }
}

// ---------------------------------------------------------------------------
// Registration
// ---------------------------------------------------------------------------

pub fn registerFetchSteps(registry: *StepRegistry, state: *FetchStepState) !void {
    try registry.register(FetchStep.handler(state));
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "urlEncode leaves safe chars alone" {
    const gpa = std.testing.allocator;
    const out = try urlEncode(gpa, "hello-world_123.txt~");
    defer gpa.free(out);
    try std.testing.expectEqualStrings("hello-world_123.txt~", out);
}

test "urlEncode encodes unsafe chars" {
    const gpa = std.testing.allocator;
    const out = try urlEncode(gpa, "hello world!");
    defer gpa.free(out);
    try std.testing.expectEqualStrings("hello%20world%21", out);
}

test "urlEncode encodes unicode bytes" {
    const gpa = std.testing.allocator;
    const out = try urlEncode(gpa, "中文");
    defer gpa.free(out);
    try std.testing.expectEqualStrings("%E4%B8%AD%E6%96%87", out);
}

test "appendQueryParams adds ? separator" {
    const gpa = std.testing.allocator;
    var args = std.StringHashMap(json.Value).init(gpa);
    defer args.deinit();
    const ctx = TemplateContext{
        .args = args,
        .data = .null,
        .item = .null,
        .index = 0,
    };

    var obj = json.ObjectMap.empty;
    try obj.put(gpa, "q", .{ .string = "hello world" });
    defer {
        var it = obj.iterator();
        while (it.next()) |entry| gpa.free(entry.key_ptr.*);
        obj.deinit(gpa);
    }

    const result = try appendQueryParams(gpa, "https://api.com/search", .{ .object = obj }, ctx);
    defer gpa.free(result);
    try std.testing.expectEqualStrings("https://api.com/search?q=hello%20world", result);
}

test "appendQueryParams adds & separator" {
    const gpa = std.testing.allocator;
    var args = std.StringHashMap(json.Value).init(gpa);
    defer args.deinit();
    const ctx = TemplateContext{
        .args = args,
        .data = .null,
        .item = .null,
        .index = 0,
    };

    var obj = json.ObjectMap.empty;
    try obj.put(gpa, "a", .{ .string = "1" });
    try obj.put(gpa, "b", .{ .string = "2" });
    defer {
        var it = obj.iterator();
        while (it.next()) |entry| gpa.free(entry.key_ptr.*);
        obj.deinit(gpa);
    }

    const result = try appendQueryParams(gpa, "https://api.com?x=0", .{ .object = obj }, ctx);
    defer gpa.free(result);
    try std.testing.expectEqualStrings("https://api.com?x=0&a=1&b=2", result);
}

test "appendQueryParams skips null values" {
    const gpa = std.testing.allocator;
    var args = std.StringHashMap(json.Value).init(gpa);
    defer args.deinit();
    const ctx = TemplateContext{
        .args = args,
        .data = .null,
        .item = .null,
        .index = 0,
    };

    var obj = json.ObjectMap.empty;
    try obj.put(gpa, "a", .{ .string = "1" });
    try obj.put(gpa, "b", .null);
    defer {
        var it = obj.iterator();
        while (it.next()) |entry| gpa.free(entry.key_ptr.*);
        obj.deinit(gpa);
    }

    const result = try appendQueryParams(gpa, "https://api.com", .{ .object = obj }, ctx);
    defer gpa.free(result);
    try std.testing.expectEqualStrings("https://api.com?a=1", result);
}

test "isPerItemUrl detects item reference" {
    try std.testing.expect(isPerItemUrl("${{ item.id }}"));
    try std.testing.expect(isPerItemUrl("https://api.com/${{ item.slug }}"));
    try std.testing.expect(!isPerItemUrl("https://api.com/${{ args.id }}"));
    try std.testing.expect(!isPerItemUrl("https://api.com/123"));
}
