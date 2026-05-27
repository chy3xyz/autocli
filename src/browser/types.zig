const std = @import("std");
const json = @import("std").json;

/// Daemon command sent from CLI to extension via daemon
pub const DaemonCommand = struct {
    id: []const u8,
    method: []const u8,
    params: json.Value,
    tab_id: ?[]const u8 = null,
};

/// Daemon result returned from extension to CLI via daemon
pub const DaemonResult = struct {
    id: []const u8,
    ok: bool,
    result: ?json.Value = null,
    @"error": ?[]const u8 = null,

    pub fn success(id: []const u8, result: json.Value) DaemonResult {
        return .{
            .id = id,
            .ok = true,
            .result = result,
            .@"error" = null,
        };
    }

    pub fn failure(id: []const u8, @"error": []const u8) DaemonResult {
        return .{
            .id = id,
            .ok = false,
            .result = null,
            .@"error" = @"error",
        };
    }
};

/// Daemon status response
pub const DaemonStatus = struct {
    daemon: bool,
    extension: bool,
    pending: usize = 0,
};

/// Port number for daemon communication
pub const DEFAULT_DAEMON_PORT: u16 = 19825;