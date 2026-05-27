const std = @import("std");
const json = @import("std").json;
const CliArgs = @import("args.zig").CliArgs;
const Registry = @import("core").Registry;

/// Built-in commands that don't require adapter loading
pub const BuiltinCommand = enum {
    list,
    doctor,
    completion,
    help,
    auth,
    search,
    generate,
    read,
};

/// Context passed to built-in commands for runtime data
pub const BuiltinContext = struct {
    environ_map: *const std.process.Environ.Map,
    /// Pre-populated registry with user adapters (for list command)
    registry: ?*Registry = null,
};

/// Execute a built-in command
pub fn runBuiltin(
    io: std.Io,
    builtin: BuiltinCommand,
    args: CliArgs,
    gpa: std.mem.Allocator,
    ctx: BuiltinContext,
) !void {
    switch (builtin) {
        .list => try runList(io, args, gpa, ctx),
        .doctor => try runDoctor(io, gpa, ctx.environ_map, ctx),
        .completion => try runCompletion(io, args),
        .help => try runHelp(io, ctx.environ_map),
        .auth => try runAuth(io, args, gpa, ctx.environ_map),
        .search => try runSearch(io, args, gpa, ctx.environ_map),
        .generate => try runGenerate(io, args, gpa, ctx.environ_map),
        .read => try runRead(io, args, gpa),
    }
}

fn runList(io: std.Io, args: CliArgs, gpa: std.mem.Allocator, ctx: BuiltinContext) !void {
    const stdout = std.Io.File.stdout();

    try stdout.writeStreamingAll(io, "autocli - Available sites and commands\n\n");
    try stdout.writeStreamingAll(io, "Usage: autocli list [site]\n\n");

    // Use fast metadata path: no YAML parsing for list command
    const builtin_metas = @import("discovery").listBuiltinAdapters();
    const user_metas = @import("discovery").listUserAdapters(gpa, io, ctx.environ_map) catch &[0]@import("discovery").AdapterMeta{};
    defer @import("discovery").freeAdapterMetaList(gpa, user_metas);

    // Build a sorted site → names map
    var site_map = std.StringHashMap(std.ArrayList([]const u8)).init(gpa);
    defer {
        var it = site_map.iterator();
        while (it.next()) |entry| {
            entry.value_ptr.deinit(gpa);
        }
        site_map.deinit();
    }

    var total_count: usize = 0;

    // Add built-ins
    for (builtin_metas) |m| {
        const gop = try site_map.getOrPut(m.site);
        if (!gop.found_existing) {
            gop.value_ptr.* = std.ArrayList([]const u8).empty;
        }
        // Avoid duplicates from user overrides
        var dup = false;
        for (gop.value_ptr.items) |existing| {
            if (std.mem.eql(u8, existing, m.name)) { dup = true; break; }
        }
        if (!dup) {
            try gop.value_ptr.append(gpa, m.name);
            total_count += 1;
        }
    }

    // Add user adapters (override built-ins, so dedup against existing)
    for (user_metas) |m| {
        const gop = try site_map.getOrPut(m.site);
        if (!gop.found_existing) {
            gop.value_ptr.* = std.ArrayList([]const u8).empty;
        }
        var dup = false;
        for (gop.value_ptr.items) |existing| {
            if (std.mem.eql(u8, existing, m.name)) { dup = true; break; }
        }
        if (!dup) {
            try gop.value_ptr.append(gpa, m.name);
            total_count += 1;
        }
    }

    var buf: [64]u8 = undefined;
    const count_str = std.fmt.bufPrint(&buf, "{d}", .{total_count}) catch "?";
    try stdout.writeStreamingAll(io, "Sites (");
    try stdout.writeStreamingAll(io, count_str);
    try stdout.writeStreamingAll(io, " commands total):\n");

    // Sort sites
    var sites = std.ArrayList([]const u8).empty;
    defer sites.deinit(gpa);
    var site_iter = site_map.keyIterator();
    while (site_iter.next()) |key| try sites.append(gpa, key.*);
    std.mem.sort([]const u8, sites.items, {}, struct {
        fn lessThan(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.lessThan(u8, a, b);
        }
    }.lessThan);

    for (sites.items) |site| {
        try stdout.writeStreamingAll(io, "  ");
        try stdout.writeStreamingAll(io, site);
        try stdout.writeStreamingAll(io, "   ");

        const names = site_map.get(site).?;
        // Sort names
        var name_list = std.ArrayList([]const u8).empty;
        defer name_list.deinit(gpa);
        try name_list.appendSlice(gpa, names.items);
        std.mem.sort([]const u8, name_list.items, {}, struct {
            fn lessThan(_: void, a: []const u8, b: []const u8) bool {
                return std.mem.lessThan(u8, a, b);
            }
        }.lessThan);

        var first = true;
        for (name_list.items) |name| {
            if (!first) try stdout.writeStreamingAll(io, ", ");
            try stdout.writeStreamingAll(io, name);
            first = false;
        }
        try stdout.writeStreamingAll(io, "\n");
    }
    try stdout.writeStreamingAll(io, "\n");

    _ = args;
}

