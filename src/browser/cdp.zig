const std = @import("std");
const json = std.json;
const CliError = @import("core").CliError;
const IPage = @import("core").IPage;
const Cookie = @import("core").Cookie;
const CookieOptions = @import("core").CookieOptions;
const GotoOptions = @import("core").GotoOptions;
const WaitOptions = @import("core").WaitOptions;
const SnapshotOptions = @import("core").SnapshotOptions;
const ScreenshotOptions = @import("core").ScreenshotOptions;
const AutoScrollOptions = @import("core").AutoScrollOptions;
const TabInfo = @import("core").TabInfo;
const InterceptedRequest = @import("core").InterceptedRequest;
const NetworkRequest = @import("core").NetworkRequest;
const dom = @import("dom.zig");

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

/// Minimal WebSocket client for CDP communication.
const WsClient = struct {
    stream: std.Io.net.Stream,
    io: std.Io,
    read_buf: [4096]u8,
    write_buf: [4096]u8,

    pub fn connect(
        _: std.mem.Allocator,
        io: std.Io,
        host: []const u8,
        port: u16,
        path: []const u8,
    ) !WsClient {
        const addr = try std.Io.net.IpAddress.resolve(io, host, port);
        const stream = try addr.connect(io, .{ .mode = .stream, .protocol = .tcp });
        errdefer stream.close(io);

        var read_buf: [4096]u8 = undefined;
        var write_buf: [4096]u8 = undefined;
        var sreader = stream.reader(io, &read_buf);
        var swriter = stream.writer(io, &write_buf);

        // Generate Sec-WebSocket-Key
        var nonce: [16]u8 = undefined;
        var prng = std.Random.DefaultPrng.init(@intCast(std.Io.Timestamp.now(io, .real).nanoseconds));
        prng.random().bytes(&nonce);
        var key_buf: [24]u8 = undefined;
        const key = std.base64.standard.Encoder.encode(&key_buf, &nonce);

        // Send HTTP upgrade request
        try swriter.interface.print("GET {s} HTTP/1.1\r\n", .{path});
        try swriter.interface.print("Host: {s}:{d}\r\n", .{ host, port });
        try swriter.interface.print("Upgrade: websocket\r\n", .{});
        try swriter.interface.print("Connection: Upgrade\r\n", .{});
        try swriter.interface.print("Sec-WebSocket-Key: {s}\r\n", .{key});
        try swriter.interface.print("Sec-WebSocket-Version: 13\r\n", .{});
        try swriter.interface.print("\r\n", .{});
        try swriter.interface.flush();

        // Read HTTP response (up to 1KB or until \r\n\r\n)
        var resp_buf: [1024]u8 = undefined;
        var total: usize = 0;
        while (total < resp_buf.len) {
            var slices = [1][]u8{resp_buf[total..]};
            const n = try sreader.interface.readVec(&slices);
            if (n == 0) break;
            total += n;
            if (total >= 4 and std.mem.eql(u8, resp_buf[total - 4..total], "\r\n\r\n")) break;
        }
        const resp = resp_buf[0..total];

        if (!std.mem.startsWith(u8, resp, "HTTP/1.1 101")) {
            return error.WsUpgradeFailed;
        }

        // Verify Sec-WebSocket-Accept (optional)
        return .{
            .stream = stream,
            .io = io,
            .read_buf = read_buf,
            .write_buf = write_buf,
        };
    }

    pub fn deinit(self: *WsClient) void {
        self.stream.close(self.io);
    }

    fn sendRawFrame(self: *WsClient, opcode: u4, payload: []const u8) !void {
        var swriter = self.stream.writer(self.io, &self.write_buf);
        const out = &swriter.interface;

        const h0: u8 = 0x80 | (@as(u8, opcode) & 0x0F);
        try out.writeByte(h0);

        const len = payload.len;
        if (len <= 125) {
            try out.writeByte(@intCast(0x80 | len));
        } else if (len <= 0xFFFF) {
            try out.writeByte(0xFE);
            try out.writeInt(u16, @intCast(len), .big);
        } else {
            try out.writeByte(0xFF);
            try out.writeInt(u64, len, .big);
        }

        var mask: [4]u8 = undefined;
        var prng2 = std.Random.DefaultPrng.init(@intCast(std.Io.Timestamp.now(self.io, .real).nanoseconds));
        prng2.random().bytes(&mask);
        try out.writeAll(&mask);

        for (payload, 0..) |byte, i| {
            try out.writeByte(byte ^ mask[i % 4]);
        }

        try out.flush();
    }

    pub fn sendText(self: *WsClient, text: []const u8) !void {
        try self.sendRawFrame(1, text);
    }

    pub fn sendPong(self: *WsClient, ping_payload: []const u8) !void {
        try self.sendRawFrame(10, ping_payload);
    }

    pub fn sendClose(self: *WsClient, code: u16) !void {
        var payload: [2]u8 = undefined;
        payload[0] = @intCast(code >> 8);
        payload[1] = @intCast(code & 0xFF);
        try self.sendRawFrame(8, &payload);
    }

    /// Read a text message into `buf`. Returns slice of buf or null on close.
    pub fn readText(self: *WsClient, buf: []u8) !?[]u8 {
        var sreader = self.stream.reader(self.io, &self.read_buf);
        const inp = &sreader.interface;

        while (true) {
            const h0 = try inp.takeByte();
            const h1 = try inp.takeByte();
            const opcode: u4 = @intCast(h0 & 0x0F);
            const fin = (h0 & 0x80) != 0;
            const masked = (h1 & 0x80) != 0;
            var payload_len: usize = @intCast(h1 & 0x7F);

            if (payload_len == 126) {
                payload_len = try inp.takeInt(u16, .big);
            } else if (payload_len == 127) {
                payload_len = std.math.cast(usize, try inp.takeInt(u64, .big)) orelse return error.MessageTooLarge;
            }

            // We don't support fragmented frames, but we must still consume them
            if (!fin) {
                // Skip payload and return error
                const skip_buf: [4096]u8 = undefined;
                var remaining = payload_len;
                if (masked) _ = try inp.takeArray(4);
                while (remaining > 0) {
                    const chunk = @min(remaining, skip_buf.len);
                    _ = try inp.take(chunk);
                    remaining -= chunk;
                }
                return error.FragmentedNotSupported;
            }

            var mask: [4]u8 = undefined;
            if (masked) {
                const mask_bytes = try inp.takeArray(4);
                mask = @bitCast(mask_bytes.*);
            }

            if (payload_len > buf.len) {
                // Skip payload and return error
                const skip_buf: [4096]u8 = undefined;
                var remaining = payload_len;
                while (remaining > 0) {
                    const chunk = @min(remaining, skip_buf.len);
                    _ = try inp.take(chunk);
                    remaining -= chunk;
                }
                return error.MessageTooLarge;
            }
            const payload = buf[0..payload_len];
            @memcpy(payload, try inp.take(payload.len));

            if (masked) {
                for (payload, 0..) |*b, i| {
                    b.* ^= mask[i % 4];
                }
            }

            switch (opcode) {
                1 => return payload, // text
                2 => return payload, // binary
                8 => {
                    // Send close response before returning
                    self.sendClose(1000) catch |err| {
                        std.log.warn("WebSocket sendClose failed: {s}", .{@errorName(err)});
                    };
                    return null;
                },
                9 => {
                    // Ping: echo payload back as Pong
                    self.sendPong(payload) catch |err| {
                        std.log.warn("WebSocket sendPong failed: {s}", .{@errorName(err)});
                    };
                    continue;
                },
                10 => continue, // pong
                else => return error.UnknownOpcode,
            }
        }
    }
};

