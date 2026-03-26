const std = @import("std");
const Import = @import("imports.zig");
const Wgpu = Import.Wgpu;
const Gctx = Import.Gctx;
const RendCTX = Import.RendCTX;
const VertexAttribute = @import("rend_ctx.zig").VertexAttribute;
const Material = @import("rend_ctx.zig").Material;
const MaterialConstants = RendCTX.MaterialConstants;
const RenderPipeline = Import.RenderPipeline;
const Vec3 = Import.Vec3;
const Vec2 = Import.Vec2;
const Vec4 = Import.Vec4;

// terrain.zig
pub const Terrain = struct {
    allocator: std.mem.Allocator,

    // 地形尺寸
    size_x: f32,
    size_z: f32,
    segments: u32,
    height_min: f32,
    height_max: f32,

    // GPU资源
    gctx: *Gctx,
    vertex_buffer: Wgpu.WGPUBuffer,
    index_buffer: Wgpu.WGPUBuffer,
    index_count: u32,

    // 地形数据（归一化存储 [0,1]）
    heights: []f32,
    normals: []Vec3, // 改为 Vec3
    colors: []Vec3, // 改为 Vec3

    // 材质
    material: Material,

    pub fn init(
        allocator: std.mem.Allocator,
        gctx: *Gctx,
        size_x: f32,
        size_z: f32,
        segments: u32,
        height_min: f32,
        height_max: f32,
        render_pipeline: *RenderPipeline,
    ) !Terrain {
        const vertex_count = (segments + 1) * (segments + 1);

        var terrain: Terrain = undefined;
        terrain.allocator = allocator;
        terrain.gctx = gctx;
        terrain.size_x = size_x;
        terrain.size_z = size_z;
        terrain.segments = segments;
        terrain.height_min = height_min;
        terrain.height_max = height_max;

        // 分配数据
        terrain.heights = try allocator.alloc(f32, vertex_count);
        terrain.normals = try allocator.alloc(Vec3, vertex_count);
        terrain.colors = try allocator.alloc(Vec3, vertex_count);

        // 初始化为平面
        @memset(terrain.heights, 0.5);

        // 计算法线和颜色
        terrain.calculateNormals();
        terrain.generateColors();

        // 创建GPU资源
        try terrain.createBuffers(gctx);
        try terrain.createMaterial(gctx, render_pipeline);

        return terrain;
    }

    // 生成随机地形（用于调试）
    pub fn generateRandom(self: *Terrain, seed: u64) void {
        var rng = std.Random.DefaultPrng.init(seed);
        const random = rng.random();

        const segments_f = @as(f32, @floatFromInt(self.segments));

        var min_height: f32 = 1.0;
        var max_height: f32 = 0.0;

        for (0..self.segments + 1) |z| {
            for (0..self.segments + 1) |x| {
                const idx = self.getIndex(x, z);
                const u = @as(f32, @floatFromInt(x)) / segments_f;
                const v = @as(f32, @floatFromInt(z)) / segments_f;

                // 生成范围 [-1, 1] 的高度值
                const h1 = @sin(u * 4.0 * std.math.pi) * @cos(v * 4.0 * std.math.pi);
                const h2 = @sin(u * 8.0 * std.math.pi + 1.0) * 0.3;
                const h3 = @cos(v * 8.0 * std.math.pi) * 0.3;
                const h4 = @sin((u * 16.0 + v * 16.0) * std.math.pi) * 0.1;

                const noise = (random.float(f32) - 0.5) * 0.2;

                var height = (h1 * 2.0 + h2 + h3 + h4) * 0.5 + noise;

                if (height < -1) height = -1;
                if (height > 1) height = 1;

                self.heights[idx] = (height + 1.0) / 2.0;

                const actual = self.getActualHeight(self.heights[idx]);
                if (actual < min_height) min_height = actual;
                if (actual > max_height) max_height = actual;
            }
        }

        std.debug.print("Generated terrain: actual height range [{d:.2}, {d:.2}]\n", .{ min_height, max_height });

        self.calculateNormals();
        self.generateColors();
        self.updateBuffers() catch {};
    }

    // 提升区域（用于编辑器功能）
    pub fn raiseArea(self: *Terrain, center_x: f32, center_z: f32, radius: f32, strength: f32) void {
        const segments_f = @as(f32, @floatFromInt(self.segments));

        for (0..self.segments + 1) |z| {
            for (0..self.segments + 1) |x| {
                const u = @as(f32, @floatFromInt(x)) / segments_f;
                const v = @as(f32, @floatFromInt(z)) / segments_f;

                const world_x = (u - 0.5) * self.size_x;
                const world_z = (v - 0.5) * self.size_z;

                const dx = world_x - center_x;
                const dz = world_z - center_z;
                const dist = @sqrt(dx * dx + dz * dz);

                if (dist < radius) {
                    const factor = (1.0 - dist / radius) * strength;
                    const idx = self.getIndex(x, z);
                    var new_height = self.heights[idx] + factor;
                    if (new_height < 0) new_height = 0;
                    if (new_height > 1) new_height = 1;
                    self.heights[idx] = new_height;
                }
            }
        }

        self.calculateNormals();
        self.generateColors();
        self.updateBuffers() catch {};
    }

    // 获取实际高度（用于单位放置）
    pub fn getHeightAt(self: *Terrain, world_x: f32, world_z: f32) f32 {
        const u = (world_x / self.size_x) + 0.5;
        const v = (world_z / self.size_z) + 0.5;

        if (u < 0 or u > 1 or v < 0 or v > 1) return self.height_min;

        const segments_f = @as(f32, @floatFromInt(self.segments));
        const x = u * segments_f;
        const z = v * segments_f;

        const x0 = @as(u32, @intFromFloat(@floor(x)));
        const x1 = @min(x0 + 1, self.segments);
        const z0 = @as(u32, @intFromFloat(@floor(z)));
        const z1 = @min(z0 + 1, self.segments);

        const fx = x - @as(f32, @floatFromInt(x0));
        const fz = z - @as(f32, @floatFromInt(z0));

        const h00 = self.heights[self.getIndex(x0, z0)];
        const h10 = self.heights[self.getIndex(x1, z0)];
        const h01 = self.heights[self.getIndex(x0, z1)];
        const h11 = self.heights[self.getIndex(x1, z1)];

        const h0 = h00 * (1 - fx) + h10 * fx;
        const h1 = h01 * (1 - fx) + h11 * fx;
        const normalized_height = h0 * (1 - fz) + h1 * fz;

        return self.height_min + normalized_height * (self.height_max - self.height_min);
    }

    // 辅助方法
    fn getIndex(self: *Terrain, x: usize, z: usize) usize {
        return z * (self.segments + 1) + x;
    }

    fn getActualHeight(self: *Terrain, normalized: f32) f32 {
        return self.height_min + normalized * (self.height_max - self.height_min);
    }

    fn calculateNormals(self: *Terrain) void {
        const segments = self.segments;
        const segments_f = @as(f32, @floatFromInt(segments));

        for (0..segments + 1) |z| {
            for (0..segments + 1) |x| {
                const idx = self.getIndex(x, z);
                const h_center = self.heights[idx];

                const h_right = if (x < segments) self.heights[self.getIndex(x + 1, z)] else h_center;
                const h_left = if (x > 0) self.heights[self.getIndex(x - 1, z)] else h_center;
                const h_down = if (z < segments) self.heights[self.getIndex(x, z + 1)] else h_center;
                const h_up = if (z > 0) self.heights[self.getIndex(x, z - 1)] else h_center;

                const segment_size_x = self.size_x / segments_f;
                const segment_size_z = self.size_z / segments_f;

                const actual_h_right = self.getActualHeight(h_right);
                const actual_h_left = self.getActualHeight(h_left);
                const actual_h_down = self.getActualHeight(h_down);
                const actual_h_up = self.getActualHeight(h_up);

                const dx = (actual_h_right - actual_h_left) / (2.0 * segment_size_x);
                const dz = (actual_h_down - actual_h_up) / (2.0 * segment_size_z);

                var nx = -dx;
                var ny: f32 = 1.0;
                var nz = -dz;

                const len = @sqrt(nx * nx + ny * ny + nz * nz);
                if (len > 0.0001) {
                    nx /= len;
                    ny /= len;
                    nz /= len;
                }

                self.normals[idx] = Vec3.new(nx, ny, nz);
            }
        }
    }

    fn generateVertices(self: *Terrain) ![]VertexAttribute {
        const vertex_count = (self.segments + 1) * (self.segments + 1);
        const vertices = try self.allocator.alloc(VertexAttribute, vertex_count);
        const segments_f = @as(f32, @floatFromInt(self.segments));

        for (0..self.segments + 1) |z| {
            for (0..self.segments + 1) |x| {
                const idx = self.getIndex(x, z);
                const u = @as(f32, @floatFromInt(x)) / segments_f;
                const v = @as(f32, @floatFromInt(z)) / segments_f;

                const world_x = (u - 0.5) * self.size_x;
                const world_z = (v - 0.5) * self.size_z;
                const world_y = self.getActualHeight(self.heights[idx]);

                const color = self.colors[idx];
                const normal = self.normals[idx];

                vertices[idx] = .{
                    .position = Vec3.new(world_x, world_y, world_z),
                    .normal = normal,
                    .tangent = Vec4.new(1, 0, 0, 1),
                    .texcoord = Vec2.new(u, v),
                    .color = Vec4.new(color.x, color.y, color.z, 1.0),
                    .joint_indices = .{ 0, 0, 0, 0 },
                    .joint_weights = .{ 1, 0, 0, 0 },
                };
            }
        }

        return vertices;
    }

    fn generateIndices(self: *Terrain) ![]u32 {
        const num_quads = self.segments * self.segments;
        const indices = try self.allocator.alloc(u32, num_quads * 6);

        var idx: u32 = 0;
        for (0..self.segments) |z| {
            for (0..self.segments) |x| {
                const top_left = @as(u32, @intCast(self.getIndex(x, z)));
                const top_right = @as(u32, @intCast(self.getIndex(x + 1, z)));
                const bottom_left = @as(u32, @intCast(self.getIndex(x, z + 1)));
                const bottom_right = @as(u32, @intCast(self.getIndex(x + 1, z + 1)));

                indices[idx] = top_left;
                indices[idx + 1] = bottom_left;
                indices[idx + 2] = top_right;
                indices[idx + 3] = top_right;
                indices[idx + 4] = bottom_left;
                indices[idx + 5] = bottom_right;
                idx += 6;
            }
        }

        return indices;
    }

    fn createBuffers(self: *Terrain, gctx: *Gctx) !void {
        const vertices = try self.generateVertices();
        defer self.allocator.free(vertices);

        const indices = try self.generateIndices();
        defer self.allocator.free(indices);

        self.vertex_buffer = Wgpu.wgpuDeviceCreateBuffer(gctx.device, &.{
            .size = @sizeOf(VertexAttribute) * vertices.len,
            .usage = Wgpu.WGPUBufferUsage_Vertex | Wgpu.WGPUBufferUsage_CopyDst,
            .mappedAtCreation = 0,
        });
        Wgpu.wgpuQueueWriteBuffer(gctx.queue, self.vertex_buffer, 0, vertices.ptr, @sizeOf(VertexAttribute) * vertices.len);

        self.index_buffer = Wgpu.wgpuDeviceCreateBuffer(gctx.device, &.{
            .size = @sizeOf(u32) * indices.len,
            .usage = Wgpu.WGPUBufferUsage_Index | Wgpu.WGPUBufferUsage_CopyDst,
            .mappedAtCreation = 0,
        });
        Wgpu.wgpuQueueWriteBuffer(gctx.queue, self.index_buffer, 0, indices.ptr, @sizeOf(u32) * indices.len);
        self.index_count = @intCast(indices.len);
    }

    fn updateBuffers(self: *Terrain) !void {
        const vertices = try self.generateVertices();
        defer self.allocator.free(vertices);

        Wgpu.wgpuQueueWriteBuffer(self.gctx.queue, self.vertex_buffer, 0, vertices.ptr, @sizeOf(VertexAttribute) * vertices.len);
    }

    fn createMaterial(self: *Terrain, gctx: *Gctx, render_pipeline: *RenderPipeline) !void {
        const default_texture = try RendCTX.createDefaultTexture(gctx);

        const material_constants = MaterialConstants{
            .has_base_color = 1,
            .has_normal = 0,
            ._padding = .{ 0, 0 },
        };

        const uniform_buffer = Wgpu.wgpuDeviceCreateBuffer(gctx.device, &.{
            .size = @sizeOf(MaterialConstants),
            .usage = Wgpu.WGPUBufferUsage_Uniform | Wgpu.WGPUBufferUsage_CopyDst,
            .mappedAtCreation = 0,
        });

        Wgpu.wgpuQueueWriteBuffer(gctx.queue, uniform_buffer, 0, &material_constants, @sizeOf(MaterialConstants));

        const bind_group = Wgpu.wgpuDeviceCreateBindGroup(gctx.device, &Wgpu.WGPUBindGroupDescriptor{
            .layout = render_pipeline.material_bgl,
            .entryCount = render_pipeline.entry_count,
            .entries = &[_]Wgpu.WGPUBindGroupEntry{
                .{ .binding = 0, .buffer = uniform_buffer, .size = Wgpu.wgpuBufferGetSize(uniform_buffer) },
                .{ .binding = 1, .textureView = default_texture.view },
                .{ .binding = 2, .textureView = default_texture.view },
            },
        });

        self.material = .{
            .color_texture = default_texture,
            .normal_texture = default_texture,
            .uniform_buffer = uniform_buffer,
            .bind_group = bind_group,
        };
    }

    pub fn draw(self: *Terrain, pass: Wgpu.WGPURenderPassEncoder, instance_idx: u32) void {
        Wgpu.wgpuRenderPassEncoderSetVertexBuffer(pass, 0, self.vertex_buffer, 0, Wgpu.wgpuBufferGetSize(self.vertex_buffer));
        Wgpu.wgpuRenderPassEncoderSetIndexBuffer(pass, self.index_buffer, Wgpu.WGPUIndexFormat_Uint32, 0, Wgpu.wgpuBufferGetSize(self.index_buffer));
        Wgpu.wgpuRenderPassEncoderSetBindGroup(pass, 1, self.material.bind_group, 0, null);
        Wgpu.wgpuRenderPassEncoderDrawIndexed(pass, self.index_count, 1, 0, 0, instance_idx);
    }

    pub fn deinit(self: *Terrain) void {
        self.allocator.free(self.heights);
        self.allocator.free(self.normals);
        self.allocator.free(self.colors);
        Wgpu.wgpuBufferRelease(self.vertex_buffer);
        Wgpu.wgpuBufferRelease(self.index_buffer);

        if (self.material.color_texture.texture) |tex| Wgpu.wgpuTextureRelease(tex);
        if (self.material.color_texture.view) |view| Wgpu.wgpuTextureViewRelease(view);
        if (self.material.normal_texture.texture) |tex| Wgpu.wgpuTextureRelease(tex);
        if (self.material.normal_texture.view) |view| Wgpu.wgpuTextureViewRelease(view);
        if (self.material.uniform_buffer) |buffer| Wgpu.wgpuBufferRelease(buffer);
        if (self.material.bind_group) |bind_group| Wgpu.wgpuBindGroupRelease(bind_group);
    }

    fn generateColors(self: *Terrain) void {
        const height_range = self.height_max - self.height_min;

        for (0..self.segments + 1) |z| {
            for (0..self.segments + 1) |x| {
                const idx = self.getIndex(x, z);
                const actual = self.getActualHeight(self.heights[idx]);
                const t = (actual - self.height_min) / height_range;

                var color: Vec3 = undefined;
                if (t < 0.3) {
                    const t2 = t / 0.3;
                    color = Vec3.new(0.2, 0.4 + t2 * 0.3, 0.2);
                } else if (t < 0.6) {
                    const t2 = (t - 0.3) / 0.3;
                    color = Vec3.new(0.5 + t2 * 0.2, 0.4 + t2 * 0.1, 0.2);
                } else {
                    const t2 = (t - 0.6) / 0.4;
                    color = Vec3.new(0.7 + t2 * 0.3, 0.7 + t2 * 0.3, 0.7 + t2 * 0.3);
                }
                self.colors[idx] = color;
            }
        }
    }
};