fn runDoctor(io: std.Io, gpa: std.mem.Allocator, environ_map: *const std.process.Environ.Map, ctx: BuiltinContext) !void {
    const stdout = std.Io.File.stdout();

    try stdout.writeStreamingAll(io, "autocli diagnostics\n\n");

    // 1. Check Chrome/Chromium
    const t1 = std.Io.Timestamp.now(io, .real);
    const chrome_ok = try checkChromeRunning(io, gpa);
    try printCheckTimed(io, stdout, "Chrome/Chromium", chrome_ok, elapsedMs(io, t1));

    // 2. Check daemon reachable
    const port = getDaemonPort(environ_map);
    const t2 = std.Io.Timestamp.now(io, .real);
    const daemon_ok = try checkDaemonRunning(io, gpa, port);
    try printCheckTimed(io, stdout, "Daemon running", daemon_ok, elapsedMs(io, t2));

    // 3. Check extension connected
    if (daemon_ok) {
        const t3 = std.Io.Timestamp.now(io, .real);
        const ext_ok = try checkExtensionConnected(io, gpa, port);
        try printCheckTimed(io, stdout, "Chrome extension connected", ext_ok, elapsedMs(io, t3));
    } else {
        try printCheck(io, stdout, "Chrome extension connected", false);
    }

    // 4. Check external CLIs
    try stdout.writeStreamingAll(io, "\nExternal CLIs:\n");
    const externals = &[_][]const u8{ "gh", "docker", "kubectl", "obsidian", "readwise", "gws" };
    for (externals) |name| {
        const ok = try isBinaryInstalled(io, gpa, name);
        try printCheck(io, stdout, name, ok);
    }

    // 5. Check CDP endpoint
    if (environ_map.get("AUTOCLI_CDP_ENDPOINT")) |endpoint| {
        try stdout.writeStreamingAll(io, "\nCDP endpoint: ");
        try stdout.writeStreamingAll(io, endpoint);
        try stdout.writeStreamingAll(io, "\n");
    }

    // 6. Adapter stats
    try stdout.writeStreamingAll(io, "\nAdapter stats:\n");
    if (ctx.registry) |registry| {
        var buf: [64]u8 = undefined;
        const site_count = registry.siteCount();
        const cmd_count = registry.commandCount();
        const sites_str = try std.fmt.bufPrint(&buf, "  Sites: {d}\n", .{site_count});
        try stdout.writeStreamingAll(io, sites_str);
        const cmds_str = try std.fmt.bufPrint(&buf, "  Commands: {d}\n", .{cmd_count});
        try stdout.writeStreamingAll(io, cmds_str);
    } else {
        try stdout.writeStreamingAll(io, "  No registry loaded\n");
    }

    // 7. Config check
    if (environ_map.get("HOME")) |home| {
        const config_path = try std.fmt.allocPrint(gpa, "{s}/.autocli/config.json", .{home});
        defer gpa.free(config_path);
        var config_exists = false;
        if (std.Io.Dir.cwd().openFile(io, config_path, .{})) |f| {
            f.close(io);
            config_exists = true;
        } else |_| {}
        try printCheck(io, stdout, "Config file", config_exists);
    }

    // 8. Adapter validation (sample built-ins)
    try stdout.writeStreamingAll(io, "\nAdapter validation (sample):\n");
    const builtin_adapters = @import("discovery").builtin_adapters;
    const parseYamlAdapter = @import("discovery").parseYamlAdapter;
    const freeCliCommand = @import("core").freeCliCommand;

    const sample_count = @min(3, builtin_adapters.len);
    var validated: usize = 0;
    var failed: usize = 0;
    for (builtin_adapters[0..sample_count]) |adapter| {
        const t = std.Io.Timestamp.now(io, .real);
        const cmd = parseYamlAdapter(gpa, adapter.content) catch |err| {
            var ebuf: [128]u8 = undefined;
            const label = std.fmt.bufPrint(&ebuf, "{s}: {s}", .{ adapter.path, @errorName(err) }) catch adapter.path;
            try printCheckTimed(io, stdout, label, false, elapsedMs(io, t));
            failed += 1;
            continue;
        };
        freeCliCommand(gpa, cmd);
        try printCheckTimed(io, stdout, adapter.path, true, elapsedMs(io, t));
        validated += 1;
    }
    if (failed > 0) {
        var sbuf: [128]u8 = undefined;
        const summary = std.fmt.bufPrint(&sbuf, "\n  {d}/{d} samples failed\n", .{ failed, sample_count }) catch "";
        try stdout.writeStreamingAll(io, summary);
    }

    try stdout.writeStreamingAll(io, "\n");
}

