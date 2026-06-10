//render_pipeline.zig:
// 主渲染管线管理。一个 shader module + 三个 vertex entry point (vs_static/vs_skinned/vs_chunk)，
// 三个 vertex entry：vs_static / vs_skinned / vs_chunk 共享同一份片段着色器。
global_bgl: Wgpu.WGPUBindGroupLayout,
global_bind_group: Wgpu.WGPUBindGroup,
material_bgl: Wgpu.WGPUBindGroupLayout,
shadow_bgl: Wgpu.WGPUBindGroupLayout,
shadow_bind_group: ?Wgpu.WGPUBindGroup,
pipeline_layout: Wgpu.WGPUPipelineLayout,
shader_module: Wgpu.WGPUShaderModule,
pipeline_static: Wgpu.WGPURenderPipeline,
pipeline_skinned: Wgpu.WGPURenderPipeline,
pipeline_chunk: Wgpu.WGPURenderPipeline,

pub fn init(game: *Game, shader_file_path: []const u8) !@This() {
    const shader_module = try game.gctx.createShaderModule(shader_file_path);
    // 创建 binding group layout
    const global_bgl_entries = [_]Wgpu.WGPUBindGroupLayoutEntry{
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
        .{ // ins_data
            .binding = 2,
            .visibility = Wgpu.WGPUShaderStage_Vertex | Wgpu.WGPUShaderStage_Fragment,
            .buffer = .{
                .type = Wgpu.WGPUBufferBindingType_ReadOnlyStorage,
                .hasDynamicOffset = 0,
            },
        },
        .{ // bone_matrices
            .binding = 3,
            .visibility = Wgpu.WGPUShaderStage_Vertex,
            .buffer = .{
                .type = Wgpu.WGPUBufferBindingType_ReadOnlyStorage,
                .hasDynamicOffset = 0,
            },
        },
    };
    const global_bgl = Wgpu.wgpuDeviceCreateBindGroupLayout(
        game.gctx.device,
        &Wgpu.WGPUBindGroupLayoutDescriptor{
            .entryCount = global_bgl_entries.len,
            .entries = &global_bgl_entries,
        },
    );
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
            .{ // entities_data
                .binding = 1,
                .buffer = game.res_manager.entities_data_buffer,
                .offset = 0,
                .size = Wgpu.wgpuBufferGetSize(game.res_manager.entities_data_buffer),
            },
            .{ // instances_data
                .binding = 2,
                .buffer = game.res_manager.instances_data_buffer,
                .offset = 0,
                .size = Wgpu.wgpuBufferGetSize(game.res_manager.instances_data_buffer),
            },
            .{ // bone_matrices（占位，动画系统初始化后通过 setBoneBuffer 更新）
                .binding = 3,
                .buffer = game.res_manager.instances_data_buffer,
                .offset = 0,
                .size = Wgpu.wgpuBufferGetSize(game.res_manager.instances_data_buffer),
            },
        },
    });
    // ... after creating the pipeline, add setBoneBuffer method

    const material_bgl_entries = [_]Wgpu.WGPUBindGroupLayoutEntry{
        .{ // texture_uniform
            .binding = 0,
            .visibility = Wgpu.WGPUShaderStage_Vertex | Wgpu.WGPUShaderStage_Fragment,
            .buffer = .{
                .type = Wgpu.WGPUBufferBindingType_Uniform,
                .hasDynamicOffset = 0,
            },
        },
        .{ // color_texture
            .binding = 1,
            .visibility = Wgpu.WGPUShaderStage_Vertex | Wgpu.WGPUShaderStage_Fragment,
            .texture = .{
                .sampleType = Wgpu.WGPUTextureSampleType_Float,
                .viewDimension = Wgpu.WGPUTextureViewDimension_2D,
            },
        },
        .{ // normal_texture
            .binding = 2,
            .visibility = Wgpu.WGPUShaderStage_Vertex | Wgpu.WGPUShaderStage_Fragment,
            .texture = .{
                .sampleType = Wgpu.WGPUTextureSampleType_Float,
                .viewDimension = Wgpu.WGPUTextureViewDimension_2D,
            },
        },
    };
    const material_bgl = Wgpu.wgpuDeviceCreateBindGroupLayout(
        game.gctx.device,
        &Wgpu.WGPUBindGroupLayoutDescriptor{
            .entryCount = material_bgl_entries.len,
            .entries = &material_bgl_entries,
        },
    );

    // 阴影贴图 BGL (group 2)：深度纹理 + 比较采样器
    const shadow_bgl_entries = [_]Wgpu.WGPUBindGroupLayoutEntry{
        .{ .binding = 0, .visibility = Wgpu.WGPUShaderStage_Fragment, .texture = .{ .sampleType = Wgpu.WGPUTextureSampleType_Depth, .viewDimension = Wgpu.WGPUTextureViewDimension_2D } },
        .{ .binding = 1, .visibility = Wgpu.WGPUShaderStage_Fragment, .sampler = .{ .type = Wgpu.WGPUSamplerBindingType_Comparison } },
    };
    const shadow_bgl = Wgpu.wgpuDeviceCreateBindGroupLayout(
        game.gctx.device,
        &Wgpu.WGPUBindGroupLayoutDescriptor{
            .entryCount = shadow_bgl_entries.len,
            .entries = &shadow_bgl_entries,
        },
    );

    // 创建渲染管线
    const pipeline_layout = Wgpu.wgpuDeviceCreatePipelineLayout(
        game.gctx.device,
        &Wgpu.WGPUPipelineLayoutDescriptor{
            .bindGroupLayoutCount = 3,
            .bindGroupLayouts = &[_]Wgpu.WGPUBindGroupLayout{
                global_bgl, material_bgl, shadow_bgl,
            },
        },
    );

    // 两个管线共享 shader_module、pipeline_layout、bind groups，仅 vertex entry/attributes 不同
    // 三条 pipeline：static（32B stride，无骨骼）、skinned（64B stride，蒙皮）、chunk（4B stride，紧凑区块格式）
    const static_attrs = Gctx.generateVertexAttributes(RenderCTX.StaticVertex);
    const skinned_attrs = Gctx.generateVertexAttributes(RenderCTX.SkinnedVertex);
    // ChunkVertex 是 packed struct，GPU 侧以单一 u32 读取
    const chunk_attrs = [_]Wgpu.WGPUVertexAttribute{
        .{ .format = Wgpu.WGPUVertexFormat_Uint32, .offset = 0, .shaderLocation = 0 },
    };

    const pipe_static = createPipelineGctx(&game.gctx, pipeline_layout, shader_module, "vs_static", RenderCTX.StaticVertex, &static_attrs);
    const pipe_skinned = createPipelineGctx(&game.gctx, pipeline_layout, shader_module, "vs_skinned", RenderCTX.SkinnedVertex, &skinned_attrs);
    const pipe_chunk = createPipelineGctx(&game.gctx, pipeline_layout, shader_module, "vs_chunk", RenderCTX.ChunkVertex, &chunk_attrs);

    return @This(){
        .global_bgl = global_bgl,
        .global_bind_group = global_bind_group,
        .material_bgl = material_bgl,
        .pipeline_layout = pipeline_layout,
        .shader_module = shader_module,
        .pipeline_static = pipe_static,
        .pipeline_skinned = pipe_skinned,
        .pipeline_chunk = pipe_chunk,
        .shadow_bgl = shadow_bgl,
        .shadow_bind_group = null,
    };
}

