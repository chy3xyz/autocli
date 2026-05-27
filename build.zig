const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Generate builtin adapters file before compiling
    generateBuiltinAdapters(b) catch |err| {
        std.log.err("Failed to generate builtin adapters: {s}", .{@errorName(err)});
        std.process.exit(1);
    };

    // Core 模块
    const core_mod = b.createModule(.{
        .root_source_file = b.path("src/core/mod.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Pipeline 模块（依赖 core）
    const pipeline_mod = b.createModule(.{
        .root_source_file = b.path("src/pipeline/mod.zig"),
        .target = target,
        .optimize = optimize,
    });
    pipeline_mod.addImport("core", core_mod);

    // Output 模块
    const output_mod = b.createModule(.{
        .root_source_file = b.path("src/output/mod.zig"),
        .target = target,
        .optimize = optimize,
    });
    output_mod.addImport("core", core_mod);

    // 主可执行文件模块
    const exe_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    exe_mod.addImport("core", core_mod);
    exe_mod.addImport("pipeline", pipeline_mod);
    exe_mod.addImport("output", output_mod);
    // Discovery 模块（依赖 core）
    const discovery_mod = b.createModule(.{
        .root_source_file = b.path("src/discovery/mod.zig"),
        .target = target,
        .optimize = optimize,
    });
    discovery_mod.addImport("core", core_mod);
    exe_mod.addImport("discovery", discovery_mod);
    // External 模块（依赖 core）
    const external_mod = b.createModule(.{
        .root_source_file = b.path("src/external/mod.zig"),
        .target = target,
        .optimize = optimize,
    });
    external_mod.addImport("core", core_mod);
    exe_mod.addImport("external", external_mod);
    // Browser 模块（依赖 core）
    const browser_mod = b.createModule(.{
        .root_source_file = b.path("src/browser/mod.zig"),
        .target = target,
        .optimize = optimize,
    });
    browser_mod.addImport("core", core_mod);
    exe_mod.addImport("browser", browser_mod);
    // AI 模块（依赖 core + browser + pipeline）
    const ai_mod = b.createModule(.{
        .root_source_file = b.path("src/ai/mod.zig"),
        .target = target,
        .optimize = optimize,
    });
    ai_mod.addImport("core", core_mod);
    ai_mod.addImport("browser", browser_mod);
    ai_mod.addImport("pipeline", pipeline_mod);
    exe_mod.addImport("ai", ai_mod);
    // CLI 模块（依赖 core + external + ai + discovery）
    const cli_mod = b.createModule(.{
        .root_source_file = b.path("src/cli/mod.zig"),
        .target = target,
        .optimize = optimize,
    });
    cli_mod.addImport("core", core_mod);
    cli_mod.addImport("external", external_mod);
    cli_mod.addImport("ai", ai_mod);
    cli_mod.addImport("discovery", discovery_mod);
    cli_mod.addImport("browser", browser_mod);
    exe_mod.addImport("cli", cli_mod);

    const exe = b.addExecutable(.{
        .name = "autocli",
        .root_module = exe_mod,
    });

    b.installArtifact(exe);

    // Run command
    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }
    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);

    // Tests
    const test_step = b.step("test", "Run unit tests");

    // 核心模块测试
    const core_tests = b.addTest(.{
        .name = "core_tests",
        .root_module = core_mod,
    });
    const run_core_tests = b.addRunArtifact(core_tests);
    test_step.dependOn(&run_core_tests.step);

    // Pipeline 模块测试
    const pipeline_tests = b.addTest(.{
        .name = "pipeline_tests",
        .root_module = pipeline_mod,
    });
    const run_pipeline_tests = b.addRunArtifact(pipeline_tests);
    test_step.dependOn(&run_pipeline_tests.step);

    // Output 模块测试
    const output_tests = b.addTest(.{
        .name = "output_tests",
        .root_module = output_mod,
    });
    const run_output_tests = b.addRunArtifact(output_tests);
    test_step.dependOn(&run_output_tests.step);
    // Discovery 模块测试
    const discovery_tests = b.addTest(.{
        .name = "discovery_tests",
        .root_module = discovery_mod,
    });
    const run_discovery_tests = b.addRunArtifact(discovery_tests);
    test_step.dependOn(&run_discovery_tests.step);

    // Security tests (core security functions)
    const security_tests_mod = b.createModule(.{
        .root_source_file = b.path("src/core/security.zig"),
        .target = target,
        .optimize = optimize,
    });
    const security_tests = b.addTest(.{
        .name = "security_tests",
        .root_module = security_tests_mod,
    });
    const run_security_tests = b.addRunArtifact(security_tests);
    test_step.dependOn(&run_security_tests.step);

    // Integration tests (pipeline + browser + core)
    const integration_tests_mod = b.createModule(.{
        .root_source_file = b.path("src/tests/integration.zig"),
        .target = target,
        .optimize = optimize,
    });
    integration_tests_mod.addImport("core", core_mod);
    integration_tests_mod.addImport("pipeline", pipeline_mod);
    integration_tests_mod.addImport("browser", browser_mod);
    const integration_tests = b.addTest(.{
        .name = "integration_tests",
        .root_module = integration_tests_mod,
    });
    const run_integration_tests = b.addRunArtifact(integration_tests);
    test_step.dependOn(&run_integration_tests.step);

}

