// sky.zig — 全球经纬球 mesh + 2D 噪声纹理云渲染
const std = @import("std");
const Wgpu = @import("imports.zig").Wgpu;
const Gctx = @import("gctx.zig");
const Vec2 = @import("algebra.zig").Vec2;
const Vec3 = @import("algebra.zig").Vec3;
const Vec4 = @import("algebra.zig").Vec4;
const Mat4 = @import("algebra.zig").Mat4;
const zigimg = @import("zigimg");

pub const SkyUniform = struct {
    inv_view_proj: Mat4, // mesh 顶点 → 裁剪空间（proj × view_rot，不含平移）
    sun_direction: Vec4, // 太阳朝向（归一化方向向量）
    sun_color: Vec4, // 太阳光颜色
    horizon_color: Vec4, // 地平线天空颜色
    zenith_color: Vec4, // 天顶天空颜色
    cloud_params1: Vec4, // x=云量(越大云越多), y=密度, z=高度, w=风速
    cloud_params2: Vec4, // x=风向_X, y=风向_Z, z=云图缩放, w=光照偏移距
    cloud_color0: Vec4, // 云阴影色（暗）
    cloud_color1: Vec4, // 云中间色（中）
    cloud_color2: Vec4, // 云高光色（亮）
    time: f32, // 游戏时间（秒）
    sun_intensity: f32, // 太阳光晕和亮盘强度乘数
    moon_phase: f32, // 月相（0~1）
    moon_brightness: f32, // 月亮亮度乘数
    star_density: f32, // 星星密度（0~1，越小星越多）
    star_twinkle_speed: f32, // 星星闪烁速度
    star_color_strength: f32, // 星星色偏强度（0=全白）
    back_lit_strength: f32, // 云背光亮度
    edge_lit_power: f32, // 云边缘辉光幂次
    edge_lit_strength: f32, // 云边缘辉光强度
    cloud_color_mtime: f32, // 云三色调插值阈值
    _pad: [1]f32 = undefined, // uniform 16字节对齐填充

    pub fn pack(inv_view_proj: Mat4, state: SkyState, time: f32) SkyUniform {
        return .{
            .inv_view_proj = inv_view_proj,
            .sun_direction = Vec4{ .x = state.sun_direction.x, .y = state.sun_direction.y, .z = state.sun_direction.z, .w = 0 },
            .sun_color = Vec4{ .x = state.sun_color.x, .y = state.sun_color.y, .z = state.sun_color.z, .w = 0 },
            .horizon_color = Vec4{ .x = state.horizon_color.x, .y = state.horizon_color.y, .z = state.horizon_color.z, .w = 0 },
            .zenith_color = Vec4{ .x = state.zenith_color.x, .y = state.zenith_color.y, .z = state.zenith_color.z, .w = 0 },
            .cloud_params1 = Vec4{ .x = state.cloud_coverage, .y = state.cloud_density, .z = state.cloud_altitude, .w = state.cloud_speed },
            .cloud_params2 = Vec4{ .x = state.wind_dir.x, .y = state.wind_dir.y, .z = state.cloud_size, .w = state.offset_distance },
            .cloud_color0 = Vec4{ .x = state.cloud_color0.x, .y = state.cloud_color0.y, .z = state.cloud_color0.z, .w = 0 },
            .cloud_color1 = Vec4{ .x = state.cloud_color1.x, .y = state.cloud_color1.y, .z = state.cloud_color1.z, .w = 0 },
            .cloud_color2 = Vec4{ .x = state.cloud_color2.x, .y = state.cloud_color2.y, .z = state.cloud_color2.z, .w = 0 },
            .time = time,
            .sun_intensity = state.sun_intensity,
            .moon_phase = state.moon_phase,
            .moon_brightness = state.moon_brightness,
            .star_density = state.star_density,
            .star_twinkle_speed = state.star_twinkle_speed,
            .star_color_strength = state.star_color_strength,
            .back_lit_strength = state.back_lit_strength,
            .edge_lit_power = state.edge_lit_power,
            .edge_lit_strength = state.edge_lit_strength,
            .cloud_color_mtime = state.cloud_color_mtime,
            ._pad = undefined,
        };
    }
};

