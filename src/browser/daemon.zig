const std = @import("std");
const json = std.json;
const CliError = @import("core").CliError;

/// Default buffer sizes for network I/O.
const READ_BUF_SIZE = 8192;
const WRITE_BUF_SIZE = 8192;
const WS_MSG_BUF_SIZE = 65536;
const MAX_BODY_SIZE = 1024 * 1024;

/// A pending request waiting for the Chrome extension to respond.
const ResponseWaiter = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    mutex: std.Io.Mutex,
    condition: std.Io.Condition,
    response_json: ?[]const u8,
    done: bool,

    pub fn init(allocator: std.mem.Allocator, io: std.Io) ResponseWaiter {
        return .{
            .allocator = allocator,
            .io = io,
            .mutex = .init,
            .condition = .init,
            .response_json = null,
            .done = false,
        };
    }

    pub fn deinit(self: *ResponseWaiter) void {
        if (self.response_json) |r| self.allocator.free(r);
    }

    /// Block until a response arrives or timeout expires.
    /// Returns an owned copy or null on timeout.
    pub fn wait(self: *ResponseWaiter, timeout_ms: u64) ?[]const u8 {
        const start = std.Io.Timestamp.now(self.io, .real);
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        while (!self.done) {
            self.mutex.unlock(self.io);
            std.Io.sleep(self.io, std.Io.Duration.fromMilliseconds(10), .real) catch {};
            self.mutex.lockUncancelable(self.io);
            const elapsed = @divFloor(std.Io.Timestamp.now(self.io, .real).nanoseconds - start.nanoseconds, std.time.ns_per_ms);
            if (elapsed > timeout_ms) return null;
        }
        if (self.response_json) |r| {
            return self.allocator.dupe(u8, r) catch null;
        }
        return null;
    }

    /// Deliver a response to the waiter. `json_str` is copied.
    pub fn signal(self: *ResponseWaiter, json_str: []const u8) void {
        self.mutex.lockUncancelable(self.io);
        if (self.response_json) |old| self.allocator.free(old);
        self.response_json = self.allocator.dupe(u8, json_str) catch null;
        self.done = true;
        self.mutex.unlock(self.io);
        self.condition.signal(self.io);
    }
};

/// Thread-safe shared state between HTTP handlers and the WebSocket reader.
const SharedState = struct {
    io: std.Io,
    allocator: std.mem.Allocator,
    mutex: std.Io.Mutex,
    ws: ?*std.http.Server.WebSocket,
    ws_connected: bool,
    next_id: u64,
    pending: std.StringHashMap(*ResponseWaiter),
    // Metrics
    start_time: std.Io.Timestamp,
    request_count: u64,
    command_count: u64,
    connection_count: usize,
    max_connections: usize,

    pub fn init(allocator: std.mem.Allocator, io: std.Io) SharedState {
        return .{
            .io = io,
            .allocator = allocator,
            .mutex = .init,
            .ws = null,
            .ws_connected = false,
            .next_id = 1,
            .pending = std.StringHashMap(*ResponseWaiter).init(allocator),
            .start_time = std.Io.Timestamp.now(io, .real),
            .request_count = 0,
            .command_count = 0,
            .connection_count = 0,
            .max_connections = 100,
        };
    }

    pub fn deinit(self: *SharedState) void {
        var it = self.pending.iterator();
        while (it.next()) |entry| {
            entry.value_ptr.*.deinit();
            self.allocator.destroy(entry.value_ptr.*);
        }
        self.pending.deinit();
    }
};