fn printCheck(io: std.Io, stdout: std.Io.File, label: []const u8, ok: bool) !void {
    try printCheckTimed(io, stdout, label, ok, null);
}

fn printCheckTimed(io: std.Io, stdout: std.Io.File, label: []const u8, ok: bool, duration_ms: ?u64) !void {
    if (ok) {
        try stdout.writeStreamingAll(io, "  ✓ ");
    } else {
        try stdout.writeStreamingAll(io, "  ✗ ");
    }
    try stdout.writeStreamingAll(io, label);
    if (duration_ms) |ms| {
        var buf: [32]u8 = undefined;
        const timing = std.fmt.bufPrint(&buf, " [{d}ms]", .{ms}) catch "";
        try stdout.writeStreamingAll(io, timing);
    }
    try stdout.writeStreamingAll(io, "\n");
}

fn elapsedMs(io: std.Io, start: std.Io.Timestamp) u64 {
    const end = std.Io.Timestamp.now(io, .real);
    const diff = end.nanoseconds - start.nanoseconds;
    return @intCast(@divFloor(diff, std.time.ns_per_ms));
}

fn getDaemonPort(environ_map: *const std.process.Environ.Map) u16 {
    if (environ_map.get("AUTOCLI_DAEMON_PORT")) |port_str| {
        return std.fmt.parseInt(u16, port_str, 10) catch 19825;
    }
    return 19825;
}

fn isBinaryInstalled(io: std.Io, gpa: std.mem.Allocator, name: []const u8) !bool {
    const builtin = @import("builtin");
    const cmd = if (builtin.os.tag == .windows) "where" else "which";
    const argv = &[_][]const u8{cmd, name};
    var child = std.process.spawn(io, .{
        .argv = argv,
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .ignore,
    }) catch return false;
    const term = child.wait(io) catch return false;
    _ = gpa;
    return switch (term) {
        .exited => |code| code == 0,
        else => false,
    };
}

