const std = @import("std");

/// Definition of an external CLI that can be passed through.
pub const ExternalCli = struct {
    name: []const u8,
    binary: []const u8,
    description: []const u8,
    homepage: ?[]const u8 = null,
    tags: []const []const u8 = &.{},
    install_mac: ?[]const u8 = null,
    install_default: ?[]const u8 = null,
    args: []const []const u8 = &.{},
    is_user_defined: bool = false,

    /// Return the base command to execute (the binary path/name).
    pub fn baseCommand(self: ExternalCli) []const u8 {
        return self.binary;
    }

    /// Execute this external CLI with additional arguments.
    /// Returns true if the process exited successfully.
    pub fn execute(
        self: ExternalCli,
        allocator: std.mem.Allocator,
        io: std.Io,
        extra_args: []const []const u8,
    ) !bool {
        const total = 1 + self.args.len + extra_args.len;
        var argv = std.ArrayList([]const u8).empty;
        defer argv.deinit(allocator);
        try argv.ensureTotalCapacity(allocator, total);

        try argv.append(allocator, self.binary);
        try argv.appendSlice(allocator, self.args);
        try argv.appendSlice(allocator, extra_args);

        const result = try std.process.run(allocator, io, .{
            .argv = argv.items,
        });
        defer {
            allocator.free(result.stdout);
            allocator.free(result.stderr);
        }

        // Forward stdout/stderr
        if (result.stdout.len > 0) {
            _ = std.Io.File.stdout().writeStreamingAll(io, result.stdout) catch {};
        }
        if (result.stderr.len > 0) {
            _ = std.Io.File.stderr().writeStreamingAll(io, result.stderr) catch {};
        }

        return result.term == .exited and result.term.exited == 0;
    }
};

/// Built-in external CLI definitions.
const builtin_clis = [_]ExternalCli{
    .{ .name = "gh", .binary = "gh", .description = "GitHub CLI — repos, PRs, issues, releases, gists", .homepage = "https://cli.github.com", .tags = &.{ "github", "git", "dev" }, .install_mac = "brew install gh" },
    .{ .name = "obsidian", .binary = "obsidian", .description = "Obsidian vault management — notes, search, tags, tasks, sync", .homepage = "https://obsidian.md/help/cli", .tags = &.{ "notes", "knowledge", "markdown" }, .install_mac = "brew install --cask obsidian" },
    .{ .name = "readwise", .binary = "readwise", .description = "Readwise & Reader CLI — highlights, annotations, reading list", .homepage = "https://github.com/readwiseio/readwise-cli", .tags = &.{ "reading", "highlights" }, .install_default = "npm install -g @readwiseio/readwise-cli" },
    .{ .name = "kubectl", .binary = "kubectl", .description = "Kubernetes command-line tool", .homepage = "https://kubernetes.io/docs/reference/kubectl/", .tags = &.{ "kubernetes", "k8s", "devops" }, .install_mac = "brew install kubectl" },
    .{ .name = "docker", .binary = "docker", .description = "Docker command-line interface", .homepage = "https://docs.docker.com/engine/reference/commandline/cli/", .tags = &.{ "docker", "containers", "devops" }, .install_mac = "brew install --cask docker" },
    .{ .name = "gws", .binary = "gws", .description = "Google Workspace CLI — Docs, Sheets, Drive, Gmail, Calendar", .homepage = "https://github.com/nicholasgasior/gws", .tags = &.{ "google", "docs", "sheets", "drive", "workspace" }, .install_mac = "brew install gws", .install_default = "npm install -g @nicholasgasior/gws" },
};

