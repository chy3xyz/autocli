const std = @import("std");
const json = std.json;
const CliError = @import("core").CliError;

const AI_TIMEOUT_MS: u32 = 30_000;

/// Search autocli.ai for adapters matching a URL pattern.
/// Returns allocated JSON string. Caller must free.
pub fn search(
    gpa: std.mem.Allocator,
    io: std.Io,
    environ_map: *const std.process.Environ.Map,
    token: []const u8,
    pattern: []const u8,
) CliError![]const u8 {
    const config = @import("config.zig");
    const url = try config.searchUrl(environ_map, pattern, gpa);
    defer gpa.free(url);

    const uri = std.Uri.parse(url) catch return CliError.Http;
    var client = std.http.Client{ .allocator = gpa, .io = io };
    defer client.deinit();

    const auth_header = try std.fmt.allocPrint(gpa, "Bearer {s}", .{token});
    defer gpa.free(auth_header);

    const extra_headers = &[_]std.http.Header{
        .{ .name = "Authorization", .value = auth_header },
        .{ .name = "User-Agent", .value = config.userAgent() },
    };

    const http_util = @import("core").http_util;
    const retry_cfg = http_util.RetryConfig{};

    var attempt: u32 = 0;
    var log_state = http_util.HttpLogState{
        .enabled = http_util.http_logging_enabled,
        .method = "GET",
        .url = url,
        .start_ts = std.Io.Timestamp.now(io, .real),
        .attempt = &attempt,
    };
    defer log_state.log(io);

    while (true) {
        var req = @import("core").requestWithTimeout(&client, .GET, uri, .{ .extra_headers = extra_headers }, AI_TIMEOUT_MS) catch |err| {
            if (attempt >= retry_cfg.max_retries or !http_util.isRetryableHttpError(err)) {
                return switch (err) {
                    error.Timeout => CliError.Timeout,
                    else => CliError.Http,
                };
            }
            http_util.logRetry("ai.search", attempt, retry_cfg.max_retries, err);
            http_util.backoffSleep(io, retry_cfg.base_delay_ms, attempt, retry_cfg.max_delay_ms);
            attempt += 1;
            continue;
        };

        req.sendBodiless() catch {
            req.deinit();
            if (attempt >= retry_cfg.max_retries) return CliError.Http;
            http_util.logRetry("ai.search", attempt, retry_cfg.max_retries, error.Http);
            http_util.backoffSleep(io, retry_cfg.base_delay_ms, attempt, retry_cfg.max_delay_ms);
            attempt += 1;
            continue;
        };

        var redirect_buf: [4096]u8 = undefined;
        var response = req.receiveHead(&redirect_buf) catch |err| {
            req.deinit();
            if (attempt >= retry_cfg.max_retries or !http_util.isRetryableHttpError(err)) return CliError.Http;
            http_util.logRetry("ai.search", attempt, retry_cfg.max_retries, err);
            http_util.backoffSleep(io, retry_cfg.base_delay_ms, attempt, retry_cfg.max_delay_ms);
            attempt += 1;
            continue;
        };
        const status = @intFromEnum(response.head.status);

        if (status == 403) {
            req.deinit();
            return CliError.AuthRequired;
        }
        if (http_util.isRetryableStatus(status)) {
            req.deinit();
            if (attempt >= retry_cfg.max_retries) return CliError.Http;
            http_util.logRetry("ai.search", attempt, retry_cfg.max_retries, error.Http);
            http_util.backoffSleep(io, retry_cfg.base_delay_ms, attempt, retry_cfg.max_delay_ms);
            attempt += 1;
            continue;
        }
        if (status < 200 or status >= 300) {
            req.deinit();
            return CliError.Http;
        }

        var transfer_buf: [4096]u8 = undefined;
        const reader = response.reader(&transfer_buf);
        const body = reader.allocRemaining(gpa, .limited(256 * 1024)) catch {
            req.deinit();
            return CliError.Http;
        };
        log_state.recordStatus(status);
        req.deinit();
        return body;
    }
}

