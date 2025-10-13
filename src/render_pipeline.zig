//render_pipeline.zig:
handle: wgpu.WGPURenderPipeline,
bind_group_layout: wgpu.WGPUBindGroupLayout,
bind_group: wgpu.WGPUBindGroup,
pipeline_layout: wgpu.WGPUPipelineLayout,
shader_module: wgpu.WGPUShaderModule,
pub fn init(gctx: *Gctx, shader_file_path: []const u8, grm: *const ResourceManager) !@This() {
    const shader_module = try gctx.createShaderModule(shader_file_path);
    // 创建 binding group
    const bgl_entries = [_]wgpu.WGPUBindGroupLayoutEntry{
        .{ // scene_uniform
            .binding = 0,
            .visibility = wgpu.WGPUShaderStage_Vertex | wgpu.WGPUShaderStage_Fragment,
            .buffer = .{
                .type = wgpu.WGPUBufferBindingType_Uniform,
                .hasDynamicOffset = 0,
            },
        },
        .{ // entities_data
            .binding = 1,
            .visibility = wgpu.WGPUShaderStage_Vertex | wgpu.WGPUShaderStage_Fragment,
            .buffer = .{
                .type = wgpu.WGPUBufferBindingType_ReadOnlyStorage,
                .hasDynamicOffset = 0,
            },
        },
    };
    const bind_group_layout = wgpu.wgpuDeviceCreateBindGroupLayout(
        gctx.device,
        &wgpu.WGPUBindGroupLayoutDescriptor{
            .entryCount = bgl_entries.len,
            .entries = &bgl_entries,
        },
    );
    const bind_group = wgpu.wgpuDeviceCreateBindGroup(gctx.device, &wgpu.WGPUBindGroupDescriptor{
        .layout = bind_group_layout,
        .entryCount = bgl_entries.len,
        .entries = &[_]wgpu.WGPUBindGroupEntry{
            .{ // scene_uniform
                .binding = 0,
                .buffer = grm.scene_uniform_buffer,
                .offset = 0,
                .size = wgpu.wgpuBufferGetSize(grm.scene_uniform_buffer),
            },
            .{ // entities_data
                .binding = 1,
                .buffer = grm.entities_data_buffer,
                .offset = 0,
                .size = wgpu.wgpuBufferGetSize(grm.entities_data_buffer),
            },
        },
    });
    // 创建渲染管线
    const pipeline_layout = wgpu.wgpuDeviceCreatePipelineLayout(gctx.device, &wgpu.WGPUPipelineLayoutDescriptor{
        .bindGroupLayoutCount = 1,
        .bindGroupLayouts = &bind_group_layout,
    });
    const attributes = Gctx.generateVertexAttributes(VertexAttribute);
    const pipeline_desc = wgpu.WGPURenderPipelineDescriptor{
        .layout = pipeline_layout, // 添加管线布局
        .vertex = .{
            .bufferCount = 1,
            .buffers = &wgpu.WGPUVertexBufferLayout{
                .arrayStride = @sizeOf(VertexAttribute),
                .stepMode = wgpu.WGPUVertexStepMode_Vertex,
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
            .topology = wgpu.WGPUPrimitiveTopology_TriangleList,
        },
        .fragment = &wgpu.WGPUFragmentState{
            .module = shader_module,
            .entryPoint = .{
                .data = "fs_main",
                .length = 7,
            },
            .targetCount = 1,
            .targets = &wgpu.WGPUColorTargetState{
                .format = wgpu.WGPUTextureFormat_BGRA8UnormSrgb,
                .writeMask = wgpu.WGPUColorWriteMask_All,
            },
        },
        .multisample = .{
            .count = 1,
            .mask = wgpu.WGPUColorWriteMask_All,
        },
        .depthStencil = &wgpu.WGPUDepthStencilState{
            .format = wgpu.WGPUTextureFormat_Depth24Plus,
            .depthWriteEnabled = 1,
            .depthCompare = wgpu.WGPUCompareFunction_Less,
            .stencilFront = .{},
            .stencilBack = .{},
            .stencilReadMask = 0,
            .stencilWriteMask = 0,
            .depthBias = 0,
            .depthBiasSlopeScale = 0.0,
            .depthBiasClamp = 0.0,
        },
    };
    const pipeline = wgpu.wgpuDeviceCreateRenderPipeline(gctx.device, &pipeline_desc);
    return @This(){
        .handle = pipeline,
        .bind_group_layout = bind_group_layout,
        .bind_group = bind_group,
        .pipeline_layout = pipeline_layout,
        .shader_module = shader_module,
    };
}
pub fn deinit(self: @This()) void {
    wgpu.wgpuRenderPipelineRelease(self.handle);
    wgpu.wgpuBindGroupLayoutRelease(self.bind_group_layout);
    wgpu.wgpuBindGroupRelease(self.bind_group);
    wgpu.wgpuPipelineLayoutRelease(self.pipeline_layout);
    wgpu.wgpuShaderModuleRelease(self.shader_module);
}

const std = @import("std");
const Gctx = @import("gctx.zig");
const Algebra = @import("zalgebra");
const Vec3 = Algebra.Vec3;
const Mat4 = Algebra.Mat4;
const Window = @import("window.zig");
const Gltf = @import("zgltf");
const wgpu = @import("cimprots.zig").wgpu;
const ResourceManager = @import("resource_manager.zig");

const ShaderType = @import("shader_types.zig");
const SceneUniform = ShaderType.SceneUniform;
const VertexAttribute = ShaderType.VertexAttribute;
const EntityData = ShaderType.EntityData;
const ModelData = ShaderType.ModelData;