/// Registry of external CLIs (built-in + user-defined).
pub const ExternalCliRegistry = struct {
    allocator: std.mem.Allocator,
    clis: std.StringHashMap(ExternalCli),

    pub fn init(allocator: std.mem.Allocator) ExternalCliRegistry {
        var clis = std.StringHashMap(ExternalCli).init(allocator);
        for (builtin_clis) |cli| {
            _ = clis.put(cli.name, cli) catch |err| {
                std.log.warn("failed to register external CLI '{s}': {s}", .{ cli.name, @errorName(err) });
            };
        }
        return .{
            .allocator = allocator,
            .clis = clis,
        };
    }

    /// Load registry with built-in CLIs and optional user-defined ones.
    pub fn load(allocator: std.mem.Allocator, io: std.Io, environ_map: *const std.process.Environ.Map) ExternalCliRegistry {
        var registry = init(allocator);
        registry.loadUserClis(io, environ_map);
        return registry;
    }

    pub fn deinit(self: *ExternalCliRegistry) void {
        var it = self.clis.iterator();
        while (it.next()) |entry| {
            if (entry.value_ptr.is_user_defined) {
                self.allocator.free(entry.key_ptr.*);
                const cli = entry.value_ptr.*;
                self.allocator.free(cli.name);
                self.allocator.free(cli.binary);
                self.allocator.free(cli.description);
                if (cli.homepage) |h| self.allocator.free(h);
                for (cli.tags) |t| self.allocator.free(t);
                self.allocator.free(cli.tags);
                if (cli.install_mac) |m| self.allocator.free(m);
                if (cli.install_default) |d| self.allocator.free(d);
                for (cli.args) |a| self.allocator.free(a);
                self.allocator.free(cli.args);
            }
        }
        self.clis.deinit();
    }

    pub fn get(self: *const ExternalCliRegistry, name: []const u8) ?ExternalCli {
        return self.clis.get(name);
    }

    pub fn findByName(self: *const ExternalCliRegistry, name: []const u8) ?ExternalCli {
        return self.clis.get(name);
    }

    pub fn loadUserClis(self: *ExternalCliRegistry, io: std.Io, environ_map: *const std.process.Environ.Map) void {
        const home = environ_map.get("HOME") orelse return;
        const path = std.fmt.allocPrint(self.allocator, "{s}/.autocli/external-clis.yaml", .{home}) catch return;
        defer self.allocator.free(path);

        const content = std.Io.Dir.cwd().readFileAlloc(io, path, self.allocator, std.Io.Limit.limited(1024 * 1024)) catch return;
        defer self.allocator.free(content);

        self.parseAndMerge(content) catch |err| {
            std.log.warn("Failed to parse user external-clis.yaml: {s}", .{@errorName(err)});
        };
    }

    fn parseAndMerge(self: *ExternalCliRegistry, content: []const u8) !void {
        var lines = std.mem.splitScalar(u8, content, '\n');

        var current_name: ?[]const u8 = null;
        var current_binary: ?[]const u8 = null;
        var current_description: ?[]const u8 = null;
        var current_homepage: ?[]const u8 = null;
        var current_tags: std.ArrayList([]const u8) = std.ArrayList([]const u8).empty;
        defer current_tags.deinit(self.allocator);
        var current_install_mac: ?[]const u8 = null;
        var current_install_default: ?[]const u8 = null;
        var current_args: std.ArrayList([]const u8) = std.ArrayList([]const u8).empty;
        defer current_args.deinit(self.allocator);
        var in_install_block = false;

        while (lines.next()) |raw_line| {
            const line = std.mem.trimEnd(u8, raw_line, "\r");
            const trimmed = std.mem.trimStart(u8, line, " ");

            if (std.mem.startsWith(u8, trimmed, "- name:")) {
                // Flush previous entry if complete
                if (current_name) |n| {
                    if (current_binary) |b| {
                        try self.flushEntry(n, b, current_description, current_homepage, &current_tags, current_install_mac, current_install_default, &current_args);
                    }
                    self.freeCurrentEntry(n, current_binary, current_description, current_homepage, current_install_mac, current_install_default);
                }

                // Reset state
                current_name = try self.dupeTrimmedValue(trimmed, "- name:");
                current_binary = null;
                current_description = null;
                current_homepage = null;
                current_tags = std.ArrayList([]const u8).empty;
                in_install_block = false;
                current_install_mac = null;
                current_install_default = null;
                current_args = std.ArrayList([]const u8).empty;
            } else if (std.mem.startsWith(u8, trimmed, "binary:")) {
                current_binary = try self.dupeTrimmedValue(trimmed, "binary:");
                in_install_block = false;
            } else if (std.mem.startsWith(u8, trimmed, "description:")) {
                current_description = try self.dupeTrimmedValue(trimmed, "description:");
                in_install_block = false;
            } else if (std.mem.startsWith(u8, trimmed, "homepage:")) {
                current_homepage = try self.dupeTrimmedValue(trimmed, "homepage:");
                in_install_block = false;
            } else if (std.mem.startsWith(u8, trimmed, "tags:")) {
                in_install_block = false;
                const rest = std.mem.trimStart(u8, trimmed[5..], " ");
                if (rest.len > 0 and rest[0] == '[') {
                    const inner = std.mem.trimEnd(u8, std.mem.trimStart(u8, rest, "["), "]");
                    var tag_it = std.mem.splitScalar(u8, inner, ',');
                    while (tag_it.next()) |tag| {
                        const t = std.mem.trim(u8, tag, " \"");
                        if (t.len > 0) {
                            try current_tags.append(self.allocator, try self.allocator.dupe(u8, t));
                        }
                    }
                }
            } else if (std.mem.startsWith(u8, trimmed, "args:")) {
                in_install_block = false;
                const rest = std.mem.trimStart(u8, trimmed[5..], " ");
                if (rest.len > 0 and rest[0] == '[') {
                    const inner = std.mem.trimEnd(u8, std.mem.trimStart(u8, rest, "["), "]");
                    var arg_it = std.mem.splitScalar(u8, inner, ',');
                    while (arg_it.next()) |arg| {
                        const a = std.mem.trim(u8, arg, " \"");
                        if (a.len > 0) {
                            try current_args.append(self.allocator, try self.allocator.dupe(u8, a));
                        }
                    }
                }
            } else if (std.mem.startsWith(u8, trimmed, "install:")) {
                in_install_block = true;
            } else if (in_install_block and std.mem.startsWith(u8, trimmed, "mac:")) {
                current_install_mac = try self.dupeTrimmedValue(trimmed, "mac:");
            } else if (in_install_block and std.mem.startsWith(u8, trimmed, "default:")) {
                current_install_default = try self.dupeTrimmedValue(trimmed, "default:");
            }
        }

        // Flush last entry
        if (current_name) |n| {
            if (current_binary) |b| {
                try self.flushEntry(n, b, current_description, current_homepage, &current_tags, current_install_mac, current_install_default, &current_args);
            }
            self.freeCurrentEntry(n, current_binary, current_description, current_homepage, current_install_mac, current_install_default);
        }
    }

    fn flushEntry(
        self: *ExternalCliRegistry,
        name: []const u8,
        binary: []const u8,
        description: ?[]const u8,
        homepage: ?[]const u8,
        tags: *std.ArrayList([]const u8),
        install_mac: ?[]const u8,
        install_default: ?[]const u8,
        args: *std.ArrayList([]const u8),
    ) !void {
        const name_copy = try self.allocator.dupe(u8, name);
        errdefer self.allocator.free(name_copy);
        const binary_copy = try self.allocator.dupe(u8, binary);
        errdefer self.allocator.free(binary_copy);
        const desc_copy = if (description) |d| try self.allocator.dupe(u8, d) else try self.allocator.dupe(u8, "");
        errdefer self.allocator.free(desc_copy);
        const homepage_copy = if (homepage) |h| try self.allocator.dupe(u8, h) else null;
        errdefer if (homepage_copy) |h| self.allocator.free(h);
        const install_mac_copy = if (install_mac) |m| try self.allocator.dupe(u8, m) else null;
        errdefer if (install_mac_copy) |m| self.allocator.free(m);
        const install_default_copy = if (install_default) |d| try self.allocator.dupe(u8, d) else null;
        errdefer if (install_default_copy) |d| self.allocator.free(d);

        const tags_slice = try tags.toOwnedSlice(self.allocator);
        errdefer {
            for (tags_slice) |t| self.allocator.free(t);
            self.allocator.free(tags_slice);
        }
        const args_slice = try args.toOwnedSlice(self.allocator);
        errdefer {
            for (args_slice) |a| self.allocator.free(a);
            self.allocator.free(args_slice);
        }

        const cli = ExternalCli{
            .name = name_copy,
            .binary = binary_copy,
            .description = desc_copy,
            .homepage = homepage_copy,
            .tags = tags_slice,
            .install_mac = install_mac_copy,
            .install_default = install_default_copy,
            .args = args_slice,
            .is_user_defined = true,
        };
        try self.clis.put(name_copy, cli);
    }

    fn freeCurrentEntry(
        self: *ExternalCliRegistry,
        name: []const u8,
        binary: ?[]const u8,
        description: ?[]const u8,
        homepage: ?[]const u8,
        install_mac: ?[]const u8,
        install_default: ?[]const u8,
    ) void {
        self.allocator.free(name);
        if (binary) |b| self.allocator.free(b);
        if (description) |d| self.allocator.free(d);
        if (homepage) |h| self.allocator.free(h);
        if (install_mac) |m| self.allocator.free(m);
        if (install_default) |d| self.allocator.free(d);
    }

    fn dupeTrimmedValue(self: *ExternalCliRegistry, line: []const u8, prefix: []const u8) ![]const u8 {
        const rest = std.mem.trimStart(u8, line[prefix.len..], " ");
        const val = if (rest.len >= 2 and rest[0] == '"' and rest[rest.len - 1] == '"')
            rest[1 .. rest.len - 1]
        else
            rest;
        return try self.allocator.dupe(u8, val);
    }
};
