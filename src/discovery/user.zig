const std = @import("std");
const CliCommand = @import("core").CliCommand;
const Registry = @import("core").Registry;
const freeCliCommand = @import("core").freeCliCommand;
const parseYamlAdapter = @import("yaml.zig").parseYamlAdapter;
const AdapterMeta = @import("builtin.zig").AdapterMeta;

/// Load all user adapters from ~/.autocli/adapters/ into the registry.
/// Scans both directory formats:
///   ~/.autocli/adapters/{site}/{command}.yaml  (nested)
///   ~/.autocli/adapters/{site}_{command}.yaml  (flat)
/// User adapters override built-in adapters with the same site+name.
pub fn loadUserAdapters(
    allocator: std.mem.Allocator,
    io: std.Io,
    environ_map: *const std.process.Environ.Map,
    registry: *Registry,
) !usize {
    const home = environ_map.get("HOME") orelse return 0;

    const adapters_dir = try std.fmt.allocPrint(allocator, "{s}/.autocli/adapters", .{home});
    defer allocator.free(adapters_dir);

    var count: usize = 0;

    // 1. Scan nested format: ~/.autocli/adapters/{site}/{command}.yaml
    var site_dir = std.Io.Dir.cwd().openDir(io, adapters_dir, .{ .iterate = true }) catch return 0;
    defer site_dir.close(io);

    var site_iter = site_dir.iterate();
    while (site_iter.next(io) catch null) |site_entry| {
        if (site_entry.kind != .directory) continue;
        // Skip hidden dirs
        if (site_entry.name.len > 0 and site_entry.name[0] == '.') continue;

        const site_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ adapters_dir, site_entry.name });
        defer allocator.free(site_path);

        var cmd_dir = site_dir.openDir(io, site_entry.name, .{ .iterate = true }) catch continue;
        defer cmd_dir.close(io);

        var cmd_iter = cmd_dir.iterate();
        while (cmd_iter.next(io) catch null) |cmd_entry| {
            if (cmd_entry.kind != .file) continue;
            const name = cmd_entry.name;
            // Only process .yaml and .yml files
            if (!std.mem.endsWith(u8, name, ".yaml") and !std.mem.endsWith(u8, name, ".yml")) continue;

            const cmd_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ site_path, name });
            defer allocator.free(cmd_path);

            if (loadAndRegister(allocator, io, registry, cmd_path)) |added| {
                if (added) count += 1;
            } else |_| {
                // Skip malformed adapters silently — user can fix them later
                continue;
            }
        }
    }

    // 2. Scan flat format: ~/.autocli/adapters/{site}_{command}.yaml
    // Re-open the directory for flat files
    var flat_dir = std.Io.Dir.cwd().openDir(io, adapters_dir, .{ .iterate = true }) catch return count;
    defer flat_dir.close(io);

    var flat_iter = flat_dir.iterate();
    while (flat_iter.next(io) catch null) |entry| {
        if (entry.kind != .file) continue;
        const name = entry.name;
        if (!std.mem.endsWith(u8, name, ".yaml") and !std.mem.endsWith(u8, name, ".yml")) continue;
        // Must contain underscore to be a flat-format adapter
        if (std.mem.indexOfScalar(u8, name, '_') == null) continue;

        const file_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ adapters_dir, name });
        defer allocator.free(file_path);

        if (loadAndRegister(allocator, io, registry, file_path)) |added| {
            if (added) count += 1;
        } else |_| {
            continue;
        }
    }

    return count;
}

/// Fast list of user adapter metadata without YAML parsing.
/// Caller owns returned slice and its inner strings; free with freeAdapterMetaList.
pub fn listUserAdapters(
    allocator: std.mem.Allocator,
    io: std.Io,
    environ_map: *const std.process.Environ.Map,
) ![]AdapterMeta {
    const home = environ_map.get("HOME") orelse return &[0]AdapterMeta{};

    const adapters_dir = try std.fmt.allocPrint(allocator, "{s}/.autocli/adapters", .{home});
    defer allocator.free(adapters_dir);

    var list = std.ArrayList(AdapterMeta).empty;
    errdefer freeAdapterMetaList(allocator, list.items);

    // 1. Scan nested format
    var site_dir = std.Io.Dir.cwd().openDir(io, adapters_dir, .{ .iterate = true }) catch return list.toOwnedSlice(allocator);
    defer site_dir.close(io);

    var site_iter = site_dir.iterate();
    while (site_iter.next(io) catch null) |site_entry| {
        if (site_entry.kind != .directory) continue;
        if (site_entry.name.len > 0 and site_entry.name[0] == '.') continue;

        var cmd_dir = site_dir.openDir(io, site_entry.name, .{ .iterate = true }) catch continue;
        defer cmd_dir.close(io);

        var cmd_iter = cmd_dir.iterate();
        while (cmd_iter.next(io) catch null) |cmd_entry| {
            if (cmd_entry.kind != .file) continue;
            const name = cmd_entry.name;
            if (!std.mem.endsWith(u8, name, ".yaml") and !std.mem.endsWith(u8, name, ".yml")) continue;

            const dot = std.mem.lastIndexOfScalar(u8, name, '.') orelse continue;
            const cmd_name = try allocator.dupe(u8, name[0..dot]);
            errdefer allocator.free(cmd_name);
            const site_name = try allocator.dupe(u8, site_entry.name);
            errdefer allocator.free(site_name);
            try list.append(allocator, .{ .site = site_name, .name = cmd_name });
        }
    }

    // 2. Scan flat format
    var flat_dir = std.Io.Dir.cwd().openDir(io, adapters_dir, .{ .iterate = true }) catch return list.toOwnedSlice(allocator);
    defer flat_dir.close(io);

    var flat_iter = flat_dir.iterate();
    while (flat_iter.next(io) catch null) |entry| {
        if (entry.kind != .file) continue;
        const name = entry.name;
        if (!std.mem.endsWith(u8, name, ".yaml") and !std.mem.endsWith(u8, name, ".yml")) continue;
        if (std.mem.indexOfScalar(u8, name, '_') == null) continue;

        const dot = std.mem.lastIndexOfScalar(u8, name, '.') orelse continue;
        const underscore = std.mem.indexOfScalar(u8, name, '_') orelse continue;
        const site_name = try allocator.dupe(u8, name[0..underscore]);
        errdefer allocator.free(site_name);
        const cmd_name = try allocator.dupe(u8, name[underscore + 1 .. dot]);
        errdefer allocator.free(cmd_name);
        try list.append(allocator, .{ .site = site_name, .name = cmd_name });
    }

    return list.toOwnedSlice(allocator);
}

/// Free a slice of AdapterMeta allocated by listUserAdapters.
pub fn freeAdapterMetaList(allocator: std.mem.Allocator, list: []const AdapterMeta) void {
    for (list) |m| {
        allocator.free(m.site);
        allocator.free(m.name);
    }
    allocator.free(list);
}

/// Load a single adapter file and register it. Returns true if registered.
fn loadAndRegister(allocator: std.mem.Allocator, io: std.Io, registry: *Registry, path: []const u8) !bool {
    const content = std.Io.Dir.cwd().readFileAlloc(io, path, allocator, @as(std.Io.Limit, @enumFromInt(1024 * 1024))) catch return false;
    defer allocator.free(content);

    const cmd = parseYamlAdapter(allocator, content) catch return false;
    registry.register(cmd) catch return false;
    freeCliCommand(allocator, cmd);
    return true;
}
