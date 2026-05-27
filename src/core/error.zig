const std = @import("std");

pub const CliError = error{
    BrowserConnect,
    AdapterLoad,
    CommandExecution,
    Config,
    AuthRequired,
    Timeout,
    Argument,
    EmptyResult,
    Selector,
    Pipeline,
    Http,
    Io,
    Json,
    Yaml,
    OutOfMemory,
    ExternalCli,
};

pub const ErrorInfo = struct {
    message: []const u8,
    suggestions: []const []const u8,

    pub fn init(message: []const u8) ErrorInfo {
        return .{
            .message = message,
            .suggestions = &.{},
        };
    }
};

pub fn errorIcon(err: CliError) []const u8 {
    return switch (err) {
        error.BrowserConnect => "🌐",
        error.AdapterLoad => "🔌",
        error.CommandExecution => "⚡",
        error.Config => "⚙️",
        error.AuthRequired => "🔒",
        error.Timeout => "⏱️",
        error.Argument => "📝",
        error.EmptyResult => "📭",
        error.Selector => "🎯",
        error.Pipeline => "🔧",
        error.Io => "💾",
        error.Json => "📄",
        error.Yaml => "📄",
        error.Http => "🌍",
        error.OutOfMemory => "💾",
        error.ExternalCli => "🔌",
    };
}

pub fn errorCode(err: CliError) []const u8 {
    return switch (err) {
        error.BrowserConnect => "BROWSER_CONNECT",
        error.AdapterLoad => "ADAPTER_LOAD",
        error.CommandExecution => "COMMAND_EXECUTION",
        error.Config => "CONFIG",
        error.AuthRequired => "AUTH_REQUIRED",
        error.Timeout => "TIMEOUT",
        error.Argument => "ARGUMENT",
        error.EmptyResult => "EMPTY_RESULT",
        error.Selector => "SELECTOR",
        error.Pipeline => "PIPELINE",
        error.Io => "IO",
        error.Json => "JSON",
        error.Yaml => "YAML",
        error.Http => "HTTP",
        error.OutOfMemory => "OUT_OF_MEMORY",
        error.ExternalCli => "EXTERNAL_CLI",
    };
}

/// Cast an anyerror to CliError if it belongs to the CliError set.
pub fn castToCliError(err: anyerror) ?CliError {
    return switch (err) {
        error.BrowserConnect => CliError.BrowserConnect,
        error.AdapterLoad => CliError.AdapterLoad,
        error.CommandExecution => CliError.CommandExecution,
        error.Config => CliError.Config,
        error.AuthRequired => CliError.AuthRequired,
        error.Timeout => CliError.Timeout,
        error.Argument => CliError.Argument,
        error.EmptyResult => CliError.EmptyResult,
        error.Selector => CliError.Selector,
        error.Pipeline => CliError.Pipeline,
        error.Http => CliError.Http,
        error.Io => CliError.Io,
        error.Json => CliError.Json,
        error.Yaml => CliError.Yaml,
        error.OutOfMemory => CliError.OutOfMemory,
        error.ExternalCli => CliError.ExternalCli,
        else => null,
    };
}

test "errorIcon and errorCode cover all variants" {
    const errors = &[_]CliError{
        CliError.BrowserConnect, CliError.AdapterLoad, CliError.CommandExecution, CliError.Config,
        CliError.AuthRequired, CliError.Timeout, CliError.Argument, CliError.EmptyResult,
        CliError.Selector, CliError.Pipeline, CliError.Io, CliError.Json, CliError.Yaml, CliError.Http,
        CliError.OutOfMemory, CliError.ExternalCli,
    };
    for (errors) |err| {
        const icon = errorIcon(err);
        const code = errorCode(err);
        _ = icon;
        _ = code;
    }
}
