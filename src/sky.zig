// sky.zig — 彩色 cubemap 天空盒（全屏三角，无 mesh 依赖）
const std = @import("std");
const Wgpu = @import("imports.zig").Wgpu;
const Gctx = @import("gctx.zig");
const Vec3 = @import("algebra.zig").Vec3;
const Vec4 = @import("algebra.zig").Vec4;
const Mat4 = @import("algebra.zig").Mat4;
const zigimg = @import("zigimg");

pub const SkyUniform = struct {
    // inv(proj * view_rot)，不含平移：sky_mat * ndc → world 方向，数值稳定
    inv_view_proj: Mat4,
    sun_direction: Vec4,
    sun_color: Vec4,
    horizon_color: Vec4,
    zenith_color: Vec4,
    sun_intensity: f32,
    moon_phase: f32,
    moon_brightness: f32,
    star_density: f32,
    star_twinkle_speed: f32,
    star_color_strength: f32,
    time: f32,
    _pad: [1]f32 = undefined,

    pub fn pack(inv_view_proj: Mat4, state: SkyState, time: f32) SkyUniform {
        return .{
            .inv_view_proj = inv_view_proj,
            .sun_direction = Vec4{ .x = state.sun_direction.x, .y = state.sun_direction.y, .z = state.sun_direction.z, .w = 0 },
            .sun_color = Vec4{ .x = state.sun_color.x, .y = state.sun_color.y, .z = state.sun_color.z, .w = 0 },
            .horizon_color = Vec4{ .x = state.horizon_color.x, .y = state.horizon_color.y, .z = state.horizon_color.z, .w = 0 },
            .zenith_color = Vec4{ .x = state.zenith_color.x, .y = state.zenith_color.y, .z = state.zenith_color.z, .w = 0 },
            .sun_intensity = state.sun_intensity,
            .moon_phase = state.moon_phase,
            .moon_brightness = state.moon_brightness,
            .star_density = state.star_density,
            .star_twinkle_speed = state.star_twinkle_speed,
            .star_color_strength = state.star_color_strength,
            .time = time,
            ._pad = undefined,
        };
    }
};

pub const SkyState = struct {
    sun_direction: Vec3,
    sun_color: Vec3,
    sun_intensity: f32,
    moon_phase: f32,
    moon_brightness: f32,
    horizon_color: Vec3,
    zenith_color: Vec3,
    star_density: f32,
    star_twinkle_speed: f32,
    star_color_strength: f32,
    seasonal_tilt: f32 = 0, // +0.3=夏至(昼长), 0=春秋分, -0.3=冬至(昼短)；未来可从季节系统获取

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
            .seasonal_tilt = 0, // 未来可从季节系统获取
        };
    }
};

