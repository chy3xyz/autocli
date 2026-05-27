const std = @import("std");
const json = @import("std").json;
const CliArgs = @import("cli").CliArgs;
const parseArgs = @import("cli").parseArgs;
const BuiltinCommand = @import("cli").BuiltinCommand;
const BuiltinContext = @import("cli").BuiltinContext;
const runBuiltin = @import("cli").runBuiltin;
const discovery = @import("discovery");
const pipeline_mod = @import("pipeline");
const StepRegistry = pipeline_mod.StepRegistry;
const StepHandler = pipeline_mod.StepHandler;
const PipelineContext = pipeline_mod.PipelineContext;
const executePipeline = pipeline_mod.executePipeline;
const PipelineOptions = pipeline_mod.PipelineOptions;
const ExecutionMetrics = pipeline_mod.ExecutionMetrics;
const freeJsonValue = pipeline_mod.freeJsonValue;
const FetchStepState = pipeline_mod.FetchStepState;
const registerFetchSteps = pipeline_mod.registerFetchSteps;
const registerTransformSteps = pipeline_mod.registerTransformSteps;
const registerBrowserSteps = pipeline_mod.registerBrowserSteps;
const registerDownloadSteps = pipeline_mod.registerDownloadSteps;
const OutputFormat = @import("output/format.zig").OutputFormat;
const RenderOptions = @import("output/format.zig").RenderOptions;
const render = @import("output/render.zig").render;
const core = @import("core");
const CliError = core.CliError;
const IPage = core.IPage;
const errorIcon = core.errorIcon;
const errorCode = core.errorCode;
const castToCliError = core.castToCliError;
const extCli = @import("cli/external.zig");
const BrowserBridge = @import("browser").BrowserBridge;
const Daemon = @import("browser").Daemon;
const SandboxPage = @import("browser").SandboxPage;

var shutdown_requested = false;

fn setupSignalHandlers() void {
    const SIGTERM: std.posix.SIG = @enumFromInt(15);
    const SIGINT: std.posix.SIG = @enumFromInt(2);
    var sa_term: std.posix.Sigaction = .{
        .handler = .{ .handler = struct {
            fn f(sig: std.posix.SIG) callconv(.c) void {
                _ = sig;
                @atomicStore(bool, &shutdown_requested, true, .release);
            }
        }.f },
        .flags = 0,
        .mask = 0,
    };
    std.posix.sigaction(SIGTERM, &sa_term, null);
    var sa_int: std.posix.Sigaction = .{
        .handler = .{ .handler = struct {
            fn f(sig: std.posix.SIG) callconv(.c) void {
                _ = sig;
                @atomicStore(bool, &shutdown_requested, true, .release);
            }
        }.f },
        .flags = 0,
        .mask = 0,
    };
    std.posix.sigaction(SIGINT, &sa_int, null);
}

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const gpa = init.gpa;
    const environ_map = init.environ_map;

    setupSignalHandlers();

    // Convert raw args to slice of strings
    var args_list: [16][]const u8 = undefined;
    var count: usize = 0;
    for (init.minimal.args.vector[1..]) |arg| {
        if (count >= 16) break;
        args_list[count] = std.mem.sliceTo(arg, 0);
        count += 1;
    }

    // Check for daemon mode before normal arg parsing
    for (args_list[0..count]) |arg| {
        if (std.mem.eql(u8, arg, "--daemon")) {
            const port = getDaemonPort(environ_map);
            var daemon = try Daemon.init(gpa, io, port);
            defer daemon.deinit();
            try daemon.run();
            return;
        }
    }

    var args = try parseArgs(gpa, args_list[0..count]);
    defer {
        var it = args.extra_args.iterator();
        while (it.next()) |entry| {
            gpa.free(entry.key_ptr.*);
        }
        args.extra_args.deinit();
    }

    // Detect verbose mode from env or flag
    const verbose = args.verbose or
        environ_map.get("OPENCLI_VERBOSE") != null or
        environ_map.get("AUTOCLI_VERBOSE") != null;
    if (verbose) {
        @import("core").http_util.http_logging_enabled = true;
    }

    // Handle --version
    if (args.version_flag) {
        try printVersion(io);
        return;
    }

    // Handle --help / no site given
    if (args.site == null) {
        try printUsage(io);
        return;
    }

    // Check for built-in commands
    const builtin_ctx = BuiltinContext{ .environ_map = environ_map, .registry = null };

    if (std.mem.eql(u8, args.site.?, "list")) {
        // list command uses fast metadata path (no YAML parsing)
        try runBuiltin(io, .list, args, gpa, builtin_ctx);
        return;
    }
    if (std.mem.eql(u8, args.site.?, "doctor")) {
        try runBuiltin(io, .doctor, args, gpa, builtin_ctx);
        return;
    }
    if (std.mem.eql(u8, args.site.?, "completion")) {
        try runBuiltin(io, .completion, args, gpa, builtin_ctx);
        return;
    }
    if (std.mem.eql(u8, args.site.?, "help")) {
        try runBuiltin(io, .help, args, gpa, builtin_ctx);
        return;
    }
    if (std.mem.eql(u8, args.site.?, "auth")) {
        try runBuiltin(io, .auth, args, gpa, builtin_ctx);
        return;
    }
    if (std.mem.eql(u8, args.site.?, "search")) {
        try runBuiltin(io, .search, args, gpa, builtin_ctx);
        return;
    }
    if (std.mem.eql(u8, args.site.?, "generate")) {
        try runBuiltin(io, .generate, args, gpa, builtin_ctx);
        return;
    }
    if (std.mem.eql(u8, args.site.?, "read")) {
        try runBuiltin(io, .read, args, gpa, builtin_ctx);
        return;
    }

    // Check for external CLI passthrough (gh, docker, kubectl, etc.)
    {
        const exec_args = args_list[0..count];
        const handled = extCli.tryExecuteExternalCli(gpa, io, environ_map, exec_args, false) catch |err| {
            try printError(io, gpa, err, "failed to execute external CLI");
            std.process.exit(1);
        };
        if (handled) return;
    }

    // Load adapter and execute pipeline
    executeSiteCommand(io, gpa, args, environ_map, verbose) catch |err| {
        try printError(io, gpa, err, "command execution failed");
        std.process.exit(1);
    };
}