// ------------------------------------------------------------------
// CDP Client
// ------------------------------------------------------------------

pub const CdpClient = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    ws: WsClient,
    mutex: std.Io.Mutex,
    next_id: u32,
    pending: std.AutoHashMap(u32, *ResponseWaiter),

    const ResponseWaiter = struct {
        response: ?[]const u8, // owned JSON string
        done: bool,
        condition: std.Io.Condition,
        mutex: std.Io.Mutex,
    };

    pub fn init(allocator: std.mem.Allocator, io: std.Io, host: []const u8, port: u16, path: []const u8) !CdpClient {
        const ws = try WsClient.connect(allocator, io, host, port, path);
        const client = CdpClient{
            .allocator = allocator,
            .io = io,
            .ws = ws,
            .mutex = .init,
            .next_id = 1,
            .pending = std.AutoHashMap(u32, *ResponseWaiter).init(allocator),
        };
        return client;
    }

    pub fn deinit(self: *CdpClient) void {
        var it = self.pending.iterator();
        while (it.next()) |entry| {
            const waiter = entry.value_ptr.*;
            if (waiter.response) |r| self.allocator.free(r);
            self.allocator.destroy(waiter);
        }
        self.pending.deinit();
        self.ws.deinit();
    }

    pub fn send(self: *CdpClient, method: []const u8, params: ?json.Value) !json.Value {
        self.mutex.lockUncancelable(self.io);
        var locked = true;
        defer if (locked) self.mutex.unlock(self.io);

        const id = self.next_id;
        self.next_id += 1;

        var cmd = json.ObjectMap.empty;
        defer cmd.deinit(self.allocator);
        try cmd.put(self.allocator, "id", json.Value{ .integer = id });
        try cmd.put(self.allocator, "method", json.Value{ .string = method });
        if (params) |p| try cmd.put(self.allocator, "params", p);

        const cmd_str = try std.json.Stringify.valueAlloc(self.allocator, json.Value{ .object = cmd }, .{});
        defer self.allocator.free(cmd_str);

        const waiter = try self.allocator.create(ResponseWaiter);
        errdefer self.allocator.destroy(waiter);
        waiter.* = .{
            .response = null,
            .done = false,
            .condition = .init,
            .mutex = .init,
        };
        errdefer _ = self.pending.remove(id);
        try self.pending.put(id, waiter);

        try self.ws.sendText(cmd_str);

        var recv_buf: [262144]u8 = undefined;
        const start = std.Io.Timestamp.now(self.io, .real);
        const timeout_ns = std.time.ns_per_s * 30;

        while (true) {
            const maybe_msg = self.ws.readText(&recv_buf) catch |err| {
                _ = self.pending.remove(id);
                self.allocator.destroy(waiter);
                return err;
            };
            if (maybe_msg) |msg| {
                const parsed = json.parseFromSlice(json.Value, self.allocator, msg, .{}) catch continue;
                defer parsed.deinit();

                if (parsed.value == .object) {
                    if (parsed.value.object.get("id")) |id_val| {
                        const msg_id: u32 = switch (id_val) {
                            .integer => |i| @intCast(i),
                            else => continue,
                        };

                        if (self.pending.get(msg_id)) |waiter_ptr| {
                            waiter_ptr.response = self.allocator.dupe(u8, msg) catch |err| {
                                _ = self.pending.remove(msg_id);
                                if (waiter_ptr.response) |r| self.allocator.free(r);
                                self.allocator.destroy(waiter_ptr);
                                return err;
                            };
                            waiter_ptr.done = true;
                        }
                    }
                }
            } else {
                _ = self.pending.remove(id);
                self.allocator.destroy(waiter);
                return error.ConnectionClosed;
            }

            if (waiter.done) break;

            const now = std.Io.Timestamp.now(self.io, .real);
            if (now.nanoseconds - start.nanoseconds > timeout_ns) {
                _ = self.pending.remove(id);
                if (waiter.response) |r| self.allocator.free(r);
                self.allocator.destroy(waiter);
                return error.Timeout;
            }

            std.Io.sleep(self.io, std.Io.Duration.fromMilliseconds(10), .real) catch |err| {
                std.log.warn("CDP wait sleep failed: {s}", .{@errorName(err)});
            };
        }

        _ = self.pending.remove(id);
        locked = false;
        self.mutex.unlock(self.io);

        if (waiter.response) |r| {
            const parsed = json.parseFromSliceLeaky(json.Value, self.allocator, r, .{}) catch |err| {
                self.allocator.free(r);
                self.allocator.destroy(waiter);
                return err;
            };
            self.allocator.free(r);
            self.allocator.destroy(waiter);
            return parsed;
        }
        self.allocator.destroy(waiter);
        return CliError.BrowserConnect;
    }
};

