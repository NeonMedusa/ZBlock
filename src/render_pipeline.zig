//render_pipeline.zig:
handle: Wgpu.WGPURenderPipeline,
bind_group_layout: Wgpu.WGPUBindGroupLayout,
bind_group: Wgpu.WGPUBindGroup,
pipeline_layout: Wgpu.WGPUPipelineLayout,
shader_module: Wgpu.WGPUShaderModule,
pub fn init(game: *Game, shader_file_path: []const u8) !@This() {
    const shader_module = try game.gctx.createShaderModule(shader_file_path);
    // 创建 binding group
    const bgl_entries = [_]Wgpu.WGPUBindGroupLayoutEntry{
        .{ // scene_uniform
            .binding = 0,
            .visibility = Wgpu.WGPUShaderStage_Vertex | Wgpu.WGPUShaderStage_Fragment,
            .buffer = .{
                .type = Wgpu.WGPUBufferBindingType_Uniform,
                .hasDynamicOffset = 0,
            },
        },
        .{ // entities_data
            .binding = 1,
            .visibility = Wgpu.WGPUShaderStage_Vertex | Wgpu.WGPUShaderStage_Fragment,
            .buffer = .{
                .type = Wgpu.WGPUBufferBindingType_ReadOnlyStorage,
                .hasDynamicOffset = 0,
            },
        },
        .{ // textures
            .binding = 2,
            .visibility = Wgpu.WGPUShaderStage_Vertex | Wgpu.WGPUShaderStage_Fragment,
            .texture = .{
                .sampleType = Wgpu.WGPUTextureSampleType_Float,
                .viewDimension = Wgpu.WGPUTextureViewDimension_2DArray,
            },
        },
        .{ // anime_textures
            .binding = 3,
            .visibility = Wgpu.WGPUShaderStage_Vertex | Wgpu.WGPUShaderStage_Fragment,
            .texture = .{
                .sampleType = Wgpu.WGPUTextureSampleType_UnfilterableFloat,
                .viewDimension = Wgpu.WGPUTextureViewDimension_2DArray,
            },
        },
        .{ // texture_info_buffer
            .binding = 4,
            .visibility = Wgpu.WGPUShaderStage_Vertex | Wgpu.WGPUShaderStage_Fragment,
            .buffer = .{
                .type = Wgpu.WGPUBufferBindingType_ReadOnlyStorage,
                .hasDynamicOffset = 0,
            },
        },
    };
    const bind_group_layout = Wgpu.wgpuDeviceCreateBindGroupLayout(
        game.gctx.device,
        &Wgpu.WGPUBindGroupLayoutDescriptor{
            .entryCount = bgl_entries.len,
            .entries = &bgl_entries,
        },
    );
    const bind_group = Wgpu.wgpuDeviceCreateBindGroup(game.gctx.device, &Wgpu.WGPUBindGroupDescriptor{
        .layout = bind_group_layout,
        .entryCount = bgl_entries.len,
        .entries = &[_]Wgpu.WGPUBindGroupEntry{
            .{ // scene_uniform
                .binding = 0,
                .buffer = game.res_manager.scene_uniform_buffer,
                .offset = 0,
                .size = Wgpu.wgpuBufferGetSize(game.res_manager.scene_uniform_buffer),
            },
            .{ // entities_data
                .binding = 1,
                .buffer = game.res_manager.entities_data_buffer,
                .offset = 0,
                .size = Wgpu.wgpuBufferGetSize(game.res_manager.entities_data_buffer),
            },
            .{ // color_altas
                .binding = 2,
                .textureView = game.res_manager.color_altas_view,
            },
            .{ // anime_altas
                .binding = 3,
                .textureView = game.res_manager.anime_altas_view,
            },
            .{ // textures_info
                .binding = 4,
                .buffer = game.res_manager.color_textures_info_buffer,
                .offset = 0,
                .size = Wgpu.wgpuBufferGetSize(game.res_manager.color_textures_info_buffer),
            },
        },
    });
    // 创建渲染管线
    const pipeline_layout = Wgpu.wgpuDeviceCreatePipelineLayout(game.gctx.device, &Wgpu.WGPUPipelineLayoutDescriptor{
        .bindGroupLayoutCount = 1,
        .bindGroupLayouts = &bind_group_layout,
    });
    const attributes = Gctx.generateVertexAttributes(VertexAttribute);
    const pipeline_desc = Wgpu.WGPURenderPipelineDescriptor{
        .layout = pipeline_layout, // 添加管线布局
        .vertex = .{
            .bufferCount = 1,
            .buffers = &Wgpu.WGPUVertexBufferLayout{
                .arrayStride = @sizeOf(VertexAttribute),
                .stepMode = Wgpu.WGPUVertexStepMode_Vertex,
                .attributeCount = attributes.len,
                .attributes = &attributes,
            },
            .module = shader_module,
            .entryPoint = .{
                .data = "vs_main",
                .length = 7,
            },
        },
        .primitive = .{
            .topology = Wgpu.WGPUPrimitiveTopology_TriangleList,
        },
        .fragment = &Wgpu.WGPUFragmentState{
            .module = shader_module,
            .entryPoint = .{
                .data = "fs_main",
                .length = 7,
            },
            .targetCount = 1,
            .targets = &Wgpu.WGPUColorTargetState{
                .format = Wgpu.WGPUTextureFormat_BGRA8UnormSrgb,
                .writeMask = Wgpu.WGPUColorWriteMask_All,
            },
        },
        .multisample = .{
            .count = 1,
            .mask = Wgpu.WGPUColorWriteMask_All,
        },
        .depthStencil = &Wgpu.WGPUDepthStencilState{
            .format = Wgpu.WGPUTextureFormat_Depth24Plus,
            .depthWriteEnabled = 1,
            .depthCompare = Wgpu.WGPUCompareFunction_Less,
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
    return @This(){
        .handle = pipeline,
        .bind_group_layout = bind_group_layout,
        .bind_group = bind_group,
        .pipeline_layout = pipeline_layout,
        .shader_module = shader_module,
    };
}
pub fn deinit(self: @This()) void {
    Wgpu.wgpuRenderPipelineRelease(self.handle);
    Wgpu.wgpuBindGroupLayoutRelease(self.bind_group_layout);
    Wgpu.wgpuBindGroupRelease(self.bind_group);
    Wgpu.wgpuPipelineLayoutRelease(self.pipeline_layout);
    Wgpu.wgpuShaderModuleRelease(self.shader_module);
}

const std = @import("std");
const Gctx = @import("gctx.zig");
const Algebra = @import("zalgebra");
const Vec3 = Algebra.Vec3;
const Mat4 = Algebra.Mat4;
const Window = @import("window.zig");
const Gltf = @import("zgltf");
const Wgpu = @import("cimports.zig").Wgpu;
const ResourceManager = @import("resource_manager.zig");
const Game = @import("game.zig");

const ShaderType = @import("shader_types.zig");
const SceneUniform = ShaderType.SceneUniform;
const VertexAttribute = ShaderType.VertexAttribute;
const EntityData = ShaderType.EntityData;