fn checkChromeRunning(io: std.Io, gpa: std.mem.Allocator) !bool {
    const builtin = @import("builtin");
    const os_tag = builtin.os.tag;
    if (os_tag == .macos) {
        // Check process or app bundle
        const argv1 = &[_][]const u8{ "pgrep", "-x", "Google Chrome" };
        if (try runCheckCmd(io, gpa, argv1)) return true;
        const argv2 = &[_][]const u8{ "pgrep", "-x", "Chromium" };
        if (try runCheckCmd(io, gpa, argv2)) return true;
        // Check app bundle exists
        if (std.Io.Dir.cwd().openDir(io, "/Applications/Google Chrome.app", .{})) |d| {
            d.close(io);
            return true;
        } else |_| {}
        return false;
    } else if (os_tag == .windows) {
        const argv = &[_][]const u8{ "tasklist", "/FI", "IMAGENAME eq chrome.exe", "/NH" };
        var child = std.process.spawn(io, .{
            .argv = argv,
            .stdin = .ignore,
            .stdout = .pipe,
            .stderr = .ignore,
        }) catch return false;
        var buf: [4096]u8 = undefined;
        const n = child.stdout.?.read(io, &buf) catch 0;
        _ = child.wait(io) catch |err| {
            std.log.warn("child.wait failed: {s}", .{@errorName(err)});
        };
        const output = buf[0..n];
        return std.mem.indexOf(u8, output, "chrome.exe") != null;
    } else {
        // Linux
        const checks = &[_][]const u8{ "google-chrome", "google-chrome-stable", "chromium", "chromium-browser" };
        for (checks) |name| {
            const argv = &[_][]const u8{ "which", name };
            if (try runCheckCmd(io, gpa, argv)) return true;
        }
        return false;
    }
}

fn runCheckCmd(io: std.Io, gpa: std.mem.Allocator, argv: []const []const u8) !bool {
    _ = gpa;
    var child = std.process.spawn(io, .{
        .argv = argv,
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .ignore,
    }) catch return false;
    const term = child.wait(io) catch return false;
    return switch (term) {
        .exited => |code| code == 0,
        else => false,
    };
}

fn checkDaemonRunning(io: std.Io, gpa: std.mem.Allocator, port: u16) !bool {
    var buf: [256]u8 = undefined;
    const url = std.fmt.bufPrint(&buf, "http://127.0.0.1:{d}/status", .{port}) catch return false;

    const http_util = @import("core").http_util;
    var zero_attempt: u32 = 0;
    var log_state = http_util.HttpLogState{
        .enabled = http_util.http_logging_enabled,
        .method = "GET",
        .url = url,
        .start_ts = std.Io.Timestamp.now(io, .real),
        .attempt = &zero_attempt,
    };
    defer log_state.log(io);

    const uri = std.Uri.parse(url) catch return false;
    var client = std.http.Client{ .allocator = gpa, .io = io };
    defer client.deinit();
    var req = @import("core").requestWithTimeout(&client, .GET, uri, .{}, 5_000) catch return false;
    defer req.deinit();
    req.sendBodiless() catch return false;
    var redirect_buf: [4096]u8 = undefined;
    const response = req.receiveHead(&redirect_buf) catch return false;
    const status = response.head.status;
    const ok = @intFromEnum(status) >= 200 and @intFromEnum(status) < 300;
    if (ok) log_state.recordStatus(@intFromEnum(status));
    return ok;
}

fn checkExtensionConnected(io: std.Io, gpa: std.mem.Allocator, port: u16) !bool {
    var buf: [256]u8 = undefined;
    const url = std.fmt.bufPrint(&buf, "http://127.0.0.1:{d}/status", .{port}) catch return false;

    const http_util = @import("core").http_util;
    var zero_attempt: u32 = 0;
    var log_state = http_util.HttpLogState{
        .enabled = http_util.http_logging_enabled,
        .method = "GET",
        .url = url,
        .start_ts = std.Io.Timestamp.now(io, .real),
        .attempt = &zero_attempt,
    };
    defer log_state.log(io);

    const uri = std.Uri.parse(url) catch return false;
    var client = std.http.Client{ .allocator = gpa, .io = io };
    defer client.deinit();
    var req = @import("core").requestWithTimeout(&client, .GET, uri, .{}, 5_000) catch return false;
    defer req.deinit();
    req.sendBodiless() catch return false;
    var redirect_buf: [4096]u8 = undefined;
    var response = req.receiveHead(&redirect_buf) catch return false;
    const status = response.head.status;
    if (@intFromEnum(status) < 200 or @intFromEnum(status) >= 300) return false;
    log_state.recordStatus(@intFromEnum(status));

    var transfer_buf: [64]u8 = undefined;
    const reader = response.reader(&transfer_buf);
    const body = reader.allocRemaining(gpa, std.Io.Limit.limited(1024)) catch return false;
    defer gpa.free(body);

    const parsed = std.json.parseFromSlice(std.json.Value, gpa, body, .{}) catch return false;
    defer parsed.deinit();

    const val = parsed.value;
    if (val != .object) return false;
    const ext = val.object.get("extension") orelse val.object.get("extensionConnected") orelse return false;
    return switch (ext) {
        .bool => |b| b,
        else => false,
    };
}

