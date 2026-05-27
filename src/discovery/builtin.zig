const std = @import("std");
const CliError = @import("core").CliError;
const Registry = @import("core").Registry;
const freeCliCommand = @import("core").freeCliCommand;
const parseYamlAdapter = @import("yaml.zig").parseYamlAdapter;

const builtin_adapters = @import("builtin_adapters.zig").adapters;

/// Lightweight adapter metadata for list operations (no YAML parsing).
pub const AdapterMeta = struct {
    site: []const u8,
    name: []const u8,
};

/// Extract site/name from a path like "site/name.yaml".
/// Returns null if path format is unexpected.
fn metaFromPath(path: []const u8) ?AdapterMeta {
    const slash = std.mem.indexOfScalar(u8, path, '/');
    const dot = std.mem.lastIndexOfScalar(u8, path, '.');
    if (slash == null or dot == null) return null;
    const s = slash.?;
    const d = dot.?;
    if (s == 0 or d <= s + 1) return null;
    return .{ .site = path[0..s], .name = path[s + 1 .. d] };
}

/// Discover and register all built-in adapters into the registry.
/// Returns the number of adapters successfully registered.
pub fn discoverBuiltinAdapters(allocator: std.mem.Allocator, registry: *Registry) !usize {
    var count: usize = 0;
    for (builtin_adapters) |adapter| {
        const cmd = parseYamlAdapter(allocator, adapter.content) catch |err| {
            std.log.warn("Failed to parse builtin adapter {s}: {s}", .{ adapter.path, @errorName(err) });
            continue;
        };
        registry.register(cmd) catch |err| {
            std.log.warn("Failed to register builtin adapter {s}: {s}", .{ adapter.path, @errorName(err) });
            freeCliCommand(allocator, cmd);
            continue;
        };
        freeCliCommand(allocator, cmd);
        count += 1;
    }
    return count;
}

/// Fast list of built-in adapter metadata without YAML parsing.
/// The returned slice points into compile-time data; caller does not need to free items.
pub fn listBuiltinAdapters() []const AdapterMeta {
    return &builtin_meta;
}

const builtin_meta = blk: {
    @setEvalBranchQuota(10000);
    var meta: [builtin_adapters.len]AdapterMeta = undefined;
    for (builtin_adapters, 0..) |adapter, i| {
        if (metaFromPath(adapter.path)) |m| {
            meta[i] = m;
        } else {
            meta[i] = .{ .site = "unknown", .name = "unknown" };
        }
    }
    break :blk meta;
};
