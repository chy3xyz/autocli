const std = @import("std");
const builtin_mod = @import("builtin");
const CliError = @import("core").CliError;
const IPage = @import("core").IPage;
const DaemonClient = @import("client.zig").DaemonClient;
const makeIPage = @import("page.zig").makeIPage;
const CdpPage = @import("cdp.zig").CdpPage;
const CdpClient = @import("cdp.zig").CdpClient;
const discoverCdpWsUrl = @import("cdp.zig").discoverCdpWsUrl;
const DEFAULT_DAEMON_PORT = @import("types.zig").DEFAULT_DAEMON_PORT;

const READY_TIMEOUT_MS = 10_000;
const READY_POLL_INTERVAL_MS = 200;
const EXTENSION_INITIAL_WAIT_MS = 5_000;
const EXTENSION_REMAINING_WAIT_MS = 25_000;
const EXTENSION_POLL_INTERVAL_MS = 500;

/// BrowserBridge - High-level bridge for managing browser connections
///
/// Architecture:
/// 1. Check if Chrome is running
/// 2. Ensure daemon is running (spawn if needed)
/// 3. Wait for extension to connect
/// 4. Return DaemonPage implementing IPage
///
/// Note: Zig 0.16.0 uses synchronous I/O. All waiting is done via polling + sleep.
pub const BrowserBridge = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    port: u16,

    pub fn init(allocator: std.mem.Allocator, io: std.Io, port: u16) BrowserBridge {
        return .{ .allocator = allocator, .io = io, .port = port };
    }

    pub fn defaultPort(allocator: std.mem.Allocator, io: std.Io) BrowserBridge {
        return .{ .allocator = allocator, .io = io, .port = DEFAULT_DAEMON_PORT };
    }

    /// Connect to the daemon, starting it if necessary, and return an IPage
    /// Returns error if Chrome extension is not connected
    pub fn connect(self: *BrowserBridge) !IPage {
        // Step 1: Check Chrome is running
        if (!self.isChromeRunning()) {
            std.log.err("Chrome is not running", .{});
            return CliError.BrowserConnect;
        }

        // Heap-allocate the client so it can outlive this function
        const client_ptr = try self.allocator.create(DaemonClient);
        errdefer {
            client_ptr.deinit();
            self.allocator.destroy(client_ptr);
        }
        client_ptr.* = DaemonClient.init(self.allocator, self.port, self.io);

        // Step 2: Ensure daemon is running
        if (client_ptr.isRunning()) {
            std.log.info("daemon already running on port {d}, reusing", .{self.port});
        } else {
            std.log.info("daemon not running on port {d}, spawning", .{self.port});
            try self.spawnDaemon();
            try self.waitForReady(client_ptr);
        }

        // Step 3: Wait up to 5s for extension to connect
        if (self.pollExtension(client_ptr, EXTENSION_INITIAL_WAIT_MS, false)) {
            return try makeIPage(self.allocator, client_ptr, true, "default");
        }

        // Step 4: Extension not connected — try to wake up Chrome
        std.log.info("Extension not connected after 5s, attempting to wake up Chrome", .{});
        const stderr = std.Io.File.stderr();
        stderr.writeStreamingAll(self.io, "Waking up Chrome extension...\n") catch {};
        self.wakeChrome();

        // Step 5: Wait remaining 25s with progress
        if (self.pollExtension(client_ptr, EXTENSION_REMAINING_WAIT_MS, true)) {
            return try makeIPage(self.allocator, client_ptr, true, "default");
        }

        std.log.err("Chrome extension is not connected to the daemon", .{});
        // Clean up client before trying fallback
        client_ptr.deinit();
        self.allocator.destroy(client_ptr);

        // Fallback: try direct CDP WebSocket connection
        const ws_url = discoverCdpWsUrl(self.allocator, self.io) catch {
            return CliError.BrowserConnect;
        };
        defer self.allocator.free(ws_url);

        const stderr2 = std.Io.File.stderr();
        stderr2.writeStreamingAll(self.io, "Falling back to direct CDP connection...\n") catch {};

        // Parse ws_url: ws://host:port/path
        const ws_url_trimmed = if (std.mem.startsWith(u8, ws_url, "ws://"))
            ws_url[5..]
        else if (std.mem.startsWith(u8, ws_url, "wss://"))
            ws_url[6..]
        else
            ws_url;

        const path_start = std.mem.indexOfScalar(u8, ws_url_trimmed, '/') orelse ws_url_trimmed.len;
        const host_port = ws_url_trimmed[0..path_start];
        const cdp_path = if (path_start < ws_url_trimmed.len) ws_url_trimmed[path_start..] else "/";

        const port_start = std.mem.lastIndexOfScalar(u8, host_port, ':') orelse host_port.len;
        const cdp_host = host_port[0..port_start];
        const cdp_port = if (port_start < host_port.len)
            std.fmt.parseInt(u16, host_port[port_start + 1..], 10) catch 9222
        else
            9222;

        const cdp_client = try self.allocator.create(CdpClient);
        cdp_client.* = CdpClient.init(self.allocator, self.io, cdp_host, cdp_port, cdp_path) catch {
            self.allocator.destroy(cdp_client);
            return CliError.BrowserConnect;
        };

        return CdpPage.makeIPage(self.allocator, cdp_client, true) catch {
            cdp_client.deinit();
            self.allocator.destroy(cdp_client);
            return CliError.BrowserConnect;
        };
    }

    /// Spawn the daemon as a child process using --daemon flag on the current binary.
    fn spawnDaemon(self: *BrowserBridge) !void {
        const exe_path = std.process.executablePathAlloc(self.io, self.allocator) catch |err| {
            std.log.err("Cannot determine current executable: {s}", .{@errorName(err)});
            return CliError.BrowserConnect;
        };
        defer self.allocator.free(exe_path);

        const port_str = try std.fmt.allocPrint(self.allocator, "{d}", .{self.port});
        defer self.allocator.free(port_str);

        const argv = [_][]const u8{
            exe_path,
            "--daemon",
            "--port",
            port_str,
        };

        const child = std.process.spawn(self.io, .{
            .argv = &argv,
            .stdin = .ignore,
            .stdout = .ignore,
            .stderr = .ignore,
        }) catch |err| {
            std.log.err("Failed to spawn daemon: {s}", .{@errorName(err)});
            return CliError.BrowserConnect;
        };
        _ = child;
        std.log.info("daemon process spawned on port {d}", .{self.port});
    }

    /// Wait for the daemon to become ready by polling /health.
    fn waitForReady(self: *BrowserBridge, client: *DaemonClient) !void {
        const start = @divFloor(std.Io.Timestamp.now(self.io, .real).nanoseconds, std.time.ns_per_ms);
        const deadline = start + READY_TIMEOUT_MS;

        while (@divFloor(std.Io.Timestamp.now(self.io, .real).nanoseconds, std.time.ns_per_ms) < deadline) {
            if (client.isRunning()) {
                std.log.info("daemon is ready", .{});
                return;
            }
            std.Io.sleep(self.io, .{ .nanoseconds = READY_POLL_INTERVAL_MS * std.time.ns_per_ms }, .real) catch {};
        }

        return CliError.Timeout;
    }

    /// Poll for extension connection within the given duration.
    /// Returns true if connected, false if timed out.
    fn pollExtension(self: *BrowserBridge, client: *DaemonClient, timeout_ms: u64, show_progress: bool) bool {
        const start = @divFloor(std.Io.Timestamp.now(self.io, .real).nanoseconds, std.time.ns_per_ms);
        const deadline = start + @as(i64, @intCast(timeout_ms));
        var printed = false;

        while (@divFloor(std.Io.Timestamp.now(self.io, .real).nanoseconds, std.time.ns_per_ms) < deadline) {
            if (client.isExtensionConnected()) {
                if (printed) std.debug.print("\n", .{});
                std.log.info("Chrome extension connected", .{});
                return true;
            }

            if (show_progress) {
                const elapsed = @divFloor(@divFloor(std.Io.Timestamp.now(self.io, .real).nanoseconds, std.time.ns_per_ms) - start, 1000);
                if (elapsed >= 1 and !printed) {
                    std.debug.print("Waiting for Chrome extension to connect", .{});
                    printed = true;
                } else if (printed and @mod(elapsed, 3) == 0) {
                    std.debug.print(".", .{});
                }
            }

            std.Io.sleep(self.io, .{ .nanoseconds = EXTENSION_POLL_INTERVAL_MS * std.time.ns_per_ms }, .real) catch {};
        }

        if (printed) std.debug.print("\n", .{});
        return false;
    }

    /// Check if Chrome/Chromium is running as a process
    fn isChromeRunning(self: *BrowserBridge) bool {
        const os = builtin_mod.os.tag;
        if (os == .macos) {
            const argv = [_][]const u8{ "pgrep", "-x", "Google Chrome" };
            var child = std.process.spawn(self.io, .{
                .argv = &argv,
                .stdin = .ignore,
                .stdout = .ignore,
                .stderr = .ignore,
            }) catch return false;
            const term = child.wait(self.io) catch return false;
            return switch (term) {
                .exited => |code| code == 0,
                else => false,
            };
        } else if (os == .windows) {
            // Windows: check for chrome.exe via tasklist
            const argv = [_][]const u8{ "tasklist", "/FI", "IMAGENAME eq chrome.exe", "/NH" };
            var child = std.process.spawn(self.io, .{
                .argv = &argv,
                .stdin = .ignore,
                .stdout = .pipe,
                .stderr = .ignore,
            }) catch return false;
            const stdout_pipe = child.stdout.?;
            var buf: [1024]u8 = undefined;
            const n = stdout_pipe.read(self.io, &buf) catch return false;
            _ = child.wait(self.io) catch |err| {
                std.log.warn("child.wait failed: {s}", .{@errorName(err)});
            };
            const output = buf[0..n];
            return std.mem.indexOf(u8, output, "chrome.exe") != null;
        } else {
            // Linux: check for chrome or chromium
            const argv = [_][]const u8{ "pgrep", "-x", "chrome|chromium" };
            var child = std.process.spawn(self.io, .{
                .argv = &argv,
                .stdin = .ignore,
                .stdout = .ignore,
                .stderr = .ignore,
            }) catch return false;
            const term = child.wait(self.io) catch return false;
            return switch (term) {
                .exited => |code| code == 0,
                else => false,
            };
        }
    }

    /// Try to wake up Chrome by opening a window.
    /// When Chrome is running but has no windows, the extension Service Worker is suspended.
    /// Opening a window activates the Service Worker, which then reconnects to the daemon.
    fn wakeChrome(self: *BrowserBridge) void {
        const os = builtin_mod.os.tag;
        if (os == .macos) {
            const argv = [_][]const u8{ "open", "-a", "Google Chrome", "about:blank" };
            _ = std.process.spawn(self.io, .{
                .argv = &argv,
                .stdin = .ignore,
                .stdout = .ignore,
                .stderr = .ignore,
            }) catch |err| {
                std.log.warn("failed to spawn Chrome ({s}): {s}", .{@tagName(os), @errorName(err)});
            };
        } else if (os == .windows) {
            const argv = [_][]const u8{ "cmd", "/C", "start", "chrome", "about:blank" };
            _ = std.process.spawn(self.io, .{
                .argv = &argv,
                .stdin = .ignore,
                .stdout = .ignore,
                .stderr = .ignore,
            }) catch |err| {
                std.log.warn("failed to spawn Chrome ({s}): {s}", .{@tagName(os), @errorName(err)});
            };
        } else {
            const argv = [_][]const u8{ "xdg-open", "about:blank" };
            _ = std.process.spawn(self.io, .{
                .argv = &argv,
                .stdin = .ignore,
                .stdout = .ignore,
                .stderr = .ignore,
            }) catch |err| {
                std.log.warn("failed to spawn Chrome ({s}): {s}", .{@tagName(os), @errorName(err)});
            };
        }
    }
};
