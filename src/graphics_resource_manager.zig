pub const GraphicsResourceManager = struct {
    allocator: std.mem.Allocator,
    // 核心缓冲区
    vertex_buffer: wgpu.WGPUBuffer,
    index_buffer: wgpu.WGPUBuffer,
    scene_constants_buffer: wgpu.WGPUBuffer,
    // 层级结构
    node_data_buffer: wgpu.WGPUBuffer, // array<GpuNode>
    world_matrix_buffer: wgpu.WGPUBuffer, // array<mat4x4<f32>> (输出)
    // 实例数据
    instances_data_buffer: wgpu.WGPUBuffer,
    aligned_instances_data_size: u64,
    // CPU端元数据
    models: std.StringHashMap(ModelMetaData),
    pub fn init(allocator: std.mem.Allocator, gctx: *Gctx) !@This() {
        const scene_constants_buffer = wgpu.wgpuDeviceCreateBuffer(gctx.device, &.{
            .size = @sizeOf(SceneConstants),
            .usage = wgpu.WGPUBufferUsage_Uniform | wgpu.WGPUBufferUsage_CopyDst,
            .mappedAtCreation = 0,
        });
        // 假设你已经从 GLTF 加载了数据，并知道了节点数 (num_nodes)
        const num_nodes = 1000; // 假设最大节点数
        const world_matrix_buffer = wgpu.wgpuDeviceCreateBuffer(gctx.device, &.{
            .size = num_nodes * @sizeOf(Mat4),
            .usage = wgpu.WGPUBufferUsage_Storage,
            .mappedAtCreation = 0,
        });
        // 获取对齐大小
        const max_entities = 1000;
        const min_align_size = gctx.device_limits.minUniformBufferOffsetAlignment;
        const aligned_instances_data_size = ((@sizeOf(InstanceData) + min_align_size - 1) / min_align_size) * min_align_size;
        const instances_data_buffer = wgpu.wgpuDeviceCreateBuffer(gctx.device, &wgpu.WGPUBufferDescriptor{
            .size = aligned_instances_data_size * max_entities,
            .usage = wgpu.WGPUBufferUsage_Storage | wgpu.WGPUBufferUsage_CopyDst,
            .mappedAtCreation = 0,
        });

        return @This(){
            .allocator = allocator,
            .vertex_buffer = undefined,
            .index_buffer = undefined,
            .scene_constants_buffer = scene_constants_buffer,
            .node_data_buffer = undefined,
            .world_matrix_buffer = world_matrix_buffer,
            .instances_data_buffer = instances_data_buffer,
            .models = std.StringHashMap(ModelMetaData).init(allocator),
            .aligned_instances_data_size = aligned_instances_data_size,
        };
    }

    pub fn updateSceneConstants(self: *@This(), queue: wgpu.WGPUQueue, constants: SceneConstants) void {
        wgpu.wgpuQueueWriteBuffer(queue, self.scene_constants_buffer, 0, &constants, @sizeOf(SceneConstants));
    }

    pub fn updateInstanceData(self: *@This(), queue: wgpu.WGPUQueue, instance_index: u32, data: InstanceData) void {
        const offset = instance_index * self.aligned_instances_data_size;
        wgpu.wgpuQueueWriteBuffer(queue, self.instances_data_buffer, offset, &data, @sizeOf(InstanceData));
    }

    pub fn createShaderModule(device: wgpu.WGPUDevice, shader_file_path: []const u8) !wgpu.WGPUShaderModule {
        const code_file = try std.fs.cwd().openFile(shader_file_path, .{});
        defer code_file.close();
        var shader_code: [4096]u8 = undefined;
        const size = try code_file.reader().readAll(&shader_code);
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
};

// 计算管线
pub const ComputePipeline = struct {
    handle: wgpu.WGPUComputePipeline,
    bind_group_layout: wgpu.WGPUBindGroupLayout,
    bind_group: wgpu.WGPUBindGroup,
    pipeline_layout: wgpu.WGPUPipelineLayout,
    shader_module: wgpu.WGPUShaderModule,
    pub fn init(gctx: *Gctx, compute_shader_path: []const u8, grm: *GraphicsResourceManager) !@This() {
        // 1. 创建计算着色器模块
        const shader_module = try grm.createShaderModule(gctx.device, compute_shader_path);
        // 2. 创建 BindGroupLayout 和 BindGroup
        const bgl_entries = [_]wgpu.WGPUBindGroupLayoutEntry{
            .{ // node_data_buffer (Storage, ReadOnly)
                .binding = 0,
                .visibility = wgpu.WGPUShaderStage_Compute,
                .buffer = .{ .type = wgpu.WGPUBufferBindingType_ReadOnlyStorage },
            },
            .{ // world_matrix_buffer (Storage, ReadWrite) - 输出
                .binding = 1,
                .visibility = wgpu.WGPUShaderStage_Compute,
                .buffer = .{ .type = wgpu.WGPUBufferBindingType_Storage },
            },
            .{ // scene_constants_buffer (Uniform) - 可选，可以先不用
                .binding = 2,
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
                .{ .binding = 0, .buffer = grm.node_data_buffer, .offset = 0, .size = wgpu.WGPU_WHOLE_SIZE },
                .{ .binding = 1, .buffer = grm.world_matrix_buffer, .offset = 0, .size = wgpu.WGPU_WHOLE_SIZE },
                .{ .binding = 2, .buffer = grm.scene_constants_buffer, .offset = 0, .size = @sizeOf(SceneConstants) },
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
        };
    }

    pub fn deinit(self: *@This()) void {
        wgpu.wgpuComputePipelineRelease(self.handle);
        wgpu.wgpuBindGroupLayoutRelease(self.bind_group_layout);
        wgpu.wgpuBindGroupRelease(self.bind_group);
        wgpu.wgpuPipelineLayoutRelease(self.pipeline_layout);
        wgpu.wgpuShaderModuleRelease(self.shader_module);
    }

    // 一个更新 SceneStateUniform（主要是时间）的方法
    pub fn updateSceneState(self: *@This(), queue: wgpu.WGPUQueue, state: SceneConstants) void {
        wgpu.wgpuQueueWriteBuffer(queue, self.scene_state_buffer, 0, &state, @sizeOf(SceneConstants));
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
};

pub const RenderPipeline = struct {
    handle: wgpu.WGPURenderPipeline,
    bind_group_layout: wgpu.WGPUBindGroupLayout,
    bind_group: wgpu.WGPUBindGroup,
    pipeline_layout: wgpu.WGPUPipelineLayout,
    shader_module: wgpu.WGPUShaderModule,
    pub fn init(gctx: *Gctx, shader_file_path: []const u8, grm: *GraphicsResourceManager) !@This() {
        const shader_module = try grm.createShaderModule(
            gctx.device,
            shader_file_path,
        );
        // 创建 binding group
        const bgl_entries = [_]wgpu.WGPUBindGroupLayoutEntry{
            .{ // scene_constants_buffer (Uniform)
                .binding = 0,
                .visibility = wgpu.WGPUShaderStage_Vertex | wgpu.WGPUShaderStage_Fragment,
                .buffer = .{
                    .type = wgpu.WGPUBufferBindingType_ReadOnlyStorage,
                    .hasDynamicOffset = 0,
                },
            },
            .{ // instances_data_buffer
                .binding = 1,
                .visibility = wgpu.WGPUShaderStage_Vertex | wgpu.WGPUShaderStage_Fragment,
                .buffer = .{
                    .type = wgpu.WGPUBufferBindingType_ReadOnlyStorage,
                    .hasDynamicOffset = 1,
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
                .{
                    .binding = 0,
                    .buffer = grm.scene_constants_buffer,
                    .offset = 0,
                    .size = @sizeOf(SceneConstants),
                },
                .{
                    .binding = 1,
                    .buffer = grm.instances_data_buffer,
                    .offset = 0,
                    .size = grm.aligned_instances_data_size,
                },
            },
        });

        // 创建渲染管线
        const pipeline_layout = wgpu.wgpuDeviceCreatePipelineLayout(gctx.device, &wgpu.WGPUPipelineLayoutDescriptor{
            .bindGroupLayoutCount = 1,
            .bindGroupLayouts = &bind_group_layout,
        });
        const attributes = generateVertexAttributes(VertexAttribute);
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

    fn generateVertexAttributes(comptime VertexType: type) [std.meta.fields(VertexType).len]wgpu.WGPUVertexAttribute {
        const fields = std.meta.fields(VertexType);
        var attributes: [fields.len]wgpu.WGPUVertexAttribute = undefined;
        var offset: usize = 0;
        inline for (fields, 0..) |field, i| {
            const format = switch (field.type) {
                f32 => wgpu.WGPUVertexFormat_Float32,
                [3]f32 => wgpu.WGPUVertexFormat_Float32x3,
                [4]f32 => wgpu.WGPUVertexFormat_Float32x4,
                u32 => wgpu.WGPUVertexFormat_Uint32,
                [4]u32 => wgpu.WGPUVertexFormat_Uint32x4,
                else => @compileError("Unsupported vertex attribute type: " ++ @typeName(field.type)),
            };
            attributes[i] = .{
                .format = format,
                .offset = offset,
                .shaderLocation = @intCast(i),
            };
            offset += @sizeOf(field.type);
        }
        return attributes;
    }
};

pub const SceneConstants = struct {
    projection_matrix: Mat4 = undefined, // 投影变换
    view_matrix: Mat4 = undefined, // 视图变换
    time: f32 = undefined, // 当前时间
    delta_time: f32 = undefined, // 帧间隔时间
    _padding: [2]f32 = undefined, // 需要对齐到16字节
    pub fn init(window: Window) @This() {
        const aspect_ratio: f32 = window.widthF / window.heightF;
        const projection_matrix = Algebra.perspective(70, aspect_ratio, 0.001, 100);
        const view_matrix = Algebra.lookAt(Vec3.new(0.0, 0.0, -3.0), Vec3.zero(), Vec3.up());
        return .{
            .projection_matrix = projection_matrix,
            .view_matrix = view_matrix,
        };
    }
};

pub const ModelMetaData = struct {
    meshes: std.ArrayList(GpuMeshInfo), // 网格信息
    nodes: std.ArrayList(NodeInfo), // 节点层级信息
    vertex_buffer_offset: u64, // 在全局缓冲区中的偏移量
    index_buffer_offset: u64,
    node_data_offset: u32, // 在 node_data_buffer 中的起始索引
    pub fn deinit(self: *ModelMetaData, allocator: std.mem.Allocator) void {
        self.meshes.deinit();
        self.nodes.deinit();
        self.skins.deinit();
        _ = allocator; // 如果使用分配器的话
    }
};
pub const VertexAttribute = struct {
    pos: [3]f32,
    normal: [3]f32,
    color: [4]f32,
    joint_indices: [4]u32,
    joint_weights: [4]f32,
};
pub const NodeInfo = struct {
    parent_index: i32,
    local_matrix: Mat4,
};
const GpuMeshInfo = struct {
    vertex_offset: u32,
    vertex_size: u32,
    vertex_count: u32,
    index_offset: u32,
    index_size: u32,
    index_count: u32,
};
pub const GpuNode = struct {
    local_matrix: Mat4,
    parent_index: i32, // -1 表示无父节点
    _padding: [3]i32 = undefined,
};
pub const InstanceData = struct {
    entity_transform: Mat4, // 实体的世界变换
};
const std = @import("std");
const Gctx = @import("gctx.zig");
const Algebra = @import("zalgebra");
const Vec3 = Algebra.Vec3;
const Mat4 = Algebra.Mat4;
const Window = @import("window.zig");
const Gltf = @import("zgltf");
const wgpu = @cImport({
    @cInclude("wgpu.h");
});