// ------------------------------------------------------------------
// CDP Page Discovery
// ------------------------------------------------------------------

const CDP_DISCOVER_TIMEOUT_MS: u32 = 5_000;

/// Discover Chrome CDP WebSocket URL from localhost:9222
pub fn discoverCdpWsUrl(allocator: std.mem.Allocator, io: std.Io) ![]const u8 {
    const http_util = @import("core").http_util;
    var zero_attempt: u32 = 0;
    var log_state = http_util.HttpLogState{
        .enabled = http_util.http_logging_enabled,
        .method = "GET",
        .url = "http://localhost:9222/json/list",
        .start_ts = std.Io.Timestamp.now(io, .real),
        .attempt = &zero_attempt,
    };
    defer log_state.log(io);

    const uri = std.Uri.parse("http://localhost:9222/json/list") catch return error.UriParseFailed;

    var client = std.http.Client{ .allocator = allocator, .io = io };
    defer client.deinit();

    var req = @import("core").requestWithTimeout(&client, .GET, uri, .{}, CDP_DISCOVER_TIMEOUT_MS) catch |err| switch (err) {
        error.Timeout => return error.Timeout,
        else => return error.CdpNotAvailable,
    };
    defer req.deinit();
    try req.sendBodiless();

    var redirect_buf: [4096]u8 = undefined;
    var response = try req.receiveHead(&redirect_buf);

    const status = @intFromEnum(response.head.status);
    if (status != 200) {
        return error.CdpNotAvailable;
    }
    log_state.recordStatus(status);

    var transfer_buf: [64]u8 = undefined;
    const reader = response.reader(&transfer_buf);
    const body = reader.allocRemaining(allocator, std.Io.Limit.limited(128 * 1024)) catch return error.ReadFailed;
    defer allocator.free(body);

    const parsed = json.parseFromSlice(json.Value, allocator, body, .{}) catch return error.JsonParseFailed;
    defer parsed.deinit();

    if (parsed.value != .array) return error.InvalidCdpResponse;
    const arr = parsed.value.array;

    for (arr.items) |item| {
        if (item != .object) continue;
        const obj = item.object;
        if (obj.get("webSocketDebuggerUrl")) |url_val| {
            if (url_val == .string) {
                return try allocator.dupe(u8, url_val.string);
            }
        }
    }

    return error.NoCdpPage;
}

