const std = @import("std");
const Imports = @import("imports.zig");
const Wgpu = Imports.Wgpu;
const Gctx = Imports.Gctx;
const Vec2 = Imports.Vec2;
const Vec2u = Imports.Vec2u;
const Vec3 = Imports.Vec3;
const Vec4 = Imports.Vec4;
const RendCTX = Imports.RendCTX;
const VertexAttribute = RendCTX.VertexAttribute;
const RenderPipeline = Imports.RenderPipeline;
const Foo = @import("cdt.zig");
const CDT = Foo.CDT;
const Edge = Foo.Edge;

pub const RTSMap = struct {
    allocator: std.mem.Allocator,
    // ---------- 渲染相关字段 ----------
    gctx: *Gctx,
    width: u32, // 地图宽度（格点数）
    height: u32, // 地图高度（格点数）
    vertex_buffer: Wgpu.WGPUBuffer,
    index_buffer: Wgpu.WGPUBuffer,
    index_count: u32,
    wireframe_index_buffer: Wgpu.WGPUBuffer,
    wireframe_index_count: u32,
    material: RendCTX.Material,
    position: Vec3 = Vec3.zero,
    rotation_y: f32 = 0,
    // ---------- 路径显示缓冲区 ----------
    path_vertex_buffer: Wgpu.WGPUBuffer,
    path_index_buffer: Wgpu.WGPUBuffer,
    path_vertex_count: u32 = 0,
    path_index_count: u32 = 0,
    path_vertices: std.ArrayList(VertexAttribute),
    path_indices: std.ArrayList(u32),

    // --------- 边界线框缓冲区（蓝色）----------
    boundary_vertex_buffer: Wgpu.WGPUBuffer,
    boundary_index_buffer: Wgpu.WGPUBuffer,
    boundary_vertex_count: u32 = 0,
    boundary_index_count: u32 = 0,

    path_start: ?Vec2u = null,
    path_end: ?Vec2u = null,

    // ---------- CDT 核心数据 ----------
    cdt: CDT,

    /// 初始化地图
    pub fn init(allocator: std.mem.Allocator, gctx: *Gctx, width: u32, height: u32, render_pipeline: *RenderPipeline) !RTSMap {
        var self: RTSMap = undefined;
        self.allocator = allocator;

        self.cdt = try CDT.init(allocator, width, height);

        self.gctx = gctx;
        self.width = width;
        self.height = height;
        self.index_count = 0;
        self.wireframe_index_count = 0;
        self.path_vertex_count = 0;
        self.path_index_count = 0;
        self.path_start = null;
        self.path_end = null;

        try self.initBoundaryBuffers();

        self.path_vertices = try std.ArrayList(VertexAttribute).initCapacity(allocator, 256);
        self.path_indices = try std.ArrayList(u32).initCapacity(allocator, 256);

        self.material = try RendCTX.createDefaultMaterial(gctx, render_pipeline);

        self.vertex_buffer = Wgpu.wgpuDeviceCreateBuffer(gctx.device, &.{
            .size = 0,
            .usage = Wgpu.WGPUBufferUsage_Vertex | Wgpu.WGPUBufferUsage_CopyDst,
        });
        self.index_buffer = Wgpu.wgpuDeviceCreateBuffer(gctx.device, &.{
            .size = 0,
            .usage = Wgpu.WGPUBufferUsage_Index | Wgpu.WGPUBufferUsage_CopyDst,
        });
        self.wireframe_index_buffer = Wgpu.wgpuDeviceCreateBuffer(gctx.device, &.{
            .size = 0,
            .usage = Wgpu.WGPUBufferUsage_Index | Wgpu.WGPUBufferUsage_CopyDst,
        });

        const max_path_vertices = 1024;
        const max_path_indices = 2048;
        self.path_vertex_buffer = Wgpu.wgpuDeviceCreateBuffer(gctx.device, &.{
            .size = @sizeOf(VertexAttribute) * max_path_vertices,
            .usage = Wgpu.WGPUBufferUsage_Vertex | Wgpu.WGPUBufferUsage_CopyDst,
        });
        self.path_index_buffer = Wgpu.wgpuDeviceCreateBuffer(gctx.device, &.{
            .size = @sizeOf(u32) * max_path_indices,
            .usage = Wgpu.WGPUBufferUsage_Index | Wgpu.WGPUBufferUsage_CopyDst,
        });

        try self.updateMeshBuffers();

        return self;
    }

    // ---------- 资源释放 ----------
    pub fn deinit(self: *RTSMap) void {
        // 释放渲染资源
        if (self.material.color_texture.texture) |t| Wgpu.wgpuTextureRelease(t);
        if (self.material.color_texture.view) |v| Wgpu.wgpuTextureViewRelease(v);
        if (self.material.normal_texture.texture) |t| Wgpu.wgpuTextureRelease(t);
        if (self.material.normal_texture.view) |v| Wgpu.wgpuTextureViewRelease(v);
        if (self.material.uniform_buffer) |b| Wgpu.wgpuBufferRelease(b);
        if (self.material.bind_group) |g| Wgpu.wgpuBindGroupRelease(g);
        if (self.vertex_buffer) |vb| Wgpu.wgpuBufferRelease(vb);
        if (self.index_buffer) |ib| Wgpu.wgpuBufferRelease(ib);
        if (self.wireframe_index_buffer) |ib| Wgpu.wgpuBufferRelease(ib);
        if (self.path_vertex_buffer) |vb| Wgpu.wgpuBufferRelease(vb);
        if (self.path_index_buffer) |ib| Wgpu.wgpuBufferRelease(ib);
        self.path_vertices.deinit(self.allocator);
        self.path_indices.deinit(self.allocator);

        self.cdt.deinit();
    }

    pub fn raycast(self: *RTSMap, origin: Vec3, direction: Vec3) ?struct { point: Vec3 } {
        const widht_f: f32 = @floatFromInt(self.width);
        const height_f: f32 = @floatFromInt(self.height);
        // 简单的射线投射到Y=0的平面
        if (direction.y == 0) return null; // 射线平行于平面
        const t = -origin.y / direction.y;
        if (t < 0) return null; // 交点在射线后面
        const hit_x = origin.x + t * direction.x;
        const hit_z = origin.z + t * direction.z;
        // 检查是否在地图范围内
        if (hit_x >= 0 and hit_x <= widht_f and hit_z >= 0 and hit_z <= height_f)
            return .{ .point = Vec3.new(hit_x, 0, hit_z) };
        return null;
    }

    /// 从 CDT 网格重建渲染缓冲区（顶点、填充索引、线框索引）
    pub fn updateMeshBuffers(self: *RTSMap) !void {
        const cdt = &self.cdt;
        // 临时顶点和索引列表
        var vertex_list = std.ArrayList(VertexAttribute){};
        defer vertex_list.deinit(self.allocator);
        var index_list = std.ArrayList(u32){};
        defer index_list.deinit(self.allocator);
        var wireframe_index_list = std.ArrayList(u32){};
        defer wireframe_index_list.deinit(self.allocator);
        // 遍历所有三角形
        for (cdt.triangles.items) |tri| {
            const v0 = tri.vertices[0];
            const v1 = tri.vertices[1];
            const v2 = tri.vertices[2];
            const pos0 = cdt.vertices.items[v0];
            const pos1 = cdt.vertices.items[v1];
            const pos2 = cdt.vertices.items[v2];

            // 检查三条边是否为约束边
            const edge01 = Edge{ .v1 = v0, .v2 = v1 };
            const edge12 = Edge{ .v1 = v1, .v2 = v2 };
            const edge20 = Edge{ .v1 = v2, .v2 = v0 };

            const is_edge01_fixed = cdt.constrained_edges.contains(edge01) or cdt.constrained_edges.contains(.{ .v1 = v1, .v2 = v0 });
            const is_edge12_fixed = cdt.constrained_edges.contains(edge12) or cdt.constrained_edges.contains(.{ .v1 = v2, .v2 = v1 });
            const is_edge20_fixed = cdt.constrained_edges.contains(edge20) or cdt.constrained_edges.contains(.{ .v1 = v0, .v2 = v2 });

            // 默认颜色：半透明绿色（可通行区域）
            const default_color = Vec4.new(0.2, 0.8, 0.2, 1.0);
            const fixed_color = Vec4.new(1.0, 0.0, 0.0, 1.0); // 红色

            // 为三个顶点分别决定颜色：若该顶点属于任意约束边，则设为红色，否则为默认绿色
            const color0 = if (is_edge01_fixed or is_edge20_fixed) fixed_color else default_color;
            const color1 = if (is_edge01_fixed or is_edge12_fixed) fixed_color else default_color;
            const color2 = if (is_edge12_fixed or is_edge20_fixed) fixed_color else default_color;

            // 通用顶点属性（Y轴向上，CDT的2D坐标放在XZ平面）
            const normal = Vec3.new(0.0, 1.0, 0.0);
            const tangent = Vec4.new(1.0, 0.0, 0.0, 1.0);
            const texcoord = Vec2.new(0.0, 0.0);

            const base_idx = @as(u32, @intCast(vertex_list.items.len));

            // 添加三个顶点
            try vertex_list.append(self.allocator, .{
                .position = Vec3.new(pos0.x, 0.0, pos0.y),
                .normal = normal,
                .tangent = tangent,
                .color = color0,
                .texcoord = texcoord,
            });
            try vertex_list.append(self.allocator, .{
                .position = Vec3.new(pos1.x, 0.0, pos1.y),
                .normal = normal,
                .tangent = tangent,
                .color = color1,
                .texcoord = texcoord,
            });
            try vertex_list.append(self.allocator, .{
                .position = Vec3.new(pos2.x, 0.0, pos2.y),
                .normal = normal,
                .tangent = tangent,
                .color = color2,
                .texcoord = texcoord,
            });

            // 填充三角形索引（逆时针顺序）
            try index_list.append(self.allocator, base_idx);
            try index_list.append(self.allocator, base_idx + 1);
            try index_list.append(self.allocator, base_idx + 2);

            // 线框索引：三条边
            try wireframe_index_list.append(self.allocator, base_idx);
            try wireframe_index_list.append(self.allocator, base_idx + 1);
            try wireframe_index_list.append(self.allocator, base_idx + 1);
            try wireframe_index_list.append(self.allocator, base_idx + 2);
            try wireframe_index_list.append(self.allocator, base_idx + 2);
            try wireframe_index_list.append(self.allocator, base_idx);
        }

        self.index_count = @intCast(index_list.items.len);
        self.wireframe_index_count = @intCast(wireframe_index_list.items.len);

        // 更新顶点缓冲区
        if (vertex_list.items.len > 0) {
            const vert_size = vertex_list.items.len * @sizeOf(VertexAttribute);
            if (self.vertex_buffer) |vb| Wgpu.wgpuBufferRelease(vb);
            self.vertex_buffer = Wgpu.wgpuDeviceCreateBuffer(self.gctx.device, &.{
                .size = vert_size,
                .usage = Wgpu.WGPUBufferUsage_Vertex | Wgpu.WGPUBufferUsage_CopyDst,
            });
            Wgpu.wgpuQueueWriteBuffer(self.gctx.queue, self.vertex_buffer, 0, @ptrCast(vertex_list.items.ptr), vert_size);
        }

        // 更新填充索引缓冲区
        if (index_list.items.len > 0) {
            const idx_size = index_list.items.len * @sizeOf(u32);
            if (self.index_buffer) |ib| Wgpu.wgpuBufferRelease(ib);
            self.index_buffer = Wgpu.wgpuDeviceCreateBuffer(self.gctx.device, &.{
                .size = idx_size,
                .usage = Wgpu.WGPUBufferUsage_Index | Wgpu.WGPUBufferUsage_CopyDst,
            });
            Wgpu.wgpuQueueWriteBuffer(self.gctx.queue, self.index_buffer, 0, @ptrCast(index_list.items.ptr), idx_size);
        }

        // 更新线框索引缓冲区
        if (wireframe_index_list.items.len > 0) {
            const wireframe_idx_size = wireframe_index_list.items.len * @sizeOf(u32);
            if (self.wireframe_index_buffer) |ib| Wgpu.wgpuBufferRelease(ib);
            self.wireframe_index_buffer = Wgpu.wgpuDeviceCreateBuffer(self.gctx.device, &.{
                .size = wireframe_idx_size,
                .usage = Wgpu.WGPUBufferUsage_Index | Wgpu.WGPUBufferUsage_CopyDst,
            });
            Wgpu.wgpuQueueWriteBuffer(self.gctx.queue, self.wireframe_index_buffer, 0, @ptrCast(wireframe_index_list.items.ptr), wireframe_idx_size);
        }
    }

    fn initBoundaryBuffers(self: *RTSMap) !void {
        const w: f32 = @floatFromInt(self.width);
        const h: f32 = @floatFromInt(self.height);

        const color = Vec4.new(0.0, 0.4, 1.0, 1.0); // 蓝色
        const normal = Vec3.new(0, 1, 0);
        const tangent = Vec4.new(1, 0, 0, 1);
        const texcoord = Vec2.new(0, 0);

        // 四个顶点（顺序：左下 → 右下 → 右上 → 左上）
        const vertices = [_]VertexAttribute{
            .{ .position = Vec3.new(0, 0.01, 0), .normal = normal, .tangent = tangent, .color = color, .texcoord = texcoord },
            .{ .position = Vec3.new(w, 0.01, 0), .normal = normal, .tangent = tangent, .color = color, .texcoord = texcoord },
            .{ .position = Vec3.new(w, 0.01, h), .normal = normal, .tangent = tangent, .color = color, .texcoord = texcoord },
            .{ .position = Vec3.new(0, 0.01, h), .normal = normal, .tangent = tangent, .color = color, .texcoord = texcoord },
        };

        // 四条边的索引（LineList 每段 2 个索引）
        const indices = [_]u32{
            0, 1, // 下边
            1, 2, // 右边
            2, 3, // 上边
            3, 0, // 左边
        };

        // 创建顶点缓冲区
        const vert_size = vertices.len * @sizeOf(VertexAttribute);
        self.boundary_vertex_buffer = Wgpu.wgpuDeviceCreateBuffer(self.gctx.device, &.{
            .size = vert_size,
            .usage = Wgpu.WGPUBufferUsage_Vertex | Wgpu.WGPUBufferUsage_CopyDst,
        });
        Wgpu.wgpuQueueWriteBuffer(self.gctx.queue, self.boundary_vertex_buffer, 0, &vertices, vert_size);
        self.boundary_vertex_count = vertices.len;

        // 创建索引缓冲区
        const idx_size = indices.len * @sizeOf(u32);
        self.boundary_index_buffer = Wgpu.wgpuDeviceCreateBuffer(self.gctx.device, &.{
            .size = idx_size,
            .usage = Wgpu.WGPUBufferUsage_Index | Wgpu.WGPUBufferUsage_CopyDst,
        });
        Wgpu.wgpuQueueWriteBuffer(self.gctx.queue, self.boundary_index_buffer, 0, &indices, idx_size);
        self.boundary_index_count = indices.len;
    }

    /// 放置新建筑（添加约束边）
    pub fn placeBuilding(self: *RTSMap, footprint: []const Vec2) !void {
        // 1. 为建筑角点创建顶点
        var verts = std.ArrayList(u32).init(self.allocator);
        defer verts.deinit();
        for (footprint) |pt| {
            const v = try self.cdt.addVertex(pt);
            try self.cdt.insertVertex(v);
            try verts.append(v);
        }

        // 2. 插入建筑边缘作为约束边
        for (0..verts.items.len) |i| {
            const v1 = verts.items[i];
            const v2 = verts.items[(i + 1) % verts.items.len];
            try self.cdt.insertConstraintEdge(v1, v2);
        }
    }

    /// 移除建筑（可选实现，较复杂）
    pub fn removeBuilding(self: *RTSMap, building_id: u32) !void {
        _ = self;
        _ = building_id;
        // 通常RTS中只需标记为可通行，无需真正删除约束边
        // 若需实现，参考论文中的约束边删除算法
    }

    /// 放置一个凸多边形障碍物（顶点按逆时针顺序给出）
    pub fn placeObstacle(self: *RTSMap, footprint: []const Vec2) !void {
        if (footprint.len < 3) return;
        // 添加所有顶点并插入 CDT
        var verts = std.ArrayList(u32){};
        defer verts.deinit(self.allocator);
        for (footprint) |pt| {
            const v = try self.cdt.addVertex(pt);
            try self.cdt.insertVertex(v);
            try verts.append(self.allocator, v);
        }
        // 插入约束边（闭合多边形）
        for (0..verts.items.len) |i| {
            const v1 = verts.items[i];
            const v2 = verts.items[(i + 1) % verts.items.len];
            try self.cdt.insertConstraintEdge(v1, v2);
        }
        // 更新渲染缓冲区
        try self.updateMeshBuffers();
    }
};
