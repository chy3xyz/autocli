const std = @import("std");
const json = @import("std").json;
const CliError = @import("core").CliError;
const IPage = @import("core").IPage;
const StepRegistry = @import("registry.zig").StepRegistry;

const MAX_BROWSER_ATTEMPTS = 3;
const DEFAULT_TIMEOUT_MS = 120_000; // 2 minutes

/// Recursively free a json.Value and all nested allocations.
/// Safe to call on .null / .bool / .integer / .float (no-op).
pub fn freeJsonValue(allocator: std.mem.Allocator, val: json.Value) void {
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

/// Deep clone a json.Value so the clone is independently owned.
/// All string allocations are duplicated with the given allocator.
pub fn cloneJsonValue(allocator: std.mem.Allocator, val: json.Value) !json.Value {
    switch (val) {
        .null, .bool, .integer, .float, .number_string => return val,
        .string => |s| return .{ .string = try allocator.dupe(u8, s) },
        .array => |arr| {
            var items = std.ArrayListUnmanaged(json.Value){ .items = &.{}, .capacity = 0 };
            defer items.deinit(allocator);
            for (arr.items) |item| {
                const cloned = try cloneJsonValue(allocator, item);
                try items.append(allocator, cloned);
            }
            return .{ .array = std.array_list.Managed(json.Value){ .items = items.items, .capacity = items.capacity, .allocator = allocator } };
        },
        .object => |obj| {
            var new_obj = json.ObjectMap.init(allocator, &[_][]const u8{}, &[_]json.Value{}) catch return error.OutOfMemory;
            errdefer new_obj.deinit(allocator);
            var it = obj.iterator();
            while (it.next()) |entry| {
                const key_copy = try allocator.dupe(u8, entry.key_ptr.*);
                const value_copy = try cloneJsonValue(allocator, entry.value_ptr.*);
                try new_obj.put(allocator, key_copy, value_copy);
            }
            return .{ .object = new_obj };
        },
    }
}

pub const PipelineOptions = struct {
    timeout_ms: u64 = DEFAULT_TIMEOUT_MS,
    step_mode: bool = false,
};

/// Execution metrics collected during a pipeline run.
pub const ExecutionMetrics = struct {
    total_steps: usize = 0,
    total_duration_ms: u64 = 0,
    browser_retries: usize = 0,
    step_counts: std.StringHashMap(usize),

    pub fn init(allocator: std.mem.Allocator) ExecutionMetrics {
        return .{ .step_counts = std.StringHashMap(usize).init(allocator) };
    }

    pub fn deinit(self: *ExecutionMetrics) void {
        var it = self.step_counts.iterator();
        while (it.next()) |entry| {
            self.step_counts.allocator.free(entry.key_ptr.*);
        }
        self.step_counts.deinit();
    }

    pub fn recordStep(self: *ExecutionMetrics, allocator: std.mem.Allocator, name: []const u8, retries: usize) !void {
        self.total_steps += 1;
        self.browser_retries += retries;
        const gop = try self.step_counts.getOrPut(name);
        if (gop.found_existing) {
            gop.value_ptr.* += 1;
        } else {
            gop.key_ptr.* = try allocator.dupe(u8, name);
            gop.value_ptr.* = 1;
        }
    }

    pub fn printSummary(self: *const ExecutionMetrics, io: std.Io) void {
        const stdout = std.Io.File.stdout();
        var buf: [256]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "\nPipeline summary: {d} steps, {d}ms, {d} browser retries\n", .{
            self.total_steps,
            self.total_duration_ms,
            self.browser_retries,
        }) catch return;
        _ = stdout.writeStreamingAll(io, msg) catch {};
    }
};

