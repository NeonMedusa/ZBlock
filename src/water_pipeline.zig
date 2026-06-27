const io = @import("imports.zig").io;
const Gctx = @import("gctx.zig");
const Wgpu = @import("imports.zig").Wgpu;

/// 水面渲染管线：共享主管线的 bind group 0（场景 uniform）和 group 2（阴影贴图），
/// 但使用专用的水面着色器（波纹顶点位移 + 半透明蓝色着色）。
pipeline_layout: Wgpu.WGPUPipelineLayout,
shader_module: Wgpu.WGPUShaderModule,
pipeline: Wgpu.WGPURenderPipeline,

pub fn init(
    gctx: *Gctx,
    global_bgl: Wgpu.WGPUBindGroupLayout,
    shadow_bgl: Wgpu.WGPUBindGroupLayout,
    ssr_bgl: Wgpu.WGPUBindGroupLayout,
    sky_bgl: Wgpu.WGPUBindGroupLayout,
) !@This() {
    const shader_src = Gctx.loadEmbeddedShader("shaders/water_shader.wgsl");
    const shader_module = gctx.createShaderModuleFromSource(&shader_src);

    // 水面管线 4 个 bind group：场景 uniform + 阴影 + SSR纹理 + 天空Uniform
    const pipeline_layout = Wgpu.wgpuDeviceCreatePipelineLayout(
        gctx.device,
        &Wgpu.WGPUPipelineLayoutDescriptor{
            .bindGroupLayoutCount = 4,
            .bindGroupLayouts = &[_]Wgpu.WGPUBindGroupLayout{ global_bgl, shadow_bgl, ssr_bgl, sky_bgl },
        },
    );

    const static_attrs = Gctx.generateVertexAttributes(@import("rend_ctx.zig").StaticVertex);

    const pipeline = Wgpu.wgpuDeviceCreateRenderPipeline(
        gctx.device,
        &Wgpu.WGPURenderPipelineDescriptor{
            .layout = pipeline_layout,
            .vertex = .{
                .module = shader_module,
                .entryPoint = .{ .data = "vs_water", .length = 8 },
                .bufferCount = 1,
                .buffers = &[_]Wgpu.WGPUVertexBufferLayout{.{
                    .arrayStride = @sizeOf(@import("rend_ctx.zig").StaticVertex),
                    .stepMode = Wgpu.WGPUVertexStepMode_Vertex,
                    .attributeCount = static_attrs.len,
                    .attributes = &static_attrs,
                }},
            },
            .primitive = .{
                .topology = Wgpu.WGPUPrimitiveTopology_TriangleList,
                .frontFace = Wgpu.WGPUFrontFace_CCW,
                .cullMode = Wgpu.WGPUCullMode_Back, // 背面剔除，调试面朝向
            },
            .fragment = &Wgpu.WGPUFragmentState{
                .module = shader_module,
                .entryPoint = .{ .data = "fs_water", .length = 8 },
                .targetCount = 1,
                .targets = &Wgpu.WGPUColorTargetState{
                    .format = Wgpu.WGPUTextureFormat_BGRA8UnormSrgb,
                    .blend = &Wgpu.WGPUBlendState{
                        .color = .{ .operation = Wgpu.WGPUBlendOperation_Add, .srcFactor = Wgpu.WGPUBlendFactor_SrcAlpha, .dstFactor = Wgpu.WGPUBlendFactor_OneMinusSrcAlpha },
                        .alpha = .{ .operation = Wgpu.WGPUBlendOperation_Add, .srcFactor = Wgpu.WGPUBlendFactor_One, .dstFactor = Wgpu.WGPUBlendFactor_OneMinusSrcAlpha },
                    },
                    .writeMask = Wgpu.WGPUColorWriteMask_All,
                },
            },
            .multisample = .{ .count = 1, .mask = Wgpu.WGPUColorWriteMask_All },
            .depthStencil = &Wgpu.WGPUDepthStencilState{
                .format = Wgpu.WGPUTextureFormat_Depth24Plus,
                .depthWriteEnabled = 1, // 写入深度，正确遮挡后方水面
                .depthCompare = Wgpu.WGPUCompareFunction_GreaterEqual,
                .stencilFront = .{},
                .stencilBack = .{},
                .stencilReadMask = 0,
                .stencilWriteMask = 0,
                .depthBias = 0,
                .depthBiasSlopeScale = 0.0,
                .depthBiasClamp = 0.0,
            },
        },
    );

    return .{
        .pipeline_layout = pipeline_layout,
        .shader_module = shader_module,
        .pipeline = pipeline,
    };
}

pub fn deinit(self: *@This(), _: *Gctx) void {
    Wgpu.wgpuRenderPipelineRelease(self.pipeline);
    Wgpu.wgpuPipelineLayoutRelease(self.pipeline_layout);
    Wgpu.wgpuShaderModuleRelease(self.shader_module);
}
