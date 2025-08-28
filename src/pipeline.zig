handle: wgpu.WGPURenderPipeline,
aligned_instances_data_size: u64,
uniform_buffer: wgpu.WGPUBuffer,
instances_data_buffer: wgpu.WGPUBuffer,
bind_group_layout: wgpu.WGPUBindGroupLayout,
bind_group: wgpu.WGPUBindGroup,
pipeline_layout: wgpu.WGPUPipelineLayout,
shader_module: wgpu.WGPUShaderModule,
pub fn init(gctx: *Gctx, shader_file_path: []const u8) !@This() {
    const shader_module = try createShaderModule(
        gctx.device,
        shader_file_path,
    );

    const uniform_buffer = wgpu.wgpuDeviceCreateBuffer(gctx.device, &wgpu.WGPUBufferDescriptor{
        .size = @sizeOf(Uniform),
        .usage = wgpu.WGPUBufferUsage_Storage | wgpu.WGPUBufferUsage_CopyDst,
        .mappedAtCreation = 0,
    });

    // 获取对齐大小
    const max_entities = 1000;
    const min_align_size = gctx.device_limits.minUniformBufferOffsetAlignment;
    const aligned_instances_data_size = ((@sizeOf(InstanceData) + min_align_size - 1) / min_align_size) * min_align_size;
    const instance_data_buffer = wgpu.wgpuDeviceCreateBuffer(gctx.device, &wgpu.WGPUBufferDescriptor{
        .size = aligned_instances_data_size * max_entities,
        .usage = wgpu.WGPUBufferUsage_Storage | wgpu.WGPUBufferUsage_CopyDst,
        .mappedAtCreation = 0,
    });

    // 创建 binding group
    const bgl_entries = [_]wgpu.WGPUBindGroupLayoutEntry{
        .{ // Uniform
            .binding = 0,
            .visibility = wgpu.WGPUShaderStage_Vertex | wgpu.WGPUShaderStage_Fragment,
            .buffer = .{
                .type = wgpu.WGPUBufferBindingType_ReadOnlyStorage,
                .hasDynamicOffset = 0,
            },
        },
        .{ // instances_data
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
                .buffer = uniform_buffer,
                .offset = 0,
                .size = @sizeOf(Uniform),
            },
            .{
                .binding = 1,
                .buffer = instance_data_buffer,
                .offset = 0,
                .size = aligned_instances_data_size,
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
        .uniform_buffer = uniform_buffer,
        .aligned_instances_data_size = aligned_instances_data_size,
        .bind_group_layout = bind_group_layout,
        .bind_group = bind_group,
        .pipeline_layout = pipeline_layout,
        .shader_module = shader_module,
        .instances_data_buffer = instance_data_buffer,
    };
}

pub fn deinit(self: @This()) void {
    wgpu.wgpuRenderPipelineRelease(self.handle);
    wgpu.wgpuBufferRelease(self.uniform_buffer);
    wgpu.wgpuBufferRelease(self.instances_data_buffer);
    wgpu.wgpuBindGroupLayoutRelease(self.bind_group_layout);
    wgpu.wgpuBindGroupRelease(self.bind_group);
    wgpu.wgpuPipelineLayoutRelease(self.pipeline_layout);
    wgpu.wgpuShaderModuleRelease(self.shader_module);
}

pub fn createShaderModule(device: wgpu.WGPUDevice, shader_file_path: []const u8) !wgpu.WGPUShaderModule {
    const code_file = try std.fs.cwd().openFile(shader_file_path, .{});
    defer code_file.close();

    var shader_code: [4096]u8 = undefined;
    var reader = code_file.reader(&shader_code);
    const size = try reader.read(&shader_code);

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

const std = @import("std");
const Gctx = @import("gctx.zig");

const ShaderTypes = @import("shader_types.zig");
const Uniform = ShaderTypes.Uniform;
const InstanceData = ShaderTypes.InstanceData;
const VertexAttribute = ShaderTypes.VertexAttribute;

const wgpu = @import("cimprot.zig").wgpu;