fn logVerbose(io: std.Io, comptime fmt: []const u8, args: anytype) void {
    const stderr = std.Io.File.stderr();
    var buf: [512]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, "[verbose] " ++ fmt ++ "\n", args) catch return;
    stderr.writeStreamingAll(io, msg) catch {};
}

fn isShutdownRequested() bool {
    return @atomicLoad(bool, &shutdown_requested, .acquire);
}

fn executeSiteCommand(io: std.Io, gpa: std.mem.Allocator, args: CliArgs, environ_map: *const std.process.Environ.Map, verbose: bool) !void {
    if (isShutdownRequested()) {
        std.log.warn("interrupted by signal", .{});
        std.process.exit(130);
    }

    const stdout = std.Io.File.stdout();
    const site = args.site.?;
    const command = args.command orelse {
        try printError(io, gpa, CliError.CommandExecution, "command required");
        return;
    };

    if (!core.isSafePathComponent(site) or !core.isSafePathComponent(command)) {
        try printError(io, gpa, CliError.Argument, "invalid site or command name");
        return;
    }

    if (verbose) logVerbose(io, "site={s} command={s}", .{ site, command });

    // Try loading adapter in priority order: user overrides → builtins
    // 1. ~/.autocli/adapters/{site}/{command}.yaml
    // 2. ~/.autocli/adapters/{site}_{command}.yaml
    // 3. _def/AutoCLI/adapters/{site}/{command}.yaml
    const home = environ_map.get("HOME") orelse ".";

    const user_path1 = try std.fmt.allocPrint(gpa, "{s}/.autocli/adapters/{s}/{s}.yaml", .{ home, site, command });
    defer gpa.free(user_path1);
    const user_path2 = try std.fmt.allocPrint(gpa, "{s}/.autocli/adapters/{s}_{s}.yaml", .{ home, site, command });
    defer gpa.free(user_path2);
    const builtin_path = try std.fmt.allocPrint(gpa, "_def/AutoCLI/adapters/{s}/{s}.yaml", .{ site, command });
    defer gpa.free(builtin_path);

    var adapter_content: ?[]u8 = tryLoadFile(io, gpa, user_path1);
    if (adapter_content == null) adapter_content = tryLoadFile(io, gpa, user_path2);
    if (adapter_content == null) adapter_content = tryLoadFile(io, gpa, builtin_path);

    const loaded = adapter_content orelse {
        try printError(io, gpa, CliError.AdapterLoad, "adapter not found");
        return;
    };
    defer gpa.free(loaded);

    if (verbose) logVerbose(io, "adapter loaded ({d} bytes)", .{loaded.len});

    // Parse adapter
    const cmd = discovery.parseYamlAdapter(gpa, loaded) catch |err| {
        try printError(io, gpa, err, "failed to parse adapter");
        return;
    };
    defer {
        gpa.free(cmd.site);
        gpa.free(cmd.name);
        gpa.free(cmd.description);
        if (cmd.domain) |d| gpa.free(d);
        for (cmd.columns) |col| gpa.free(col);
        gpa.free(cmd.columns);
        for (cmd.args) |arg| {
            gpa.free(arg.name);
            if (arg.description) |desc| gpa.free(desc);
            if (arg.choices) |choices| {
                for (choices) |c| gpa.free(c);
                gpa.free(choices);
            }
            if (arg.default) |default_val| freeJsonValue(gpa, default_val);
        }
        gpa.free(cmd.args);
        if (cmd.pipeline) |pipeline| {
            for (pipeline) |step| freeJsonValue(gpa, step);
            gpa.free(pipeline);
        }
    }

    if (verbose) logVerbose(io, "strategy={s} needs_browser={}", .{@tagName(cmd.strategy), cmd.needsBrowser()});

    // Build args hashmap from CLI args and defaults
    var pipeline_args = std.StringHashMap(json.Value).init(gpa);
    defer pipeline_args.deinit();

    // Add default args from adapter (only if not already provided)
    for (cmd.args) |arg_def| {
        if (arg_def.default) |default_val| {
            if (!pipeline_args.contains(arg_def.name)) {
                try pipeline_args.put(arg_def.name, default_val);
            }
        }
    }

    // Override with provided CLI args
    var it = args.extra_args.iterator();
    while (it.next()) |entry| {
        try pipeline_args.put(entry.key_ptr.*, entry.value_ptr.*);
    }

    // Add -l/--limit flag as 'limit' in pipeline_args
    if (args.limit) |limit_val| {
        try pipeline_args.put("limit", json.Value{ .integer = @as(i64, limit_val) });
    }

    // Create step registry
    var registry = StepRegistry.init(gpa);
    defer registry.deinit();

    // Create fetch step state
    var fetch_state = FetchStepState{
        .allocator = gpa,
        .client = .{ .allocator = gpa, .io = io },
    };

    // Register all steps (fetch + transform + browser)
    registerFetchSteps(&registry, &fetch_state) catch |err| {
        try printError(io, gpa, err, "failed to register fetch steps");
        return;
    };

    registerTransformSteps(&registry) catch |err| {
        try printError(io, gpa, err, "failed to register transform steps");
        return;
    };

    registerBrowserSteps(&registry) catch |err| {
        try printError(io, gpa, err, "failed to register browser steps");
        return;
    };

    registerDownloadSteps(&registry) catch |err| {
        try printError(io, gpa, err, "failed to register download steps");
        return;
    };

    // Execute pipeline if present
    if (cmd.pipeline) |pipeline| {
        var maybe_page: ?IPage = null;
        var sandbox_storage: ?SandboxPage = null;
        defer if (maybe_page) |page| {
            page.close() catch |err| {
                std.log.warn("page.close failed: {s}", .{@errorName(err)});
            };
        };

        if (cmd.needsBrowser()) {
            if (args.sandbox) {
                if (verbose) logVerbose(io, "sandbox mode: skipping browser connection", .{});
                sandbox_storage = SandboxPage.init(gpa, io);
                maybe_page = sandbox_storage.?.makeIPage();
            } else {
                if (verbose) logVerbose(io, "connecting browser...", .{});
                var bridge = BrowserBridge.init(gpa, io, 19825);
                maybe_page = try bridge.connect();
                if (verbose) logVerbose(io, "browser connected", .{});
            }

            // Pre-navigate to domain if set, but ONLY if the pipeline doesn't
            // start with its own navigate step (to avoid double navigation).
            var pipeline_starts_with_navigate = false;
            if (pipeline.len > 0) {
                const first_step = pipeline[0];
                if (first_step == .object) {
                    pipeline_starts_with_navigate = first_step.object.contains("navigate");
                }
            }

            if (!pipeline_starts_with_navigate) {
                if (cmd.domain) |domain| {
                    const url = try std.fmt.allocPrint(gpa, "https://{s}", .{domain});
                    defer gpa.free(url);
                    if (verbose) logVerbose(io, "pre-navigate to {s}", .{url});
                    try maybe_page.?.goto(url, null);
                }
            }
        }

        if (verbose) logVerbose(io, "executing pipeline ({d} steps)", .{pipeline.len});
        const timeout_ms = getCommandTimeoutMs(environ_map);
        var metrics = ExecutionMetrics.init(gpa);
        defer metrics.deinit();
        const result = executePipeline(gpa, io, maybe_page, pipeline, pipeline_args, &registry, .{ .timeout_ms = timeout_ms, .step_mode = args.step }, &metrics) catch |err| {
            try printError(io, gpa, err, "pipeline execution failed");
            return;
        };
        defer freeJsonValue(gpa, result);
        if (verbose) {
            logVerbose(io, "pipeline completed", .{});
            metrics.printSummary(io);
        }

        // Render output
        const format = OutputFormat.fromString(args.format);
        const render_opts = RenderOptions{
            .format = format orelse .table,
            .columns = cmd.columns,
            .title = null,
            .elapsed_ms = null,
            .source = null,
            .footer_extra = null,
        };

        const output = render(gpa, result, render_opts) catch |err| {
            try printError(io, gpa, err, "rendering failed");
            return;
        };
        defer gpa.free(output);
        if (verbose) logVerbose(io, "output rendered ({d} bytes)", .{output.len});

        // Write to file or stdout
        if (args.output) |output_path| {
            if (std.mem.indexOf(u8, output_path, "..") != null or std.mem.startsWith(u8, output_path, "/")) {
                try printError(io, gpa, CliError.Argument, "invalid output path");
                return;
            }
            if (verbose) logVerbose(io, "writing output to {s}", .{output_path});
            const file = std.Io.Dir.cwd().createFile(io, output_path, .{}) catch |err| {
                try printError(io, gpa, err, "failed to create output file");
                return;
            };
            defer file.close(io);
            try file.writeStreamingAll(io, output);
        } else {
            try stdout.writeStreamingAll(io, output);
        }
    } else {
        try stdout.writeStreamingAll(io, "No pipeline defined for this command.\n");
    }
}

