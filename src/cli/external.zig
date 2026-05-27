const std = @import("std");
const CliError = @import("core").CliError;
const ExternalCliRegistry = @import("external").ExternalCliRegistry;

/// 尝试执行外部 CLI 命令
/// 返回 true 表示已处理（已找到并执行），false 表示未找到外部 CLI
pub fn tryExecuteExternalCli(
    allocator: std.mem.Allocator,
    io: std.Io,
    environ_map: *const std.process.Environ.Map,
    args: []const []const u8,
    verbose: bool,
) !bool {
    if (args.len < 1) return false;
    const name = args[0];

    var registry = ExternalCliRegistry.load(allocator, io, environ_map);
    defer registry.deinit();

    const entry = registry.findByName(name) orelse return false;

    if (verbose) {
        const stderr = std.Io.File.stderr();
        stderr.writeStreamingAll(io, "[external] Passthrough: ") catch {};
        stderr.writeStreamingAll(io, entry.name) catch {};
        stderr.writeStreamingAll(io, "\n") catch {};
    }

    const ok = entry.execute(allocator, io, args[1..]) catch {
        if (verbose) {
            const stderr = std.Io.File.stderr();
            stderr.writeStreamingAll(io, "[external] Failed to run command\n") catch {};
        }
        return CliError.ExternalCli;
    };

    if (!ok) return CliError.ExternalCli;
    return true;
}
