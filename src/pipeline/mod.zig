const std = @import("std");

pub const PipelineContext = @import("context.zig").PipelineContext;
pub const executePipeline = @import("executor.zig").executePipeline;
pub const PipelineOptions = @import("executor.zig").PipelineOptions;
pub const ExecutionMetrics = @import("executor.zig").ExecutionMetrics;
pub const freeJsonValue = @import("executor.zig").freeJsonValue;
pub const cloneJsonValue = @import("executor.zig").cloneJsonValue;
pub const StepRegistry = @import("registry.zig").StepRegistry;
pub const StepHandler = @import("registry.zig").StepHandler;

// Template engine
pub const TemplateContext = @import("template/mod.zig").TemplateContext;
pub const renderTemplate = @import("template/mod.zig").renderTemplate;
pub const renderTemplateStr = @import("template/mod.zig").renderTemplateStr;

// Step registration helpers
pub const FetchStepState = @import("steps/fetch.zig").FetchStepState;
pub const registerFetchSteps = @import("steps/fetch.zig").registerFetchSteps;
pub const registerTransformSteps = @import("steps/transform.zig").registerTransformSteps;
pub const registerBrowserSteps = @import("steps/browser.zig").registerBrowserSteps;
pub const registerDownloadSteps = @import("steps/download.zig").registerDownloadSteps;

// Include tests from sub-modules that are not directly imported above
test {
    _ = @import("steps/download.zig");
}
