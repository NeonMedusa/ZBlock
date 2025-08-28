handle: wgpu.WGPUComputePipeline,
bind_group_layout: wgpu.WGPUBindGroupLayout,
bind_group: wgpu.WGPUBindGroup,
pipeline_layout: wgpu.WGPUPipelineLayout,
shader_module: wgpu.WGPUShaderModule,

// 计算管线需要的缓冲区
node_buffer: wgpu.WGPUBuffer, // 存储 GpuNode 数组
animation_buffer: wgpu.WGPUBuffer, // 存储动画数据 (GpuAnimationSampler, GpuAnimationChannel)
world_matrix_buffer: wgpu.WGPUBuffer, // 输出：计算好的世界矩阵
scene_state_buffer: wgpu.WGPUBuffer, // 输入：包含 u_time 等 uniform

pub fn init(gctx: *Gctx, compute_shader_path: []const u8) !@This() {
    // 1. 创建计算着色器模块
    const shader_module = try createShaderModule(gctx.device, compute_shader_path);
    // 2. 创建计算管线需要的各种缓冲区

    // 假设你已经从 GLTF 加载了数据，并知道了节点数 (num_nodes)
    // 创建并上传 GpuNode 数据
    const num_nodes = 1000;
    const node_buffer = wgpu.wgpuDeviceCreateBuffer(gctx.device, &wgpu.WGPUBufferDescriptor{
        .size = @sizeOf(GpuNode) * num_nodes,
        .usage = wgpu.WGPUBufferUsage_Storage | wgpu.WGPUBufferUsage_CopySrc, // 注意这里是 CopySrc，因为渲染管线要读它
        .mappedAtCreation = 0,
    });

    // 创建并上传动画数据
    const animation_buffer = wgpu.wgpuDeviceCreateBuffer(gctx.device, &wgpu.WGPUBufferDescriptor{
        .size = @sizeOf(Mat4) * num_nodes,
        .usage = wgpu.WGPUBufferUsage_Storage | wgpu.WGPUBufferUsage_CopySrc, // 注意这里是 CopySrc，因为渲染管线要读它
        .mappedAtCreation = 0,
    });

    const world_matrix_buffer = wgpu.wgpuDeviceCreateBuffer(gctx.device, &wgpu.WGPUBufferDescriptor{
        .size = @sizeOf(Mat4) * num_nodes,
        .usage = wgpu.WGPUBufferUsage_Storage | wgpu.WGPUBufferUsage_CopySrc, // 注意这里是 CopySrc，因为渲染管线要读它
        .mappedAtCreation = 0,
    });
    const scene_state_buffer = wgpu.wgpuDeviceCreateBuffer(gctx.device, &wgpu.WGPUBufferDescriptor{
        .size = @sizeOf(SceneStateUniform),
        .usage = wgpu.WGPUBufferUsage_Uniform | wgpu.WGPUBufferUsage_CopyDst,
        .mappedAtCreation = 0,
    });

    // 3. 创建 BindGroupLayout 和 BindGroup
    //    计算着色器需要访问 node_buffer, animation_buffer, world_matrix_buffer, scene_state_buffer
    const bgl_entries = [_]wgpu.WGPUBindGroupLayoutEntry{
        .{ // node_buffer (Storage, ReadOnly)
            .binding = 0,
            .visibility = wgpu.WGPUShaderStage_Compute,
            .buffer = .{ .type = wgpu.WGPUBufferBindingType_ReadOnlyStorage },
        },
        .{ // animation_buffer (Storage, ReadOnly) - 可能还需要更复杂的设计
            .binding = 1,
            .visibility = wgpu.WGPUShaderStage_Compute,
            .buffer = .{ .type = wgpu.WGPUBufferBindingType_ReadOnlyStorage },
        },
        .{ // world_matrix_buffer (Storage, ReadWrite) - 这是输出
            .binding = 2,
            .visibility = wgpu.WGPUShaderStage_Compute,
            .buffer = .{ .type = wgpu.WGPUBufferBindingType_Storage },
        },
        .{ // scene_state_buffer (Uniform)
            .binding = 3,
            .visibility = wgpu.WGPUShaderStage_Compute,
            .buffer = .{ .type = wgpu.WGPUBufferBindingType_Uniform },
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
            .{ .binding = 0, .buffer = node_buffer, .offset = 0, .size = wgpu.WGPU_WHOLE_SIZE },
            .{ .binding = 1, .buffer = animation_buffer, .offset = 0, .size = wgpu.WGPU_WHOLE_SIZE },
            .{ .binding = 2, .buffer = world_matrix_buffer, .offset = 0, .size = wgpu.WGPU_WHOLE_SIZE },
            .{ .binding = 3, .buffer = scene_state_buffer, .offset = 0, .size = @sizeOf(SceneStateUniform) },
        },
    });

    // 4. 创建 PipelineLayout
    const pipeline_layout = wgpu.wgpuDeviceCreatePipelineLayout(gctx.device, &wgpu.WGPUPipelineLayoutDescriptor{
        .bindGroupLayoutCount = 1,
        .bindGroupLayouts = &bind_group_layout,
    });

    // 5. 创建 ComputePipeline
    const pipeline_desc = wgpu.WGPUComputePipelineDescriptor{
        .layout = pipeline_layout,
        .compute = .{
            .module = shader_module,
            .entryPoint = .{ .data = "cs_main", .length = 7 }, // 计算着色器的入口函数
            .constantCount = 0,
            .constants = null,
        },
    };
    const pipeline = wgpu.wgpuDeviceCreateComputePipeline(gctx.device, &pipeline_desc);

    return @This(){
        .handle = pipeline,
        .bind_group_layout = bind_group_layout,
        .bind_group = bind_group,
        .pipeline_layout = pipeline_layout,
        .shader_module = shader_module,
        .node_buffer = node_buffer,
        .animation_buffer = animation_buffer,
        .world_matrix_buffer = world_matrix_buffer,
        .scene_state_buffer = scene_state_buffer,
    };
}