pub fn setShadowBindGroup(self: *@This(), shadow_bind_group: Wgpu.WGPUBindGroup) void {
    self.shadow_bind_group = shadow_bind_group;
}

fn createPipelineGctx(gctx: *Gctx, layout: Wgpu.WGPUPipelineLayout, module: Wgpu.WGPUShaderModule, comptime entry: []const u8, comptime VertexType: type, attrs: []const Wgpu.WGPUVertexAttribute) Wgpu.WGPURenderPipeline {
    return Wgpu.wgpuDeviceCreateRenderPipeline(gctx.device, &.{
        .layout = layout,
        .vertex = .{
            .bufferCount = 1,
            .buffers = &Wgpu.WGPUVertexBufferLayout{
                .arrayStride = @sizeOf(VertexType),
                .stepMode = Wgpu.WGPUVertexStepMode_Vertex,
                .attributeCount = @as(u32, @intCast(attrs.len)),
                .attributes = attrs.ptr,
            },
            .module = module,
            .entryPoint = .{ .data = entry.ptr, .length = @as(u32, @intCast(entry.len)) },
        },
        .primitive = .{
            .topology = Wgpu.WGPUPrimitiveTopology_TriangleList,
            .frontFace = Wgpu.WGPUFrontFace_CCW,
            .cullMode = Wgpu.WGPUCullMode_Back,
        },
        .fragment = &Wgpu.WGPUFragmentState{
            .module = module,
            .entryPoint = .{ .data = "fs_main", .length = 7 },
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
            .depthWriteEnabled = 1,
            .depthCompare = Wgpu.WGPUCompareFunction_Greater,
            .stencilFront = .{},
            .stencilBack = .{},
            .stencilReadMask = 0,
            .stencilWriteMask = 0,
            .depthBias = 0,
            .depthBiasSlopeScale = 0.0,
            .depthBiasClamp = 0.0,
        },
    });
}

