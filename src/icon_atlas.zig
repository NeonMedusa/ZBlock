// icon_atlas.zig — RingBuffer 缓存的方块图标图集 + 渲染管线
const std = @import("std");
const Allocator = std.mem.Allocator;
const Gctx = @import("gctx.zig");
const Wgpu = @import("imports.zig").Wgpu;
const zigimg = @import("zigimg");
const BlockRegistry = @import("block_registry.zig");
const BlockId = BlockRegistry.BlockId;

const ICON_SLOT: u32 = 16;
const ATLAS_W: u32 = 2048;
const ATLAS_H: u32 = 2048;
const PER_ROW: u32 = ATLAS_W / ICON_SLOT; // 128
const MAX_SLOTS: u32 = PER_ROW * PER_ROW; // 16384
const MAX_ICON_VERTS: u32 = 512; // ~85 个 quad (6 顶点/quad)

/// 图标顶点格式
pub const IconVertex = struct {
    pos: [2]f32,
    uv: [2]f32,
};

/// 图标渲染管线
pub const IconPipeline = struct {
    handle: Wgpu.WGPURenderPipeline,
    bind_group: Wgpu.WGPUBindGroup,
    bind_group_layout: Wgpu.WGPUBindGroupLayout,
    pipeline_layout: Wgpu.WGPUPipelineLayout,
    shader_module: Wgpu.WGPUShaderModule,
    sampler: Wgpu.WGPUSampler,

    const wgsl =
        \\@group(0) @binding(0) var<uniform> u: mat4x4f;
        \\@group(0) @binding(1) var t: texture_2d<f32>;
        \\@group(0) @binding(2) var s: sampler;
        \\struct VIn { @location(0) pos: vec2f, @location(1) uv: vec2f };
        \\struct VOut { @builtin(position) pos: vec4f, @location(0) uv: vec2f };
        \\@vertex fn vs(in: VIn) -> VOut {
        \\    var o: VOut; o.pos = u * vec4f(in.pos, 0.0, 1.0); o.uv = in.uv; return o;
        \\}
        \\@fragment fn fs(in: VOut) -> @location(0) vec4f {
        \\    return textureSample(t, s, in.uv);
        \\}
    ;

    fn init(device: Wgpu.WGPUDevice, uniform_buffer: Wgpu.WGPUBuffer, tex_view: Wgpu.WGPUTextureView) !IconPipeline {
        const sm = blk: {
            const src = Wgpu.struct_WGPUShaderSourceWGSL{
                .code = .{ .data = wgsl.ptr, .length = wgsl.len },
                .chain = .{ .sType = Wgpu.WGPUSType_ShaderSourceWGSL },
            };
            break :blk Wgpu.wgpuDeviceCreateShaderModule(device, &.{ .nextInChain = &src.chain });
        };
        const sampler = Wgpu.wgpuDeviceCreateSampler(device, &.{
            .addressModeU = Wgpu.WGPUAddressMode_ClampToEdge,
            .addressModeV = Wgpu.WGPUAddressMode_ClampToEdge,
            .addressModeW = Wgpu.WGPUAddressMode_ClampToEdge,
            .magFilter = Wgpu.WGPUFilterMode_Linear,
            .minFilter = Wgpu.WGPUFilterMode_Linear,
            .mipmapFilter = Wgpu.WGPUMipmapFilterMode_Nearest,
            .lodMinClamp = 0, .lodMaxClamp = 32,
            .compare = Wgpu.WGPUCompareFunction_Undefined,
            .maxAnisotropy = 1,
        });
        const bgl_entries = [_]Wgpu.WGPUBindGroupLayoutEntry{
            .{ .binding = 0, .visibility = Wgpu.WGPUShaderStage_Vertex, .buffer = .{ .type = Wgpu.WGPUBufferBindingType_Uniform, .hasDynamicOffset = 0 } },
            .{ .binding = 1, .visibility = Wgpu.WGPUShaderStage_Fragment, .texture = .{ .sampleType = Wgpu.WGPUTextureSampleType_Float, .viewDimension = Wgpu.WGPUTextureViewDimension_2D, .multisampled = 0 } },
            .{ .binding = 2, .visibility = Wgpu.WGPUShaderStage_Fragment, .sampler = .{ .type = Wgpu.WGPUSamplerBindingType_Filtering } },
        };
        const bgl = Wgpu.wgpuDeviceCreateBindGroupLayout(device, &.{ .entryCount = bgl_entries.len, .entries = &bgl_entries });
        const bg = Wgpu.wgpuDeviceCreateBindGroup(device, &.{
            .layout = bgl, .entryCount = bgl_entries.len,
            .entries = &[_]Wgpu.WGPUBindGroupEntry{
                .{ .binding = 0, .buffer = uniform_buffer, .offset = 0, .size = Wgpu.wgpuBufferGetSize(uniform_buffer) },
                .{ .binding = 1, .textureView = tex_view },
                .{ .binding = 2, .sampler = sampler },
            },
        });
        const pl = Wgpu.wgpuDeviceCreatePipelineLayout(device, &.{ .bindGroupLayoutCount = 1, .bindGroupLayouts = &bgl });
        const attribs = Gctx.generateVertexAttributes(IconVertex);
        const blend = Wgpu.WGPUBlendState{
            .color = .{ .operation = Wgpu.WGPUBlendOperation_Add, .srcFactor = Wgpu.WGPUBlendFactor_SrcAlpha, .dstFactor = Wgpu.WGPUBlendFactor_OneMinusSrcAlpha },
            .alpha = .{ .operation = Wgpu.WGPUBlendOperation_Add, .srcFactor = Wgpu.WGPUBlendFactor_One, .dstFactor = Wgpu.WGPUBlendFactor_OneMinusSrcAlpha },
        };
        const ds = Wgpu.WGPUDepthStencilState{
            .format = Wgpu.WGPUTextureFormat_Depth24Plus,
            .depthWriteEnabled = 0, .depthCompare = Wgpu.WGPUCompareFunction_Always,
            .stencilFront = .{}, .stencilBack = .{}, .stencilReadMask = 0, .stencilWriteMask = 0,
            .depthBias = 0, .depthBiasSlopeScale = 0, .depthBiasClamp = 0,
        };
        const desc = Wgpu.WGPURenderPipelineDescriptor{
            .layout = pl,
            .vertex = .{
                .bufferCount = 1,
                .buffers = &Wgpu.WGPUVertexBufferLayout{
                    .arrayStride = @sizeOf(IconVertex),
                    .stepMode = Wgpu.WGPUVertexStepMode_Vertex,
                    .attributeCount = attribs.len, .attributes = &attribs,
                },
                .module = sm,
                .entryPoint = .{ .data = "vs", .length = 2 },
            },
            .primitive = .{ .topology = Wgpu.WGPUPrimitiveTopology_TriangleList },
            .fragment = &Wgpu.WGPUFragmentState{
                .module = sm, .entryPoint = .{ .data = "fs", .length = 2 },
                .targetCount = 1,
                .targets = &Wgpu.WGPUColorTargetState{
                    .format = Wgpu.WGPUTextureFormat_BGRA8UnormSrgb,
                    .blend = &blend, .writeMask = Wgpu.WGPUColorWriteMask_All,
                },
            },
            .multisample = .{ .count = 1, .mask = Wgpu.WGPUColorWriteMask_All },
            .depthStencil = &ds,
        };
        return IconPipeline{
            .handle = Wgpu.wgpuDeviceCreateRenderPipeline(device, &desc),
            .bind_group = bg, .bind_group_layout = bgl, .pipeline_layout = pl,
            .shader_module = sm, .sampler = sampler,
        };
    }

    fn deinit(self: @This()) void {
        Wgpu.wgpuRenderPipelineRelease(self.handle);
        Wgpu.wgpuBindGroupLayoutRelease(self.bind_group_layout);
        Wgpu.wgpuBindGroupRelease(self.bind_group);
        Wgpu.wgpuPipelineLayoutRelease(self.pipeline_layout);
        Wgpu.wgpuShaderModuleRelease(self.shader_module);
        Wgpu.wgpuSamplerRelease(self.sampler);
    }
};

