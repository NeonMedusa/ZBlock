const std = @import("std");
const Import = @import("imports.zig");
const Wgpu = Import.Wgpu;
const Gctx = Import.Gctx;
const RendCTX = Import.RendCTX;
const VertexAttribute = @import("rend_ctx.zig").VertexAttribute;
const Material = @import("rend_ctx.zig").Material;
const MaterialConstants = RendCTX.MaterialConstants;
const RenderPipeline = Import.RenderPipeline;

// terrain.zig
pub const Terrain = struct {
    allocator: std.mem.Allocator,
    width: u32,
    height: u32,
    // GPU资源
    vertex_buffer: Wgpu.WGPUBuffer,
    index_buffer: Wgpu.WGPUBuffer,
    index_count: u32,
    // 地形数据
    heights: []f32,
    normals: [][3]f32,
    colors: [][3]f32,
    // 材质
    material: Material, // 取消注释

    pub fn init(allocator: std.mem.Allocator, gctx: *Gctx, width: u32, height: u32, render_pipeline: *RenderPipeline) !Terrain {
        var terrain: Terrain = undefined;

        terrain.allocator = allocator;
        terrain.width = width;
        terrain.height = height;
        terrain.heights = try allocator.alloc(f32, width * height);
        terrain.normals = try allocator.alloc([3]f32, width * height);
        terrain.colors = try allocator.alloc([3]f32, width * height);

        // 生成地形数据
        terrain.generateHeights();
        terrain.calculateNormals();
        terrain.generateColors();

        // 创建GPU缓冲区
        try terrain.createBuffers(gctx);

        // 创建材质
        try terrain.createMaterial(gctx, render_pipeline);

        return terrain;
    }

    fn createBuffers(self: *Terrain, gctx: *Gctx) !void {
        const vertices = try self.generateVertices();
        defer self.allocator.free(vertices);

        const indices = try self.generateIndices();
        defer self.allocator.free(indices);

        // 创建顶点缓冲区
        self.vertex_buffer = Wgpu.wgpuDeviceCreateBuffer(gctx.device, &.{
            .size = @sizeOf(VertexAttribute) * vertices.len,
            .usage = Wgpu.WGPUBufferUsage_Vertex | Wgpu.WGPUBufferUsage_CopyDst,
            .mappedAtCreation = 0,
        });
        Wgpu.wgpuQueueWriteBuffer(gctx.queue, self.vertex_buffer, 0, vertices.ptr, @sizeOf(VertexAttribute) * vertices.len);

        // 创建索引缓冲区
        self.index_buffer = Wgpu.wgpuDeviceCreateBuffer(gctx.device, &.{
            .size = @sizeOf(u32) * indices.len,
            .usage = Wgpu.WGPUBufferUsage_Index | Wgpu.WGPUBufferUsage_CopyDst,
            .mappedAtCreation = 0,
        });
        Wgpu.wgpuQueueWriteBuffer(gctx.queue, self.index_buffer, 0, indices.ptr, @sizeOf(u32) * indices.len);
        self.index_count = @intCast(indices.len);
    }

    fn generateColors(self: *Terrain) void {
        for (0..self.height) |z| {
            for (0..self.width) |x| {
                const height = self.heights[z * self.width + x];
                // 根据高度设置颜色：低->绿色，中->棕色，高->白色
                var color: [3]f32 = undefined;
                if (height < 0.3) {
                    color = .{ 0.2, 0.6, 0.2 }; // 草地
                } else if (height < 0.6) {
                    color = .{ 0.6, 0.4, 0.2 }; // 泥土
                } else {
                    color = .{ 0.9, 0.9, 0.9 }; // 雪
                }
                self.colors[z * self.width + x] = color;
            }
        }
    }

    fn createMaterial(self: *Terrain, gctx: *Gctx, render_pipeline: *RenderPipeline) !void {
        // 创建默认纹理（1x1 白色纹理）
        const default_texture = try RendCTX.createDefaultTexture(gctx.*);

        // 材质常量
        const material_constants = MaterialConstants{
            .has_base_color = 1,
            .has_normal = 0,
            ._padding = .{ 0, 0 },
        };

        // 创建 uniform buffer
        const uniform_buffer = Wgpu.wgpuDeviceCreateBuffer(gctx.device, &.{
            .size = @sizeOf(MaterialConstants),
            .usage = Wgpu.WGPUBufferUsage_Uniform | Wgpu.WGPUBufferUsage_CopyDst,
            .mappedAtCreation = 0,
        });

        Wgpu.wgpuQueueWriteBuffer(
            gctx.queue,
            uniform_buffer,
            0,
            &material_constants,
            @sizeOf(MaterialConstants),
        );

        // 创建绑定组
        const bind_group = Wgpu.wgpuDeviceCreateBindGroup(gctx.device, &Wgpu.WGPUBindGroupDescriptor{
            .layout = render_pipeline.material_bgl,
            .entryCount = render_pipeline.entry_count,
            .entries = &[_]Wgpu.WGPUBindGroupEntry{
                .{ // material uniform
                    .binding = 0,
                    .buffer = uniform_buffer,
                    .size = Wgpu.wgpuBufferGetSize(uniform_buffer),
                },
                .{ // color texture
                    .binding = 1,
                    .textureView = default_texture.view,
                },
                .{ // normal texture
                    .binding = 2,
                    .textureView = default_texture.view,
                },
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
        // 设置顶点和索引缓冲区
        Wgpu.wgpuRenderPassEncoderSetVertexBuffer(pass, 0, self.vertex_buffer, 0, Wgpu.wgpuBufferGetSize(self.vertex_buffer));
        Wgpu.wgpuRenderPassEncoderSetIndexBuffer(pass, self.index_buffer, Wgpu.WGPUIndexFormat_Uint32, 0, Wgpu.wgpuBufferGetSize(self.index_buffer));

        // 设置材质绑定组
        Wgpu.wgpuRenderPassEncoderSetBindGroup(pass, 1, self.material.bind_group, 0, null);

        // 绘制
        Wgpu.wgpuRenderPassEncoderDrawIndexed(
            pass,
            self.index_count,
            1, // 实例数量
            0, // 基础索引
            0, // 基础顶点
            instance_idx, // 实例起始索引
        );
    }

    fn generateVertices(self: *Terrain) ![]VertexAttribute {
        const vertices = try self.allocator.alloc(VertexAttribute, self.width * self.height);
        for (0..self.height) |z| {
            for (0..self.width) |x| {
                const idx = z * self.width + x;
                const fx = @as(f32, @floatFromInt(x)) / @as(f32, @floatFromInt(self.width - 1)) - 0.5;
                const fz = @as(f32, @floatFromInt(z)) / @as(f32, @floatFromInt(self.height - 1)) - 0.5;

                const position = .{
                    (fx - 0.5) * 100.0, // X范围 -50 到 50
                    self.heights[idx] * 10.0, // 高度范围 0-10
                    (fz - 0.5) * 100.0, // Z范围 -50 到 50
                };

                const normal = self.normals[idx];
                const texcoord = .{ fx + 0.5, fz + 0.5 };
                const color = self.colors[idx];

                vertices[idx] = .{
                    .position = position,
                    .normal = normal,
                    .tangent = .{ 1, 0, 0, 1 }, // 默认切线
                    .texcoord = texcoord,
                    .color = .{ color[0], color[1], color[2], 1.0 }, // 添加 alpha 通道
                    .joint_indices = .{ 0, 0, 0, 0 },
                    .joint_weights = .{ 1, 0, 0, 0 },
                };
            }
        }

        return vertices;
    }

    fn generateIndices(self: *Terrain) ![]u32 {
        const num_quads = (self.width - 1) * (self.height - 1);
        const indices = try self.allocator.alloc(u32, num_quads * 6);

        var idx: u32 = 0;
        for (0..self.height - 1) |z| {
            for (0..self.width - 1) |x| {
                const top_left = @as(u32, @intCast(z * self.width + x));
                const top_right = top_left + 1;
                const bottom_left = @as(u32, @intCast((z + 1) * self.width + x));
                const bottom_right = bottom_left + 1;

                // 两个三角形组成一个正方形
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

    fn generateHeights(self: *Terrain) void {
        // 使用简单的正弦波 + 噪声生成地形
        for (0..self.height) |z| {
            for (0..self.width) |x| {
                const fx = @as(f32, @floatFromInt(x)) / @as(f32, @floatFromInt(self.width - 1));
                const fz = @as(f32, @floatFromInt(z)) / @as(f32, @floatFromInt(self.height - 1));
                // 简单的地形生成：多个正弦波叠加
                const h1 = @sin(fx * 4.0 * std.math.pi) * @cos(fz * 4.0 * std.math.pi);
                const h2 = @sin(fx * 8.0 * std.math.pi + 1.0) * 0.3;
                const h3 = @cos(fz * 8.0 * std.math.pi) * 0.3;
                const h4 = @sin((fx * 16.0 + fz * 16.0) * std.math.pi) * 0.1;
                self.heights[z * self.width + x] = (h1 * 2.0 + h2 + h3 + h4) * 0.5 + 0.5;
            }
        }
    }

    fn calculateNormals(self: *Terrain) void {
        // 简单实现：计算每个顶点的法线
        for (0..self.height) |z| {
            for (0..self.width) |x| {
                // 获取相邻顶点高度
                const h_center = self.heights[z * self.width + x];
                const h_right = if (x < self.width - 1) self.heights[z * self.width + x + 1] else h_center;
                const h_left = if (x > 0) self.heights[z * self.width + x - 1] else h_center;
                const h_down = if (z < self.height - 1) self.heights[(z + 1) * self.width + x] else h_center;
                const h_up = if (z > 0) self.heights[(z - 1) * self.width + x] else h_center;

                // 计算切线方向
                const dx = (h_right - h_left) * 0.5;
                const dz = (h_down - h_up) * 0.5;

                // 计算法线向量
                var nx = -dx;
                var ny: f32 = 1.0;
                var nz = -dz;

                // 归一化
                const len = @sqrt(nx * nx + ny * ny + nz * nz);
                if (len > 0.0001) {
                    nx /= len;
                    ny /= len;
                    nz /= len;
                }

                self.normals[z * self.width + x] = .{ nx, ny, nz };
            }
        }
    }

    pub fn deinit(self: *Terrain) void {
        self.allocator.free(self.heights);
        self.allocator.free(self.normals);
        self.allocator.free(self.colors);
        Wgpu.wgpuBufferRelease(self.vertex_buffer);
        Wgpu.wgpuBufferRelease(self.index_buffer);

        // 释放材质资源
        if (self.material.color_texture.texture) |tex| {
            Wgpu.wgpuTextureRelease(tex);
        }
        if (self.material.color_texture.view) |view| {
            Wgpu.wgpuTextureViewRelease(view);
        }
        if (self.material.normal_texture.texture) |tex| {
            Wgpu.wgpuTextureRelease(tex);
        }
        if (self.material.normal_texture.view) |view| {
            Wgpu.wgpuTextureViewRelease(view);
        }
        if (self.material.uniform_buffer) |buffer| {
            Wgpu.wgpuBufferRelease(buffer);
        }
        if (self.material.bind_group) |bind_group| {
            Wgpu.wgpuBindGroupRelease(bind_group);
        }
    }
};
