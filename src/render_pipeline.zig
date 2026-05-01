//render_pipeline.zig:
handle: Wgpu.WGPURenderPipeline,
global_bgl: Wgpu.WGPUBindGroupLayout,
global_bind_group: Wgpu.WGPUBindGroup,
material_bgl: Wgpu.WGPUBindGroupLayout,
pipeline_layout: Wgpu.WGPUPipelineLayout,
shader_module: Wgpu.WGPUShaderModule,

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
        },
    });

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

    // 创建渲染管线
    const pipeline_layout = Wgpu.wgpuDeviceCreatePipelineLayout(
        game.gctx.device,
        &Wgpu.WGPUPipelineLayoutDescriptor{
            .bindGroupLayoutCount = 2,
            .bindGroupLayouts = &[_]Wgpu.WGPUBindGroupLayout{
                global_bgl, material_bgl,
            },
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
            .entryPoint = .{
                .data = "vs_main",
                .length = 7,
            },
        },
        .primitive = .{
            .topology = Wgpu.WGPUPrimitiveTopology_TriangleList,
            .frontFace = Wgpu.WGPUFrontFace_CCW,
            .cullMode = Wgpu.WGPUCullMode_Back,
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
        .global_bgl = global_bgl,
        .global_bind_group = global_bind_group,
        .material_bgl = material_bgl,
        .pipeline_layout = pipeline_layout,
        .shader_module = shader_module,
    };
}

pub fn deinit(self: @This()) void {
    Wgpu.wgpuRenderPipelineRelease(self.handle);
    Wgpu.wgpuBindGroupLayoutRelease(self.global_bgl);
    Wgpu.wgpuBindGroupRelease(self.global_bind_group);
    Wgpu.wgpuBindGroupLayoutRelease(self.material_bgl);
    Wgpu.wgpuPipelineLayoutRelease(self.pipeline_layout);
    Wgpu.wgpuShaderModuleRelease(self.shader_module);
}

const std = @import("std");
const Gctx = @import("gctx.zig");
const Algebra = @import("algebra.zig");
const Vec3 = Algebra.Vec3;
const Mat4 = Algebra.Mat4;
const Window = @import("window.zig");
const Gltf = @import("zgltf");
const Wgpu = @import("imports.zig").Wgpu;
const Imports = @import("imports.zig");
const Game = Imports.Game;

const RenderCTX = @import("rend_ctx.zig");
const SceneUniform = RenderCTX.SceneUniform;
const VertexAttribute = RenderCTX.VertexAttribute;
const EntityData = RenderCTX.EntityData;