/// HTTP daemon that bridges CLI commands to a Chrome extension via WebSocket.
pub const Daemon = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    port: u16,
    state: *SharedState,

    pub fn init(allocator: std.mem.Allocator, io: std.Io, port: u16) !Daemon {
        const state = try allocator.create(SharedState);
        state.* = SharedState.init(allocator, io);
        return .{
            .allocator = allocator,
            .io = io,
            .port = port,
            .state = state,
        };
    }

    pub fn deinit(self: *Daemon) void {
        self.state.deinit();
        self.allocator.destroy(self.state);
    }

    /// Start the TCP server and accept connections forever.
    pub fn run(self: *Daemon) !void {
        const addr = std.Io.net.IpAddress{ .ip4 = std.Io.net.Ip4Address.loopback(self.port) };
        var server = try addr.listen(self.io, .{ .reuse_address = true });
        defer server.deinit(self.io);

        // Log startup
        const stdout = std.Io.File.stdout();
        var msg_buf: [128]u8 = undefined;
        const msg = std.fmt.bufPrint(&msg_buf, "[daemon] Listening on http://127.0.0.1:{d}\n", .{self.port}) catch "[daemon] Listening\n";
        stdout.writeStreamingAll(self.io, msg) catch {};

        while (true) {
            const stream = server.accept(self.io) catch |err| {
                const stderr = std.Io.File.stderr();
                var ebuf: [128]u8 = undefined;
                const estr = std.fmt.bufPrint(&ebuf, "[daemon] accept error: {s}\n", .{@errorName(err)}) catch "[daemon] accept error\n";
                stderr.writeStreamingAll(self.io, estr) catch {};
                std.Io.sleep(self.io, std.Io.Duration.fromMilliseconds(100), .real) catch {};
                continue;
            };

            self.state.mutex.lockUncancelable(self.io);
            const at_limit = self.state.connection_count >= self.state.max_connections;
            self.state.mutex.unlock(self.io);
            if (at_limit) {
                stream.close(self.io);
                std.log.warn("[daemon] connection limit reached, dropping connection", .{});
                continue;
            }

            const thread = std.Thread.spawn(.{}, handleConnection, .{ self, stream }) catch |err| {
                const stderr = std.Io.File.stderr();
                var ebuf: [128]u8 = undefined;
                const estr = std.fmt.bufPrint(&ebuf, "[daemon] spawn error: {s}\n", .{@errorName(err)}) catch "[daemon] spawn error\n";
                stderr.writeStreamingAll(self.io, estr) catch {};
                stream.close(self.io);
                continue;
            };
            thread.detach();
        }
    }

    // ------------------------------------------------------------------
    // Per-connection handler
    // ------------------------------------------------------------------

    fn handleConnection(self: *Daemon, stream: std.Io.net.Stream) void {
        defer {
            stream.close(self.io);
            self.state.mutex.lockUncancelable(self.io);
            self.state.connection_count -= 1;
            self.state.mutex.unlock(self.io);
        }
        self.state.mutex.lockUncancelable(self.io);
        self.state.connection_count += 1;
        self.state.mutex.unlock(self.io);

        var read_buf: [READ_BUF_SIZE]u8 = undefined;
        var write_buf: [WRITE_BUF_SIZE]u8 = undefined;
        var stream_reader = stream.reader(self.io, &read_buf);
        var stream_writer = stream.writer(self.io, &write_buf);

        var http_server = std.http.Server.init(&stream_reader.interface, &stream_writer.interface);

        while (true) {
            var request = http_server.receiveHead() catch break;

            // Route WebSocket upgrade requests to /ext
            const upgrade = request.upgradeRequested();
            if (upgrade != .none and std.mem.startsWith(u8, request.head.target, "/ext")) {
                handleWebSocket(self, &request) catch |err| {
                    std.log.err("WebSocket handler failed: {s}", .{@errorName(err)});
                };
                return;
            }

            handleHttp(self, &request) catch break;
        }
    }

    // ------------------------------------------------------------------
    // WebSocket handler (Chrome extension connection)
    // ------------------------------------------------------------------

    fn handleWebSocket(
        self: *Daemon,
        request: *std.http.Server.Request,
    ) !void {
        const upgrade = request.upgradeRequested();
        const ws_key = switch (upgrade) {
            .websocket => |key| key orelse return error.NotWebSocket,
            else => return error.NotWebSocket,
        };

        var ws = try request.respondWebSocket(.{ .key = ws_key });
        try ws.flush(); // Send 101 Switching Protocols

        // Register this WebSocket in shared state
        self.state.mutex.lockUncancelable(self.io);
        self.state.ws = &ws;
        self.state.ws_connected = true;
        self.state.mutex.unlock(self.io);

        const stdout = std.Io.File.stdout();
        stdout.writeStreamingAll(self.io, "[daemon] Extension connected via WebSocket\n") catch {};

        defer {
            self.state.mutex.lockUncancelable(self.io);
            self.state.ws = null;
            self.state.ws_connected = false;
            self.state.mutex.unlock(self.io);
            stdout.writeStreamingAll(self.io, "[daemon] Extension disconnected\n") catch {};
        }

        // Read loop: process messages from the extension
        while (true) {
            const msg = ws.readSmallMessage() catch |err| switch (err) {
                error.ConnectionClose => break,
                error.EndOfStream => break,
                else => continue,
            };

            if (msg.opcode == .connection_close) break;
            if (msg.opcode != .text and msg.opcode != .binary) continue;

            // Try to parse as JSON and match request ID
            const parsed = std.json.parseFromSlice(json.Value, self.allocator, msg.data, .{}) catch continue;
            defer parsed.deinit();

            const id_val = switch (parsed.value) {
                .object => |obj| obj.get("id"),
                else => null,
            };
            const id = switch (id_val orelse continue) {
                .string => |s| s,
                else => continue,
            };

            self.state.mutex.lockUncancelable(self.io);
            const waiter_ptr = self.state.pending.get(id);
            self.state.mutex.unlock(self.io);

            if (waiter_ptr) |waiter| {
                waiter.signal(msg.data);
            }
        }
    }

    // ------------------------------------------------------------------
    // HTTP handler (CLI commands)
    // ------------------------------------------------------------------

    fn handleHttp(self: *Daemon, request: *std.http.Server.Request) !void {
        // Handle CORS preflight
        if (request.head.method == .OPTIONS) {
            return try respondCorsPreflight(request);
        }

        const target = request.head.target;

        // Increment request counter for all non-health requests
        if (!std.mem.eql(u8, target, "/health") and !std.mem.eql(u8, target, "/ping")) {
            self.state.mutex.lockUncancelable(self.io);
            self.state.request_count += 1;
            self.state.mutex.unlock(self.io);
        }

        if (std.mem.eql(u8, target, "/health") or std.mem.eql(u8, target, "/ping")) {
            return try self.respondHealth(request);
        }

        if (std.mem.eql(u8, target, "/status")) {
            self.state.mutex.lockUncancelable(self.io);
            const connected = self.state.ws_connected;
            self.state.mutex.unlock(self.io);
            var buf: [64]u8 = undefined;
            const body = std.fmt.bufPrint(&buf, "{{\"extension_connected\":{s}}}", .{if (connected) "true" else "false"}) catch "{}";
            return try respondJson(self.io, request, body);
        }

        if (std.mem.eql(u8, target, "/command")) {
            self.state.mutex.lockUncancelable(self.io);
            self.state.command_count += 1;
            self.state.mutex.unlock(self.io);
            return try handleCommand(self, request);
        }

        // 404
        return try request.respond("Not Found\n", .{ .status = .not_found });
    }

    fn respondHealth(self: *Daemon, request: *std.http.Server.Request) !void {
        self.state.mutex.lockUncancelable(self.io);
        const connected = self.state.ws_connected;
        const req_count = self.state.request_count;
        const cmd_count = self.state.command_count;
        const pending = self.state.pending.count();
        const start = self.state.start_time;
        self.state.mutex.unlock(self.io);

        const now = std.Io.Timestamp.now(self.io, .real);
        const uptime_ms = @divFloor(now.nanoseconds - start.nanoseconds, std.time.ns_per_ms);

        var buf: [512]u8 = undefined;
        const body = std.fmt.bufPrint(&buf,
            "{{\"ok\":true,\"uptime_ms\":{d},\"extension_connected\":{s},\"request_count\":{d},\"command_count\":{d},\"pending_requests\":{d}}}",
            .{
                uptime_ms,
                if (connected) "true" else "false",
                req_count,
                cmd_count,
                pending,
            },
        ) catch "{\"ok\":true}";
        return try respondJson(self.io, request, body);
    }

    fn handleCommand(self: *Daemon, request: *std.http.Server.Request) !void {
        // Security: require X-AutoCLI: 1 or X-OpenCLI: 1 header
        var has_auth = false;
        var it = request.iterateHeaders();
        while (it.next()) |header| {
            if ((std.ascii.eqlIgnoreCase(header.name, "x-autocli") or
                std.ascii.eqlIgnoreCase(header.name, "x-opencli")) and
                std.mem.eql(u8, header.value, "1"))
            {
                has_auth = true;
                break;
            }
        }
        if (!has_auth) {
            return try request.respond("Unauthorized\n", .{ .status = .unauthorized });
        }

        // Read body
        var body_buf: [4096]u8 = undefined;
        const body_reader = request.readerExpectNone(&body_buf);
        const body = body_reader.allocRemaining(self.allocator, std.Io.Limit.limited(MAX_BODY_SIZE)) catch {
            return try request.respond("Bad Request\n", .{ .status = .bad_request });
        };
        defer self.allocator.free(body);

        // Parse JSON command
        const parsed = std.json.parseFromSlice(json.Value, self.allocator, body, .{}) catch {
            return try request.respond("Invalid JSON\n", .{ .status = .bad_request });
        };
        defer parsed.deinit();

        // Generate or extract request ID
        const id = blk: {
            if (parsed.value == .object) {
                if (parsed.value.object.get("id")) |id_val| {
                    switch (id_val) {
                        .string => |s| break :blk try self.allocator.dupe(u8, s),
                        else => {},
                    }
                }
            }
            self.state.mutex.lockUncancelable(self.io);
            const next = self.state.next_id;
            self.state.next_id += 1;
            self.state.mutex.unlock(self.io);
            var id_buf: [32]u8 = undefined;
            break :blk try self.allocator.dupe(u8, std.fmt.bufPrint(&id_buf, "cmd_{d}", .{next}) catch "cmd_0");
        };
        defer self.allocator.free(id);

        // Re-serialize command with ID injected
        var cmd_obj = switch (parsed.value) {
            .object => |obj| obj,
            else => return try request.respond("Expected JSON object\n", .{ .status = .bad_request }),
        };
        try cmd_obj.put(self.allocator, "id", json.Value{ .string = id });

        const cmd_str = std.json.Stringify.valueAlloc(self.allocator, json.Value{ .object = cmd_obj }, .{}) catch {
            return try request.respond("Internal error\n", .{ .status = .internal_server_error });
        };
        defer self.allocator.free(cmd_str);

        // Create waiter and register it
        const waiter = try self.allocator.create(ResponseWaiter);
        waiter.* = ResponseWaiter.init(self.allocator, self.io);
        errdefer {
            waiter.deinit();
            self.allocator.destroy(waiter);
        }

        self.state.mutex.lockUncancelable(self.io);
        try self.state.pending.put(id, waiter);
        self.state.mutex.unlock(self.io);
        defer {
            self.state.mutex.lockUncancelable(self.io);
            _ = self.state.pending.remove(id);
            self.state.mutex.unlock(self.io);
            waiter.deinit();
            self.allocator.destroy(waiter);
        }

        // Forward command to extension via WebSocket
        self.state.mutex.lockUncancelable(self.io);
        const ws_opt = self.state.ws;
        const ws_connected = self.state.ws_connected;
        self.state.mutex.unlock(self.io);

        if (!ws_connected or ws_opt == null) {
            return try respondJson(self.io, request, "{\"ok\":false,\"error\":\"Extension not connected\"}");
        }

        const ws = ws_opt.?;
        ws.writeMessage(cmd_str, .text) catch |err| {
            var ebuf: [256]u8 = undefined;
            const estr = std.fmt.bufPrint(&ebuf, "{{\"ok\":false,\"error\":\"WebSocket write failed: {s}\"}}", .{@errorName(err)}) catch "{}";
            return try respondJson(self.io, request, estr);
        };

        // Wait for response (60s timeout)
        const response_json = waiter.wait(60_000);
        if (response_json) |r| {
            defer self.allocator.free(r);
            return try respondJson(self.io, request, r);
        } else {
            return try respondJson(self.io, request, "{\"ok\":false,\"error\":\"Timeout waiting for extension response\"}");
        }
    }
};

// ------------------------------------------------------------------
// Helpers
// ------------------------------------------------------------------

const json_content_type = std.http.Header{ .name = "content-type", .value = "application/json" };
const cors_origin = std.http.Header{ .name = "Access-Control-Allow-Origin", .value = "http://127.0.0.1" };
const cors_methods = std.http.Header{ .name = "Access-Control-Allow-Methods", .value = "GET, POST, OPTIONS" };
const cors_headers = std.http.Header{ .name = "Access-Control-Allow-Headers", .value = "*" };
const cors_max_age = std.http.Header{ .name = "Access-Control-Max-Age", .value = "86400" };

const json_headers = &[_]std.http.Header{ json_content_type, cors_origin, cors_methods, cors_headers };
const cors_preflight_headers = &[_]std.http.Header{ cors_origin, cors_methods, cors_headers, cors_max_age };

fn respondJson(io: std.Io, request: *std.http.Server.Request, body: []const u8) !void {
    _ = io;
    return try request.respond(body, .{ .extra_headers = json_headers });
}

fn respondCorsPreflight(request: *std.http.Server.Request) !void {
    return try request.respond("", .{
        .status = .no_content,
        .extra_headers = cors_preflight_headers,
    });
}