// ------------------------------------------------------------------
// CdpPage IPage Implementation
// ------------------------------------------------------------------

pub const CdpPage = struct {
    allocator: std.mem.Allocator,
    client: *CdpClient,
    owns_client: bool,

    pub fn makeIPage(allocator: std.mem.Allocator, client: *CdpClient, owns_client: bool) !IPage {
        const state = try allocator.create(CdpPage);
        state.* = .{
            .allocator = allocator,
            .client = client,
            .owns_client = owns_client,
        };
        return .{
            .ptr = state,
            .vtable = &.{
                .goto = goto_,
                .url = url_,
                .title = title_,
                .content = content_,
                .evaluate = evaluate_,
                .click = click_,
                .type_text = typeText_,
                .wait_for_selector = waitForSelector_,
                .wait_for_navigation = waitForNavigation_,
                .wait_for_timeout = waitForTimeout_,
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

    pub fn goto_(ptr: *anyopaque, url: []const u8, _: ?GotoOptions) CliError!void {
        const state: *CdpPage = @ptrCast(@alignCast(ptr));
        var params = json.ObjectMap.empty;
        defer params.deinit(state.allocator);
        params.put(state.allocator, "url", json.Value{ .string = url }) catch return CliError.OutOfMemory;
        const result = state.client.send("Page.navigate", json.Value{ .object = params }) catch return CliError.BrowserConnect;
        defer freeJsonValue(state.allocator, result);

        // Inject stealth script after navigation
        const stealth = @import("stealth.zig").STEALTH_JS;
        var stealth_params = json.ObjectMap.empty;
        defer stealth_params.deinit(state.allocator);
        stealth_params.put(state.allocator, "expression", json.Value{ .string = stealth }) catch return CliError.OutOfMemory;
        stealth_params.put(state.allocator, "runImmediately", json.Value{ .bool = true }) catch return CliError.OutOfMemory;
        const eval_result = state.client.send("Runtime.evaluate", json.Value{ .object = stealth_params }) catch return;
        defer freeJsonValue(state.allocator, eval_result);
    }

    pub fn url_(ptr: *anyopaque) CliError![]const u8 {
        const state: *CdpPage = @ptrCast(@alignCast(ptr));
        var p = json.ObjectMap.empty;
        defer p.deinit(state.allocator);
        p.put(state.allocator, "expression", json.Value{ .string = "window.location.href" }) catch return CliError.OutOfMemory;
        const result = state.client.send("Runtime.evaluate", json.Value{ .object = p }) catch return CliError.BrowserConnect;
        defer freeJsonValue(state.allocator, result);
        if (result.object.get("result")) |r| {
            if (r.object.get("value")) |v| {
                if (v == .string) return state.allocator.dupe(u8, v.string) catch return CliError.OutOfMemory;
            }
        }
        return state.allocator.dupe(u8, "") catch return CliError.OutOfMemory;
    }

    pub fn title_(ptr: *anyopaque) CliError![]const u8 {
        const state: *CdpPage = @ptrCast(@alignCast(ptr));
        var p = json.ObjectMap.empty;
        defer p.deinit(state.allocator);
        p.put(state.allocator, "expression", json.Value{ .string = "document.title" }) catch return CliError.OutOfMemory;
        const result = state.client.send("Runtime.evaluate", json.Value{ .object = p }) catch return CliError.BrowserConnect;
        defer freeJsonValue(state.allocator, result);
        if (result.object.get("result")) |r| {
            if (r.object.get("value")) |v| {
                if (v == .string) return state.allocator.dupe(u8, v.string) catch return CliError.OutOfMemory;
            }
        }
        return state.allocator.dupe(u8, "") catch return CliError.OutOfMemory;
    }

    pub fn content_(ptr: *anyopaque) CliError![]const u8 {
        const state: *CdpPage = @ptrCast(@alignCast(ptr));
        var p = json.ObjectMap.empty;
        defer p.deinit(state.allocator);
        p.put(state.allocator, "expression", json.Value{ .string = "document.documentElement.outerHTML" }) catch return CliError.OutOfMemory;
        const result = state.client.send("Runtime.evaluate", json.Value{ .object = p }) catch return CliError.BrowserConnect;
        defer freeJsonValue(state.allocator, result);
        if (result.object.get("result")) |r| {
            if (r.object.get("value")) |v| {
                if (v == .string) return state.allocator.dupe(u8, v.string) catch return CliError.OutOfMemory;
            }
        }
        return state.allocator.dupe(u8, "") catch return CliError.OutOfMemory;
    }

    pub fn evaluate_(ptr: *anyopaque, expression: []const u8) CliError!json.Value {
        const state: *CdpPage = @ptrCast(@alignCast(ptr));
        var params = json.ObjectMap.empty;
        defer params.deinit(state.allocator);
        params.put(state.allocator, "expression", json.Value{ .string = expression }) catch return CliError.OutOfMemory;
        params.put(state.allocator, "returnByValue", json.Value{ .bool = true }) catch return CliError.OutOfMemory;
        return state.client.send("Runtime.evaluate", json.Value{ .object = params }) catch CliError.BrowserConnect;
    }

    pub fn click_(ptr: *anyopaque, selector: []const u8) CliError!void {
        const state: *CdpPage = @ptrCast(@alignCast(ptr));
        const js = dom.clickJs(state.allocator, selector) catch return CliError.BrowserConnect;
        defer state.allocator.free(js);
        const result = evaluate_(ptr, js) catch return CliError.BrowserConnect;
        defer freeJsonValue(state.allocator, result);
    }

    pub fn typeText_(ptr: *anyopaque, selector: []const u8, text: []const u8) CliError!void {
        const state: *CdpPage = @ptrCast(@alignCast(ptr));
        const js = dom.typeTextJs(state.allocator, selector, text) catch return CliError.BrowserConnect;
        defer state.allocator.free(js);
        const result = evaluate_(ptr, js) catch return CliError.BrowserConnect;
        defer freeJsonValue(state.allocator, result);
    }

    pub fn waitForSelector_(ptr: *anyopaque, selector: []const u8, opts: ?WaitOptions) CliError!void {
        const state: *CdpPage = @ptrCast(@alignCast(ptr));
        const timeout_ms = if (opts) |o| o.timeout_ms orelse 30000 else 30000;
        const visible = if (opts) |o| o.visible orelse false else false;
        const js = dom.waitForSelectorJs(state.allocator, selector, timeout_ms, visible) catch return CliError.BrowserConnect;
        defer state.allocator.free(js);
        const result = evaluate_(ptr, js) catch return CliError.BrowserConnect;
        defer freeJsonValue(state.allocator, result);
    }

    pub fn waitForNavigation_(ptr: *anyopaque, _: ?WaitOptions) CliError!void {
        const state: *CdpPage = @ptrCast(@alignCast(ptr));
        const js = dom.waitForDomStableJs(state.allocator) catch return CliError.BrowserConnect;
        defer state.allocator.free(js);
        const result = evaluate_(ptr, js) catch return CliError.BrowserConnect;
        defer freeJsonValue(state.allocator, result);
    }

    pub fn waitForTimeout_(ptr: *anyopaque, ms: u64) CliError!void {
        const state: *CdpPage = @ptrCast(@alignCast(ptr));
        const js_code = std.fmt.allocPrint(state.allocator,
            "new Promise(r => setTimeout(r, {d}))",
            .{ms}) catch return CliError.OutOfMemory;
        defer state.allocator.free(js_code);
        const result = evaluate_(ptr, js_code) catch return CliError.BrowserConnect;
        defer freeJsonValue(state.allocator, result);
    }

    pub fn cookies_(ptr: *anyopaque, _: ?CookieOptions) CliError![]Cookie {
        const state: *CdpPage = @ptrCast(@alignCast(ptr));
        const result = state.client.send("Network.getAllCookies", null) catch return CliError.BrowserConnect;
        defer freeJsonValue(state.allocator, result);
        var list = std.ArrayList(Cookie).empty;
        defer {
            for (list.items) |*c| {
                state.allocator.free(c.name);
                state.allocator.free(c.value);
                if (c.domain) |d| state.allocator.free(d);
                if (c.path) |p| state.allocator.free(p);
                if (c.same_site) |s| state.allocator.free(s);
            }
            list.deinit(state.allocator);
        }
        if (result.object.get("cookies")) |arr_val| {
            if (arr_val == .array) {
                for (arr_val.array.items) |item| {
                    if (item != .object) continue;
                    const obj = item.object;
                    const name = switch (obj.get("name") orelse continue) {
                        .string => |s| state.allocator.dupe(u8, s) catch continue,
                        else => continue,
                    };
                    const value = switch (obj.get("value") orelse continue) {
                        .string => |s| state.allocator.dupe(u8, s) catch continue,
                        else => continue,
                    };
                    list.append(state.allocator, Cookie{
                        .name = name,
                        .value = value,
                        .domain = jsonStringOpt(state.allocator, obj.get("domain")),
                        .path = jsonStringOpt(state.allocator, obj.get("path")),
                        .same_site = jsonStringOpt(state.allocator, obj.get("sameSite")),
                        .http_only = jsonBoolOpt(obj.get("httpOnly")),
                        .secure = jsonBoolOpt(obj.get("secure")),
                        .expires = jsonFloatOpt(obj.get("expires")),
                    }) catch continue;
                }
            }
        }
        return list.toOwnedSlice(state.allocator) catch return CliError.OutOfMemory;
    }

    pub fn setCookies_(ptr: *anyopaque, cookies: []Cookie) CliError!void {
        const state: *CdpPage = @ptrCast(@alignCast(ptr));
        var arr = std.array_list.Managed(json.Value).init(state.allocator);
        defer {
            for (arr.items) |*v| freeJsonValue(state.allocator, v.*);
            arr.deinit();
        }
        for (cookies) |c| {
            var obj = json.ObjectMap.empty;
            obj.put(state.allocator, "name", json.Value{ .string = c.name }) catch continue;
            obj.put(state.allocator, "value", json.Value{ .string = c.value }) catch continue;
            if (c.domain) |d| obj.put(state.allocator, "domain", json.Value{ .string = d }) catch return CliError.OutOfMemory;
            if (c.path) |p| obj.put(state.allocator, "path", json.Value{ .string = p }) catch return CliError.OutOfMemory;
            arr.append(json.Value{ .object = obj }) catch continue;
        }
        var params = json.ObjectMap.empty;
        defer params.deinit(state.allocator);
        params.put(state.allocator, "cookies", json.Value{ .array = arr }) catch return CliError.OutOfMemory;
        const result = state.client.send("Network.setCookies", json.Value{ .object = params }) catch return CliError.BrowserConnect;
        defer freeJsonValue(state.allocator, result);
    }

    pub fn screenshot_(ptr: *anyopaque, opts: ?ScreenshotOptions) CliError![]u8 {
        const state: *CdpPage = @ptrCast(@alignCast(ptr));
        var params = json.ObjectMap.empty;
        defer params.deinit(state.allocator);
        const full_page = if (opts) |o| o.full_page else false;
        params.put(state.allocator, "format", json.Value{ .string = "png" }) catch return CliError.OutOfMemory;
        params.put(state.allocator, "fromSurface", json.Value{ .bool = true }) catch return CliError.OutOfMemory;
        params.put(state.allocator, "captureBeyondViewport", json.Value{ .bool = full_page }) catch return CliError.OutOfMemory;
        const result = state.client.send("Page.captureScreenshot", json.Value{ .object = params }) catch return CliError.BrowserConnect;
        defer freeJsonValue(state.allocator, result);
        if (result.object.get("data")) |v| {
            if (v == .string) {
                {
                    const decoder = std.base64.standard.Decoder;
                    const size = decoder.calcSizeForSlice(v.string) catch return CliError.Pipeline;
                    const buf = state.allocator.alloc(u8, size) catch return CliError.Pipeline;
                    decoder.decode(buf, v.string) catch {
                        state.allocator.free(buf);
                        return CliError.Pipeline;
                    };
                    return buf;
                }
            }
        }
        return &[_]u8{};
    }

    pub fn snapshot_(ptr: *anyopaque, opts: ?SnapshotOptions) CliError!json.Value {
        const state: *CdpPage = @ptrCast(@alignCast(ptr));
        const selector = if (opts) |o| o.selector else null;
        const include_hidden = if (opts) |o| o.include_hidden else false;
        const js = dom.snapshotJs(state.allocator, selector, include_hidden) catch return CliError.BrowserConnect;
        defer state.allocator.free(js);
        return evaluate_(ptr, js) catch CliError.BrowserConnect;
    }

    pub fn autoScroll_(ptr: *anyopaque, opts: ?AutoScrollOptions) CliError!void {
        const state: *CdpPage = @ptrCast(@alignCast(ptr));
        const max_scrolls = if (opts) |o| o.max_scrolls orelse 3 else 3;
        const delay_ms = if (opts) |o| o.delay_ms orelse 200 else 200;
        const js = dom.autoScrollJs(state.allocator, max_scrolls, delay_ms) catch return CliError.BrowserConnect;
        defer state.allocator.free(js);
        const result = evaluate_(ptr, js) catch return CliError.BrowserConnect;
        defer freeJsonValue(state.allocator, result);
    }

    pub fn tabs_(ptr: *anyopaque) CliError![]TabInfo {
        const state: *CdpPage = @ptrCast(@alignCast(ptr));
        const response = state.client.send("Target.getTargets", null) catch return CliError.BrowserConnect;
        defer freeJsonValue(state.allocator, response);

        const result = response.object.get("result") orelse return &[_]TabInfo{};
        const target_infos = result.object.get("targetInfos") orelse return &[_]TabInfo{};

        var list = std.ArrayList(TabInfo).empty;
        errdefer {
            for (list.items) |*t| {
                state.allocator.free(t.id);
                state.allocator.free(t.url);
                if (t.title) |title| state.allocator.free(title);
            }
            list.deinit(state.allocator);
        }

        switch (target_infos) {
            .array => |arr| {
                for (arr.items) |item| {
                    if (item != .object) continue;
                    const obj = item.object;

                    const type_val = obj.get("type") orelse continue;
                    if (type_val != .string or !std.mem.eql(u8, type_val.string, "page")) continue;

                    const id = switch (obj.get("targetId") orelse continue) {
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
                        .title = if (obj.get("title")) |t| switch (t) {
                            .string => |s| try state.allocator.dupe(u8, s),
                            else => null,
                        } else null,
                    });
                }
            },
            else => {},
        }

        return try list.toOwnedSlice(state.allocator);
    }

    pub fn switchTab_(ptr: *anyopaque, new_tab_id: []const u8) CliError!void {
        const state: *CdpPage = @ptrCast(@alignCast(ptr));
        var params = json.ObjectMap.empty;
        defer params.deinit(state.allocator);
        params.put(state.allocator, "targetId", json.Value{ .string = new_tab_id }) catch return CliError.OutOfMemory;
        const result = state.client.send("Target.activateTarget", json.Value{ .object = params }) catch return CliError.BrowserConnect;
        defer freeJsonValue(state.allocator, result);
    }

    pub fn close_(ptr: *anyopaque) CliError!void {
        const state: *CdpPage = @ptrCast(@alignCast(ptr));
        if (state.owns_client) {
            state.client.deinit();
            state.allocator.destroy(state.client);
        }
        state.allocator.destroy(state);
    }

    pub fn interceptRequests_(ptr: *anyopaque, url_pattern: []const u8) CliError!void {
        const state: *CdpPage = @ptrCast(@alignCast(ptr));
        const js = dom.installInterceptorJs(state.allocator, url_pattern) catch return CliError.BrowserConnect;
        defer state.allocator.free(js);
        const result = evaluate_(ptr, js) catch return CliError.BrowserConnect;
        defer freeJsonValue(state.allocator, result);
    }

    pub fn getInterceptedRequests_(ptr: *anyopaque) CliError![]InterceptedRequest {
        const state: *CdpPage = @ptrCast(@alignCast(ptr));
        const js = dom.getInterceptedRequestsJs(state.allocator) catch return CliError.BrowserConnect;
        defer state.allocator.free(js);
        const result = evaluate_(ptr, js) catch return CliError.BrowserConnect;
        defer freeJsonValue(state.allocator, result);
        if (result != .array) return &[_]InterceptedRequest{};
        var list = std.ArrayList(InterceptedRequest).empty;
        defer list.deinit(state.allocator);
        for (result.array.items) |item| {
            if (item != .object) continue;
            const obj = item.object;
            const url = switch (obj.get("url") orelse continue) {
                .string => |s| state.allocator.dupe(u8, s) catch continue,
                else => continue,
            };
            const method = switch (obj.get("method") orelse continue) {
                .string => |s| state.allocator.dupe(u8, s) catch continue,
                else => continue,
            };
            list.append(state.allocator, InterceptedRequest{
                .url = url,
                .method = method,
                .headers = std.StringHashMap([]const u8).init(state.allocator),
                .body = null,
            }) catch continue;
        }
        return list.toOwnedSlice(state.allocator) catch &[_]InterceptedRequest{};
    }

    pub fn getNetworkRequests_(ptr: *anyopaque) CliError![]NetworkRequest {
        const state: *CdpPage = @ptrCast(@alignCast(ptr));
        const js = dom.networkRequestsJs(state.allocator) catch return CliError.BrowserConnect;
        defer state.allocator.free(js);
        const result = evaluate_(ptr, js) catch return CliError.BrowserConnect;
        defer freeJsonValue(state.allocator, result);
        if (result != .array) return &[_]NetworkRequest{};
        var list = std.ArrayList(NetworkRequest).empty;
        defer list.deinit(state.allocator);
        for (result.array.items) |item| {
            if (item != .object) continue;
            const obj = item.object;
            const url = switch (obj.get("url") orelse continue) {
                .string => |s| state.allocator.dupe(u8, s) catch continue,
                else => continue,
            };
            const method = switch (obj.get("method") orelse continue) {
                .string => |s| state.allocator.dupe(u8, s) catch continue,
                else => continue,
            };
            list.append(state.allocator, NetworkRequest{
                .url = url,
                .method = method,
                .headers = std.StringHashMap([]const u8).init(state.allocator),
                .body = null,
                .status = jsonU16Opt(obj.get("status")),
                .response_body = null,
            }) catch continue;
        }
        return list.toOwnedSlice(state.allocator) catch &[_]NetworkRequest{};
    }
};
