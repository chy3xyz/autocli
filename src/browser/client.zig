const std = @import("std");
const json = @import("std").json;
const http = @import("std").http;
const CliError = @import("core").CliError;
const DaemonCommand = @import("types.zig").DaemonCommand;
const DaemonResult = @import("types.zig").DaemonResult;
const DaemonStatus = @import("types.zig").DaemonStatus;

/// HTTP client for communicating with the autocli daemon (axum:19825)
pub const DaemonClient = struct {
    allocator: std.mem.Allocator,
    port: u16,
    client: http.Client,
    io: std.Io,

    pub fn init(allocator: std.mem.Allocator, port: u16, io: std.Io) DaemonClient {
        return .{
            .allocator = allocator,
            .port = port,
            .client = http.Client{ .allocator = allocator, .io = io },
            .io = io,
        };
    }

    pub fn deinit(self: *DaemonClient) void {
        self.client.deinit();
    }

    /// Check if daemon is running by calling /status
    pub fn isRunning(self: *DaemonClient) bool {
        var buf: [256]u8 = undefined;
        const url = std.fmt.bufPrint(&buf, "http://127.0.0.1:{d}/status", .{self.port}) catch return false;
        return self.doGet(url, 2000);
    }

    const DAEMON_TIMEOUT_MS: u32 = 5_000;

    /// Check if Chrome extension is connected
    /// Compatible with both autocli (`extension` field) and original opencli (`extensionConnected` field).
    pub fn isExtensionConnected(self: *DaemonClient) bool {
        var buf: [256]u8 = undefined;
        const url = std.fmt.bufPrint(&buf, "http://127.0.0.1:{d}/status", .{self.port}) catch return false;

        const http_util = @import("core").http_util;
        var zero_attempt: u32 = 0;
        var log_state = http_util.HttpLogState{
            .enabled = http_util.http_logging_enabled,
            .method = "GET",
            .url = url,
            .start_ts = std.Io.Timestamp.now(self.io, .real),
            .attempt = &zero_attempt,
        };
        defer log_state.log(self.io);

        const uri = std.Uri.parse(url) catch return false;
        const options: http.Client.RequestOptions = .{
            .extra_headers = &.{
                .{ .name = "X-AutoCLI", .value = "1" },
                .{ .name = "Accept-Encoding", .value = "identity" },
            },
        };

        var req = @import("core").requestWithTimeout(&self.client, .GET, uri, options, DAEMON_TIMEOUT_MS) catch return false;
        defer req.deinit();

        req.sendBodiless() catch return false;

        var redirect_buffer: [4096]u8 = undefined;
        var response = req.receiveHead(&redirect_buffer) catch return false;

        const status = response.head.status;
        const ok = @intFromEnum(status) >= 200 and @intFromEnum(status) < 300;
        if (!ok) return false;
        log_state.recordStatus(@intFromEnum(status));

        var transfer_buffer: [64]u8 = undefined;
        const reader = response.reader(&transfer_buffer);
        const body_text = reader.allocRemaining(self.allocator, std.Io.Limit.limited(1024 * 1024)) catch return false;
        defer self.allocator.free(body_text);

        const parsed = json.parseFromSlice(json.Value, self.allocator, body_text, .{}) catch return false;
        defer parsed.deinit();

        const val = parsed.value;
        if (val != .object) return false;

        const ext = val.object.get("extension") orelse val.object.get("extensionConnected") orelse return false;
        return switch (ext) {
            .bool => |b| b,
            else => false,
        };
    }

    fn doGet(self: *DaemonClient, url: []const u8, timeout_ms: u32) bool {
        const http_util = @import("core").http_util;
        var zero_attempt: u32 = 0;
        var log_state = http_util.HttpLogState{
            .enabled = http_util.http_logging_enabled,
            .method = "GET",
            .url = url,
            .start_ts = std.Io.Timestamp.now(self.io, .real),
            .attempt = &zero_attempt,
        };
        defer log_state.log(self.io);

        const uri = std.Uri.parse(url) catch return false;
        const options: http.Client.RequestOptions = .{
            .extra_headers = &.{
                .{ .name = "Accept-Encoding", .value = "identity" },
            },
        };

        var req = @import("core").requestWithTimeout(&self.client, .GET, uri, options, @intCast(timeout_ms)) catch return false;
        defer req.deinit();

        req.sendBodiless() catch return false;

        var redirect_buffer: [4096]u8 = undefined;
        const response = req.receiveHead(&redirect_buffer) catch return false;

        const status = response.head.status;
        const ok = switch (@intFromEnum(status)) {
            200...299 => true,
            else => false,
        };
        if (ok) log_state.recordStatus(@intFromEnum(status));
        return ok;
    }

    /// Send a JSON command to the daemon endpoint and get the response
    pub fn sendJson(self: *DaemonClient, method: []const u8, body_json: []const u8) ![]const u8 {
        var buf: [256]u8 = undefined;
        const url = std.fmt.bufPrint(&buf, "http://127.0.0.1:{d}{s}", .{ self.port, method }) catch return error.InvalidUrl;
        const uri = std.Uri.parse(url) catch return error.UriParseFailed;

        const http_util = @import("core").http_util;
        var zero_attempt: u32 = 0;
        var log_state = http_util.HttpLogState{
            .enabled = http_util.http_logging_enabled,
            .method = "POST",
            .url = url,
            .start_ts = std.Io.Timestamp.now(self.io, .real),
            .attempt = &zero_attempt,
        };
        defer log_state.log(self.io);

        const options: http.Client.RequestOptions = .{
            .extra_headers = &.{
                .{ .name = "Content-Type", .value = "application/json" },
                .{ .name = "Accept-Encoding", .value = "identity" },
            },
        };

        var req = @import("core").requestWithTimeout(&self.client, .POST, uri, options, DAEMON_TIMEOUT_MS) catch |err| switch (err) {
            error.Timeout => return error.Timeout,
            else => return error.ConnectFailed,
        };
        defer req.deinit();

        // Send body (single shot — sendBodyComplete handles head + body + flush)
        req.transfer_encoding = .{ .content_length = body_json.len };
        req.sendBodyComplete(@constCast(body_json)) catch return error.SendFailed;

        // Check response status
        var redirect_buffer: [8192]u8 = undefined;
        var response = req.receiveHead(&redirect_buffer) catch return error.ReceiveFailed;

        const status = response.head.status;
        if (@intFromEnum(status) < 200 or @intFromEnum(status) >= 300) {
            return error.HttpStatus;
        }
        log_state.recordStatus(@intFromEnum(status));

        // Read response body
        var transfer_buffer: [64]u8 = undefined;
        const reader = response.reader(&transfer_buffer);
        const body_text = reader.allocRemaining(self.allocator, std.Io.Limit.limited(1024 * 1024)) catch return error.ReadFailed;

        return body_text;
    }

    /// Execute a page command (goto, click, type, etc.) via the daemon
    pub fn executePageCommand(self: *DaemonClient, tab_id: []const u8, cmd_name: []const u8, params_json: ?[]const u8) !json.Value {
        var cmd_buf = std.ArrayList(u8).empty;
        defer cmd_buf.deinit(self.allocator);

        // Write: {"tab_id":"...","action":"...","params":...}
        try cmd_buf.appendSlice(self.allocator, "{\"tab_id\":\"");
        try cmd_buf.appendSlice(self.allocator, tab_id);
        try cmd_buf.appendSlice(self.allocator, "\",\"action\":\"");
        try cmd_buf.appendSlice(self.allocator, cmd_name);

        if (params_json) |pj| {
            try cmd_buf.appendSlice(self.allocator, "\",\"params\":");
            try cmd_buf.appendSlice(self.allocator, pj);
            try cmd_buf.appendSlice(self.allocator, "}");
        } else {
            try cmd_buf.appendSlice(self.allocator, "\"}");
        }

        const response_body = try self.sendJson("/page/command", cmd_buf.items);
        defer self.allocator.free(response_body);

        return parseDaemonResponse(self.allocator, response_body);
    }

    fn parseDaemonResponse(allocator: std.mem.Allocator, body: []const u8) CliError!json.Value {
        return json.parseFromSliceLeaky(json.Value, allocator, body, .{}) catch return CliError.Pipeline;
    }
};
