// cdt.zig
const std = @import("std");
const Vec2 = @import("imports.zig").Vec2; // 假设已有二维向量

/// 约束边（用于固定障碍物边界）
pub const Edge = struct {
    v1: u32, // 顶点索引（即 vertices 列表中的下标）
    v2: u32, // 顶点索引（即 vertices 列表中的下标）
};

/// 三角形（紧凑存储）
pub const Triangle = struct {
    /// 逆时针顺序的三个顶点索引
    vertices: [3]u32 = [_]u32{0} ** 3,
    /// 邻居三角形索引数组，严格遵循逆时针对应规则：
    /// - neighbors[i] 对应于由 vertices[i] 和 vertices[(i + 1) % 3] 构成的边
    /// - 其值为与该边相邻的三角形在 triangles 列表中的索引
    /// - 若该边为网格边界（无邻居），则值为 -1
    /// 示意图（逆时针）：
    ///        v2
    ///        / \
    ///   n1  /   \  n2
    ///      /     \
    ///    v0 ----- v1
    ///         n0
    neighbors: [3]i32 = [_]i32{-1} ** 3,
};

/// CDT网格主结构
pub const CDT = struct {
    allocator: std.mem.Allocator,
    triangles: std.ArrayListUnmanaged(Triangle) = .{}, // 三角形列表
    vertices: std.ArrayListUnmanaged(Vec2) = .{}, // 所有顶点坐标

    /// 每个顶点的任意一个相邻三角形索引。
    /// 该值仅用作行走法（walking algorithm）的入口起点，不要求特定方向。
    /// 只要顶点存在于网格中，该字段就必须指向一个包含该顶点的有效三角形。
    /// 通过此三角形和 Triangle.neighbors 可以遍历顶点周围的所有三角形。
    vert_tris: std.ArrayListUnmanaged(u32) = .{},

    fixed_edges: std.AutoHashMapUnmanaged(Edge, void) = .{}, // 约束边集合

    // 临时工作区（预分配，避免频繁分配）
    temp_stack: std.ArrayListUnmanaged(u32) = .{},
    temp_intersected: std.ArrayListUnmanaged(u32) = .{},
    temp_poly: std.ArrayListUnmanaged(u32) = .{},
    temp_outer_tris: std.AutoHashMapUnmanaged(Edge, i32) = .{},

    // KD树（用于加速最近点查询，暂时不用，先暴力查询验证方案可行性）
    // kd_tree: ?*KDTree = null,

    // ---------- 初始化与资源管理 ----------
    /// 初始化CDT，创建覆盖整个地图的超三角形
    pub fn init(allocator: std.mem.Allocator, map_width: u32, map_height: u32) !CDT {
        var cdt = CDT{ .allocator = allocator };

        const width_f: f32 = @floatFromInt(map_width);
        const height_f: f32 = @floatFromInt(map_height);

        const center_x = width_f / 2.0;
        const center_z = height_f / 2.0;

        // 计算外接圆半径并扩大
        const ori_cir_radius = @sqrt(center_x * center_x + center_z * center_z);
        const big_cir_radius = ori_cir_radius * 2.5; // 放大系数，确保安全

        // 三个顶点：等边三角形，逆时针顺序：从左上(150°) → 正下(270°) → 右上(30°)
        const angles = [_]f32{ 150.0, 270.0, 30.0 };
        var super_verts: [3]u32 = undefined;
        for (angles, 0..) |deg, i| {
            const rad = deg * std.math.pi / 180.0;
            const x = center_x + big_cir_radius * @cos(rad);
            const y = center_z + big_cir_radius * @sin(rad);
            // 添加顶点（仅分配索引，不立即插入网格）
            super_verts[i] = try cdt.addVertex(.{ .x = x, .y = y });
        }

        // 创建超三角形，逆时针顺序
        const super_tri = Triangle{
            .vertices = .{ super_verts[0], super_verts[1], super_verts[2] },
            .neighbors = .{ -1, -1, -1 },
        };
        try cdt.triangles.append(allocator, super_tri);

        // 初始化 vert_tris 条目（每个顶点关联到超三角形）
        cdt.vert_tris.items[super_verts[0]] = 0;
        cdt.vert_tris.items[super_verts[1]] = 0;
        cdt.vert_tris.items[super_verts[2]] = 0;

        return cdt;
    }

    /// 释放所有资源
    pub fn deinit(self: *CDT) void {
        self.vertices.deinit(self.allocator);
        self.triangles.deinit(self.allocator);
        self.vert_tris.deinit(self.allocator);
        self.fixed_edges.deinit(self.allocator);

        self.temp_stack.deinit(self.allocator);
        self.temp_intersected.deinit(self.allocator);
        self.temp_poly.deinit(self.allocator);
        self.temp_outer_tris.deinit(self.allocator);
    }

    // ---------- 顶点操作 ----------
    /// 添加顶点（仅分配索引，不立即插入网格）
    pub fn addVertex(self: *CDT, pt: Vec2) !u32 {
        const idx = @as(u32, @intCast(self.vertices.items.len));
        try self.vertices.append(self.allocator, pt);
        // 确保 vert_tris 长度至少为 idx+1，新元素初始化为 0
        try self.vert_tris.resize(self.allocator, idx + 1);
        self.vert_tris.items[idx] = 0;
        return idx;
    }

    /// 将已存在的顶点（由索引指定）正式插入CDT网格
    /// 实现 Bowyer-Watson 增量插入算法
    pub fn insertVertex(self: *CDT, v_idx: u32) !void {
        const v = self.vertices.items[v_idx];
        // 1. 通过 KD 树或线性搜索找到距离新点最近的已有顶点，这里先用暴力搜索验证可行性
        const nearest = self.findNearestVertex(v);
        // 2. 以该最近顶点的某个邻接三角形为起点，开始行走法定位
        const start_tri = self.vert_tris.items[nearest];
        // 3. 执行实际插入逻辑
        try self.insertVertexWithStart(v_idx, start_tri);
        // 4. （可选）将新顶点加入 KD 树以加速后续查询
        // try self.tryAddVertexToKDtree(v_idx);
    }

    /// 内部插入实现：从指定起始三角形开始行走，找到点的确切位置并插入
    fn insertVertexWithStart(self: *CDT, v_idx: u32, start_tri: u32) !void {
        // 行走法定位：找到包含该点的三角形，或点所在的边
        const result = try self.walkToTriangle(v_idx, start_tri);
        // 临时栈，用于记录插入过程中新生成或修改的三角形，
        // 后续将基于此栈进行 Delaunay 边翻转
        self.temp_stack.clearRetainingCapacity();
        if (result.on_edge) |edge| {
            // 情况 A：点恰好落在某条边上
            // edge[0] 和 edge[1] 是该边的两个端点索引
            const t1 = result.tri_idx;
            const t2 = self.edgeNeighbor(&self.triangles.items[t1], edge[0], edge[1]);
            // 点在边上时，该边必然被两个三角形共享（t1 和 t2）。
            // 若 t2 == -1，说明该边是网格外部边界，在超三角形内部插入顶点时不应出现此情况。
            // 如果发生，通常是由于之前的拓扑操作错误或调用不当，需作为错误返回。
            if (t2 == -1) return error.EdgeHasNoNeighbor;
            try self.insertVertexOnEdge(v_idx, edge[0], edge[1], t1, @intCast(t2));
        } else {
            // 情况 B：点严格位于某个三角形内部
            try self.insertVertexInTriangle(v_idx, result.tri_idx);
        }
        // 对受影响的三角形进行边翻转，恢复 Delaunay 性质
        try self.ensureDelaunayByEdgeFlip(v_idx);
        // temp_stack 将在函数返回后保留其容量，供后续复用
    }

    /// 行走法：从起始三角形开始，逐步走向包含目标点的三角形或边
    /// 返回匿名结构体：{ tri_idx: u32, on_edge: ?[2]u32 }
    /// - tri_idx: 点所在的三角形索引
    /// - on_edge: 若点恰好在边上，则为该边两顶点索引；否则为 null
    fn walkToTriangle(self: *CDT, v_idx: u32, start_tri: u32) !struct { tri_idx: u32, on_edge: ?[2]u32 } {
        const pt = self.vertices.items[v_idx];
        var cur_tri = start_tri;
        // 防止无限循环（例如浮点误差导致循环行走）
        var visited = std.AutoHashMap(u32, void).init(self.allocator);
        defer visited.deinit();
        while (true) {
            if (visited.contains(cur_tri)) return error.InfiniteLoop;
            try visited.put(cur_tri, {});

            const tri = self.triangles.items[cur_tri];
            const v0 = self.vertices.items[tri.vertices[0]];
            const v1 = self.vertices.items[tri.vertices[1]];
            const v2 = self.vertices.items[tri.vertices[2]];

            // 1. 检查是否在三角形内部
            if (self.pointInTriangle(pt, tri))
                return .{ .tri_idx = cur_tri, .on_edge = null };

            // 2. 检查是否恰好在某条边上
            if (self.pointOnSegment(pt, v0, v1))
                return .{ .tri_idx = cur_tri, .on_edge = .{ tri.vertices[0], tri.vertices[1] } };
            if (self.pointOnSegment(pt, v1, v2))
                return .{ .tri_idx = cur_tri, .on_edge = .{ tri.vertices[1], tri.vertices[2] } };
            if (self.pointOnSegment(pt, v2, v0))
                return .{ .tri_idx = cur_tri, .on_edge = .{ tri.vertices[2], tri.vertices[0] } };

            // 3. 移动到下一个三角形
            const next = self.nextTriangleTowardsPoint(pt, tri) orelse return error.PointOutsideMesh;
            cur_tri = next;
        }
    }

    /// 寻找距离给定点最近的顶点
    fn findNearestVertex(self: *CDT, pt: Vec2) u32 {
        var nearest: u32 = 0;
        var min_dist_sq: f32 = std.math.floatMax(f32);
        for (self.vertices.items, 0..) |v, i| {
            const dx = v.x - pt.x;
            const dy = v.y - pt.y;
            const dist_sq = dx * dx + dy * dy;
            if (dist_sq < min_dist_sq) {
                min_dist_sq = dist_sq;
                nearest = @intCast(i);
            }
        }
        return nearest;
    }

    /// 在边上插入顶点（该边被两个三角形共享）
    /// 参数 v: 新顶点索引
    /// 参数 v1, v2: 边两端点索引（顺序不重要）
    /// 参数 t1, t2: 共享该边的两个三角形索引
    /// 操作：将 t1 和 t2 分别一分为二，共生成四个新三角形，并维护拓扑关系。
    /// 受影响的三角形索引（t1, t2, newt1, newt2）将被加入 temp_stack 以供后续边翻转。
    fn insertVertexOnEdge(self: *CDT, v: u32, v1: u32, v2: u32, t1: u32, t2: u32) !void {
        // 1. 分配两个新三角形索引
        const newt1 = try self.addNewTriangle();
        const newt2 = try self.addNewTriangle();

        // 获取两个原三角形的指针
        const tri1 = &self.triangles.items[t1];
        const tri2 = &self.triangles.items[t2];

        // 2. 确定边在 t1 中的局部位置，以及相对几何关系
        //    我们需要找出 v1, v2 在 t1 顶点数组中的顺序，以及对应的邻居信息。
        const local1 = try self.getEdgeLocalInfo(tri1, v1, v2, t2);
        const local2 = try self.getEdgeLocalInfo(tri2, v1, v2, t1);

        // 3. 提取拓扑信息（按文章中的变量命名）
        //    t1 相关的顶点和邻居：
        const n1 = tri1.neighbors[local1.idx]; // 边 (v1,v2) 原本的邻居，即 t2
        const n4 = tri1.neighbors[(local1.idx + 2) % 3]; // v2 逆时针下一邻边
        //    t2 相关的顶点和邻居：
        const v3 = tri2.vertices[local2.opposite]; // t2 中不与边相邻的那个顶点
        const n2 = tri2.neighbors[(local2.idx + 2) % 3]; // v3 逆时针下一邻边
        const n3 = tri2.neighbors[local2.idx]; // 边 (v1,v2) 在 t2 中的邻居，即 t1

        //    t1 的三个顶点（顺序由 local1 确定）
        const a = v1;
        const b = v2;
        const c = tri1.vertices[(local1.idx + 2) % 3]; // t1 中与 v 相对的顶点
        //    t2 的第四个顶点（与边相对的顶点）
        const d = v3;

        // 4. 更新四个三角形的数据（按照文章中的拓扑变换）
        //    注意：顶点顺序必须保持逆时针，且 neighbors 对应关系正确。

        // t1 更新为 (a, b, v)
        tri1.vertices = .{ a, b, v };
        tri1.neighbors = .{ n1, @intCast(t2), @intCast(newt1) };
        // t2 更新为 (b, d, v)
        tri2.vertices = .{ b, d, v };
        tri2.neighbors = .{ n2, @intCast(newt2), @intCast(t1) };
        // newt1 为 (c, a, v)
        self.triangles.items[newt1] = .{
            .vertices = .{ c, a, v },
            .neighbors = .{ n4, @intCast(t1), @intCast(newt2) },
        };
        // newt2 为 (d, c, v)
        self.triangles.items[newt2] = .{
            .vertices = .{ d, c, v },
            .neighbors = .{ n3, @intCast(newt1), @intCast(t2) },
        };

        // 5. 维护 vert_tris：新顶点 v 关联到 t1；顶点 c 可能需要更新
        try self.setVertTri(v, t1);
        try self.setVertTri(c, newt1);
        // 顶点 a, b, d 通常无需变动，因为它们的关联三角形可能仍有效，但可选择性更新。

        // 6. 更新外部邻居的邻接关系（n4 和 n3）
        if (n4 != -1) try self.setNewNeighbor(@intCast(n4), c, a, newt1);
        if (n3 != -1) try self.setNewNeighbor(@intCast(n3), d, c, newt2);

        // 7. 将受影响的四个三角形加入待处理栈
        try self.temp_stack.append(self.allocator, t1);
        try self.temp_stack.append(self.allocator, t2);
        try self.temp_stack.append(self.allocator, newt1);
        try self.temp_stack.append(self.allocator, newt2);
    }

    /// 获取边在三角形中的局部信息（辅助 insertVertexOnEdge）
    /// 返回结构：idx - 边在顶点数组中的起始索引（即 vertices[idx] == v1, vertices[(idx+1)%3] == v2）
    ///          opposite - 与该边相对的顶点索引（即三角形中第三个顶点在顶点数组中的索引）
    fn getEdgeLocalInfo(self: *CDT, tri: *Triangle, v1: u32, v2: u32, neighbor_tri: u32) !struct { idx: u32, opposite: u32 } {
        _ = self;
        for (0..3) |i| {
            const a = tri.vertices[i];
            const b = tri.vertices[(i + 1) % 3];
            if ((a == v1 and b == v2) or (a == v2 and b == v1)) {
                // 验证邻居关系（与文章逻辑一致，调试时可保留）
                if (tri.neighbors[i] != neighbor_tri) return error.InconsistentNeighbor;
                return .{ .idx = @intCast(i), .opposite = @intCast((i + 2) % 3) };
            }
        }
        return error.EdgeNotFoundInTriangle;
    }

    /// 在三角形内部插入顶点，将原三角形一分为三
    /// 参数 v: 新顶点索引
    /// 参数 t: 目标三角形索引（点严格位于其内部）
    /// 操作：创建两个新三角形，将 t 与 newt1、newt2 重新组织拓扑，
    ///       并将受影响的三个三角形加入 temp_stack 以供后续边翻转。
    fn insertVertexInTriangle(self: *CDT, v: u32, t: u32) !void {
        // 1. 分配两个新三角形
        const newt1 = try self.addNewTriangle();
        const newt2 = try self.addNewTriangle();

        const tri = &self.triangles.items[t];

        // 2. 提取原三角形的顶点和邻居（按逆时针顺序）
        const v0 = tri.vertices[0];
        const v1 = tri.vertices[1];
        const v2 = tri.vertices[2];
        const n0 = tri.neighbors[0]; // 边 (v0, v1) 的邻居
        const n1 = tri.neighbors[1]; // 边 (v1, v2) 的邻居
        const n2 = tri.neighbors[2]; // 边 (v2, v0) 的邻居

        // 3. 更新三个三角形的数据（顶点顺序逆时针，邻居对应规则不变）
        //    t: (v0, v1, v)
        tri.vertices = .{ v0, v1, v };
        tri.neighbors = .{ n0, @intCast(newt1), @intCast(newt2) };
        //    newt1: (v1, v2, v)
        self.triangles.items[newt1] = .{
            .vertices = .{ v1, v2, v },
            .neighbors = .{ n1, @intCast(newt2), @intCast(t) },
        };
        //    newt2: (v2, v0, v)
        self.triangles.items[newt2] = .{
            .vertices = .{ v2, v0, v },
            .neighbors = .{ n2, @intCast(t), @intCast(newt1) },
        };

        // 4. 维护 vert_tris：新顶点 v 关联到三角形 t
        try self.setVertTri(v, t);
        // 顶点 v2 的关联三角形原为 t，现在改为 newt1（可选，但有助于行走法）
        try self.setVertTri(v2, newt1);

        // 5. 更新外部邻居的邻接关系
        //    原边 (v0,v1) 的邻居 n0 仍指向 t，无需更改
        //    原边 (v1,v2) 的邻居 n1 现在应指向 newt1
        if (n1 != -1) try self.setNewNeighbor(@intCast(n1), v1, v2, newt1);
        //    原边 (v2,v0) 的邻居 n2 现在应指向 newt2
        if (n2 != -1) try self.setNewNeighbor(@intCast(n2), v2, v0, newt2);

        // 6. 将三个受影响的三角形加入待处理栈
        try self.temp_stack.append(self.allocator, t);
        try self.temp_stack.append(self.allocator, newt1);
        try self.temp_stack.append(self.allocator, newt2);
    }

    /// 更新三角形 tri_idx 的邻居关系：将边 (old_v1, old_v2) 的邻居设为 new_neighbor
    /// 注意：边的方向在邻居三角形中可能与原三角形相反，因此需要双向匹配。
    /// 参数 tri_idx: 需要更新邻居关系的三角形索引
    /// 参数 old_v1, old_v2: 共享边的两个端点（顺序应与原三角形中该边的方向一致）
    /// 参数 new_neighbor: 新的邻居三角形索引
    fn setNewNeighbor(self: *CDT, tri_idx: u32, old_v1: u32, old_v2: u32, new_neighbor: u32) !void {
        const tri = &self.triangles.items[tri_idx];
        for (0..3) |i| {
            const a = tri.vertices[i];
            const b = tri.vertices[(i + 1) % 3];
            // 检查边 (a, b) 是否与 (old_v1, old_v2) 匹配（考虑反向）
            if ((a == old_v1 and b == old_v2) or (a == old_v2 and b == old_v1)) {
                tri.neighbors[i] = @intCast(new_neighbor);
                return;
            }
        }
        return error.EdgeNotFoundInTriangle;
    }

    // ---------- 约束边操作 ----------
    /// 插入约束边（障碍物边界），若与已有约束边相交则自动拆分
    pub fn insertConstraintEdge(self: *CDT, v1: u32, v2: u32) !void {
        _ = v1;
        _ = v2;
        _ = self;
        @compileError("Not implemented");
    }

    /// 约束边插入迭代主逻辑（处理单条边，可能拆分为多段）
    fn insertEdgeIteration(self: *CDT, edge: Edge) !void {
        _ = edge;
        _ = self;
        @compileError("Not implemented");
    }

    /// 标记已存在的约束边（内部使用）
    fn fixEdge(self: *CDT, edge: Edge) !void {
        _ = edge;
        _ = self;
        @compileError("Not implemented");
    }

    /// 检查约束边是否已存在于网格中
    fn edgeExists(self: *CDT, v1: u32, v2: u32) !bool {
        _ = v1;
        _ = v2;
        _ = self;
        @compileError("Not implemented");
    }

    /// 在交点处拆分约束边，并重新插入网格
    fn splitFixedEdgeAt(self: *CDT, edge: Edge, pos: Vec2, t1: u32, t2: u32) !u32 {
        _ = edge;
        _ = pos;
        _ = t1;
        _ = t2;
        _ = self;
        @compileError("Not implemented");
    }

    /// 在交点处添加新顶点（内部调用）
    fn addSplitEdgeVertex(self: *CDT, pos: Vec2, t1: u32, t2: u32) !u32 {
        _ = pos;
        _ = t1;
        _ = t2;
        _ = self;
        @compileError("Not implemented");
    }

    /// 将固定边拆分为两段
    fn splitFixedEdge(self: *CDT, edge: Edge, split_vert: u32) !void {
        _ = edge;
        _ = split_vert;
        _ = self;
        @compileError("Not implemented");
    }

    // ---------- Delaunay维护与边翻转 ----------

    /// 通过边翻转恢复局部 Delaunay 性质
    /// 参数 v: 新插入顶点的索引（用于确定需要检查的边）
    /// 算法：循环处理 temp_stack 中的每个三角形，检查其与邻居的公共边是否需要进行翻转，
    ///       若翻转，则将新形成的三角形也加入栈中，直到栈空。
    fn ensureDelaunayByEdgeFlip(self: *CDT, v: u32) !void {
        while (self.temp_stack.items.len > 0) {
            const t = self.temp_stack.pop().?;

            // 获取边翻转所需的几何与拓扑信息
            const info = try self.edgeFlipInfo(t, v);
            if (info.new_t1 == -1) continue; // 该边无邻居三角形，无法翻转

            // 检查是否需要翻转边
            if (self.shouldFlipEdge(v, info.v2, info.v3, info.v4)) {
                // 执行边翻转
                try self.flipEdge(t, @intCast(info.new_t1), v, info.v2, info.v3, info.v4, info.n1, info.n2, info.n3, info.n4);
                // 翻转后，原三角形 t 和 new_t1 的内容已被修改，需再次检查
                try self.temp_stack.append(self.allocator, t);
                try self.temp_stack.append(self.allocator, @intCast(info.new_t1));
            }
        }
    }

    /// 执行边翻转操作（将四边形 (v1,v2,v3,v4) 的对角线从 (v2,v4) 翻转为 (v1,v3)）
    /// 参数 t1, t2: 共享边 (v2,v4) 的两个三角形
    /// 其余参数与 edgeFlipInfo 返回值对应
    fn flipEdge(self: *CDT, t1: u32, t2: u32, v1: u32, v2: u32, v3: u32, v4: u32, n1: i32, n2: i32, n3: i32, n4: i32) !void {
        const tri1 = &self.triangles.items[t1];
        const tri2 = &self.triangles.items[t2];
        // 更新 t1: 顶点变为 (v4, v1, v3)
        tri1.vertices = .{ v4, v1, v3 };
        // 边 (v4,v1) 原邻居 n3, 边 (v1,v3) -> t2, 边 (v3,v4) 原邻居 n4
        tri1.neighbors = .{ n3, @intCast(t2), n4 };
        // 更新 t2: 顶点变为 (v2, v3, v1)
        tri2.vertices = .{ v2, v3, v1 };
        // 边 (v2,v3) 原邻居 n2, 边 (v3,v1) -> t1, 边 (v1,v2) 原邻居 n1
        tri2.neighbors = .{ n2, @intCast(t1), n1 };
        // 更新外部邻居的指向
        if (n4 != -1) try self.setNewNeighbor(@intCast(n4), v3, v4, t1);
        if (n1 != -1) try self.setNewNeighbor(@intCast(n1), v1, v2, t2);
        // 维护 vert_tris：v4 关联到 t1，v2 关联到 t2（可选但有助于行走法）
        try self.setVertTri(v4, t1);
        try self.setVertTri(v2, t2);
    }

    /// 计算边翻转所需的信息（对应文章中的 EdgeFlipinfo）
    /// 参数 t: 当前三角形索引
    /// 参数 v1: 新插入的顶点索引（位于三角形 t 中，作为翻转边的对顶点）
    /// 返回结构：包含邻居关系、四个顶点索引等信息；若边无邻居则 new_t1 = -1
    fn edgeFlipInfo(self: *CDT, t: u32, v1: u32) !struct {
        new_t1: i32,
        n1: i32,
        n2: i32,
        n3: i32,
        n4: i32,
        v2: u32,
        v3: u32,
        v4: u32,
    } {
        const tri = &self.triangles.items[t];
        // 找到 v1 在三角形 t 顶点数组中的位置
        const idx = blk: {
            for (tri.vertices, 0..) |vertex, i|
                if (vertex == v1) break :blk @as(u32, @intCast(i));
            return error.VertexNotInTriangle;
        };
        // 根据 idx 构建相对几何关系（文章中的 if-else 分支）
        const v2 = tri.vertices[(idx + 1) % 3];
        const v4 = tri.vertices[(idx + 2) % 3];
        const n1 = tri.neighbors[idx]; // 边 (v1, v2) 的邻居（暂未使用）
        const n3 = tri.neighbors[(idx + 2) % 3]; // 边 (v4, v1) 的邻居
        const new_t1 = tri.neighbors[(idx + 1) % 3]; // 边 (v2, v4) 的邻居（待翻转边对边）

        if (new_t1 == -1) // 该边无邻居，无法翻转
            return .{ .new_t1 = -1, .n1 = -1, .n2 = -1, .n3 = -1, .n4 = -1, .v2 = 0, .v3 = 0, .v4 = 0 };

        const new_tri = &self.triangles.items[@intCast(new_t1)];

        // 在邻居三角形中找到边 (v2, v4) 对应的索引
        const new_idx = blk: {
            for (new_tri.neighbors, 0..) |n, i| {
                if (n == t) break :blk @as(u32, @intCast(i));
            }
            return error.NeighborNotReciprocal;
        };

        const v3 = new_tri.vertices[(new_idx + 2) % 3]; // 邻居中与边相对的顶点
        const n2 = new_tri.neighbors[(new_idx + 1) % 3]; // 边 (v2, v3) 的邻居
        const n4 = new_tri.neighbors[(new_idx + 2) % 3]; // 边 (v3, v4) 的邻居

        return .{
            .new_t1 = new_t1,
            .n1 = n1,
            .n2 = n2,
            .n3 = n3,
            .n4 = n4,
            .v2 = v2,
            .v3 = v3,
            .v4 = v4,
        };
    }

    /// 判断是否应该执行边翻转（基于空圆测试）
    /// 参数 v1, v2, v3, v4: 构成两个相邻三角形的四个顶点
    ///   - v1, v2, v4 属于三角形 t1
    ///   - v2, v3, v4 属于三角形 t2（邻居）
    /// 返回 true 如果顶点 v1 位于三角形 (v2, v3, v4) 的外接圆内。
    fn shouldFlipEdge(self: *CDT, v1: u32, v2: u32, v3: u32, v4: u32) bool {
        const a = self.vertices.items[v1];
        const b = self.vertices.items[v2];
        const c = self.vertices.items[v3];
        const d = self.vertices.items[v4];
        // 检查 v1 是否在三角形 (v2, v3, v4) 的外接圆内
        // 注意参数顺序：pointInCircumcircle(检测点, 三角形三顶点)
        return pointInCircumcircle(a, b, c, d);
    }

    // ---------- 几何查询与辅助函数 ----------
    /// 通过行走法定位点所在的三角形
    pub fn locatePoint(self: *CDT, pt: Vec2) !?u32 {
        _ = pt;
        _ = self;
        @compileError("Not implemented");
    }

    /// 选择下一个朝向目标点的三角形（行走法步进）
    /// 给定点 pt 和三角形 tri，返回点所在方向的下一个三角形索引。
    /// 前提：已知 pt 不在 tri 内部（不在任何边上），因此 pt 必然位于某条边的外侧。
    /// 遍历三条边，若点在有向面积的负侧（即边的顺时针侧），且该边有邻居，则返回邻居索引。
    /// 若没有符合条件的邻居（说明点在网格外部），返回 null。
    fn nextTriangleTowardsPoint(self: *CDT, pt: Vec2, tri: Triangle) ?u32 {
        const a = self.vertices.items[tri.vertices[0]];
        const b = self.vertices.items[tri.vertices[1]];
        const c = self.vertices.items[tri.vertices[2]];
        const vertices = [3]Vec2{ a, b, c };

        for (0..3) |i| {
            const v_start = vertices[i];
            const v_end = vertices[(i + 1) % 3];
            const neighbor = tri.neighbors[i];

            // 计算有向面积，判断点相对于边 (v_start -> v_end) 的位置
            // 由于三角形顶点逆时针，对于内部点，所有面积 >= 0。
            // 若面积 < 0，说明点在边的顺时针侧（即外部）。
            if (Vec2.signedArea2(v_start, v_end, pt) < 0) {
                if (neighbor != -1) {
                    return @intCast(neighbor);
                } else {
                    // 点在网格边界外
                    return null;
                }
            }
        }

        // 理论上不会执行到这里，因为前提是 pt 不在三角形内。
        // 如果到达此处，可能是浮点误差导致面积均为正，但点实际上在外面。
        // 作为 fallback，返回 null。
        return null;
    }

    /// 判断点 pt 是否严格位于三角形 tri 的内部（不含边界）
    /// 要求三角形顶点为逆时针顺序。
    fn pointInTriangle(self: *CDT, pt: Vec2, tri: Triangle) bool {
        const a = self.vertices.items[tri.vertices[0]];
        const b = self.vertices.items[tri.vertices[1]];
        const c = self.vertices.items[tri.vertices[2]];

        // 计算 pt 与三边构成的子三角形有向面积（使用 Vec2.signedArea2）
        const area1 = Vec2.signedArea2(a, b, pt);
        const area2 = Vec2.signedArea2(b, c, pt);
        const area3 = Vec2.signedArea2(c, a, pt);

        // 由于顶点为逆时针，内部点应使三个面积均 > 0
        const eps = 1e-9;
        return area1 > -eps and area2 > -eps and area3 > -eps;
    }

    /// 判断点 pt 是否在线段 ab 上（含端点，考虑浮点误差）
    fn pointOnSegment(self: *CDT, pt: Vec2, a: Vec2, b: Vec2) bool {
        _ = self;
        const ab = b.sub(a);
        const ap = pt.sub(a);
        // 共线性检查：叉积接近 0
        if (@abs(ab.cross(ap)) > 1e-6) return false;
        // 投影检查：点积在 [0, |ab|^2] 之间
        const dot = ap.dot(ab);
        if (dot < -1e-6 or dot > ab.len2() + 1e-6) return false;
        return true;
    }

    /// 判断点在有向边的哪一侧
    fn lineSide(pt: Vec2, a: Vec2, b: Vec2) enum { Left, Right, On } {
        const ab = b.sub(a);
        const ap = pt.sub(a);
        const cross_val = Vec2.cross(ab, ap);
        if (cross_val > 0) return .Left;
        if (cross_val < 0) return .Right;
        return .On;
    }

    /// 判断三角形是否包含指定边（顶点顺序无关）
    fn triangleHasEdge(self: *CDT, tri: Triangle, v1: u32, v2: u32) bool {
        _ = tri;
        _ = v1;
        _ = v2;
        _ = self;
        @compileError("Not implemented");
    }

    /// 获取三角形中与给定顶点对边相邻的邻居三角形
    fn getOpposedTriangle(self: *CDT, tri: *Triangle, v: u32) i32 {
        _ = tri;
        _ = v;
        _ = self;
        @compileError("Not implemented");
    }

    /// 获取相邻三角形中远离当前三角形的远端顶点
    fn opposedVertex(self: *CDT, tri: *Triangle, t_neighbor: u32) u32 {
        _ = tri;
        _ = t_neighbor;
        _ = self;
        @compileError("Not implemented");
    }

    /// 获取共享边 (v1, v2) 的邻居三角形索引
    /// 参数 tri: 当前三角形的指针
    /// 参数 v1, v2: 边的两个端点索引（顺序无关）
    /// 返回: 邻居三角形索引（i32），若无邻居则返回 -1
    fn edgeNeighbor(self: *CDT, tri: *Triangle, v1: u32, v2: u32) i32 {
        for (tri.neighbors) |n| {
            if (n == -1) continue;
            const neighbor_tri = &self.triangles.items[@intCast(n)];
            // 检查邻居三角形是否包含边 (v1, v2) 或 (v2, v1)
            const has_v1 = neighbor_tri.vertices[0] == v1 or neighbor_tri.vertices[1] == v1 or neighbor_tri.vertices[2] == v1;
            const has_v2 = neighbor_tri.vertices[0] == v2 or neighbor_tri.vertices[1] == v2 or neighbor_tri.vertices[2] == v2;
            if (has_v1 and has_v2)
                return n;
        }
        return -1;
    }

    /// 设置顶点 v 的关联三角形为 t
    /// 若 vert_tris 长度不足，自动扩容并用 0 填充
    fn setVertTri(self: *CDT, v: u32, t: u32) !void {
        const required_len = v + 1;
        if (self.vert_tris.items.len < required_len)
            try self.vert_tris.resize(self.allocator, required_len);
        self.vert_tris.items[v] = t;
    }

    /// 将顶点的关联三角形顺时针旋转（防止指向即将删除的三角形）
    fn pivotVertexTriangleCW(self: *CDT, v: u32) void {
        _ = v;
        _ = self;
        @compileError("Not implemented");
    }

    /// 判断点 pt 是否在由 a, b, c 构成的三角形外接圆内（Delaunay 空圆测试）
    /// 使用 3 阶行列式，将 pt 平移至原点简化计算
    fn pointInCircumcircle(pt: Vec2, a: Vec2, b: Vec2, c: Vec2) bool {
        const ax = a.x - pt.x;
        const ay = a.y - pt.y;
        const bx = b.x - pt.x;
        const by = b.y - pt.y;
        const cx = c.x - pt.x;
        const cy = c.y - pt.y;
        const det = blk: {
            break :blk (ax * ax + ay * ay) * (bx * cy - cx * by) -
                (bx * bx + by * by) * (ax * cy - cx * ay) +
                (cx * cx + cy * cy) * (ax * by - bx * ay);
        };
        return det > 0;
    }

    // ---------- 伪多边形重三角化 ----------
    /// 伪多边形重三角化任务结构
    const TriangulatePseudoPolygonTask = struct {
        iA: u32,
        iB: u32,
        iT: u32,
        iParent: u32,
        iInParent: u32,
    };

    /// 对伪多边形进行重新三角剖分
    fn triangulatePseudoPolygon(self: *CDT, poly: *std.ArrayListUnmanaged(u32), outer_tris: *std.AutoHashMapUnmanaged(Edge, i32), iTL: u32, iTR: u32, triangles_to_reuse: *std.ArrayListUnmanaged(u32), iterations: *std.ArrayListUnmanaged(TriangulatePseudoPolygonTask)) !void {
        _ = poly;
        _ = outer_tris;
        _ = iTL;
        _ = iTR;
        _ = triangles_to_reuse;
        _ = iterations;
        _ = self;
        @compileError("Not implemented");
    }

    /// 单次三角化迭代（处理一个固定边）
    fn triangulatePseudoPolygonIteration(self: *CDT, poly: *std.ArrayListUnmanaged(u32), outer_tris: *std.AutoHashMapUnmanaged(Edge, i32), triangles_to_reuse: *std.ArrayListUnmanaged(u32), iterations: *std.ArrayListUnmanaged(TriangulatePseudoPolygonTask)) !void {
        _ = poly;
        _ = outer_tris;
        _ = triangles_to_reuse;
        _ = iterations;
        _ = self;
        @compileError("Not implemented");
    }

    /// 在伪多边形中寻找最佳第三点（使外接圆不包含其他顶点）
    fn findDelaunayPoint(self: *CDT, poly: *std.ArrayListUnmanaged(u32), iA: u32, iB: u32) u32 {
        _ = poly;
        _ = iA;
        _ = iB;
        _ = self;
        @compileError("Not implemented");
    }

    // ---------- 寻路相关 ----------
    /// 漏斗寻路主入口：计算从start到end的世界坐标路径
    pub fn findPath(self: *CDT, start: Vec2, end: Vec2, out_path: *std.ArrayList(Vec2)) !void {
        _ = start;
        _ = end;
        _ = out_path;
        _ = self;
        @compileError("Not implemented");
    }

    /// A*搜索三角形通道（从起点三角形到终点三角形）
    fn findChannel(self: *CDT, start_tri: u32, end_tri: u32, out_channel: *std.ArrayList(u32)) !void {
        _ = start_tri;
        _ = end_tri;
        _ = out_channel;
        _ = self;
        @compileError("Not implemented");
    }

    /// 漏斗算法：将三角形通道转换为带拐点的路径
    fn funnel(self: *CDT, start_pt: Vec2, end_pt: Vec2, channel: []const u32, out_path: *std.ArrayList(Vec2)) !void {
        _ = start_pt;
        _ = end_pt;
        _ = channel;
        _ = out_path;
        _ = self;
        @compileError("Not implemented");
    }

    // ---------- 障碍物动态管理（RTS高层接口） ----------
    /// 放置新建筑（添加顶点与约束边）
    pub fn placeBuilding(self: *CDT, footprint: []const Vec2) !void {
        _ = footprint;
        _ = self;
        @compileError("Not implemented");
    }

    /// 移除建筑（标记相关区域可通行，通常不删除网格）
    pub fn removeBuilding(self: *CDT, building_id: u32) !void {
        _ = building_id;
        _ = self;
        @compileError("Not implemented");
    }

    // ---------- 内部辅助 ----------
    /// 向 triangles 列表追加一个空三角形并返回其索引
    fn addNewTriangle(self: *CDT) !u32 {
        const idx = @as(u32, @intCast(self.triangles.items.len));
        try self.triangles.append(self.allocator, undefined);
        return idx;
    }

    /// 将顶点添加到KD树（加速最近点查询）
    fn tryAddVertexToKDtree(self: *CDT, v_idx: u32) !void {
        _ = v_idx;
        _ = self;
        @compileError("Not implemented");
    }
};