fn runCompletion(io: std.Io, args: CliArgs) !void {
    const stdout = std.Io.File.stdout();
    const shell = args.extra_args.get("shell") orelse null;
    const shell_str = if (shell) |s| s.string else "bash";

    if (std.mem.eql(u8, shell_str, "zsh")) {
        try stdout.writeStreamingAll(io,
            \\# Autocli ZSH completion
            \\autocli() {
            \\  _arguments \
            \\    '-h[help]' \
            \\    '-v[version]' \
            \\    '-f+[format]:format:(table json yaml csv md)' \
            \\    '-l+[limit]:limit:' \
            \\    '*:site:->sites'
            \\  case $state in
            \\    sites)
            \\      _values 'sites' hackernews reddit twitter bilibili zhihu
            \\      ;;
            \\  esac
            \\}
            \\compdef autocli autocli
        );
    } else if (std.mem.eql(u8, shell_str, "fish")) {
        try stdout.writeStreamingAll(io,
            \\# Autocli fish completion
            \\complete -c autocli -s h -l help -d 'Show help'
            \\complete -c autocli -s v -l version -d 'Show version'
            \\complete -c autocli -s f -l format -d 'Output format' -xa 'table json yaml csv md'
            \\complete -c autocli -s l -l limit -d 'Limit results'
            \\complete -c autocli -s o -l output -d 'Output file'
            \\complete -c autocli -n '__fish_use_subcommand' -a 'list doctor completion help'
            \\complete -c autocli -n '__fish_use_subcommand' -a 'hackernews reddit twitter bilibili zhihu'
        );
    } else {
        try stdout.writeStreamingAll(io,
            \\# Autocli bash completion
            \\_autocli() {
            \\  local cur prev
            \\  COMPREPLY=()
            \\  cur="${COMP_WORDS[COMP_CWORD]}"
            \\  prev="${COMP_WORDS[COMP_CWORD-1]}"
            \\  case "${prev}" in
            \\    -f|--format)
            \\      COMPREPLY=(table json yaml csv md)
            \\      return 0
            \\      ;;
            \\  esac
            \\  COMPREPLY=(hackernews reddit twitter bilibili zhihu)
            \\}
            \\complete -F _autocli autocli
        );
    }
}

fn runHelp(io: std.Io, environ_map: *const std.process.Environ.Map) !void {
    const stdout = std.Io.File.stdout();
    const i18n = @import("i18n.zig");
    try stdout.writeStreamingAll(io,
        \\autocli - AI-driven CLI tool / AI 命令行工具
        \\
        \\Usage: autocli <site> <command> [options]
        \\
        \\Options:
        \\  -h, --help       Show this help message
        \\  -v, --version    Show version information
        \\  -f, --format     Output format: table, json, yaml, csv, md
        \\  -l, --limit      Limit number of results
        \\  -o, --output     Write output to file
        \\
        \\Built-in commands:
        \\  autocli list              List available sites and commands
        \\  autocli doctor            Run diagnostics
        \\  autocli completion        Generate shell completions
        \\  autocli help              Show this help message
        \\  autocli auth <token>      Configure AI token
        \\  autocli search <query>    Search for adapters
        \\  autocli generate <url>    Generate adapter from URL
        \\  autocli read <url>        Read article content
        \\
        \\Examples:
        \\  autocli hackernews top --limit 10
        \\  autocli hackernews top --format json
        \\  autocli reddit hot --limit 5 --format yaml
        \\  autocli read https://example.com/article --format markdown
        \\
    );
    _ = i18n;
    _ = environ_map;
}