const BuiltinAdapterEntry = struct { path: []const u8 };

/// Scan _def/AutoCLI/adapters/ and generate src/discovery/builtin_adapters.zig
/// so that builtin adapters can be embedded at compile time as string literals.
fn generateBuiltinAdapters(b: *std.Build) !void {
    const adapters_dir = "_def/AutoCLI/adapters";
    const output_path = "src/discovery/builtin_adapters.zig";
    const io = b.graph.io;

    // Check if adapters directory exists (gracefully skip if not found)
    std.Io.Dir.cwd().access(io, adapters_dir, .{}) catch {
        // No adapters directory — write empty placeholder
        const file = try std.Io.Dir.cwd().createFile(io, output_path, .{});
        defer file.close(io);
        try file.writeStreamingAll(io,
            \\pub const BuiltinAdapter = struct {
            \\    path: []const u8,
            \\    content: []const u8,
            \\};
            \\pub const adapters = [_]BuiltinAdapter{};
            \\
        );
        return;
    };

    var entries = std.ArrayList(BuiltinAdapterEntry).empty;
    defer {
        for (entries.items) |e| {
            b.allocator.free(e.path);
        }
        entries.deinit(b.allocator);
    }

    try collectYamlFiles(b.allocator, io, adapters_dir, adapters_dir, &entries);

    // Sort for deterministic output
    std.mem.sort(BuiltinAdapterEntry, entries.items, {}, struct {
        fn lessThan(_: void, a: BuiltinAdapterEntry, rhs: BuiltinAdapterEntry) bool {
            return std.mem.lessThan(u8, a.path, rhs.path);
        }
    }.lessThan);

    var code = std.ArrayList(u8).empty;
    defer code.deinit(b.allocator);

    try code.appendSlice(b.allocator,
        \\pub const BuiltinAdapter = struct {
        \\    path: []const u8,
        \\    content: []const u8,
        \\};
        \\
        \\pub const adapters = [_]BuiltinAdapter{
        \\
    );

    for (entries.items) |entry| {
        const full_path = try std.fs.path.join(b.allocator, &.{ adapters_dir, entry.path });
        defer b.allocator.free(full_path);

        const content = try readFileAlloc(b.allocator, io, full_path);
        defer b.allocator.free(content);

        try code.appendSlice(b.allocator, "    .{ .path = \"");
        try code.appendSlice(b.allocator, entry.path);
        try code.appendSlice(b.allocator, "\", .content = \"");

        // Escape content for Zig string literal
        for (content) |byte| {
            switch (byte) {
                '\\' => try code.appendSlice(b.allocator, "\\\\"),
                '"' => try code.appendSlice(b.allocator, "\\\""),
                '\n' => try code.appendSlice(b.allocator, "\\n"),
                '\r' => try code.appendSlice(b.allocator, "\\r"),
                '\t' => try code.appendSlice(b.allocator, "\\t"),
                else => try code.append(b.allocator, byte),
            }
        }

        try code.appendSlice(b.allocator, "\" },\n");
    }

    try code.appendSlice(b.allocator, "};\n");

    const file = try std.Io.Dir.cwd().createFile(io, output_path, .{});
    defer file.close(io);
    try file.writeStreamingAll(io, code.items);
}

fn collectYamlFiles(allocator: std.mem.Allocator, io: std.Io, base: []const u8, dir: []const u8, entries: *std.ArrayList(BuiltinAdapterEntry)) !void {
    var d = std.Io.Dir.cwd().openDir(io, dir, .{ .iterate = true }) catch return;
    defer d.close(io);

    var it = d.iterate();
    while (try it.next(io)) |entry| {
        const full_path = try std.fs.path.join(allocator, &.{ dir, entry.name });
        defer allocator.free(full_path);

        if (entry.kind == .directory) {
            try collectYamlFiles(allocator, io, base, full_path, entries);
        } else if (entry.kind == .file) {
            const ext = std.fs.path.extension(entry.name);
            if (std.mem.eql(u8, ext, ".yaml") or std.mem.eql(u8, ext, ".yml")) {
                const rel_path = full_path[base.len + 1 ..];
                const path_copy = try allocator.dupe(u8, rel_path);
                try entries.append(allocator, .{ .path = path_copy });
            }
        }
    }
}

fn readFileAlloc(allocator: std.mem.Allocator, io: std.Io, path: []const u8) ![]u8 {
    const file = try std.Io.Dir.cwd().openFile(io, path, .{});
    defer file.close(io);

    var tmp: [4096]u8 = undefined;
    var reader = file.reader(io, &tmp);
    return try reader.interface.allocRemaining(allocator, std.Io.Limit.unlimited);
}