pub fn executePipeline(
    allocator: std.mem.Allocator,
    io: std.Io,
    page: ?IPage,
    pipeline: []const json.Value,
    args: std.StringHashMap(json.Value),
    registry: *const StepRegistry,
    options: PipelineOptions,
    metrics: ?*ExecutionMetrics,
) CliError!json.Value {
    var data: json.Value = .null;
    const start = std.Io.Timestamp.now(io, .real);

    for (pipeline, 0..) |step, step_idx| {
        // Check global timeout before each step
        const now = std.Io.Timestamp.now(io, .real);
        const elapsed_ms = @divFloor(now.nanoseconds - start.nanoseconds, std.time.ns_per_ms);
        if (elapsed_ms > options.timeout_ms) {
            std.log.err("pipeline timeout after {d}ms", .{elapsed_ms});
            return CliError.Timeout;
        }

        if (step != .object) {
            std.log.warn("pipeline: step {d} not an object", .{step_idx});
            return CliError.Pipeline;
        }

        if (step.object.count() != 1) {
            std.log.warn("pipeline: step {d} has {d} keys", .{ step_idx, step.object.count() });
            return CliError.Pipeline;
        }

        var iter = step.object.iterator();
        const entry = iter.next().?;
        const step_name = entry.key_ptr.*;
        const params = entry.value_ptr.*;

        std.log.info("pipeline step {d}: {s}", .{ step_idx, step_name });

        if (options.step_mode) {
            const should_continue = promptStep(io, step_idx, step_name, data) catch {
                std.log.info("pipeline aborted by user", .{});
                return CliError.Io;
            };
            if (!should_continue) {
                std.log.info("pipeline aborted by user", .{});
                return CliError.Pipeline;
            }
        }

        const handler = registry.get(step_name) orelse {
            std.log.warn("pipeline: unknown step '{s}'", .{step_name});
            return CliError.Pipeline;
        };

        const is_browser = handler.isBrowserStep();
        var last_error: ?CliError = null;
        var step_retries: usize = 0;

        const max_attempts: usize = if (is_browser) @as(usize, MAX_BROWSER_ATTEMPTS) else @as(usize, 1);
        for (0..max_attempts) |attempt| {
            const result = handler.execute(allocator, io, page, params, data, args);
            if (result) |new_data| {
                // Free previous intermediate data — the handler produced a fresh value.
                freeJsonValue(allocator, data);
                data = new_data;
                last_error = null;
                break;
            } else |err| {
                std.log.warn("step '{s}' attempt {d} failed: {s}", .{ step_name, attempt + 1, @errorName(err) });
                if (is_browser and attempt + 1 < max_attempts) {
                    last_error = err;
                    step_retries = attempt + 1;
                } else {
                    return err;
                }
            }
        }

        if (last_error) |err| {
            return err;
        }

        if (metrics) |m| {
            m.recordStep(allocator, step_name, step_retries) catch {};
        }

        switch (data) {
            .array => |arr| std.log.info("  -> array[{d}]", .{arr.items.len}),
            .object => |obj| std.log.info("  -> object[{d}]", .{obj.count()}),
            else => std.log.info("  -> data", .{}),
        }
    }

    const end = std.Io.Timestamp.now(io, .real);
    if (metrics) |m| {
        m.total_duration_ms = @intCast(@divFloor(end.nanoseconds - start.nanoseconds, std.time.ns_per_ms));
    }

    return data;
}

/// Prompt user before executing a step in step-mode.
/// Returns true to continue, false to abort.
fn promptStep(io: std.Io, step_idx: usize, step_name: []const u8, data: json.Value) !bool {
    const stdout = std.Io.File.stdout();
    const stdin = std.Io.File.stdin();

    var buf: [256]u8 = undefined;

    try stdout.writeStreamingAll(io, "\n--- Step ");
    const idx_str = std.fmt.bufPrint(&buf, "{d}", .{step_idx}) catch "?";
    try stdout.writeStreamingAll(io, idx_str);
    try stdout.writeStreamingAll(io, ": ");
    try stdout.writeStreamingAll(io, step_name);
    try stdout.writeStreamingAll(io, " ---\n");

    // Data preview
    switch (data) {
        .array => |arr| {
            const preview = std.fmt.bufPrint(&buf, "data: array[{d}]\n", .{arr.items.len}) catch "";
            try stdout.writeStreamingAll(io, preview);
        },
        .object => |obj| {
            const preview = std.fmt.bufPrint(&buf, "data: object[{d}]\n", .{obj.count()}) catch "";
            try stdout.writeStreamingAll(io, preview);
        },
        .string => |s| {
            const limit = @min(s.len, 80);
            try stdout.writeStreamingAll(io, "data: \"");
            try stdout.writeStreamingAll(io, s[0..limit]);
            if (s.len > 80) try stdout.writeStreamingAll(io, "...");
            try stdout.writeStreamingAll(io, "\"\n");
        },
        .integer => |n| {
            const preview = std.fmt.bufPrint(&buf, "data: {d}\n", .{n}) catch "";
            try stdout.writeStreamingAll(io, preview);
        },
        .bool => |b| {
            try stdout.writeStreamingAll(io, if (b) "data: true\n" else "data: false\n");
        },
        .null => try stdout.writeStreamingAll(io, "data: null\n"),
        .float => |f| {
            const preview = std.fmt.bufPrint(&buf, "data: {d}\n", .{f}) catch "";
            try stdout.writeStreamingAll(io, preview);
        },
        .number_string => |s| {
            try stdout.writeStreamingAll(io, "data: ");
            try stdout.writeStreamingAll(io, s);
            try stdout.writeStreamingAll(io, "\n");
        },
    }

    try stdout.writeStreamingAll(io, "[Enter] continue | [d] dump data | [q] quit > ");

    // Read from stdin
    var input_buf: [16]u8 = undefined;
    var reader = stdin.reader(io, &input_buf);
    const n = reader.interface.readSliceShort(&input_buf) catch |err| {
        // On read error (e.g. EOF), treat as continue
        if (err == error.EndOfStream) {
            try stdout.writeStreamingAll(io, "\n");
            return true;
        }
        return err;
    };
    const input = std.mem.trim(u8, input_buf[0..n], " \r\t\n");

    try stdout.writeStreamingAll(io, "\n");

    if (input.len == 0) return true;
    const first = input[0];
    if (first == 'q' or first == 'Q') return false;
    if (first == 'd' or first == 'D') {
        // Dump full data as JSON
        const dumped = std.json.Stringify.valueAlloc(std.heap.smp_allocator, data, .{}) catch {
            try stdout.writeStreamingAll(io, "(failed to dump data)\n");
            return true;
        };
        defer std.heap.smp_allocator.free(dumped);
        try stdout.writeStreamingAll(io, "--- data dump ---\n");
        try stdout.writeStreamingAll(io, dumped);
        try stdout.writeStreamingAll(io, "\n---\n");
        // Ask again after dump
        return promptStep(io, step_idx, step_name, data);
    }
    return true;
}