pub const SkyState = struct {
    sun_direction: Vec3, // 太阳朝向
    sun_color: Vec3, // 太阳光颜色
    sun_intensity: f32, // 太阳强度
    moon_phase: f32, // 月相（0~1）
    moon_brightness: f32, // 月亮亮度
    horizon_color: Vec3, // 地平线颜色（黄昏/黎明色）
    zenith_color: Vec3, // 天顶颜色（正午天空色）
    star_density: f32, // 星星密度
    star_twinkle_speed: f32, // 星星闪烁速度
    star_color_strength: f32, // 星星色偏强度
    seasonal_tilt: f32 = 0, // 季节倾斜（0=春秋分, +0.3=夏至, -0.3=冬至）
    cloud_coverage: f32, // 云量（0~，越大云遮盖越多，晴天≈0.3，阴天≈1.5）
    cloud_density: f32, // 云密度
    cloud_altitude: f32, // 云层高度
    cloud_speed: f32, // 风速
    cloud_size: f32, // 云图缩放（越小云块越大）
    wind_dir: Vec2, // 风向（x, z）
    offset_distance: f32, // 云光照偏移距离
    cloud_color0: Vec3, // 云阴影色
    cloud_color1: Vec3, // 云中间色
    cloud_color2: Vec3, // 云亮面色
    back_lit_strength: f32, // 背光强度
    edge_lit_power: f32, // 边缘辉光幂次
    edge_lit_strength: f32, // 边缘辉光强度
    cloud_color_mtime: f32, // 云三色调插值阈值

    pub fn generate(seed: u64) SkyState {
        var prng = std.Random.DefaultPrng.init(seed);
        const r = prng.random();
        return .{
            .sun_direction = Vec3.norm(Vec3.new(-0.3 + r.float(f32) * 0.6, 0.3 + r.float(f32) * 0.5, -0.5 + r.float(f32) * 0.6)),
            .sun_color = Vec3.new(1.0, 0.95, 0.90),
            .sun_intensity = 0.6 + r.float(f32) * 0.6,
            .moon_phase = r.float(f32),
            .moon_brightness = 0.3 + r.float(f32) * 0.6,
            .horizon_color = Vec3.new(0.18, 0.28, 0.7),
            .zenith_color = Vec3.new(0.08, 0.18, 0.7),
            .star_density = 0.03 + r.float(f32) * 0.07,
            .star_twinkle_speed = 1.0 + r.float(f32) * 1.0,
            .star_color_strength = r.float(f32) * r.float(f32) * 0.6,
            .seasonal_tilt = 0,
            .cloud_coverage = 1.2,
            .cloud_density = 0.5,
            .cloud_altitude = 0.5,
            .cloud_speed = 2.0,
            .cloud_size = 1.0,
            .wind_dir = Vec2.new(-0.3 + r.float(f32) * 0.6, -0.3 + r.float(f32) * 0.6),
            .offset_distance = 0.1,
            .cloud_color0 = Vec3.new(0.2, 0.2, 0.2),
            .cloud_color1 = Vec3.new(0.65, 0.65, 0.65),
            .cloud_color2 = Vec3.new(1.0, 1.0, 1.0),
            .back_lit_strength = 5.0,
            .edge_lit_power = 1.0,
            .edge_lit_strength = 1.0,
            .cloud_color_mtime = 0.5,
        };
    }
};

const LON_SEGMENTS: u32 = 64;
const LAT_SEGMENTS: u32 = 32;

const SkyVertex = extern struct {
    position: [3]f32,
    uv: [2]f32,
};

