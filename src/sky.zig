// sky.zig — 全屏三角 + cubemap 噪声云渲染
const std = @import("std");
const Wgpu = @import("imports.zig").Wgpu;
const Gctx = @import("gctx.zig");
const Vec2 = @import("algebra.zig").Vec2;
const Vec3 = @import("algebra.zig").Vec3;
const Vec4 = @import("algebra.zig").Vec4;
const Mat4 = @import("algebra.zig").Mat4;
const zigimg = @import("zigimg");

pub const SkyUniform = struct {
    inv_view_proj: Mat4,
    sun_direction: Vec4,
    sun_color: Vec4,
    horizon_color: Vec4,
    mid_color: Vec4,
    zenith_color: Vec4,
    cloud_params1: Vec4, // x=云量, y=Y轴压缩, z=天空中间色高度, w=风速
    cloud_params2: Vec4, // x=风向_X, y=风向_Z, z=云图缩放(越大云纹越细), w=光照偏移距
    cloud_color0: Vec4,
    cloud_color1: Vec4,
    cloud_color2: Vec4,
    time: f32,
    sun_intensity: f32,
    moon_phase: f32,
    moon_brightness: f32,
    star_density: f32,
    star_twinkle_speed: f32,
    star_color_strength: f32,
    back_lit_strength: f32,
    edge_lit_power: f32,
    edge_lit_strength: f32,
    cloud_color_mtime: f32,
    _pad: [1]f32 = undefined,

    pub fn pack(inv_view_proj: Mat4, state: SkyState, time: f32) SkyUniform {
        return .{
            .inv_view_proj = inv_view_proj,
            .sun_direction = Vec4{ .x = state.sun_direction.x, .y = state.sun_direction.y, .z = state.sun_direction.z, .w = 0 },
            .sun_color = Vec4{ .x = state.sun_color.x, .y = state.sun_color.y, .z = state.sun_color.z, .w = 0 },
            .horizon_color = Vec4{ .x = state.horizon_color.x, .y = state.horizon_color.y, .z = state.horizon_color.z, .w = 0 },
            .mid_color = Vec4{ .x = state.mid_color.x, .y = state.mid_color.y, .z = state.mid_color.z, .w = 0 },
            .zenith_color = Vec4{ .x = state.zenith_color.x, .y = state.zenith_color.y, .z = state.zenith_color.z, .w = 0 },
            .cloud_params1 = Vec4{ .x = state.cloud_coverage, .y = state.cloud_squish, .z = state.cloud_altitude, .w = state.cloud_speed },
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
    sun_direction: Vec3,
    sun_color: Vec3,
    sun_intensity: f32,
    moon_phase: f32,
    moon_brightness: f32,
    moon_color: Vec3,
    horizon_color: Vec3,
    mid_color: Vec3,
    zenith_color: Vec3,
    ambient_ground: Vec3,
    star_density: f32,
    star_twinkle_speed: f32,
    star_color_strength: f32,
    seasonal_tilt: f32 = 0,
    cloud_coverage: f32,
    cloud_squish: f32,
    cloud_altitude: f32,
    cloud_speed: f32,
    cloud_size: f32,
    wind_dir: Vec2,
    offset_distance: f32,
    cloud_color0: Vec3,
    cloud_color1: Vec3,
    cloud_color2: Vec3,
    back_lit_strength: f32,
    edge_lit_power: f32,
    edge_lit_strength: f32,
    cloud_color_mtime: f32,

    pub fn generate(seed: u64) SkyState {
        var prng = std.Random.DefaultPrng.init(seed);
        const r = prng.random();
        return .{
            .sun_direction = Vec3.norm(Vec3.new(-0.3 + r.float(f32) * 0.6, 0.3 + r.float(f32) * 0.5, -0.5 + r.float(f32) * 0.6)),
            .sun_color = Vec3.new(1.0, 0.95, 0.90),
            .sun_intensity = 0.6 + r.float(f32) * 0.6,
            .moon_phase = r.float(f32),
            .moon_brightness = 0.3 + r.float(f32) * 0.6,
            .moon_color = Vec3.new(0.5, 0.55, 0.8),
            .horizon_color = Vec3.new(0.6, 0.7, 1.0),
            .mid_color = Vec3.new(0.3, 0.5, 0.9),
            .zenith_color = Vec3.new(0.05, 0.1, 0.5),
            .ambient_ground = Vec3.new(1.0, 1.0, 1.0),
            .star_density = 0.03 + r.float(f32) * 0.07,
            .star_twinkle_speed = 1.0 + r.float(f32) * 1.0,
            .star_color_strength = r.float(f32) * r.float(f32) * 0.6,
            .seasonal_tilt = 0,
            .cloud_coverage = 1.2,
            .cloud_squish = 1.5,
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

const SkyColorKeyframe = struct {
    t: f32,
    horizon: Vec3,
    mid: Vec3,
    zenith: Vec3,
    ambient: Vec3,
    sun_color: Vec3,
    cloud0: Vec3,
    cloud1: Vec3,
    cloud2: Vec3,
};

const sky_color_keyframes = [_]SkyColorKeyframe{
    .{ // t=0.00 正午
        .t = 0.00,
        .horizon = Vec3.new(0.6, 0.7, 1.0),
        .mid = Vec3.new(0.3, 0.5, 0.9),
        .zenith = Vec3.new(0.3, 0.5, 0.9),
        .ambient = Vec3.new(1.0, 1.0, 1.0),
        .sun_color = Vec3.new(1.0, 0.95, 0.9),
        .cloud0 = Vec3.new(0.2, 0.2, 0.2),
        .cloud1 = Vec3.new(0.65, 0.65, 0.65),
        .cloud2 = Vec3.new(1.0, 1.0, 1.0),
    },
    .{ // t=0.15 下午
        .t = 0.15,
        .horizon = Vec3.new(0.6, 0.7, 1.0),
        .mid = Vec3.new(0.3, 0.5, 0.9),
        .zenith = Vec3.new(0.3, 0.5, 0.9),
        .ambient = Vec3.new(1.0, 1.0, 1.0),
        .sun_color = Vec3.new(1.0, 0.97, 0.92),
        .cloud0 = Vec3.new(0.2, 0.2, 0.2),
        .cloud1 = Vec3.new(0.65, 0.65, 0.65),
        .cloud2 = Vec3.new(1.0, 1.0, 1.0),
    },
    .{ // t=0.25 日落
        .t = 0.25,
        .horizon = Vec3.new(1.0, 0.5, 0.2),
        .mid = Vec3.new(0.8, 0.4, 0.3),
        .zenith = Vec3.new(0.8, 0.4, 0.3),
        .ambient = Vec3.new(1.0, 0.5, 0.2),
        .sun_color = Vec3.new(1.0, 0.5, 0.2),
        .cloud0 = Vec3.new(0.3, 0.15, 0.1),
        .cloud1 = Vec3.new(0.6, 0.35, 0.2),
        .cloud2 = Vec3.new(1.0, 0.7, 0.4),
    },
    .{ // t=0.30 黄昏
        .t = 0.30,
        .horizon = Vec3.new(0.005, 0.05, 0.25),
        .mid = Vec3.new(0.005, 0.02, 0.15),
        .zenith = Vec3.new(0.005, 0.01, 0.10),
        .ambient = Vec3.new(0.35, 0.45, 0.75),
        .sun_color = Vec3.new(0.2, 0.1, 0.3),
        .cloud0 = Vec3.new(0.005, 0.02, 0.08),
        .cloud1 = Vec3.new(0.005, 0.04, 0.14),
        .cloud2 = Vec3.new(0.005, 0.06, 0.25),
    },
    .{ // t=0.50 午夜
        .t = 0.50,
        .horizon = Vec3.new(0.005, 0.02, 0.12),
        .mid = Vec3.new(0.005, 0.01, 0.08),
        .zenith = Vec3.new(0.005, 0.005, 0.06),
        .ambient = Vec3.new(0.24, 0.35, 0.6),
        .sun_color = Vec3.new(0.0, 0.0, 0.0),
        .cloud0 = Vec3.new(0.005, 0.01, 0.06),
        .cloud1 = Vec3.new(0.005, 0.02, 0.10),
        .cloud2 = Vec3.new(0.005, 0.04, 0.18),
    },
    .{ // t=0.65 曙光前
        .t = 0.65,
        .horizon = Vec3.new(0.005, 0.03, 0.18),
        .mid = Vec3.new(0.005, 0.02, 0.12),
        .zenith = Vec3.new(0.005, 0.01, 0.08),
        .ambient = Vec3.new(0.35, 0.45, 0.75),
        .sun_color = Vec3.new(0.1, 0.08, 0.15),
        .cloud0 = Vec3.new(0.005, 0.02, 0.08),
        .cloud1 = Vec3.new(0.005, 0.03, 0.12),
        .cloud2 = Vec3.new(0.005, 0.05, 0.22),
    },
    .{ // t=0.75 日出
        .t = 0.75,
        .horizon = Vec3.new(1.0, 0.6, 0.2),
        .mid = Vec3.new(0.7, 0.5, 0.3),
        .zenith = Vec3.new(0.7, 0.5, 0.3),
        .ambient = Vec3.new(1.0, 0.6, 0.2),
        .sun_color = Vec3.new(1.0, 0.55, 0.25),
        .cloud0 = Vec3.new(0.35, 0.2, 0.12),
        .cloud1 = Vec3.new(0.65, 0.4, 0.22),
        .cloud2 = Vec3.new(1.0, 0.75, 0.45),
    },
    .{ // t=0.85 上午
        .t = 0.85,
        .horizon = Vec3.new(0.6, 0.7, 1.0),
        .mid = Vec3.new(0.35, 0.5, 0.85),
        .zenith = Vec3.new(0.35, 0.5, 0.85),
        .ambient = Vec3.new(1.0, 1.0, 1.0),
        .sun_color = Vec3.new(1.0, 0.97, 0.92),
        .cloud0 = Vec3.new(0.2, 0.2, 0.2),
        .cloud1 = Vec3.new(0.65, 0.65, 0.65),
        .cloud2 = Vec3.new(1.0, 1.0, 1.0),
    },
    .{ // t=1.00=0.00（回到正午，用于循环插值）
        .t = 1.00,
        .horizon = Vec3.new(0.6, 0.7, 1.0),
        .mid = Vec3.new(0.3, 0.5, 0.9),
        .zenith = Vec3.new(0.3, 0.5, 0.9),
        .ambient = Vec3.new(1.0, 1.0, 1.0),
        .sun_color = Vec3.new(1.0, 0.95, 0.9),
        .cloud0 = Vec3.new(0.2, 0.2, 0.2),
        .cloud1 = Vec3.new(0.65, 0.65, 0.65),
        .cloud2 = Vec3.new(1.0, 1.0, 1.0),
    },
};

fn interpolateSkyColors(t: f32) struct { horizon: Vec3, mid: Vec3, zenith: Vec3, ambient: Vec3, sun_color: Vec3, cloud0: Vec3, cloud1: Vec3, cloud2: Vec3 } {
    const clamped_t = t - @floor(t);
    var i: usize = 0;
    while (i < sky_color_keyframes.len - 1 and clamped_t > sky_color_keyframes[i + 1].t) {
        i += 1;
    }
    const a = sky_color_keyframes[i];
    const b = sky_color_keyframes[i + 1];
    const local_t = (clamped_t - a.t) / (b.t - a.t);
    const lerp = Vec3.lerp;
    return .{
        .horizon = lerp(a.horizon, b.horizon, local_t),
        .mid = lerp(a.mid, b.mid, local_t),
        .zenith = lerp(a.zenith, b.zenith, local_t),
        .ambient = lerp(a.ambient, b.ambient, local_t),
        .sun_color = lerp(a.sun_color, b.sun_color, local_t),
        .cloud0 = lerp(a.cloud0, b.cloud0, local_t),
        .cloud1 = lerp(a.cloud1, b.cloud1, local_t),
        .cloud2 = lerp(a.cloud2, b.cloud2, local_t),
    };
}

pub const SkyPipeline = struct {
    handle: Wgpu.WGPURenderPipeline,
    bind_group_layout: Wgpu.WGPUBindGroupLayout,
    bind_group: Wgpu.WGPUBindGroup,
    uniform_buffer: Wgpu.WGPUBuffer,
    shader_module: Wgpu.WGPUShaderModule,
    state: SkyState,
    day_length: f32 = 60.0,
    cubemap_texture: Wgpu.WGPUTexture,
    cubemap_texture_view: Wgpu.WGPUTextureView,
    cubemap_sampler: Wgpu.WGPUSampler,
    moon_texture: Wgpu.WGPUTexture,
    moon_texture_view: Wgpu.WGPUTextureView,
    moon_sampler: Wgpu.WGPUSampler,

    pub fn init(gctx: *Gctx, seed: u64) !SkyPipeline {
        const shader_module = try gctx.createShaderModule("resources/shaders/sky_shader.wgsl");

        // CPU 烘培 3D 噪声 cubemap（6 面，每面 512²）
        const noise = @import("noise.zig");
        const face_size: u32 = 512;
        const freq: f32 = 3.0;
        const fd = try std.heap.page_allocator.alloc(u8, face_size * face_size * 4);
        defer std.heap.page_allocator.free(fd);

        const cubemap_texture = Wgpu.wgpuDeviceCreateTexture(gctx.device, &.{
            .usage = Wgpu.WGPUTextureUsage_CopyDst | Wgpu.WGPUTextureUsage_TextureBinding,
            .dimension = Wgpu.WGPUTextureDimension_2D,
            .size = .{ .width = face_size, .height = face_size, .depthOrArrayLayers = 6 },
            .format = Wgpu.WGPUTextureFormat_RGBA8Unorm,
            .mipLevelCount = 1,
            .sampleCount = 1,
        });

        for (0..6) |face| {
            for (0..face_size) |y| {
                for (0..face_size) |x| {
                    const u = (@as(f32, @floatFromInt(x)) + 0.5) / @as(f32, @floatFromInt(face_size)) * 2.0 - 1.0;
                    const v = (@as(f32, @floatFromInt(y)) + 0.5) / @as(f32, @floatFromInt(face_size)) * 2.0 - 1.0;
                    const dir = switch (face) {
                        0 => Vec3.norm(Vec3.new(1, -v, -u)),
                        1 => Vec3.norm(Vec3.new(-1, -v, u)),
                        2 => Vec3.norm(Vec3.new(u, 1, v)),
                        3 => Vec3.norm(Vec3.new(u, -1, -v)),
                        4 => Vec3.norm(Vec3.new(u, -v, 1)),
                        5 => Vec3.norm(Vec3.new(-u, -v, -1)),
                        else => unreachable,
                    };
                    const d = Vec3.norm(dir);
                    const n = noise.fbmSnoise3(Vec3.new(d.x * freq, d.y * freq, d.z * freq), 4);
                    const val = @as(u8, @intFromFloat(@min(@max(n * 0.5 + 0.5, 0) * 255.0, 255.0)));
                    const n2 = noise.fbmSnoise3(Vec3.new(d.x * freq * 2.3 + 10.0, d.y * freq * 2.3 + 20.0, d.z * freq * 2.3 + 30.0), 3);
                    const val2 = @as(u8, @intFromFloat(@min(@max(n2 * 0.5 + 0.5, 0) * 255.0, 255.0)));
                    const idx = (y * face_size + x) * 4;
                    fd[idx + 0] = val; // R: 低层云
                    fd[idx + 1] = val2; // G: 高层薄云
                    fd[idx + 2] = 0;
                    fd[idx + 3] = 255;
                }
            }
            Wgpu.wgpuQueueWriteTexture(
                gctx.queue,
                &Wgpu.WGPUTexelCopyTextureInfo{ .texture = cubemap_texture, .mipLevel = 0, .origin = .{ .x = 0, .y = 0, .z = @intCast(face) } },
                fd.ptr,
                face_size * face_size * 4,
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

        // 加载月亮 2D 纹理
        var moon_read_buf: [8192]u8 = undefined;
        var moon_img = try zigimg.Image.fromFilePath(std.heap.page_allocator, "resources/textures/sky/moon.png", &moon_read_buf);
        defer moon_img.deinit(std.heap.page_allocator);
        if (moon_img.pixels != .rgba32) try moon_img.convert(std.heap.page_allocator, .rgba32);
        const moon_w: u32 = @intCast(moon_img.width);
        const moon_h: u32 = @intCast(moon_img.height);
        const moon_pixels = moon_img.pixels.rgba32;
        const moon_bytes = try std.heap.page_allocator.alloc(u8, moon_w * moon_h * 4);
        defer std.heap.page_allocator.free(moon_bytes);
        @memcpy(moon_bytes[0 .. moon_w * moon_h * 4], @as([*]const u8, @ptrCast(moon_pixels.ptr))[0 .. moon_w * moon_h * 4]);

        const moon_texture = Wgpu.wgpuDeviceCreateTexture(gctx.device, &.{
            .usage = Wgpu.WGPUTextureUsage_CopyDst | Wgpu.WGPUTextureUsage_TextureBinding,
            .dimension = Wgpu.WGPUTextureDimension_2D,
            .size = .{ .width = moon_w, .height = moon_h, .depthOrArrayLayers = 1 },
            .format = Wgpu.WGPUTextureFormat_RGBA8Unorm,
            .mipLevelCount = 1,
            .sampleCount = 1,
        });
        Wgpu.wgpuQueueWriteTexture(
            gctx.queue,
            &Wgpu.WGPUTexelCopyTextureInfo{ .texture = moon_texture, .mipLevel = 0, .origin = .{ .x = 0, .y = 0, .z = 0 } },
            moon_bytes.ptr,
            moon_bytes.len,
            &Wgpu.WGPUTexelCopyBufferLayout{ .offset = 0, .bytesPerRow = moon_w * 4, .rowsPerImage = moon_h },
            &Wgpu.WGPUExtent3D{ .width = moon_w, .height = moon_h, .depthOrArrayLayers = 1 },
        );
        const moon_texture_view = Wgpu.wgpuTextureCreateView(moon_texture, &.{
            .aspect = Wgpu.WGPUTextureAspect_All,
            .dimension = Wgpu.WGPUTextureViewDimension_2D,
            .format = Wgpu.WGPUTextureFormat_RGBA8Unorm,
            .baseMipLevel = 0,
            .mipLevelCount = 1,
            .baseArrayLayer = 0,
            .arrayLayerCount = 1,
        });
        const moon_sampler = Wgpu.wgpuDeviceCreateSampler(gctx.device, &.{
            .addressModeU = Wgpu.WGPUAddressMode_ClampToEdge,
            .addressModeV = Wgpu.WGPUAddressMode_ClampToEdge,
            .addressModeW = Wgpu.WGPUAddressMode_ClampToEdge,
            .magFilter = Wgpu.WGPUFilterMode_Nearest,
            .minFilter = Wgpu.WGPUFilterMode_Nearest,
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
            .{ .binding = 3, .visibility = Wgpu.WGPUShaderStage_Fragment, .texture = .{ .sampleType = Wgpu.WGPUTextureSampleType_Float, .viewDimension = Wgpu.WGPUTextureViewDimension_2D } },
            .{ .binding = 4, .visibility = Wgpu.WGPUShaderStage_Fragment, .sampler = .{ .type = Wgpu.WGPUSamplerBindingType_Filtering } },
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
            .entryCount = 5,
            .entries = &[_]Wgpu.WGPUBindGroupEntry{
                .{ .binding = 0, .buffer = uniform_buffer, .offset = 0, .size = @sizeOf(SkyUniform) },
                .{ .binding = 1, .textureView = cubemap_texture_view },
                .{ .binding = 2, .sampler = cubemap_sampler },
                .{ .binding = 3, .textureView = moon_texture_view },
                .{ .binding = 4, .sampler = moon_sampler },
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
            .day_length = 1440,
            .cubemap_texture = cubemap_texture,
            .cubemap_texture_view = cubemap_texture_view,
            .cubemap_sampler = cubemap_sampler,
            .moon_texture = moon_texture,
            .moon_texture_view = moon_texture_view,
            .moon_sampler = moon_sampler,
        };
    }

    pub fn updateUniform(self: *SkyPipeline, gctx: *Gctx, inv_view_proj: Mat4, time: f32) void {
        const angle = (time / self.day_length) * 2.0 * std.math.pi;
        const sin_a = std.math.sin(angle);
        const cos_a = std.math.cos(angle);
        const c25: f32 = 0.906; // cos(25°)
        const s25: f32 = 0.423; // sin(25°)
        self.state.sun_direction = Vec3.norm(Vec3.new(
            (sin_a * 0.8) * c25 - (cos_a * 0.3) * s25, // XZ 绕 Y 轴旋转 25°
            cos_a * 0.6 + self.state.seasonal_tilt,
            -(sin_a * 0.8) * s25 + (cos_a * 0.3) * c25,
        ));

        // 天空颜色关键帧插值
        const colors = interpolateSkyColors(time / self.day_length);
        self.state.horizon_color = colors.horizon;
        self.state.mid_color = colors.mid;
        self.state.zenith_color = colors.zenith;
        self.state.ambient_ground = colors.ambient;
        self.state.sun_color = colors.sun_color;
        self.state.cloud_color0 = colors.cloud0;
        self.state.cloud_color1 = colors.cloud1;
        self.state.cloud_color2 = colors.cloud2;

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
        Wgpu.wgpuTextureRelease(self.moon_texture);
        Wgpu.wgpuTextureViewRelease(self.moon_texture_view);
        Wgpu.wgpuSamplerRelease(self.moon_sampler);
    }
};
