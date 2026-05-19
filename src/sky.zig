// sky.zig — 程序化天空穹顶（全屏三角，无 vertex/index buffer）
const std = @import("std");
const Wgpu = @import("imports.zig").Wgpu;
const Gctx = @import("gctx.zig");
const Vec3 = @import("algebra.zig").Vec3;
const Vec4 = @import("algebra.zig").Vec4;
const Mat4 = @import("algebra.zig").Mat4;

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

        const sun_hue = 25.0 + r.float(f32) * 55.0;
        const sat = 0.4 + r.float(f32) * 0.6;

        return .{
            .sun_direction = Vec3.norm(Vec3.new(-0.3 + r.float(f32) * 0.6, 0.3 + r.float(f32) * 0.5, -0.5 + r.float(f32) * 0.6)),
            .sun_color = hslToRgb(sun_hue, sat, 0.85 + r.float(f32) * 0.15),
            .sun_intensity = 0.6 + r.float(f32) * 0.6,
            .moon_phase = r.float(f32),
            .moon_brightness = 0.1 + r.float(f32) * 0.3,
            .horizon_color = Vec3.new(0.60, 0.72, 0.90),
            .zenith_color = Vec3.new(0.20, 0.35, 0.70),
            .star_density = 0.03 + r.float(f32) * 0.07,
            .star_twinkle_speed = 1.0 + r.float(f32) * 1.0,
            .star_color_strength = r.float(f32) * r.float(f32) * 0.6,
            .seasonal_tilt = 0, // 未来可从季节系统获取
        };
    }
};

fn hslToRgb(hue: f32, sat: f32, light: f32) Vec3 {
    const c = (1.0 - @abs(2.0 * light - 1.0)) * sat;
    const hp = @mod(hue / 60.0, 6.0);
    const x = c * (1.0 - @abs(@mod(hp, 2.0) - 1.0));
    const rgb = if (hp < 1.0) Vec3.new(c, x, 0.0) else if (hp < 2.0) Vec3.new(x, c, 0.0) else if (hp < 3.0) Vec3.new(0.0, c, x) else if (hp < 4.0) Vec3.new(0.0, x, c) else if (hp < 5.0) Vec3.new(x, 0.0, c) else Vec3.new(c, 0.0, x);
    const m = light - c / 2.0;
    return Vec3.new(rgb.x + m, rgb.y + m, rgb.z + m);
}

pub const SkyPipeline = struct {
    handle: Wgpu.WGPURenderPipeline,
    bind_group_layout: Wgpu.WGPUBindGroupLayout,
    bind_group: Wgpu.WGPUBindGroup,
    uniform_buffer: Wgpu.WGPUBuffer,
    shader_module: Wgpu.WGPUShaderModule,
    state: SkyState,
    day_length: f32 = 24.0, // 一天多少秒
    cached_inv_proj: Mat4, // inv(proj)，在 game.zig init 中赋值，避免每帧重复求逆

    pub fn init(gctx: *Gctx, seed: u64) !SkyPipeline {
        const shader_module = try gctx.createShaderModule("resources/shaders/sky_shader.wgsl");

        const bgl_entries = [_]Wgpu.WGPUBindGroupLayoutEntry{
            .{
                .binding = 0,
                .visibility = Wgpu.WGPUShaderStage_Vertex | Wgpu.WGPUShaderStage_Fragment,
                .buffer = .{
                    .type = Wgpu.WGPUBufferBindingType_Uniform,
                },
            },
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
            .entryCount = 1,
            .entries = &[_]Wgpu.WGPUBindGroupEntry{
                .{ .binding = 0, .buffer = uniform_buffer, .offset = 0, .size = @sizeOf(SkyUniform) },
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
            .day_length = 10.0,
            .cached_inv_proj = Mat4.identity,
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
    }
};
