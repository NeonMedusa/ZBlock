// terrain.zig (简化版本，height_min 固定为0，使用 Vec2)
const std = @import("std");
const Imports = @import("imports.zig");
const Wgpu = Imports.Wgpu;
const Gctx = Imports.Gctx;
const RendCTX = Imports.RendCTX;
const VertexAttribute = @import("rend_ctx.zig").VertexAttribute;
const Material = @import("rend_ctx.zig").Material;
const MaterialConstants = RendCTX.MaterialConstants;
const RenderPipeline = Imports.RenderPipeline;
const Vec2 = Imports.Vec2;
const Vec3 = Imports.Vec3;
const Vec4 = Imports.Vec4;
const Mat4 = Imports.Mat4;

pub const Terrain = struct {
    allocator: std.mem.Allocator,
    position: Vec3,
    rotation_y: f32, // 弧度
    size_x: f32,
    size_z: f32,
    segments: u32,
    max_height: f32, // 最大高度（最小高度固定为0）
    gctx: *Gctx,
    vertex_buffer: Wgpu.WGPUBuffer,
    index_buffer: Wgpu.WGPUBuffer,
    index_count: u32,
    heights: []f32, // 归一化 [0,1]
    normals: []Vec3,
    colors: []Vec3,
    material: Material,

    pub const MAX_LAYER = 10;
    const EPS = 1e-6;

    // ---------- 辅助方法 ----------
    inline fn getIndex(self: *Terrain, x: usize, z: usize) usize {
        return z * (self.segments + 1) + x;
    }

    inline fn getActualHeight(self: *Terrain, normalized: f32) f32 {
        return normalized * self.max_height;
    }

    inline fn getNormalizedHeight(self: *Terrain, actual: f32) f32 {
        return actual / self.max_height;
    }

    // ---------- 插值工具 ----------
    fn interpolateHeight(self: *Terrain, u: f32, v: f32) f32 {
        const seg_f = @as(f32, @floatFromInt(self.segments));
        const x = u * seg_f;
        const z = v * seg_f;
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
        return (h0 * (1 - fz) + h1 * fz);
    }

    fn interpolateNormal(self: *Terrain, u: f32, v: f32) Vec3 {
        const seg_f = @as(f32, @floatFromInt(self.segments));
        const x = u * seg_f;
        const z = v * seg_f;
        const x0 = @as(u32, @intFromFloat(@floor(x)));
        const x1 = @min(x0 + 1, self.segments);
        const z0 = @as(u32, @intFromFloat(@floor(z)));
        const z1 = @min(z0 + 1, self.segments);
        const fx = x - @as(f32, @floatFromInt(x0));
        const fz = z - @as(f32, @floatFromInt(z0));

        const n00 = self.normals[self.getIndex(x0, z0)];
        const n10 = self.normals[self.getIndex(x1, z0)];
        const n01 = self.normals[self.getIndex(x0, z1)];
        const n11 = self.normals[self.getIndex(x1, z1)];

        const nx0 = n00.x * (1 - fx) + n10.x * fx;
        const nx1 = n01.x * (1 - fx) + n11.x * fx;
        const ny0 = n00.y * (1 - fx) + n10.y * fx;
        const ny1 = n01.y * (1 - fx) + n11.y * fx;
        const nz0 = n00.z * (1 - fx) + n10.z * fx;
        const nz1 = n01.z * (1 - fx) + n11.z * fx;

        return Vec3.new(
            nx0 * (1 - fz) + nx1 * fz,
            ny0 * (1 - fz) + ny1 * fz,
            nz0 * (1 - fz) + nz1 * fz,
        ).norm();
    }

    // ---------- 地形数据生成 ----------
    pub fn generateRandom(self: *Terrain, seed: u64) void {
        var rng = std.Random.DefaultPrng.init(seed);
        const random = rng.random();
        const seg_f = @as(f32, @floatFromInt(self.segments));

        for (0..self.segments + 1) |z| {
            for (0..self.segments + 1) |x| {
                const idx = self.getIndex(x, z);
                const u = @as(f32, @floatFromInt(x)) / seg_f;
                const v = @as(f32, @floatFromInt(z)) / seg_f;

                const h1 = @sin(u * 4.0 * std.math.pi) * @cos(v * 4.0 * std.math.pi);
                const h2 = @sin(u * 8.0 * std.math.pi + 1.0) * 0.3;
                const h3 = @cos(v * 8.0 * std.math.pi) * 0.3;
                const h4 = @sin((u * 16.0 + v * 16.0) * std.math.pi) * 0.1;
                const noise = (random.float(f32) - 0.5) * 0.2;
                var height = (h1 * 2.0 + h2 + h3 + h4) * 0.5 + noise;
                height = @max(-1.0, @min(1.0, height));
                self.heights[idx] = (height + 1.0) / 2.0;
            }
        }
        self.calculateNormals();
        self.generateColors();
        self.updateBuffers() catch {};
    }

    pub fn modifyHeightLocal(self: *Terrain, center: Vec2, radius: f32, strength: f32) void {
        const seg_f = @as(f32, @floatFromInt(self.segments));
        for (0..self.segments + 1) |z| {
            for (0..self.segments + 1) |x| {
                const u = @as(f32, @floatFromInt(x)) / seg_f;
                const v = @as(f32, @floatFromInt(z)) / seg_f;
                const local_x = (u - 0.5) * self.size_x;
                const local_z = (v - 0.5) * self.size_z;
                const dx = local_x - center.x;
                const dz = local_z - center.y;
                const dist = @sqrt(dx * dx + dz * dz);
                if (dist < radius) {
                    const factor = (1.0 - dist / radius) * strength;
                    const idx = self.getIndex(x, z);
                    const h = self.heights[idx] + factor;
                    self.heights[idx] = @max(0.0, @min(1.0, h));
                }
            }
        }
        self.calculateNormals();
        self.generateColors();
        self.updateBuffers() catch {};
    }

    pub fn modifyHeightWorld(self: *Terrain, center: Vec2, radius: f32, strength: f32) void {
        const local = self.worldToLocal(center);
        self.modifyHeightLocal(local, radius, strength);
    }

    // ---------- 法线计算 ----------
    pub fn calculateNormals(self: *Terrain) void {
        const seg = self.segments;
        const seg_f = @as(f32, @floatFromInt(seg));
        for (0..seg + 1) |z| {
            for (0..seg + 1) |x| {
                const idx = self.getIndex(x, z);
                const hc = self.heights[idx];

                const h_right = if (x < seg) self.heights[self.getIndex(x + 1, z)] else hc;
                const h_left = if (x > 0) self.heights[self.getIndex(x - 1, z)] else hc;
                const h_down = if (z < seg) self.heights[self.getIndex(x, z + 1)] else hc;
                const h_up = if (z > 0) self.heights[self.getIndex(x, z - 1)] else hc;

                const seg_sz_x = self.size_x / seg_f;
                const seg_sz_z = self.size_z / seg_f;

                const ar = self.getActualHeight(h_right);
                const al = self.getActualHeight(h_left);
                const ad = self.getActualHeight(h_down);
                const au = self.getActualHeight(h_up);

                const dx = (ar - al) / (2.0 * seg_sz_x);
                const dz = (ad - au) / (2.0 * seg_sz_z);

                var nx = -dx;
                var ny: f32 = 1.0;
                var nz = -dz;
                const len = @sqrt(nx * nx + ny * ny + nz * nz);
                if (len > EPS) {
                    nx /= len;
                    ny /= len;
                    nz /= len;
                }
                self.normals[idx] = Vec3.new(nx, ny, nz);
            }
        }
    }

    pub fn generateColors(self: *Terrain) void {
        for (0..self.segments + 1) |z| {
            for (0..self.segments + 1) |x| {
                const idx = self.getIndex(x, z);
                const actual = self.getActualHeight(self.heights[idx]);
                const t = actual / self.max_height; // 相对高度 [0,1]
                const color = if (t < 0.3) blk: {
                    const t2 = t / 0.3;
                    break :blk Vec3.new(0.2, 0.4 + t2 * 0.3, 0.2);
                } else if (t < 0.6) blk: {
                    const t2 = (t - 0.3) / 0.3;
                    break :blk Vec3.new(0.5 + t2 * 0.2, 0.4 + t2 * 0.1, 0.2);
                } else blk: {
                    const t2 = (t - 0.6) / 0.4;
                    break :blk Vec3.new(0.7 + t2 * 0.3, 0.7 + t2 * 0.3, 0.7 + t2 * 0.3);
                };
                self.colors[idx] = color;
            }
        }
    }

    // ---------- GPU 资源 ----------
    fn generateVertices(self: *Terrain) ![]VertexAttribute {
        const count = (self.segments + 1) * (self.segments + 1);
        const vertices = try self.allocator.alloc(VertexAttribute, count);
        const seg_f = @as(f32, @floatFromInt(self.segments));

        for (0..self.segments + 1) |z| {
            for (0..self.segments + 1) |x| {
                const idx = self.getIndex(x, z);
                const u = @as(f32, @floatFromInt(x)) / seg_f;
                const v = @as(f32, @floatFromInt(z)) / seg_f;
                const world_x = (u - 0.5) * self.size_x;
                const world_z = (v - 0.5) * self.size_z;
                const world_y = self.getActualHeight(self.heights[idx]);

                vertices[idx] = .{
                    .position = Vec3.new(world_x, world_y, world_z),
                    .normal = self.normals[idx],
                    .tangent = Vec4.new(1, 0, 0, 1),
                    .texcoord = Vec2.new(u, v),
                    .color = Vec4.new(self.colors[idx].x, self.colors[idx].y, self.colors[idx].z, 1.0),
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
                const tl = @as(u32, @intCast(self.getIndex(x, z)));
                const tr = @as(u32, @intCast(self.getIndex(x + 1, z)));
                const bl = @as(u32, @intCast(self.getIndex(x, z + 1)));
                const br = @as(u32, @intCast(self.getIndex(x + 1, z + 1)));
                indices[idx] = tl;
                indices[idx + 1] = bl;
                indices[idx + 2] = tr;
                indices[idx + 3] = tr;
                indices[idx + 4] = bl;
                indices[idx + 5] = br;
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
        });
        Wgpu.wgpuQueueWriteBuffer(gctx.queue, self.vertex_buffer, 0, vertices.ptr, @sizeOf(VertexAttribute) * vertices.len);

        self.index_buffer = Wgpu.wgpuDeviceCreateBuffer(gctx.device, &.{
            .size = @sizeOf(u32) * indices.len,
            .usage = Wgpu.WGPUBufferUsage_Index | Wgpu.WGPUBufferUsage_CopyDst,
        });
        Wgpu.wgpuQueueWriteBuffer(gctx.queue, self.index_buffer, 0, indices.ptr, @sizeOf(u32) * indices.len);
        self.index_count = @intCast(indices.len);
    }

    pub fn updateBuffers(self: *Terrain) !void {
        const vertices = try self.generateVertices();
        defer self.allocator.free(vertices);
        Wgpu.wgpuQueueWriteBuffer(self.gctx.queue, self.vertex_buffer, 0, vertices.ptr, @sizeOf(VertexAttribute) * vertices.len);
    }

    fn createMaterial(self: *Terrain, gctx: *Gctx, render_pipeline: *RenderPipeline) !void {
        const default_tex = try RendCTX.createDefaultTexture(gctx);
        const material_constants = MaterialConstants{
            .has_base_color = 1,
            .has_normal = 0,
            ._padding = .{ 0, 0 },
        };
        const uniform_buffer = Wgpu.wgpuDeviceCreateBuffer(gctx.device, &.{
            .size = @sizeOf(MaterialConstants),
            .usage = Wgpu.WGPUBufferUsage_Uniform | Wgpu.WGPUBufferUsage_CopyDst,
        });
        Wgpu.wgpuQueueWriteBuffer(gctx.queue, uniform_buffer, 0, &material_constants, @sizeOf(MaterialConstants));

        const bind_group = Wgpu.wgpuDeviceCreateBindGroup(gctx.device, &Wgpu.WGPUBindGroupDescriptor{
            .layout = render_pipeline.material_bgl,
            .entryCount = 3,
            .entries = &[_]Wgpu.WGPUBindGroupEntry{
                .{ .binding = 0, .buffer = uniform_buffer, .size = Wgpu.wgpuBufferGetSize(uniform_buffer) },
                .{ .binding = 1, .textureView = default_tex.view },
                .{ .binding = 2, .textureView = default_tex.view },
            },
        });
        self.material = .{
            .color_texture = default_tex,
            .normal_texture = default_tex,
            .uniform_buffer = uniform_buffer,
            .bind_group = bind_group,
        };
    }

    // ---------- 公共 API ----------
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
        if (self.material.color_texture.texture) |t| Wgpu.wgpuTextureRelease(t);
        if (self.material.color_texture.view) |v| Wgpu.wgpuTextureViewRelease(v);
        if (self.material.normal_texture.texture) |t| Wgpu.wgpuTextureRelease(t);
        if (self.material.normal_texture.view) |v| Wgpu.wgpuTextureViewRelease(v);
        if (self.material.uniform_buffer) |b| Wgpu.wgpuBufferRelease(b);
        if (self.material.bind_group) |g| Wgpu.wgpuBindGroupRelease(g);
    }

    // ---------- 坐标转换（使用 Vec2） ----------
    pub fn worldToLocal(self: *Terrain, world: Vec2) Vec2 {
        const dx = world.x - self.position.x;
        const dz = world.y - self.position.z;
        const cos = @cos(self.rotation_y);
        const sin = @sin(self.rotation_y);
        return Vec2.new(
            dx * cos - dz * sin,
            dx * sin + dz * cos,
        );
    }

    pub fn localToWorld(self: *Terrain, local: Vec2) Vec2 {
        const cos = @cos(self.rotation_y);
        const sin = @sin(self.rotation_y);
        const world_dx = local.x * cos + local.y * sin;
        const world_dz = -local.x * sin + local.y * cos;
        return Vec2.new(
            self.position.x + world_dx,
            self.position.z + world_dz,
        );
    }

    pub fn getUV(self: *Terrain, local: Vec2) Vec2 {
        return Vec2.new(
            (local.x + self.size_x * 0.5) / self.size_x,
            (local.y + self.size_z * 0.5) / self.size_z,
        );
    }

    pub fn getHeightLocal(self: *Terrain, local: Vec2) f32 {
        const uv = self.getUV(local);
        if (uv.x < 0 or uv.x > 1 or uv.y < 0 or uv.y > 1) return 0.0;
        const norm = self.interpolateHeight(uv.x, uv.y);
        return self.getActualHeight(norm);
    }

    pub fn getHeightAt(self: *Terrain, world: Vec2) f32 {
        const local = self.worldToLocal(world);
        return self.position.y + self.getHeightLocal(local);
    }

    pub fn getNormalLocal(self: *Terrain, local: Vec2) Vec3 {
        const uv = self.getUV(local);
        if (uv.x < 0 or uv.x > 1 or uv.y < 0 or uv.y > 1) return Vec3.new(0, 1, 0);
        return self.interpolateNormal(uv.x, uv.y);
    }

    pub fn setPosition(self: *Terrain, new_pos: Vec3) void {
        self.position = new_pos;
    }

    pub fn setRotation(self: *Terrain, radians: f32) void {
        self.rotation_y = radians;
    }

    pub fn setRotationDegrees(self: *Terrain, degrees: f32) void {
        self.rotation_y = degrees * std.math.pi / 180.0;
    }

    pub fn getTransformMatrix(self: *Terrain) Mat4 {
        const cos = @cos(self.rotation_y);
        const sin = @sin(self.rotation_y);
        const rot = Mat4{
            .m = .{
                .{ cos, 0, sin, 0 },
                .{ 0, 1, 0, 0 },
                .{ -sin, 0, cos, 0 },
                .{ 0, 0, 0, 1 },
            },
        };
        const trans = Mat4.fromTranslate(self.position);
        return trans.mul(rot);
    }

    // ---------- 构造函数 ----------
    pub fn init(
        allocator: std.mem.Allocator,
        gctx: *Gctx,
        position: Vec3,
        rotation_y: f32,
        size_x: f32,
        size_z: f32,
        segments: u32,
        max_height: f32,
        render_pipeline: *RenderPipeline,
    ) !Terrain {
        const vertex_count = (segments + 1) * (segments + 1);
        var terrain = Terrain{
            .allocator = allocator,
            .gctx = gctx,
            .position = position,
            .rotation_y = rotation_y,
            .size_x = size_x,
            .size_z = size_z,
            .segments = segments,
            .max_height = max_height,
            .heights = try allocator.alloc(f32, vertex_count),
            .normals = try allocator.alloc(Vec3, vertex_count),
            .colors = try allocator.alloc(Vec3, vertex_count),
            .vertex_buffer = undefined,
            .index_buffer = undefined,
            .index_count = 0,
            .material = undefined,
        };
        @memset(terrain.heights, 0.5);
        terrain.calculateNormals();
        terrain.generateColors();
        try terrain.createBuffers(gctx);
        try terrain.createMaterial(gctx, render_pipeline);

        return terrain;
    }
};
