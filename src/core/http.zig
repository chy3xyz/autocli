const std = @import("std");

/// Perform an HTTP request with options (accept_encoding, extra_headers, etc).
/// Delegates to client.request() which handles TLS CA bundle initialization.
/// The returned Request must have deinit() called on it.
pub fn requestWithTimeout(
    client: *std.http.Client,
    method: std.http.Method,
    uri: std.Uri,
    options: std.http.Client.RequestOptions,
    timeout_ms: u32,
) std.http.Client.RequestError!std.http.Client.Request {
    _ = timeout_ms;
    return client.request(method, uri, options) catch |err| return err;
}

// ---------------------------------------------------------------------------
// Retry / backoff
// ---------------------------------------------------------------------------

pub const RetryConfig = struct {
    max_retries: u32 = 3,
    base_delay_ms: u32 = 500,
    max_delay_ms: u32 = 30_000,
};

/// Check if an error is retryable for HTTP operations.
pub fn isRetryableHttpError(err: anyerror) bool {
    return switch (err) {
        error.ConnectionRefused,
        error.ConnectionResetByPeer,
        error.BrokenPipe,
        error.NetworkUnreachable,
        error.ConnectionTimedOut,
        error.Timeout,
        => true,
        else => false,
    };
}

/// Check if an HTTP status code is retryable (5xx or 429 Too Many Requests).
pub fn isRetryableStatus(status: u16) bool {
    return status == 429 or status >= 500;
}

/// Sleep with exponential backoff. Returns false if sleep was interrupted.
pub fn backoffSleep(io: std.Io, base_delay_ms: u32, attempt: u32, max_delay_ms: u32) void {
    const shift = @min(attempt, 15); // prevent overflow on shift
    const scaled: u64 = @as(u64, base_delay_ms) << shift;
    const capped = @min(scaled, max_delay_ms);
    std.Io.sleep(io, std.Io.Duration.fromMilliseconds(@intCast(capped)), .real) catch {};
}

/// Log a retry attempt at warn level.
pub fn logRetry(comptime operation: []const u8, attempt: u32, max_retries: u32, err: anyerror) void {
    if (attempt < max_retries) {
        std.log.warn("{s} failed (attempt {d}/{d}): {s}. Retrying...", .{
            operation,
            attempt + 1,
            max_retries + 1,
            @errorName(err),
        });
    } else {
        std.log.err("{s} failed after {d} attempts: {s}", .{
            operation,
            max_retries + 1,
            @errorName(err),
        });
    }
}

// ---------------------------------------------------------------------------
// HTTP request logging (verbose mode)
// ---------------------------------------------------------------------------

/// Global toggle for HTTP request logging. Set by main.zig when --verbose is active.
pub var http_logging_enabled: bool = false;

/// State for a single HTTP request log entry.
/// Use `defer state.log(io);` to ensure logging on exit.
pub const HttpLogState = struct {
    enabled: bool,
    method: []const u8,
    url: []const u8,
    start_ts: std.Io.Timestamp,
    attempt: *const u32,
    status: ?u16 = null,

    /// Record the HTTP status code on success.
    pub fn recordStatus(self: *HttpLogState, s: u16) void {
        self.status = s;
    }

    /// Strip query string from URL for safe logging.
    fn sanitizeUrlForLog(url: []const u8) []const u8 {
        if (std.mem.indexOfScalar(u8, url, '?')) |q| {
            return url[0..q];
        }
        return url;
    }

    /// Emit the log line. Called via defer.
    pub fn log(self: *HttpLogState, io: std.Io) void {
        if (!self.enabled) return;
        const end_ts = std.Io.Timestamp.now(io, .real);
        const duration_ms = @divFloor(end_ts.nanoseconds - self.start_ts.nanoseconds, std.time.ns_per_ms);
        const safe_url = sanitizeUrlForLog(self.url);
        if (self.status) |s| {
            if (self.attempt.* > 0) {
                std.log.info("[http] {s} {s} -> {d} ({d}ms, {d} retries)", .{
                    self.method, safe_url, s, duration_ms, self.attempt.*,
                });
            } else {
                std.log.info("[http] {s} {s} -> {d} ({d}ms)", .{
                    self.method, safe_url, s, duration_ms,
                });
            }
        } else {
            if (self.attempt.* > 0) {
                std.log.info("[http] {s} {s} -> FAILED ({d}ms, {d} retries)", .{
                    self.method, safe_url, duration_ms, self.attempt.*,
                });
            } else {
                std.log.info("[http] {s} {s} -> FAILED ({d}ms)", .{
                    self.method, safe_url, duration_ms,
                });
            }
        }
    }
};

/// Log an HTTP body snippet on failure (debug level, truncated to max_bytes).
pub fn logBody(comptime direction: []const u8, body: []const u8, max_bytes: usize) void {
    if (!http_logging_enabled) return;
    const limit = @min(body.len, max_bytes);
    if (limit == 0) return;
    const suffix = if (body.len > max_bytes) "... (truncated)" else "";
    // Sanitize: avoid multi-line logs by replacing newlines
    var buf: [1024]u8 = undefined;
    if (limit > buf.len - 32) return; // safety
    for (body[0..limit], 0..) |c, i| {
        buf[i] = switch (c) {
            '\n' => ' ',
            '\r' => ' ',
            else => c,
        };
    }
    std.log.debug("[http] {s} body: {s}{s}", .{ direction, buf[0..limit], suffix });
}
