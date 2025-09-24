//compute_pipeline.zig:
handle: wgpu.WGPUComputePipeline,
bind_group_layout: wgpu.WGPUBindGroupLayout,
bind_group: wgpu.WGPUBindGroup,
pipeline_layout: wgpu.WGPUPipelineLayout,
shader_module: wgpu.WGPUShaderModule,
pub fn init(gctx: *Gctx, compute_shader_path: []const u8, grm: *const ResourceManager) !@This() {
    // 创建计算着色器模块
    const shader_module = try gctx.createShaderModule(compute_shader_path);
    // 创建 BindGroupLayout 和 BindGroup
    const bgl_entries = [_]wgpu.WGPUBindGroupLayoutEntry{
        .{ // indirect_cmds
            .binding = 0,
            .visibility = wgpu.WGPUShaderStage_Compute,
            .buffer = .{ .type = wgpu.WGPUBufferBindingType_Storage },
        },
        .{ // entities_data
            .binding = 1,
            .visibility = wgpu.WGPUShaderStage_Compute,
            .buffer = .{ .type = wgpu.WGPUBufferBindingType_Storage },
        },
        .{ // models_data
            .binding = 2,
            .visibility = wgpu.WGPUShaderStage_Compute,
            .buffer = .{ .type = wgpu.WGPUBufferBindingType_Storage },
        },
        .{ // meshes_data
            .binding = 3,
            .visibility = wgpu.WGPUShaderStage_Compute,
            .buffer = .{ .type = wgpu.WGPUBufferBindingType_Storage },
        },
        .{ // gltf_nodes_data
            .binding = 4,
            .visibility = wgpu.WGPUShaderStage_Compute,
            .buffer = .{ .type = wgpu.WGPUBufferBindingType_Storage },
        },
        .{ // world_matrices
            .binding = 5,
            .visibility = wgpu.WGPUShaderStage_Compute,
            .buffer = .{ .type = wgpu.WGPUBufferBindingType_Storage },
        },
        .{ // scene_uniform
            .binding = 6,
            .visibility = wgpu.WGPUShaderStage_Compute,
            .buffer = .{ .type = wgpu.WGPUBufferBindingType_Uniform },
        },
        .{ // instance_counter
            .binding = 7,
            .visibility = wgpu.WGPUShaderStage_Compute,
            .buffer = .{ .type = wgpu.WGPUBufferBindingType_Storage },
        },
    };
    const bind_group_layout = wgpu.wgpuDeviceCreateBindGroupLayout(gctx.device, &wgpu.WGPUBindGroupLayoutDescriptor{
        .entryCount = bgl_entries.len,
        .entries = &bgl_entries,
    });
    const bind_group = wgpu.wgpuDeviceCreateBindGroup(gctx.device, &wgpu.WGPUBindGroupDescriptor{
        .layout = bind_group_layout,
        .entryCount = bgl_entries.len,
        .entries = &[_]wgpu.WGPUBindGroupEntry{
            .{ .binding = 0, .buffer = grm.indexed_indirect_cmds_buffer, .offset = 0, .size = wgpu.wgpuBufferGetSize(grm.indexed_indirect_cmds_buffer) },
            .{ .binding = 1, .buffer = grm.entities_data_buffer, .offset = 0, .size = wgpu.wgpuBufferGetSize(grm.entities_data_buffer) },
            .{ .binding = 2, .buffer = grm.models_data_buffer, .offset = 0, .size = wgpu.wgpuBufferGetSize(grm.models_data_buffer) },
            .{ .binding = 3, .buffer = grm.meshes_data_buffer, .offset = 0, .size = wgpu.wgpuBufferGetSize(grm.meshes_data_buffer) },
            .{ .binding = 4, .buffer = grm.nodes_data_buffer, .offset = 0, .size = wgpu.wgpuBufferGetSize(grm.nodes_data_buffer) },
            .{ .binding = 5, .buffer = grm.world_matrices_buffer, .offset = 0, .size = wgpu.wgpuBufferGetSize(grm.world_matrices_buffer) },
            .{ .binding = 6, .buffer = grm.scene_uniform_buffer, .offset = 0, .size = wgpu.wgpuBufferGetSize(grm.scene_uniform_buffer) },
            .{ .binding = 7, .buffer = grm.instance_counter_buffer, .offset = 0, .size = wgpu.wgpuBufferGetSize(grm.instance_counter_buffer) },
        },
    });
    // 创建 PipelineLayout
    const pipeline_layout = wgpu.wgpuDeviceCreatePipelineLayout(gctx.device, &wgpu.WGPUPipelineLayoutDescriptor{
        .bindGroupLayoutCount = 1,
        .bindGroupLayouts = &bind_group_layout,
    });
    // 创建 ComputePipeline
    const pipeline_desc = wgpu.WGPUComputePipelineDescriptor{
        .layout = pipeline_layout,
        .compute = .{
            .module = shader_module,
            .entryPoint = .{ .data = "cs_main", .length = 7 }, // 计算着色器的入口函数
        },
    };
    const pipeline = wgpu.wgpuDeviceCreateComputePipeline(gctx.device, &pipeline_desc);
    return @This(){
        .handle = pipeline,
        .bind_group_layout = bind_group_layout,
        .bind_group = bind_group,
        .pipeline_layout = pipeline_layout,
        .shader_module = shader_module,
    };
}
pub fn deinit(self: *const @This()) void {
    wgpu.wgpuComputePipelineRelease(self.handle);
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
const DrawIndexedIndirectCmd = ShaderType.DrawIndexedIndirectCmd;
const GltfNodeData = ShaderType.GltfNodeData;
const MeshData = ShaderType.MeshData;
const ModelData = ShaderType.ModelData;
