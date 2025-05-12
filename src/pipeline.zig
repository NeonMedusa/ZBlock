handle: wgpu.WGPURenderPipeline,
aligned_uniform_size: u64,
uniform_buffer: wgpu.WGPUBuffer,
bind_group_layout: wgpu.WGPUBindGroupLayout,
bind_group: wgpu.WGPUBindGroup,
pipeline_layout: wgpu.WGPUPipelineLayout,
shader_module: wgpu.WGPUShaderModule,
pub fn init(gctx: *Gctx, shader_file_path: []const u8) !@This() {
    const shader_module = try createShaderModule(
        gctx.device,
        shader_file_path,
    );

    // 获取对齐大小
    const min_align_size = gctx.device_limits.minUniformBufferOffsetAlignment;
    const aligned_uniform_size = ((@sizeOf(Uniforms) + min_align_size - 1) / min_align_size) * min_align_size;
    const max_entities = 1000;
    const uniform_buffer = wgpu.wgpuDeviceCreateBuffer(gctx.device, &wgpu.WGPUBufferDescriptor{
        .size = aligned_uniform_size * max_entities,
        .usage = wgpu.WGPUBufferUsage_Uniform | wgpu.WGPUBufferUsage_CopyDst,
        .mappedAtCreation = 0,
    });

    // 创建 binding group layout 时启用动态偏移
    const bind_group_layout = wgpu.wgpuDeviceCreateBindGroupLayout(gctx.device, &wgpu.WGPUBindGroupLayoutDescriptor{
        .entryCount = 1,
        .entries = &wgpu.WGPUBindGroupLayoutEntry{
            .binding = 0,
            .visibility = wgpu.WGPUShaderStage_Vertex | wgpu.WGPUShaderStage_Fragment,
            .buffer = .{
                .type = wgpu.WGPUBufferBindingType_Uniform,
                .hasDynamicOffset = 1,
            },
        },
    });

    const bind_group = wgpu.wgpuDeviceCreateBindGroup(gctx.device, &wgpu.WGPUBindGroupDescriptor{
        .layout = bind_group_layout,
        .entryCount = 1,
        .entries = &wgpu.WGPUBindGroupEntry{
            .binding = 0,
            .buffer = uniform_buffer,
            .offset = 0,
            .size = aligned_uniform_size,
        },
    });

    // 创建渲染管线
    const pipeline_layout = wgpu.wgpuDeviceCreatePipelineLayout(gctx.device, &wgpu.WGPUPipelineLayoutDescriptor{
        .bindGroupLayoutCount = 1,
        .bindGroupLayouts = &bind_group_layout,
    });

    const attributes = [_]wgpu.WGPUVertexAttribute{
        .{
            .format = wgpu.WGPUVertexFormat_Float32x3,
            .offset = @offsetOf(VertexAttribute, "pos"),
            .shaderLocation = 0,
        },
        .{
            .format = wgpu.WGPUVertexFormat_Float32x3,
            .offset = @offsetOf(VertexAttribute, "normal"),
            .shaderLocation = 1,
        },
        .{
            .format = wgpu.WGPUVertexFormat_Float32x4,
            .offset = @offsetOf(VertexAttribute, "color"),
            .shaderLocation = 2,
        },
    };
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
        .aligned_uniform_size = aligned_uniform_size,
        .bind_group_layout = bind_group_layout,
        .bind_group = bind_group,
        .pipeline_layout = pipeline_layout,
        .shader_module = shader_module,
    };
}

pub fn deinit(self: @This()) void {
    wgpu.wgpuRenderPipelineRelease(self.handle);
    wgpu.wgpuBufferRelease(self.uniform_buffer);
    wgpu.wgpuBindGroupLayoutRelease(self.bind_group_layout);
    wgpu.wgpuBindGroupRelease(self.bind_group);
    wgpu.wgpuPipelineLayoutRelease(self.pipeline_layout);
    wgpu.wgpuShaderModuleRelease(self.shader_module);
}

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
const Uniforms = @import("uniforms.zig");
const VertexAttribute = @import("vertex_attribute.zig");
const wgpu = @cImport({
    @cInclude("wgpu.h");
});