fn runAuth(io: std.Io, args: CliArgs, gpa: std.mem.Allocator, environ_map: *const std.process.Environ.Map) !void {
    const stdout = std.Io.File.stdout();
    const ai_config = @import("ai").config;

    if (args.command) |token| {
        var config = ai_config.Config{};
        // Load existing config to preserve other fields
        var existing = ai_config.loadConfig(gpa, io, environ_map) catch ai_config.Config{};
        defer existing.deinit(gpa);
        if (existing.llm.endpoint) |e| config.llm.endpoint = try gpa.dupe(u8, e);
        if (existing.llm.apikey) |k| config.llm.apikey = try gpa.dupe(u8, k);
        if (existing.llm.modelname) |m| config.llm.modelname = try gpa.dupe(u8, m);
        config.autocli_token = try gpa.dupe(u8, token);
        defer config.deinit(gpa);

        try ai_config.saveConfig(gpa, io, environ_map, &config);
        try stdout.writeStreamingAll(io, "Token saved to ~/.autocli/config.json\n");
    } else {
        var config = ai_config.loadConfig(gpa, io, environ_map) catch ai_config.Config{};
        defer config.deinit(gpa);
        if (config.autocli_token) |t| {
            try stdout.writeStreamingAll(io, "Token: ");
            if (t.len > 16) {
                try stdout.writeStreamingAll(io, t[0..8]);
                try stdout.writeStreamingAll(io, "...");
                try stdout.writeStreamingAll(io, t[t.len - 4 ..]);
            } else {
                try stdout.writeStreamingAll(io, t);
            }
            try stdout.writeStreamingAll(io, "\n");
        } else {
            try stdout.writeStreamingAll(io, "No token configured. Run: autocli auth <token>\n");
        }
    }

}

fn runSearch(io: std.Io, args: CliArgs, gpa: std.mem.Allocator, environ_map: *const std.process.Environ.Map) !void {
    const stdout = std.Io.File.stdout();
    const ai_client = @import("ai").client;

    const query = args.command orelse {
        try stdout.writeStreamingAll(io, "Usage: autocli search <url-pattern>\n");
        return;
    };

    var config = @import("ai").config.loadConfig(gpa, io, environ_map) catch @import("ai").config.Config{};
    defer config.deinit(gpa);

    const token = config.autocli_token orelse {
        try stdout.writeStreamingAll(io, "No token configured. Run: autocli auth <token>\n");
        return;
    };

    const result = ai_client.search(gpa, io, environ_map, token, query) catch |err| {
        try stdout.writeStreamingAll(io, "Search failed: ");
        try stdout.writeStreamingAll(io, @errorName(err));
        try stdout.writeStreamingAll(io, "\n");
        return;
    };
    defer gpa.free(result);

    try stdout.writeStreamingAll(io, result);
    try stdout.writeStreamingAll(io, "\n");
}

fn runGenerate(io: std.Io, args: CliArgs, gpa: std.mem.Allocator, environ_map: *const std.process.Environ.Map) !void {
    const stdout = std.Io.File.stdout();
    const ai_generate = @import("ai").generate;

    const url = args.command orelse {
        try stdout.writeStreamingAll(io, "Usage: autocli generate <url> [goal]\n");
        return;
    };

    var config = @import("ai").config.loadConfig(gpa, io, environ_map) catch @import("ai").config.Config{};
    defer config.deinit(gpa);

    const token = config.autocli_token orelse {
        try stdout.writeStreamingAll(io, "No token configured. Run: autocli auth <token>\n");
        return;
    };

    // Goal is optional second arg
    const goal = args.extra_args.get("goal") orelse null;
    const goal_str = if (goal) |g| switch (g) {
        .string => |s| s,
        else => null,
    } else null;

    const result = ai_generate.generateAdapter(gpa, io, environ_map, token, url, goal_str, null) catch |err| {
        try stdout.writeStreamingAll(io, "Generation failed: ");
        try stdout.writeStreamingAll(io, @errorName(err));
        try stdout.writeStreamingAll(io, "\n");
        return;
    };
    defer gpa.free(result);

    try stdout.writeStreamingAll(io, result);
    try stdout.writeStreamingAll(io, "\n");
}