/// Try to load a file, returning null if not found or on error
fn tryLoadFile(io: std.Io, gpa: std.mem.Allocator, path: []const u8) ?[]u8 {
    const dir = std.Io.Dir.cwd();
    return dir.readFileAlloc(io, path, gpa, @as(std.Io.Limit, @enumFromInt(1024 * 1024))) catch null;
}

fn printVersion(io: std.Io) !void {
    const stdout = std.Io.File.stdout();
    try stdout.writeStreamingAll(io, "autocli 0.1.0 (zig 0.16.0)\n");
}

fn printUsage(io: std.Io) !void {
    const stdout = std.Io.File.stdout();
    try stdout.writeStreamingAll(io,
        \\autocli - AI-driven CLI tool
        \\
        \\Usage: autocli <site> <command> [options]
        \\       autocli <builtin> [options]
        \\
        \\Builtins:
        \\  list        List available sites and commands
        \\  doctor      Run diagnostics
        \\  completion  Generate shell completions
        \\  help        Show this help message
        \\
        \\Options:
        \\  -h, --help       Show this help message
        \\  -v, --version    Show version information
        \\  -f, --format     Output format: table, json, yaml, csv, md
        \\  -l, --limit      Limit number of results
        \\  -o, --output      Write output to file
        \\
        \\Examples:
        \\  autocli list
        \\  autocli doctor
        \\  autocli hackernews top --limit 10
        \\  autocli hackernews top --format json
        \\
    );
}