pub const SkyPipeline = struct {
    handle: Wgpu.WGPURenderPipeline,
    bind_group_layout: Wgpu.WGPUBindGroupLayout,
    bind_group: Wgpu.WGPUBindGroup,
    uniform_buffer: Wgpu.WGPUBuffer,
    shader_module: Wgpu.WGPUShaderModule,
    state: SkyState,
    day_length: f32 = 60.0,
    vertex_buffer: Wgpu.WGPUBuffer,
    index_buffer: Wgpu.WGPUBuffer,
    index_count: u32,
    noise_texture: Wgpu.WGPUTexture,
    noise_texture_view: Wgpu.WGPUTextureView,
    noise_sampler: Wgpu.WGPUSampler,

    pub fn init(gctx: *Gctx, seed: u64) !SkyPipeline {
        const shader_module = try gctx.createShaderModule("resources/shaders/sky_shader.wgsl");

        // CPU 烘培 2D 噪声纹理（等矩形投影，1024×512，R=低层云，G=高层云）
        const noise = @import("noise.zig");
        const tex_w: u32 = 1024;
        const tex_h: u32 = 512;
        const freq: f32 = 2.5;
        const buf = try std.heap.page_allocator.alloc(u8, tex_w * tex_h * 4);
        defer std.heap.page_allocator.free(buf);

        for (0..tex_h) |y| {
            for (0..tex_w) |x| {
                const u = (@as(f32, @floatFromInt(x)) + 0.5) / @as(f32, @floatFromInt(tex_w));
                const v = (@as(f32, @floatFromInt(y)) + 0.5) / @as(f32, @floatFromInt(tex_h));
                const theta = u * 2.0 * std.math.pi;
                const phi = v * std.math.pi;
                const d = Vec3.new(@sin(phi) * @cos(theta), @cos(phi), @sin(phi) * @sin(theta));
                const n = noise.fbmSnoise3(Vec3.new(d.x * freq, d.y * freq, d.z * freq), 4);
                const val = @as(u8, @intFromFloat(@min(@max(n * 0.5 + 0.5, 0) * 255.0, 255.0)));
                const n2 = noise.fbmSnoise3(Vec3.new(d.x * freq * 2.3 + 10.0, d.y * freq * 2.3 + 20.0, d.z * freq * 2.3 + 30.0), 3);
                const val2 = @as(u8, @intFromFloat(@min(@max(n2 * 0.5 + 0.5, 0) * 255.0, 255.0)));
                const idx = (y * tex_w + x) * 4;
                buf[idx + 0] = val;
                buf[idx + 1] = val2;
                buf[idx + 2] = 0;
                buf[idx + 3] = 255;
            }
        }
        // 修复左右边缘：将第一列复制到最后一列，确保 U=0 和 U=1 无缝环绕
        for (0..tex_h) |y| {
            const first_idx = y * tex_w * 4;
            const last_idx = (y * tex_w + (tex_w - 1)) * 4;
            buf[last_idx + 0] = buf[first_idx + 0];
            buf[last_idx + 1] = buf[first_idx + 1];
            buf[last_idx + 2] = buf[first_idx + 2];
            buf[last_idx + 3] = buf[first_idx + 3];
        }

        const noise_texture = Wgpu.wgpuDeviceCreateTexture(gctx.device, &.{
            .usage = Wgpu.WGPUTextureUsage_CopyDst | Wgpu.WGPUTextureUsage_TextureBinding,
            .dimension = Wgpu.WGPUTextureDimension_2D,
            .size = .{ .width = tex_w, .height = tex_h, .depthOrArrayLayers = 1 },
            .format = Wgpu.WGPUTextureFormat_RGBA8Unorm,
            .mipLevelCount = 1,
            .sampleCount = 1,
        });

        Wgpu.wgpuQueueWriteTexture(
            gctx.queue,
            &Wgpu.WGPUTexelCopyTextureInfo{ .texture = noise_texture, .mipLevel = 0, .origin = .{ .x = 0, .y = 0, .z = 0 } },
            buf.ptr,
            tex_w * tex_h * 4,
            &Wgpu.WGPUTexelCopyBufferLayout{ .offset = 0, .bytesPerRow = tex_w * 4, .rowsPerImage = tex_h },
            &Wgpu.WGPUExtent3D{ .width = tex_w, .height = tex_h, .depthOrArrayLayers = 1 },
        );

        const noise_texture_view = Wgpu.wgpuTextureCreateView(noise_texture, &.{
            .aspect = Wgpu.WGPUTextureAspect_All,
            .dimension = Wgpu.WGPUTextureViewDimension_2D,
            .format = Wgpu.WGPUTextureFormat_RGBA8Unorm,
            .baseMipLevel = 0,
            .mipLevelCount = 1,
            .baseArrayLayer = 0,
            .arrayLayerCount = 1,
        });

        const noise_sampler = Wgpu.wgpuDeviceCreateSampler(gctx.device, &.{
            .addressModeU = Wgpu.WGPUAddressMode_Repeat, // U=经度，需无缝环绕
            .addressModeV = Wgpu.WGPUAddressMode_ClampToEdge,
            .addressModeW = Wgpu.WGPUAddressMode_ClampToEdge,
            .magFilter = Wgpu.WGPUFilterMode_Linear,
            .minFilter = Wgpu.WGPUFilterMode_Linear,
            .mipmapFilter = Wgpu.WGPUMipmapFilterMode_Linear,
            .lodMinClamp = 0,
            .lodMaxClamp = 32,
            .compare = Wgpu.WGPUCompareFunction_Undefined,
            .maxAnisotropy = 1,
        });

        // 生成经纬球 mesh（64×32 细分）
        const vcount = (LON_SEGMENTS + 1) * (LAT_SEGMENTS + 1);
        const icount = LON_SEGMENTS * LAT_SEGMENTS * 6;
        var vertices = try std.heap.page_allocator.alloc(SkyVertex, vcount);
        defer std.heap.page_allocator.free(vertices);
        var indices = try std.heap.page_allocator.alloc(u32, icount);
        defer std.heap.page_allocator.free(indices);

        {
            var vi: u32 = 0;
            for (0..LAT_SEGMENTS + 1) |j| {
                const v = @as(f32, @floatFromInt(j)) / @as(f32, @floatFromInt(LAT_SEGMENTS));
                const phi = v * std.math.pi;
                for (0..LON_SEGMENTS + 1) |i| {
                    const u = @as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(LON_SEGMENTS));
                    const theta = u * 2.0 * std.math.pi;
                    vertices[vi] = .{
                        .position = .{
                            @sin(phi) * @cos(theta),
                            @cos(phi),
                            @sin(phi) * @sin(theta),
                        },
                        .uv = .{ u, v },
                    };
                    vi += 1;
                }
            }
        }
        {
            var ii: u32 = 0;
            for (0..LAT_SEGMENTS) |j| {
                for (0..LON_SEGMENTS) |i| {
                    const a = @as(u32, @intCast(j * (LON_SEGMENTS + 1) + i));
                    const b = a + 1;
                    const c = @as(u32, @intCast((j + 1) * (LON_SEGMENTS + 1) + i));
                    const d = c + 1;
                    indices[ii + 0] = a;
                    indices[ii + 1] = c;
                    indices[ii + 2] = b;
                    indices[ii + 3] = b;
                    indices[ii + 4] = c;
                    indices[ii + 5] = d;
                    ii += 6;
                }
            }
        }

        const vertex_buffer = Wgpu.wgpuDeviceCreateBuffer(gctx.device, &.{
            .size = vcount * @sizeOf(SkyVertex),
            .usage = Wgpu.WGPUBufferUsage_Vertex,
            .mappedAtCreation = 1,
        });
        {
            const mapped = @as([*]u8, @ptrCast(Wgpu.wgpuBufferGetMappedRange(vertex_buffer, 0, vcount * @sizeOf(SkyVertex))));
            @memcpy(mapped[0 .. vcount * @sizeOf(SkyVertex)], @as([*]const u8, @ptrCast(vertices.ptr))[0 .. vcount * @sizeOf(SkyVertex)]);
            Wgpu.wgpuBufferUnmap(vertex_buffer);
        }

        const index_buffer = Wgpu.wgpuDeviceCreateBuffer(gctx.device, &.{
            .size = icount * @sizeOf(u32),
            .usage = Wgpu.WGPUBufferUsage_Index,
            .mappedAtCreation = 1,
        });
        {
            const mapped = @as([*]u8, @ptrCast(Wgpu.wgpuBufferGetMappedRange(index_buffer, 0, icount * @sizeOf(u32))));
            @memcpy(mapped[0 .. icount * @sizeOf(u32)], @as([*]const u8, @ptrCast(indices.ptr))[0 .. icount * @sizeOf(u32)]);
            Wgpu.wgpuBufferUnmap(index_buffer);
        }

        const bgl_entries = [_]Wgpu.WGPUBindGroupLayoutEntry{
            .{ .binding = 0, .visibility = Wgpu.WGPUShaderStage_Vertex | Wgpu.WGPUShaderStage_Fragment, .buffer = .{ .type = Wgpu.WGPUBufferBindingType_Uniform } },
            .{ .binding = 1, .visibility = Wgpu.WGPUShaderStage_Fragment, .texture = .{ .sampleType = Wgpu.WGPUTextureSampleType_Float, .viewDimension = Wgpu.WGPUTextureViewDimension_2D } },
            .{ .binding = 2, .visibility = Wgpu.WGPUShaderStage_Fragment, .sampler = .{ .type = Wgpu.WGPUSamplerBindingType_Filtering } },
        };
        const bind_group_layout = Wgpu.wgpuDeviceCreateBindGroupLayout(
            gctx.device,
            &Wgpu.WGPUBindGroupLayoutDescriptor{
                .entryCount = bgl_entries.len,
                .entries = &bgl_entries,
            },
        );

        const uniform_buffer = Wgpu.wgpuDeviceCreateBuffer(gctx.device, &.{
            .size = @sizeOf(SkyUniform),
            .usage = Wgpu.WGPUBufferUsage_Uniform | Wgpu.WGPUBufferUsage_CopyDst,
        });

        const state = SkyState.generate(seed);
        var sky_uniform: SkyUniform = undefined;
        sky_uniform = SkyUniform.pack(Mat4.identity, state, 0.0);
        Wgpu.wgpuQueueWriteBuffer(gctx.queue, uniform_buffer, 0, &sky_uniform, @sizeOf(SkyUniform));

        const bind_group = Wgpu.wgpuDeviceCreateBindGroup(gctx.device, &.{
            .layout = bind_group_layout,
            .entryCount = 3,
            .entries = &[_]Wgpu.WGPUBindGroupEntry{
                .{ .binding = 0, .buffer = uniform_buffer, .offset = 0, .size = @sizeOf(SkyUniform) },
                .{ .binding = 1, .textureView = noise_texture_view },
                .{ .binding = 2, .sampler = noise_sampler },
            },
        });

        const pipeline_layout = Wgpu.wgpuDeviceCreatePipelineLayout(gctx.device, &.{
            .bindGroupLayoutCount = 1,
            .bindGroupLayouts = &[_]Wgpu.WGPUBindGroupLayout{bind_group_layout},
        });

        const vertex_attribs = [_]Wgpu.WGPUVertexAttribute{
            .{ .format = Wgpu.WGPUVertexFormat_Float32x3, .offset = 0, .shaderLocation = 0 },
            .{ .format = Wgpu.WGPUVertexFormat_Float32x2, .offset = 12, .shaderLocation = 1 },
        };
        const vertex_buf_layout = Wgpu.WGPUVertexBufferLayout{
            .arrayStride = @sizeOf(SkyVertex),
            .stepMode = Wgpu.WGPUVertexStepMode_Vertex,
            .attributeCount = vertex_attribs.len,
            .attributes = &vertex_attribs,
        };

        const pipeline = Wgpu.wgpuDeviceCreateRenderPipeline(gctx.device, &.{
            .layout = pipeline_layout,
            .vertex = .{
                .module = shader_module,
                .entryPoint = .{ .data = "vs_main", .length = 7 },
                .bufferCount = 1,
                .buffers = &vertex_buf_layout,
            },
            .primitive = .{ .topology = Wgpu.WGPUPrimitiveTopology_TriangleList },
            .fragment = &Wgpu.WGPUFragmentState{
                .module = shader_module,
                .entryPoint = .{ .data = "fs_main", .length = 7 },
                .targetCount = 1,
                .targets = &Wgpu.WGPUColorTargetState{
                    .format = Wgpu.WGPUTextureFormat_BGRA8UnormSrgb,
                    .writeMask = Wgpu.WGPUColorWriteMask_All,
                },
            },
            .multisample = .{ .count = 1, .mask = Wgpu.WGPUColorWriteMask_All },
            .depthStencil = &Wgpu.WGPUDepthStencilState{
                .format = Wgpu.WGPUTextureFormat_Depth24Plus,
                .depthWriteEnabled = 0,
                .depthCompare = Wgpu.WGPUCompareFunction_Always,
                .stencilFront = .{},
                .stencilBack = .{},
                .stencilReadMask = 0,
                .stencilWriteMask = 0,
            },
        });

        return SkyPipeline{
            .handle = pipeline,
            .bind_group_layout = bind_group_layout,
            .bind_group = bind_group,
            .uniform_buffer = uniform_buffer,
            .shader_module = shader_module,
            .state = state,
            .day_length = 60.0,
            .vertex_buffer = vertex_buffer,
            .index_buffer = index_buffer,
            .index_count = icount,
            .noise_texture = noise_texture,
            .noise_texture_view = noise_texture_view,
            .noise_sampler = noise_sampler,
        };
    }

    pub fn updateUniform(self: *SkyPipeline, gctx: *Gctx, inv_view_proj: Mat4, time: f32) void {
        const angle = (time / self.day_length) * 2.0 * std.math.pi;
        self.state.sun_direction = Vec3.norm(Vec3.new(
            std.math.sin(angle) * 0.8,
            std.math.cos(angle) * 0.6 + self.state.seasonal_tilt,
            std.math.cos(angle) * 0.3,
        ));
        const u = SkyUniform.pack(inv_view_proj, self.state, time);
        Wgpu.wgpuQueueWriteBuffer(gctx.queue, self.uniform_buffer, 0, &u, @sizeOf(SkyUniform));
    }

    pub fn deinit(self: *SkyPipeline) void {
        Wgpu.wgpuRenderPipelineRelease(self.handle);
        Wgpu.wgpuBindGroupLayoutRelease(self.bind_group_layout);
        Wgpu.wgpuBindGroupRelease(self.bind_group);
        Wgpu.wgpuBufferRelease(self.uniform_buffer);
        Wgpu.wgpuShaderModuleRelease(self.shader_module);
        Wgpu.wgpuBufferRelease(self.vertex_buffer);
        Wgpu.wgpuBufferRelease(self.index_buffer);
        Wgpu.wgpuTextureRelease(self.noise_texture);
        Wgpu.wgpuTextureViewRelease(self.noise_texture_view);
        Wgpu.wgpuSamplerRelease(self.noise_sampler);
    }
};