pub const SkyPipeline = struct {
    handle: Wgpu.WGPURenderPipeline,
    bind_group_layout: Wgpu.WGPUBindGroupLayout,
    bind_group: Wgpu.WGPUBindGroup,
    uniform_buffer: Wgpu.WGPUBuffer,
    shader_module: Wgpu.WGPUShaderModule,
    state: SkyState,
    day_length: f32 = 60.0, // 一天多少秒
    cubemap_texture: Wgpu.WGPUTexture,
    cubemap_texture_view: Wgpu.WGPUTextureView,
    cubemap_sampler: Wgpu.WGPUSampler,

    pub fn init(gctx: *Gctx, seed: u64) !SkyPipeline {
        const shader_module = try gctx.createShaderModule("resources/shaders/sky_shader.wgsl");

        // 加载 6 面彩色 cubemap 贴图
        const face_names = [_][]const u8{
            "resources/textures/sky/right.png",
            "resources/textures/sky/left.png",
            "resources/textures/sky/top.png",
            "resources/textures/sky/bottom.png",
            "resources/textures/sky/front.png",
            "resources/textures/sky/back.png",
        };
        const first_file = try std.fs.cwd().readFileAlloc(std.heap.page_allocator, face_names[0], std.math.maxInt(usize));
        defer std.heap.page_allocator.free(first_file);
        var first_img = try zigimg.Image.fromMemory(std.heap.page_allocator, first_file);
        defer first_img.deinit(std.heap.page_allocator);
        if (first_img.pixels != .rgba32) try first_img.convert(std.heap.page_allocator, .rgba32);
        const face_size: u32 = @intCast(@min(first_img.width, first_img.height));
        const face_len = face_size * face_size;
        const face_bytes = face_len * 4;

        var face0_data = try std.heap.page_allocator.alloc(u8, face_bytes);
        defer std.heap.page_allocator.free(face0_data);
        for (0..face_len) |i| {
            const p = first_img.pixels.rgba32[i];
            face0_data[i * 4 + 0] = p.r;
            face0_data[i * 4 + 1] = p.g;
            face0_data[i * 4 + 2] = p.b;
            face0_data[i * 4 + 3] = p.a;
        }

        const cubemap_texture = Wgpu.wgpuDeviceCreateTexture(gctx.device, &.{
            .usage = Wgpu.WGPUTextureUsage_CopyDst | Wgpu.WGPUTextureUsage_TextureBinding,
            .dimension = Wgpu.WGPUTextureDimension_2D,
            .size = .{ .width = face_size, .height = face_size, .depthOrArrayLayers = 6 },
            .format = Wgpu.WGPUTextureFormat_RGBA8Unorm,
            .mipLevelCount = 1,
            .sampleCount = 1,
        });

        // 写第一面（已加载）
        Wgpu.wgpuQueueWriteTexture(
            gctx.queue,
            &Wgpu.WGPUTexelCopyTextureInfo{ .texture = cubemap_texture, .mipLevel = 0, .origin = .{ .x = 0, .y = 0, .z = 0 } },
            face0_data.ptr,
            face_bytes,
            &Wgpu.WGPUTexelCopyBufferLayout{ .offset = 0, .bytesPerRow = face_size * 4, .rowsPerImage = face_size },
            &Wgpu.WGPUExtent3D{ .width = face_size, .height = face_size, .depthOrArrayLayers = 1 },
        );

        // 写第 2-6 面
        for (face_names[1..], 0..) |name, fi| {
            const file = try std.fs.cwd().readFileAlloc(std.heap.page_allocator, name, std.math.maxInt(usize));
            defer std.heap.page_allocator.free(file);
            var img = try zigimg.Image.fromMemory(std.heap.page_allocator, file);
            defer img.deinit(std.heap.page_allocator);
            if (img.pixels != .rgba32) try img.convert(std.heap.page_allocator, .rgba32);
            const fd = try std.heap.page_allocator.alloc(u8, face_bytes);
            defer std.heap.page_allocator.free(fd);
            for (0..face_len) |i| {
                const p = img.pixels.rgba32[i];
                fd[i * 4 + 0] = p.r;
                fd[i * 4 + 1] = p.g;
                fd[i * 4 + 2] = p.b;
                fd[i * 4 + 3] = p.a;
            }
            Wgpu.wgpuQueueWriteTexture(
                gctx.queue,
                &Wgpu.WGPUTexelCopyTextureInfo{ .texture = cubemap_texture, .mipLevel = 0, .origin = .{ .x = 0, .y = 0, .z = @intCast(fi + 1) } },
                fd.ptr,
                face_bytes,
                &Wgpu.WGPUTexelCopyBufferLayout{ .offset = 0, .bytesPerRow = face_size * 4, .rowsPerImage = face_size },
                &Wgpu.WGPUExtent3D{ .width = face_size, .height = face_size, .depthOrArrayLayers = 1 },
            );
        }
        const cubemap_texture_view = Wgpu.wgpuTextureCreateView(cubemap_texture, &.{
            .aspect = Wgpu.WGPUTextureAspect_All,
            .dimension = Wgpu.WGPUTextureViewDimension_Cube,
            .format = Wgpu.WGPUTextureFormat_RGBA8Unorm,
            .baseMipLevel = 0,
            .mipLevelCount = 1,
            .baseArrayLayer = 0,
            .arrayLayerCount = 6,
        });
        const cubemap_sampler = Wgpu.wgpuDeviceCreateSampler(gctx.device, &.{
            .addressModeU = Wgpu.WGPUAddressMode_ClampToEdge,
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

        const bgl_entries = [_]Wgpu.WGPUBindGroupLayoutEntry{
            .{ .binding = 0, .visibility = Wgpu.WGPUShaderStage_Vertex | Wgpu.WGPUShaderStage_Fragment, .buffer = .{ .type = Wgpu.WGPUBufferBindingType_Uniform } },
            .{ .binding = 1, .visibility = Wgpu.WGPUShaderStage_Fragment, .texture = .{ .sampleType = Wgpu.WGPUTextureSampleType_Float, .viewDimension = Wgpu.WGPUTextureViewDimension_Cube } },
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
                .{ .binding = 1, .textureView = cubemap_texture_view },
                .{ .binding = 2, .sampler = cubemap_sampler },
            },
        });

        const pipeline_layout = Wgpu.wgpuDeviceCreatePipelineLayout(gctx.device, &.{
            .bindGroupLayoutCount = 1,
            .bindGroupLayouts = &[_]Wgpu.WGPUBindGroupLayout{bind_group_layout},
        });

        const pipeline = Wgpu.wgpuDeviceCreateRenderPipeline(gctx.device, &.{
            .layout = pipeline_layout,
            .vertex = .{
                .module = shader_module,
                .entryPoint = .{ .data = "vs_main", .length = 7 },
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
            .day_length = 60.0, // 1 分钟
            .cubemap_texture = cubemap_texture,
            .cubemap_texture_view = cubemap_texture_view,
            .cubemap_sampler = cubemap_sampler,
        };
    }

    // 每帧调用：用角度计算太阳方向，打包 uniform 并上传到 GPU
    pub fn updateUniform(self: *SkyPipeline, gctx: *Gctx, inv_view_proj: Mat4, time: f32) void {
        const angle = (time / self.day_length) * 2.0 * std.math.pi;
        self.state.sun_direction = Vec3.norm(Vec3.new(
            std.math.sin(angle) * 0.8,
            std.math.cos(angle) * 0.6 + self.state.seasonal_tilt, // tilt 未来可从季节系统获取；0=春秋分,+0.3=夏至,-0.3=冬至
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
        Wgpu.wgpuTextureRelease(self.cubemap_texture);
        Wgpu.wgpuTextureViewRelease(self.cubemap_texture_view);
        Wgpu.wgpuSamplerRelease(self.cubemap_sampler);
    }
};