const ANSI_RED = "\x1b[31m";
const ANSI_BOLD = "\x1b[1m";
const ANSI_RESET = "\x1b[0m";

/// Print a rich error message with icon, error code, and ANSI colors
fn printError(io: std.Io, gpa: std.mem.Allocator, err: anyerror, message: []const u8) !void {
    const stderr = std.Io.File.stderr();
    const err_name = @errorName(err);

    const cli_err = castToCliError(err);
    const icon = if (cli_err) |ce| errorIcon(ce) else "❌";
    const code = if (cli_err) |ce| errorCode(ce) else "UNKNOWN";

    const formatted = try std.fmt.allocPrint(gpa,
        "{s}{s}{s} [{s}{s}{s}] {s}{s}{s}: {s}\n",
        .{ ANSI_BOLD, icon, ANSI_RESET, ANSI_BOLD, code, ANSI_RESET, ANSI_RED, message, ANSI_RESET, err_name },
    );
    defer gpa.free(formatted);

    try stderr.writeStreamingAll(io, formatted);
}

fn getDaemonPort(environ_map: *const std.process.Environ.Map) u16 {
    if (environ_map.get("AUTOCLI_DAEMON_PORT")) |port_str| {
        return std.fmt.parseInt(u16, port_str, 10) catch 19825;
    }
    if (environ_map.get("OPENCLI_DAEMON_PORT")) |port_str| {
        return std.fmt.parseInt(u16, port_str, 10) catch 19825;
    }
    return 19825;
}

fn getCommandTimeoutMs(environ_map: *const std.process.Environ.Map) u64 {
    if (environ_map.get("AUTOCLI_BROWSER_COMMAND_TIMEOUT")) |val| {
        return std.fmt.parseInt(u64, val, 10) catch 120;
    }
    if (environ_map.get("OPENCLI_BROWSER_COMMAND_TIMEOUT")) |val| {
        return std.fmt.parseInt(u64, val, 10) catch 120;
    }
    return 120_000; // 120 seconds default
}