/// Generate adapter YAML via autocli.ai API.
/// Returns allocated YAML string. Caller must free.
pub fn generateAdapter(
    gpa: std.mem.Allocator,
    io: std.Io,
    environ_map: *const std.process.Environ.Map,
    token: []const u8,
    captured_data: []const u8,
    goal: ?[]const u8,
) CliError![]const u8 {
    const config = @import("config.zig");
    const url = try config.generateAdapterUrl(environ_map, gpa);
    defer gpa.free(url);

    const uri = std.Uri.parse(url) catch return CliError.Http;

    // Build request body via proper JSON serialization
    var request_obj = json.ObjectMap.init(gpa, &[_][]const u8{}, &[_]json.Value{}) catch return CliError.OutOfMemory;
    errdefer request_obj.deinit(gpa);
    try request_obj.put(gpa, "captured_data", json.Value{ .string = captured_data });
    try request_obj.put(gpa, "goal", json.Value{ .string = goal orelse "" });
    try request_obj.put(gpa, "stream", json.Value{ .bool = false });

    const body_json = std.json.Stringify.valueAlloc(gpa, json.Value{ .object = request_obj }, .{}) catch return CliError.Json;
    defer gpa.free(body_json);

    var client = std.http.Client{ .allocator = gpa, .io = io };
    defer client.deinit();

    const auth_header = try std.fmt.allocPrint(gpa, "Bearer {s}", .{token});
    defer gpa.free(auth_header);

    const extra_headers = &[_]std.http.Header{
        .{ .name = "Authorization", .value = auth_header },
        .{ .name = "Content-Type", .value = "application/json" },
        .{ .name = "User-Agent", .value = config.userAgent() },
    };

    const http_util = @import("core").http_util;
    const retry_cfg = http_util.RetryConfig{};

    var attempt: u32 = 0;
    var log_state = http_util.HttpLogState{
        .enabled = http_util.http_logging_enabled,
        .method = "POST",
        .url = url,
        .start_ts = std.Io.Timestamp.now(io, .real),
        .attempt = &attempt,
    };
    defer log_state.log(io);

    while (true) {
        var req = @import("core").requestWithTimeout(&client, .POST, uri, .{ .extra_headers = extra_headers }, AI_TIMEOUT_MS) catch |err| {
            if (attempt >= retry_cfg.max_retries or !http_util.isRetryableHttpError(err)) {
                return switch (err) {
                    error.Timeout => CliError.Timeout,
                    else => CliError.Http,
                };
            }
            http_util.logRetry("ai.generate", attempt, retry_cfg.max_retries, err);
            http_util.backoffSleep(io, retry_cfg.base_delay_ms, attempt, retry_cfg.max_delay_ms);
            attempt += 1;
            continue;
        };

        _ = req.sendBody(body_json) catch {
            req.deinit();
            if (attempt >= retry_cfg.max_retries) return CliError.Http;
            http_util.logRetry("ai.generate", attempt, retry_cfg.max_retries, error.Http);
            http_util.backoffSleep(io, retry_cfg.base_delay_ms, attempt, retry_cfg.max_delay_ms);
            attempt += 1;
            continue;
        };

        var redirect_buf: [4096]u8 = undefined;
        var response = req.receiveHead(&redirect_buf) catch |err| {
            req.deinit();
            if (attempt >= retry_cfg.max_retries or !http_util.isRetryableHttpError(err)) return CliError.Http;
            http_util.logRetry("ai.generate", attempt, retry_cfg.max_retries, err);
            http_util.backoffSleep(io, retry_cfg.base_delay_ms, attempt, retry_cfg.max_delay_ms);
            attempt += 1;
            continue;
        };
        const status = @intFromEnum(response.head.status);

        if (status == 403) {
            req.deinit();
            return CliError.AuthRequired;
        }
        if (http_util.isRetryableStatus(status)) {
            req.deinit();
            if (attempt >= retry_cfg.max_retries) return CliError.Http;
            http_util.logRetry("ai.generate", attempt, retry_cfg.max_retries, error.Http);
            http_util.backoffSleep(io, retry_cfg.base_delay_ms, attempt, retry_cfg.max_delay_ms);
            attempt += 1;
            continue;
        }
        if (status < 200 or status >= 300) {
            req.deinit();
            return CliError.Http;
        }

        var transfer_buf: [4096]u8 = undefined;
        const reader = response.reader(&transfer_buf);
        const body = reader.allocRemaining(gpa, .limited(512 * 1024)) catch {
            req.deinit();
            return CliError.Http;
        };
        log_state.recordStatus(status);
        req.deinit();

        const result = extractContent(gpa, body) catch {
            http_util.logBody("response", body, 512);
            gpa.free(body);
            return CliError.Http;
        };
        gpa.free(body);
        return result;
    }
}

/// Extract content from OpenAI-compatible JSON response.
/// Supports multiple response formats.
fn extractContent(gpa: std.mem.Allocator, response_body: []const u8) ![]const u8 {
    const parsed = json.parseFromSlice(json.Value, gpa, response_body, .{}) catch {
        return try gpa.dupe(u8, response_body);
    };
    defer parsed.deinit();

    const root = parsed.value;

    // Check for error field
    if (root.object.get("error")) |err_val| {
        const msg = if (err_val.object.get("message")) |m| m.string else "unknown error";
        std.log.err("LLM API error: {s}", .{msg});
        return error.LLMError;
    }

    // Try choices[0].message.content (OpenAI standard)
    if (root.object.get("choices")) |choices| {
        if (choices.array.items.len > 0) {
            const first = choices.array.items[0];
            if (first.object.get("message")) |msg| {
                if (msg.object.get("content")) |content| {
                    if (content.string.len > 0) {
                        return try gpa.dupe(u8, content.string);
                    }
                }
            }
            // Try delta for streaming
            if (first.object.get("delta")) |delta| {
                if (delta.object.get("content")) |content| {
                    if (content.string.len > 0) {
                        return try gpa.dupe(u8, content.string);
                    }
                }
            }
            // Try text field
            if (first.object.get("text")) |text| {
                if (text.string.len > 0) {
                    return try gpa.dupe(u8, text.string);
                }
            }
        }
    }

    // Try output.text
    if (root.object.get("output")) |output| {
        if (output.object.get("text")) |text| {
            if (text.string.len > 0) {
                return try gpa.dupe(u8, text.string);
            }
        }
    }

    // Try data[0].content
    if (root.object.get("data")) |data| {
        if (data.array.items.len > 0) {
            const first = data.array.items[0];
            if (first.object.get("content")) |content| {
                if (content.string.len > 0) {
                    return try gpa.dupe(u8, content.string);
                }
            }
        }
    }

    return try gpa.dupe(u8, response_body);
}