const READ_ARTICLE_JS =
    \\(() => {
    \\    function getMeta(prop) {
    \\        const el = document.querySelector('meta[property="og:' + prop + '"], meta[name="' + prop + '"]');
    \\        return el ? el.getAttribute('content') || '' : '';
    \\    }
    \\    function getByline() {
    \\        const author = getMeta('author');
    \\        if (author) return author;
    \\        const el = document.querySelector('[rel="author"], .author, .byline, [itemprop="author"]');
    \\        return el ? el.textContent.trim() : '';
    \\    }
    \\    function getSiteName() {
    \\        const site = getMeta('site_name');
    \\        if (site) return site;
    \\        try { return new URL(document.URL).hostname.replace(/^www\\./, ''); } catch { return ''; }
    \\    }
    \\    function extractContent() {
    \\        const candidates = document.querySelectorAll('article, [role="main"], main, .post-content, .article-content, .entry-content, .post-body, #content, .content');
    \\        for (const el of candidates) {
    \\            const text = el.textContent.trim();
    \\            if (text.length > 500) return el.innerHTML;
    \\        }
    \\        const divs = document.querySelectorAll('div, section');
    \\        let best = null, bestLen = 0;
    \\        for (const div of divs) {
    \\            if (div.offsetHeight < 100) continue;
    \\            const text = div.textContent.trim();
    \\            if (text.length > bestLen) { bestLen = text.length; best = div; }
    \\        }
    \\        return best ? best.innerHTML : document.body.innerHTML;
    \\    }
    \\    return {
    \\        title: getMeta('title') || document.title || '',
    \\        byline: getByline(),
    \\        siteName: getSiteName(),
    \\        content: extractContent(),
    \\        url: document.URL,
    \\    };
    \\})()
;