/// RingBuffer 缓存的方块图标图集，按需加载方块 variant 0 纹理并缩放到 16×16
pub const IconAtlas = struct {
    allocator: Allocator,
    gctx: *Gctx,
    texture: Wgpu.WGPUTexture,
    texture_view: Wgpu.WGPUTextureView,
    slots: [MAX_SLOTS]?u32,
    next_free: u32,
    pipeline: IconPipeline,
    vertex_buffer: Wgpu.WGPUBuffer,
    vertex_count: u32,
    /// 内部顶点缓冲区（每帧由 addQuad 填充，upload 上传）
    frame_vertices: [MAX_ICON_VERTS]IconVertex = undefined,

    pub fn init(allocator: Allocator, gctx: *Gctx, uniform_buffer: Wgpu.WGPUBuffer) !IconAtlas {
        const tex = Wgpu.wgpuDeviceCreateTexture(gctx.device, &.{
            .usage = @as(Wgpu.WGPUTextureUsage, Wgpu.WGPUTextureUsage_CopyDst) | Wgpu.WGPUTextureUsage_TextureBinding,
            .dimension = Wgpu.WGPUTextureDimension_2D,
            .size = .{ .width = ATLAS_W, .height = ATLAS_H, .depthOrArrayLayers = 1 },
            .format = Wgpu.WGPUTextureFormat_RGBA8Unorm,
            .mipLevelCount = 1, .sampleCount = 1,
            .viewFormatCount = 0, .viewFormats = null,
        });
        const view = Wgpu.wgpuTextureCreateView(tex, null);
        // 初始化为全透明黑色
        {
            const buf = try allocator.alloc(u8, ATLAS_W * ATLAS_H * 4);
            defer allocator.free(buf);
            @memset(buf, 0);
            Wgpu.wgpuQueueWriteTexture(
                gctx.queue,
                &.{ .texture = tex, .mipLevel = 0, .origin = .{ .x = 0, .y = 0, .z = 0 }, .aspect = Wgpu.WGPUTextureAspect_All },
                buf.ptr, @sizeOf(u32) * ATLAS_W * ATLAS_H,
                &.{ .offset = 0, .bytesPerRow = ATLAS_W * 4, .rowsPerImage = ATLAS_H },
                &.{ .width = ATLAS_W, .height = ATLAS_H, .depthOrArrayLayers = 1 },
            );
        }
        const vtx_buf = Wgpu.wgpuDeviceCreateBuffer(gctx.device, &.{
            .usage = Wgpu.WGPUBufferUsage_CopyDst | Wgpu.WGPUBufferUsage_Vertex,
            .size = MAX_ICON_VERTS * @sizeOf(IconVertex),
            .mappedAtCreation = 0,
        });
        return IconAtlas{
            .allocator = allocator,
            .gctx = gctx,
            .texture = tex,
            .texture_view = view,
            .slots = .{null} ** MAX_SLOTS,
            .next_free = 0,
            .pipeline = try IconPipeline.init(gctx.device, uniform_buffer, view),
            .vertex_buffer = vtx_buf,
            .vertex_count = 0,
        };
    }

    pub fn deinit(self: *IconAtlas) void {
        Wgpu.wgpuTextureRelease(self.texture);
        Wgpu.wgpuTextureViewRelease(self.texture_view);
        Wgpu.wgpuBufferRelease(self.vertex_buffer);
        self.pipeline.deinit();
    }

    /// 重置顶点计数（帧开头调用）
    pub fn reset(self: *IconAtlas) void {
        self.vertex_count = 0;
    }

    /// 上传当前帧的顶点数据到 GPU
    pub fn upload(self: *IconAtlas, queue: Wgpu.WGPUQueue) void {
        if (self.vertex_count > 0) {
            Wgpu.wgpuQueueWriteBuffer(
                queue, self.vertex_buffer, 0,
                &self.frame_vertices,
                self.vertex_count * @sizeOf(IconVertex),
            );
        }
    }

    /// 向当前帧的顶点列表添加一个正方形 quad（6 个顶点，两个三角形）
    pub fn addQuad(self: *IconAtlas, uvs: [4][2]f32, x: f32, y: f32, size: f32) void {
        if (self.vertex_count + 6 > MAX_ICON_VERTS) return;
        const v = self.vertex_count;
        var fv = &self.frame_vertices;
        fv[v + 0] = .{ .pos = .{ x, y }, .uv = uvs[0] };
        fv[v + 1] = .{ .pos = .{ x + size, y }, .uv = uvs[1] };
        fv[v + 2] = .{ .pos = .{ x + size, y + size }, .uv = uvs[2] };
        fv[v + 3] = .{ .pos = .{ x, y }, .uv = uvs[0] };
        fv[v + 4] = .{ .pos = .{ x + size, y + size }, .uv = uvs[2] };
        fv[v + 5] = .{ .pos = .{ x, y + size }, .uv = uvs[3] };
        self.vertex_count += 6;
    }

    /// 获取 block_id 的图集槽位索引，未缓存则自动加载
    pub fn getOrLoad(self: *IconAtlas, block_id: u32) ?u32 {
        for (self.slots, 0..) |maybe, i| {
            if (maybe) |stored| if (stored == block_id) return @intCast(i);
        }
        const dst = self.next_free;
        self.next_free = (self.next_free + 1) % MAX_SLOTS;

        const name = BlockId.fromInt(block_id).name();
        const path = std.fmt.allocPrint(self.allocator, "resources/textures/{s}_0.png", .{name}) catch return null;
        defer self.allocator.free(path);
        var rgba: [ICON_SLOT * ICON_SLOT * 4]u8 = .{0} ** (ICON_SLOT * ICON_SLOT * 4);
        loadAndScale(path, &rgba);

        const sx = (@as(u32, @intCast(dst)) % PER_ROW) * ICON_SLOT;
        const sy = (@as(u32, @intCast(dst)) / PER_ROW) * ICON_SLOT;
        Wgpu.wgpuQueueWriteTexture(
            self.gctx.queue,
            &.{ .texture = self.texture, .mipLevel = 0, .origin = .{ .x = sx, .y = sy, .z = 0 }, .aspect = Wgpu.WGPUTextureAspect_All },
            &rgba, @sizeOf(u32) * ICON_SLOT * ICON_SLOT,
            &.{ .offset = 0, .bytesPerRow = ICON_SLOT * 4, .rowsPerImage = ICON_SLOT },
            &.{ .width = ICON_SLOT, .height = ICON_SLOT, .depthOrArrayLayers = 1 },
        );
        self.slots[@as(usize, @intCast(dst))] = block_id;
        return @intCast(dst);
    }

    /// 将槽位索引转换为四个角的 UV 坐标
    pub fn slotUV(idx: u32) [4][2]f32 {
        const per = @as(f32, @floatFromInt(PER_ROW));
        const row = idx / PER_ROW;
        const col = idx % PER_ROW;
        const u_min = @as(f32, @floatFromInt(col)) / per;
        const v_min = @as(f32, @floatFromInt(row)) / per;
        const u_max = (@as(f32, @floatFromInt(col)) + 1) / per;
        const v_max = (@as(f32, @floatFromInt(row)) + 1) / per;
        return .{ .{ u_min, v_min }, .{ u_max, v_min }, .{ u_max, v_max }, .{ u_min, v_max } };
    }
};

fn loadAndScale(path: []const u8, dst: *[ICON_SLOT * ICON_SLOT * 4]u8) void {
    var read_buf: [8192]u8 = undefined;
    var img = zigimg.Image.fromFilePath(std.heap.page_allocator, path, &read_buf) catch return;
    defer img.deinit(std.heap.page_allocator);
    if (img.pixels != .rgba32) img.convert(std.heap.page_allocator, .rgba32) catch return;
    const rgba = img.pixels.rgba32;
    const sw: u32 = @intCast(img.width);
    const sh: u32 = @intCast(img.height);
    if (sw == 0 or sh == 0) return;
    for (0..ICON_SLOT) |dy| {
        for (0..ICON_SLOT) |dx| {
            const sx = @min(dx * sw / ICON_SLOT, sw - 1);
            const sy = @min(dy * sh / ICON_SLOT, sh - 1);
            const src = rgba[sy * sw + sx];
            const d = (dy * ICON_SLOT + dx) * 4;
            dst[d + 0] = src.r; dst[d + 1] = src.g;
            dst[d + 2] = src.b; dst[d + 3] = src.a;
        }
    }
}
