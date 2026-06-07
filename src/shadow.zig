// shadow.zig — 方向光阴影贴图（shadow map）
const Wgpu = @import("imports.zig").Wgpu;
const Gctx = @import("gctx.zig");
const Vec3 = @import("algebra.zig").Vec3;
const Mat4 = @import("algebra.zig").Mat4;
const StaticVertex = @import("rend_ctx.zig").StaticVertex;

const LightUniform = extern struct {
    light_vp: [16]f32,
};

pub const ShadowPipeline = struct {
    handle: Wgpu.WGPURenderPipeline,
    bind_group_layout: Wgpu.WGPUBindGroupLayout,
    bind_group: Wgpu.WGPUBindGroup,
    uniform_buffer: Wgpu.WGPUBuffer,
    depth_texture: Wgpu.WGPUTexture,
    depth_texture_view: Wgpu.WGPUTextureView,
    depth_sampler: Wgpu.WGPUSampler,
    light_vp: Mat4,

    pub fn init(gctx: *Gctx) !ShadowPipeline {
        const shader_module = try gctx.createShaderModule("resources\\shaders\\shadow_shader.wgsl");
        const map_size: u32 = 2048; // 2048² 深度贴图

        const bgl_entries = [_]Wgpu.WGPUBindGroupLayoutEntry{
            .{ .binding = 0, .visibility = Wgpu.WGPUShaderStage_Vertex, .buffer = .{ .type = Wgpu.WGPUBufferBindingType_Uniform } },
        };
        const bind_group_layout = Wgpu.wgpuDeviceCreateBindGroupLayout(gctx.device, &.{
            .entryCount = bgl_entries.len,
            .entries = &bgl_entries,
        });

        const uniform_buffer = Wgpu.wgpuDeviceCreateBuffer(gctx.device, &.{
            .size = @sizeOf(LightUniform),
            .usage = Wgpu.WGPUBufferUsage_Uniform | Wgpu.WGPUBufferUsage_CopyDst,
        });

        const light_vp = Mat4.identity;
        var m: [16]f32 = undefined;
        for (0..4) |col| {
            for (0..4) |row| {
                m[col * 4 + row] = light_vp.m[col][row];
            }
        }
        var u: LightUniform = .{ .light_vp = m };
        Wgpu.wgpuQueueWriteBuffer(gctx.queue, uniform_buffer, 0, &u, @sizeOf(LightUniform));

        const bind_group = Wgpu.wgpuDeviceCreateBindGroup(gctx.device, &.{
            .layout = bind_group_layout,
            .entryCount = 1,
            .entries = &[_]Wgpu.WGPUBindGroupEntry{
                .{ .binding = 0, .buffer = uniform_buffer, .offset = 0, .size = @sizeOf(LightUniform) },
            },
        });

        const pipeline_layout = Wgpu.wgpuDeviceCreatePipelineLayout(gctx.device, &.{
            .bindGroupLayoutCount = 1,
            .bindGroupLayouts = &[_]Wgpu.WGPUBindGroupLayout{bind_group_layout},
        });

        const vertex_attribs = [_]Wgpu.WGPUVertexAttribute{
            .{ .format = Wgpu.WGPUVertexFormat_Float32x3, .offset = 0, .shaderLocation = 0 },
        };
        const vertex_buf_layout = Wgpu.WGPUVertexBufferLayout{
            .arrayStride = @sizeOf(StaticVertex),
            .stepMode = Wgpu.WGPUVertexStepMode_Vertex,
            .attributeCount = vertex_attribs.len,
            .attributes = &vertex_attribs,
        };

        const depth_texture = Wgpu.wgpuDeviceCreateTexture(gctx.device, &.{
            .usage = Wgpu.WGPUTextureUsage_RenderAttachment | Wgpu.WGPUTextureUsage_TextureBinding,
            .dimension = Wgpu.WGPUTextureDimension_2D,
            .size = .{ .width = map_size, .height = map_size, .depthOrArrayLayers = 1 },
            .format = Wgpu.WGPUTextureFormat_Depth32Float,
            .mipLevelCount = 1,
            .sampleCount = 1,
        });
        const depth_texture_view = Wgpu.wgpuTextureCreateView(depth_texture, &.{
            .aspect = Wgpu.WGPUTextureAspect_DepthOnly,
            .dimension = Wgpu.WGPUTextureViewDimension_2D,
            .format = Wgpu.WGPUTextureFormat_Depth32Float,
            .baseMipLevel = 0,
            .mipLevelCount = 1,
            .baseArrayLayer = 0,
            .arrayLayerCount = 1,
        });
        const depth_sampler = Wgpu.wgpuDeviceCreateSampler(gctx.device, &.{
            .addressModeU = Wgpu.WGPUAddressMode_ClampToEdge,
            .addressModeV = Wgpu.WGPUAddressMode_ClampToEdge,
            .addressModeW = Wgpu.WGPUAddressMode_ClampToEdge,
            .magFilter = Wgpu.WGPUFilterMode_Linear,
            .minFilter = Wgpu.WGPUFilterMode_Linear, // Linear + comparison → 硬件 PCF
            .mipmapFilter = Wgpu.WGPUMipmapFilterMode_Linear,
            .lodMinClamp = 0,
            .lodMaxClamp = 32,
            .compare = Wgpu.WGPUCompareFunction_Less, // reference < stored → lit
            .maxAnisotropy = 1,
        });

        const pipeline = Wgpu.wgpuDeviceCreateRenderPipeline(gctx.device, &.{
            .layout = pipeline_layout,
            .vertex = .{
                .module = shader_module,
                .entryPoint = .{ .data = "vs_main", .length = 7 },
                .bufferCount = 1,
                .buffers = &vertex_buf_layout,
            },
            .fragment = null,
            .primitive = .{ .topology = Wgpu.WGPUPrimitiveTopology_TriangleList, .cullMode = Wgpu.WGPUCullMode_None },
            .multisample = .{ .count = 1, .mask = Wgpu.WGPUColorWriteMask_All },
            .depthStencil = &Wgpu.WGPUDepthStencilState{
                .format = Wgpu.WGPUTextureFormat_Depth32Float,
                .depthWriteEnabled = 1,
                .depthCompare = Wgpu.WGPUCompareFunction_Less,
                .stencilFront = .{},
                .stencilBack = .{},
                .stencilReadMask = 0,
                .stencilWriteMask = 0,
                .depthBias = 0,
                .depthBiasSlopeScale = 0, // 无深度偏置（靠法线偏移防自交）
                .depthBiasClamp = 0.0,
            },
        });

        return ShadowPipeline{
            .handle = pipeline,
            .bind_group_layout = bind_group_layout,
            .bind_group = bind_group,
            .uniform_buffer = uniform_buffer,
            .depth_texture = depth_texture,
            .depth_texture_view = depth_texture_view,
            .depth_sampler = depth_sampler,
            .light_vp = light_vp,
        };
    }

    // 计算光源视角的 VP 矩阵（正交投影）
    // n/f 为负值，因为 view 空间中相机前方是 -Z 方向
    pub fn computeLightVp(self: *ShadowPipeline, sun_dir: Vec3, player_pos: Vec3) void {
        const half_size: f32 = 128.0; // 覆盖 ±128m = 256m 宽
        const dist: f32 = 256.0; // 光源距离中心 256m
        const snap: f32 = 3.0; // 阴影中心 snap 间隔，防边缘拉锯
        const d = sun_dir.norm();
        const center = Vec3.new(
            @round(player_pos.x / snap) * snap,
            60.0,
            @round(player_pos.z / snap) * snap,
        );
        const light_pos = Vec3.new(
            center.x + d.x * dist,
            center.y + d.y * dist,
            center.z + d.z * dist,
        );
        const view = Mat4.lookAt(light_pos, center, Vec3.new(0, 1, 0));
        var proj = Mat4.identity;
        proj.m[0][0] = 1.0 / half_size;
        proj.m[1][1] = 1.0 / half_size;
        const n: f32 = -128.0; // 近平面（距光源最近的可视点）
        const f: f32 = -640.0; // 远平面（距光源最远的可视点）
        proj.m[2][2] = 1.0 / (f - n);
        proj.m[3][2] = -n / (f - n);
        self.light_vp = Mat4.mul(proj, view); // VP = proj * view
    }

    pub fn updateUniform(self: *ShadowPipeline, gctx: *Gctx) void {
        var m: [16]f32 = undefined;
        for (0..4) |col| {
            for (0..4) |row| {
                m[col * 4 + row] = self.light_vp.m[col][row];
            }
        }
        const u: LightUniform = .{ .light_vp = m };
        Wgpu.wgpuQueueWriteBuffer(gctx.queue, self.uniform_buffer, 0, &u, @sizeOf(LightUniform));
    }

    pub fn deinit(self: *ShadowPipeline) void {
        Wgpu.wgpuRenderPipelineRelease(self.handle);
        Wgpu.wgpuBindGroupLayoutRelease(self.bind_group_layout);
        Wgpu.wgpuBindGroupRelease(self.bind_group);
        Wgpu.wgpuBufferRelease(self.uniform_buffer);
        Wgpu.wgpuTextureRelease(self.depth_texture);
        Wgpu.wgpuTextureViewRelease(self.depth_texture_view);
        Wgpu.wgpuSamplerRelease(self.depth_sampler);
    }
};