fn runRead(io: std.Io, args: CliArgs, gpa: std.mem.Allocator) !void {
    const stdout = std.Io.File.stdout();
    const url = args.command orelse {
        try stdout.writeStreamingAll(io, "Usage: autocli read <url> [--format markdown|text|html|json] [--output <path>]\n");
        return;
    };
    const format_val = args.extra_args.get("format");
    const format: enum { markdown, text, html, json } = if (format_val) |f| blk: {
        if (f == .string) {
            if (std.mem.eql(u8, f.string, "text") or std.mem.eql(u8, f.string, "txt")) break :blk .text;
            if (std.mem.eql(u8, f.string, "html")) break :blk .html;
            if (std.mem.eql(u8, f.string, "json")) break :blk .json;
        }
        break :blk .markdown;
    } else .markdown;
    const output_path = if (args.extra_args.get("output")) |o| blk: {
        if (o == .string) break :blk o.string;
        break :blk null;
    } else null;

    // Connect to Chrome via CDP
    const CdpClient = @import("browser").CdpClient;
    const CdpPage = @import("browser").CdpPage;
    const discoverCdpWsUrl = @import("browser").discoverCdpWsUrl;

    const ws_url = discoverCdpWsUrl(gpa, io) catch |err| {
        try stdout.writeStreamingAll(io, "Failed to discover Chrome: ");
        try stdout.writeStreamingAll(io, @errorName(err));
        try stdout.writeStreamingAll(io, "\nTip: ensure Chrome is running with --remote-debugging-port=9222\n");
        return;
    };
    defer gpa.free(ws_url);

    // Parse ws://host:port/path
    const ws_rest = if (std.mem.startsWith(u8, ws_url, "ws://")) ws_url[5..] else ws_url;
    const host_end = std.mem.indexOfScalar(u8, ws_rest, ':') orelse ws_rest.len;
    const host = ws_rest[0..host_end];
    const port_path = ws_rest[host_end + 1 ..];
    const port_end = std.mem.indexOfScalar(u8, port_path, '/') orelse port_path.len;
    const port_str = port_path[0..port_end];
    const path = if (port_end < port_path.len) port_path[port_end..] else "/";
    const port = std.fmt.parseInt(u16, port_str, 10) catch 9222;

    var client = CdpClient.init(gpa, io, host, port, path) catch |err| {
        try stdout.writeStreamingAll(io, "Failed to connect CDP client: ");
        try stdout.writeStreamingAll(io, @errorName(err));
        try stdout.writeStreamingAll(io, "\n");
        return;
    };
    defer client.deinit();

    const ipage: @import("core").IPage = CdpPage.makeIPage(gpa, &client, false) catch |err| {
        try stdout.writeStreamingAll(io, "Page init failed: ");
        try stdout.writeStreamingAll(io, @errorName(err));
        try stdout.writeStreamingAll(io, "\n");
        return;
    };
    ipage.goto(url, null) catch |err| {
        try stdout.writeStreamingAll(io, "Navigation failed: ");
        try stdout.writeStreamingAll(io, @errorName(err));
        try stdout.writeStreamingAll(io, "\n");
        return;
    };
    ipage.waitForTimeout(3000) catch {};
    const result = ipage.evaluate(READ_ARTICLE_JS) catch |err| {
        try stdout.writeStreamingAll(io, "Article extraction failed: ");
        try stdout.writeStreamingAll(io, @errorName(err));
        try stdout.writeStreamingAll(io, "\n");
        return;
    };
    defer @import("core").freeJsonValue(gpa, result);
    if (result != .object) {
        try stdout.writeStreamingAll(io, "No article content found.\n");
        return;
    }
    const obj = result.object;
    const title = if (obj.get("title")) |v| blk: {
        if (v == .string) break :blk v.string;
        break :blk "";
    } else "";
    const byline = if (obj.get("byline")) |v| blk: {
        if (v == .string) break :blk v.string;
        break :blk "";
    } else "";
    const content = if (obj.get("content")) |v| blk: {
        if (v == .string) break :blk v.string;
        break :blk "";
    } else "";
    var output_buf = std.ArrayList(u8).empty;
    defer output_buf.deinit(gpa);
    switch (format) {
        .json => {
            const json_str = std.json.Stringify.valueAlloc(gpa, result, .{ .whitespace = .indent_2 }) catch "";
            defer gpa.free(json_str);
            try output_buf.appendSlice(gpa, json_str);
        },
        .html => try output_buf.appendSlice(gpa, content),
        .text => {
            try output_buf.appendSlice(gpa, title);
            try output_buf.appendSlice(gpa, "\n\n");
            if (byline.len > 0) {
                try output_buf.appendSlice(gpa, "By ");
                try output_buf.appendSlice(gpa, byline);
                try output_buf.appendSlice(gpa, "\n\n");
            }
            var in_tag = false;
            for (content) |c| {
                if (c == '<') in_tag = true;
                if (!in_tag) try output_buf.append(gpa, c);
                if (c == '>') in_tag = false;
            }
        },
        .markdown => {
            try output_buf.appendSlice(gpa, "# ");
            try output_buf.appendSlice(gpa, title);
            try output_buf.appendSlice(gpa, "\n\n");
            if (byline.len > 0) {
                try output_buf.appendSlice(gpa, "*By ");
                try output_buf.appendSlice(gpa, byline);
                try output_buf.appendSlice(gpa, "*\n\n");
            }
            var in_tag = false;
            var prev_nl = false;
            for (content) |c| {
                if (c == '<') {
                    in_tag = true;
                } else if (c == '>' and in_tag) {
                    in_tag = false;
                } else if (!in_tag) {
                    try output_buf.append(gpa, c);
                    prev_nl = c == '\n';
                }
            }
        },
    }
    try output_buf.append(gpa, '\n');
    if (output_path) |out_path| {
        std.Io.Dir.cwd().writeFile(io, .{ .sub_path = out_path, .data = output_buf.items }) catch |err| {
            try stdout.writeStreamingAll(io, "Failed to write output: ");
            try stdout.writeStreamingAll(io, @errorName(err));
            try stdout.writeStreamingAll(io, "\n");
            return;
        };
        const saved_msg = try std.fmt.allocPrint(gpa, "Saved to {s}\n", .{out_path});
        defer gpa.free(saved_msg);
        try stdout.writeStreamingAll(io, saved_msg);
    } else {
        try stdout.writeStreamingAll(io, output_buf.items);
    }
}
