const std = @import("std");
const json = @import("std").json;

/// Parsed CLI arguments
pub const CliArgs = struct {
    site: ?[]const u8 = null,
    command: ?[]const u8 = null,
    format: []const u8 = "table",
    limit: ?u32 = null,
    output: ?[]const u8 = null,
    version_flag: bool = false,
    verbose: bool = false,
    step: bool = false,
    sandbox: bool = false,
    extra_args: std.StringHashMap(json.Value),
};

/// Parse raw arguments into structured CliArgs
pub fn parseArgs(allocator: std.mem.Allocator, raw_args: [][]const u8) !CliArgs {
    var args = CliArgs{
        .extra_args = std.StringHashMap(json.Value).init(allocator),
    };

    var i: usize = 0;
    while (i < raw_args.len) : (i += 1) {
        const arg = raw_args[i];

        // Handle --key=value format
        if (std.mem.startsWith(u8, arg, "--")) {
            if (std.mem.indexOfScalar(u8, arg, '=')) |eq| {
                const key = arg[0..eq];
                const value = arg[eq + 1..];
                if (std.mem.eql(u8, key, "--format")) {
                    args.format = value;
                } else if (std.mem.eql(u8, key, "--limit")) {
                    args.limit = try std.fmt.parseInt(u32, value, 10);
                } else if (std.mem.eql(u8, key, "--output")) {
                    args.output = value;
                } else if (std.mem.eql(u8, key, "--shell")) {
                    try args.extra_args.put("shell", json.Value{ .string = value });
                } else {
                    try args.extra_args.put(key[2..], json.Value{ .string = value });
                }
                continue;
            }
        }

        if (std.mem.eql(u8, arg, "--format") or std.mem.eql(u8, arg, "-f")) {
            if (i + 1 < raw_args.len) {
                args.format = raw_args[i + 1];
                i += 1;
            }
        } else if (std.mem.eql(u8, arg, "--limit") or std.mem.eql(u8, arg, "-l")) {
            if (i + 1 < raw_args.len) {
                const limit_str = raw_args[i + 1];
                args.limit = try std.fmt.parseInt(u32, limit_str, 10);
                i += 1;
            }
        } else if (std.mem.eql(u8, arg, "--output") or std.mem.eql(u8, arg, "-o")) {
            if (i + 1 < raw_args.len) {
                args.output = raw_args[i + 1];
                i += 1;
            }
        } else if (std.mem.eql(u8, arg, "--shell")) {
            if (i + 1 < raw_args.len) {
                try args.extra_args.put("shell", json.Value{ .string = raw_args[i + 1] });
                i += 1;
            }
        } else if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            // Handled by caller
        } else if (std.mem.eql(u8, arg, "--version") or std.mem.eql(u8, arg, "-v")) {
            args.version_flag = true;
        } else if (std.mem.eql(u8, arg, "--verbose")) {
            args.verbose = true;
        } else if (std.mem.eql(u8, arg, "--step")) {
            args.step = true;
        } else if (std.mem.eql(u8, arg, "--sandbox")) {
            args.sandbox = true;
        } else if (args.site == null) {
            args.site = arg;
        } else if (args.command == null) {
            args.command = arg;
        } else {
            // Extra positional args as key=value
            if (std.mem.indexOfScalar(u8, arg, '=')) |eq| {
                const key = arg[0..eq];
                const value = arg[eq + 1..];
                try args.extra_args.put(key, json.Value{ .string = value });
            }
        }
    }

    return args;
}
