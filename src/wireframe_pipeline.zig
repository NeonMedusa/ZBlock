// wireframe_pipeline.zig
const std = @import("std");
const Wgpu = @import("imports.zig").Wgpu;
const Gctx = @import("gctx.zig");
const VertexAttribute = @import("rend_ctx.zig").VertexAttribute;
const Game = @import("game.zig");

pub const WireframePipeline = struct {
    handle: Wgpu.WGPURenderPipeline,
    global_bgl: Wgpu.WGPUBindGroupLayout,
    global_bind_group: Wgpu.WGPUBindGroup,
    pipeline_layout: Wgpu.WGPUPipelineLayout,
    shader_module: Wgpu.WGPUShaderModule,

    pub fn init(game: *Game, shader_file_path: []const u8) !WireframePipeline {
        const shader_module = try game.gctx.createShaderModule(shader_file_path);

        // 创建全局绑定组布局（只包含 scene_uniform，因为线框不需要 entities_data 和 ins_data）
        // 但为了与主渲染管线统一，你也可以保留所有三个 binding，但线框着色器只使用 scene_uniform。
        // 为简化，我们只创建 scene_uniform 的绑定组布局。
        const global_bgl_entries = [_]Wgpu.WGPUBindGroupLayoutEntry{
            .{ // scene_uniform
                .binding = 0,
                .visibility = Wgpu.WGPUShaderStage_Vertex,
                .buffer = .{ .type = Wgpu.WGPUBufferBindingType_Uniform },
            },
        };
        const global_bgl = Wgpu.wgpuDeviceCreateBindGroupLayout(
            game.gctx.device,
            &Wgpu.WGPUBindGroupLayoutDescriptor{
                .entryCount = global_bgl_entries.len,
                .entries = &global_bgl_entries,
            },
        );

        // 创建全局绑定组
        const global_bind_group = Wgpu.wgpuDeviceCreateBindGroup(game.gctx.device, &Wgpu.WGPUBindGroupDescriptor{
            .layout = global_bgl,
            .entryCount = global_bgl_entries.len,
            .entries = &[_]Wgpu.WGPUBindGroupEntry{
                .{ // scene_uniform
                    .binding = 0,
                    .buffer = game.res_manager.scene_uniform_buffer,
                    .offset = 0,
                    .size = Wgpu.wgpuBufferGetSize(game.res_manager.scene_uniform_buffer),
                },
            },
        });

        // 管线布局只需要一个绑定组
        const pipeline_layout = Wgpu.wgpuDeviceCreatePipelineLayout(
            game.gctx.device,
            &Wgpu.WGPUPipelineLayoutDescriptor{
                .bindGroupLayoutCount = 1,
                .bindGroupLayouts = &[_]Wgpu.WGPUBindGroupLayout{global_bgl},
            },
        );

        const attributes = Gctx.generateVertexAttributes(VertexAttribute);
        const pipeline_desc = Wgpu.WGPURenderPipelineDescriptor{
            .layout = pipeline_layout,
            .vertex = .{
                .bufferCount = 1,
                .buffers = &Wgpu.WGPUVertexBufferLayout{
                    .arrayStride = @sizeOf(VertexAttribute),
                    .stepMode = Wgpu.WGPUVertexStepMode_Vertex,
                    .attributeCount = attributes.len,
                    .attributes = &attributes,
                },
                .module = shader_module,
                .entryPoint = .{ .data = "vs_main", .length = 7 },
            },
            .primitive = .{
                .topology = Wgpu.WGPUPrimitiveTopology_LineList, // 线框模式
                .frontFace = Wgpu.WGPUFrontFace_CCW,
                .cullMode = Wgpu.WGPUCullMode_None,
            },
            .fragment = &Wgpu.WGPUFragmentState{
                .module = shader_module,
                .entryPoint = .{ .data = "fs_main", .length = 7 },
                .targetCount = 1,
                .targets = &Wgpu.WGPUColorTargetState{
                    .format = Wgpu.WGPUTextureFormat_BGRA8UnormSrgb,
                    .writeMask = Wgpu.WGPUColorWriteMask_All,
                    .blend = &Wgpu.WGPUBlendState{
                        .color = .{
                            .srcFactor = Wgpu.WGPUBlendFactor_SrcAlpha,
                            .dstFactor = Wgpu.WGPUBlendFactor_OneMinusSrcAlpha,
                            .operation = Wgpu.WGPUBlendOperation_Add,
                        },
                        .alpha = .{
                            .srcFactor = Wgpu.WGPUBlendFactor_One,
                            .dstFactor = Wgpu.WGPUBlendFactor_Zero,
                            .operation = Wgpu.WGPUBlendOperation_Add,
                        },
                    },
                },
            },
            .multisample = .{
                .count = 1,
                .mask = Wgpu.WGPUColorWriteMask_All,
            },
            .depthStencil = &Wgpu.WGPUDepthStencilState{
                .format = Wgpu.WGPUTextureFormat_Depth24Plus,
                .depthWriteEnabled = 0, // 禁用深度写入
                .depthCompare = Wgpu.WGPUCompareFunction_LessEqual,
                .stencilFront = .{},
                .stencilBack = .{},
                .stencilReadMask = 0,
                .stencilWriteMask = 0,
                .depthBias = 0,
                .depthBiasSlopeScale = 0.0,
                .depthBiasClamp = 0.0,
            },
        };
        const pipeline = Wgpu.wgpuDeviceCreateRenderPipeline(game.gctx.device, &pipeline_desc);

        return WireframePipeline{
            .handle = pipeline,
            .global_bgl = global_bgl,
            .global_bind_group = global_bind_group,
            .pipeline_layout = pipeline_layout,
            .shader_module = shader_module,
        };
    }

    pub fn deinit(self: WireframePipeline) void {
        Wgpu.wgpuRenderPipelineRelease(self.handle);
        Wgpu.wgpuBindGroupLayoutRelease(self.global_bgl);
        Wgpu.wgpuBindGroupRelease(self.global_bind_group);
        Wgpu.wgpuPipelineLayoutRelease(self.pipeline_layout);
        Wgpu.wgpuShaderModuleRelease(self.shader_module);
    }
};