pub fn setBoneBuffer(self: *@This(), game: *Game, bone_buffer: Wgpu.WGPUBuffer) void {
    if (self.global_bind_group) |old| Wgpu.wgpuBindGroupRelease(old);
    self.global_bind_group = Wgpu.wgpuDeviceCreateBindGroup(game.gctx.device, &.{
        .layout = self.global_bgl,
        .entryCount = 4,
        .entries = &[_]Wgpu.WGPUBindGroupEntry{
            .{ .binding = 0, .buffer = game.res_manager.scene_uniform_buffer, .offset = 0, .size = Wgpu.wgpuBufferGetSize(game.res_manager.scene_uniform_buffer) },
            .{ .binding = 1, .buffer = game.res_manager.entities_data_buffer, .offset = 0, .size = Wgpu.wgpuBufferGetSize(game.res_manager.entities_data_buffer) },
            .{ .binding = 2, .buffer = game.res_manager.instances_data_buffer, .offset = 0, .size = Wgpu.wgpuBufferGetSize(game.res_manager.instances_data_buffer) },
            .{ .binding = 3, .buffer = bone_buffer, .offset = 0, .size = Wgpu.wgpuBufferGetSize(bone_buffer) },
        },
    });
}

pub fn deinit(self: @This()) void {
    Wgpu.wgpuRenderPipelineRelease(self.pipeline_static);
    Wgpu.wgpuRenderPipelineRelease(self.pipeline_skinned);
    Wgpu.wgpuRenderPipelineRelease(self.pipeline_chunk);
    Wgpu.wgpuBindGroupLayoutRelease(self.global_bgl);
    Wgpu.wgpuBindGroupRelease(self.global_bind_group);
    Wgpu.wgpuBindGroupLayoutRelease(self.material_bgl);
    Wgpu.wgpuPipelineLayoutRelease(self.pipeline_layout);
    Wgpu.wgpuShaderModuleRelease(self.shader_module);
}

const std = @import("std");
const Gctx = @import("gctx.zig");
const Wgpu = @import("imports.zig").Wgpu;
const Imports = @import("imports.zig");
const Game = Imports.Game;

const RenderCTX = @import("rend_ctx.zig");