pub fn deinit(self: *@This()) void {
    wgpu.wgpuComputePipelineRelease(self.handle);
    wgpu.wgpuBindGroupLayoutRelease(self.bind_group_layout);
    wgpu.wgpuBindGroupRelease(self.bind_group);
    wgpu.wgpuPipelineLayoutRelease(self.pipeline_layout);
    wgpu.wgpuShaderModuleRelease(self.shader_module);
    wgpu.wgpuBufferRelease(self.node_buffer);
    wgpu.wgpuBufferRelease(self.animation_buffer);
    wgpu.wgpuBufferRelease(self.world_matrix_buffer);
    wgpu.wgpuBufferRelease(self.scene_state_buffer);
}

// 一个更新 SceneStateUniform（主要是时间）的方法
pub fn updateSceneState(self: *@This(), queue: wgpu.WGPUQueue, state: SceneStateUniform) void {
    wgpu.wgpuQueueWriteBuffer(queue, self.scene_state_buffer, 0, &state, @sizeOf(SceneStateUniform));
}

// 一个记录计算命令到 CommandEncoder 的方法
pub fn recordComputePass(self: *@This(), encoder: wgpu.WGPUCommandEncoder, num_workgroups_x: u32) void {
    const pass = wgpu.wgpuCommandEncoderBeginComputePass(encoder, null);
    defer wgpu.wgpuComputePassEncoderRelease(pass);

    wgpu.wgpuComputePassEncoderSetPipeline(pass, self.handle);
    wgpu.wgpuComputePassEncoderSetBindGroup(pass, 0, self.bind_group, 0, null);
    wgpu.wgpuComputePassEncoderDispatchWorkgroups(pass, num_workgroups_x, 1, 1);
    wgpu.wgpuComputePassEncoderEnd(pass);
}

// 计算管线使用的 Uniform 结构
const SceneStateUniform = struct {
    time: f32,
    delta_time: f32,
    // ... 其他全局状态
};

pub fn createShaderModule(device: wgpu.WGPUDevice, shader_file_path: []const u8) !wgpu.WGPUShaderModule {
    const code_file = try std.fs.cwd().openFile(shader_file_path, .{});
    defer code_file.close();

    var shader_code: [4096]u8 = undefined;
    const size = try code_file.reader().readAll(&shader_code);

    // 确保以null结尾
    const shader_source = wgpu.struct_WGPUShaderSourceWGSL{
        .code = .{
            .data = shader_code[0..size].ptr,
            .length = size,
        },
        .chain = .{
            .sType = wgpu.WGPUSType_ShaderSourceWGSL,
        },
    };
    const shader_desc = wgpu.WGPUShaderModuleDescriptor{
        .nextInChain = &shader_source.chain,
    };
    return wgpu.wgpuDeviceCreateShaderModule(device, &shader_desc);
}

const std = @import("std");
const Gctx = @import("gctx.zig");

const ShaderTypes = @import("shader_types.zig");
const Uniform = ShaderTypes.Uniform;
const InstanceData = ShaderTypes.InstanceData;
const VertexAttribute = ShaderTypes.VertexAttribute;

const Algebra = @import("zalgebra");
const Vec3 = Algebra.Vec3;
const Mat4 = Algebra.Mat4;
const Window = @import("window.zig");

const wgpu = @cImport({
    @cInclude("wgpu.h");
});

const GpuNode = @import("zgltf_wapper.zig").GpuNode;
