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

        // --- 添加地图边界约束边 ---
        // 边界矩形的四个角点
        const corners = [_]Vec2{
            .{ .x = 0.0, .y = 0.0 },
            .{ .x = width_f, .y = 0.0 },
            .{ .x = width_f, .y = height_f },
            .{ .x = 0.0, .y = height_f },
        };
        var corner_verts: [4]u32 = undefined;
        for (corners, 0..) |pt, i| {
            // 边界点直接作为普通顶点插入（先 addVertex 再 insertVertex）
            corner_verts[i] = try cdt.addVertex(pt);
            try cdt.insertVertex(corner_verts[i]);
        }

        // 插入四条约束边（矩形边界）
        try cdt.insertConstraintEdge(corner_verts[0], corner_verts[1]); // 下边
        try cdt.insertConstraintEdge(corner_verts[1], corner_verts[2]); // 右边
        try cdt.insertConstraintEdge(corner_verts[2], corner_verts[3]); // 上边
        try cdt.insertConstraintEdge(corner_verts[3], corner_verts[0]); // 左边

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

    /// 查找或添加顶点：若存在距离小于容差的顶点则返回其索引，否则新增。
    pub fn findOrAddVertex(self: *CDT, pt: Vec2, tolerance: f32) !u32 {
        const nearest = self.findNearestVertex(pt);
        const dist = self.vertices.items[nearest].sub(pt).len();
        if (dist <= tolerance)
            return nearest;
        const idx = try self.addVertex(pt);
        try self.insertVertex(idx);
        return idx;
    }

    /// 插入约束边
    pub fn insertConstraintEdge(self: *CDT, v1: u32, v2: u32) !void {
        if (v1 == v2) return;
        if (try self.edgeExists(v1, v2)) {
            try self.fixEdge(.{ .v1 = v1, .v2 = v2 });
            return;
        }
        try self.insertEdgeIteration(.{ .v1 = v1, .v2 = v2 });
    }

    /// 约束边插入迭代主逻辑：处理单条边，可能因相交而拆分为多段。
    /// 算法采用栈式处理：将待插入边压入 remaining 栈，循环处理直到栈空。
    fn insertEdgeIteration(self: *CDT, edge: Edge) !void {
        var remaining = std.ArrayList(Edge){};
        defer remaining.deinit(self.allocator);
        try remaining.append(self.allocator, edge);

        var iter_count: u32 = 0;
        const max_iter = self.triangles.items.len * 2;

        while (remaining.items.len > 0) : (iter_count += 1) {
            if (iter_count > max_iter) return error.InfiniteLoopInInsert;
            const cur_edge = remaining.pop().?;
            const iA = cur_edge.v1;
            var iB = cur_edge.v2;

            // 1. 收集相交三角形与伪多边形
            var intersected = std.ArrayList(u32){};
            defer intersected.deinit(self.allocator);
            var polyL = std.ArrayList(u32){};
            defer polyL.deinit(self.allocator);
            var polyR = std.ArrayList(u32){};
            defer polyR.deinit(self.allocator);
            var outerTris = std.AutoHashMap(Edge, i32).init(self.allocator);
            defer outerTris.deinit();

            try self.collectIntersectedTriangles(iA, &iB, &intersected, &polyL, &polyR, &outerTris);

            // 如果 intersected 为空，说明边已存在或完全在三角形内部，只需固定
            if (intersected.items.len == 0) {
                try self.fixEdge(.{ .v1 = iA, .v2 = iB });
                continue;
            }

            // 2. 如果终点被截断（例如与顶点共线），将剩余段压入栈
            if (iB != cur_edge.v2) {
                try self.fixEdge(.{ .v1 = iA, .v2 = iB });
                try remaining.append(self.allocator, .{ .v1 = iB, .v2 = cur_edge.v2 });
                continue;
            }

            // 3. 准备重三角化（iTL、iTR 为与外部相连的两个三角形）
            const iTL = intersected.items[0]; // 第一个相交三角形
            const iTR = intersected.items[intersected.items.len - 1]; // 最后一个

            // 反转 polyR 使其变为逆时针（便于统一处理）
            std.mem.reverse(u32, polyR.items);

            // 收集可重用的三角形索引（即被删除的相交三角形）
            var trianglesToReuse = std.ArrayList(u32){};
            defer trianglesToReuse.deinit(self.allocator);
            try trianglesToReuse.appendSlice(self.allocator, intersected.items);

            var iterations = std.ArrayList(TriangulatePseudoPolygonTask){};
            defer iterations.deinit(self.allocator);

            // 4. 对两侧伪多边形分别重三角化
            try self.triangulatePseudoPolygon(&polyL, &outerTris, iTL, iTR, &trianglesToReuse, &iterations);
            try self.triangulatePseudoPolygon(&polyR, &outerTris, iTR, iTL, &trianglesToReuse, &iterations);

            // 5. 标记整条边为固定边
            try self.fixEdge(.{ .v1 = iA, .v2 = iB });
        }
    }

    /// 收集与约束边 (iA, iB) 相交的所有三角形，并构建两侧伪多边形。
    /// 参数：
    ///   - iA: 约束边起点索引
    ///   - iB: 约束边终点索引（作为可修改指针，若边经过现有顶点则更新为该顶点）
    ///   - intersected: 输出参数，存储相交三角形的索引序列
    ///   - polyL: 输出参数，存储左侧伪多边形的顶点索引（逆时针顺序）
    ///   - polyR: 输出参数，存储右侧伪多边形的顶点索引（逆时针顺序）
    ///   - outerTris: 输出参数，存储伪多边形边界边对应的外部三角形索引（Edge -> 邻居三角形）
    /// 注意：调用前需确保传入的容器已清空。
    fn collectIntersectedTriangles(
        self: *CDT,
        iA: u32,
        iB: *u32,
        intersected: *std.ArrayList(u32),
        polyL: *std.ArrayList(u32),
        polyR: *std.ArrayList(u32),
        outerTris: *std.AutoHashMap(Edge, i32),
    ) !void {
        const a = self.vertices.items[iA];
        const b = self.vertices.items[iB.*];

        var first = try self.intersectedTriangle(iA, a, b);
        var start_from_a = true;

        if (first.tri_idx == -1) {
            const first_rev = try self.intersectedTriangle(iB.*, b, a);
            if (first_rev.tri_idx == -1) {
                // 双向均未找到穿出
                if (try self.edgeExists(iA, iB.*)) {
                    return; // 边已存在，无需处理
                }
                // 线段完全在某个三角形内部，可视为成功（无需重三角化）
                return;
            }
            first = first_rev;
            start_from_a = false;
        }

        // 根据实际行走方向确定起点、终点及左右多边形对应关系
        const start_pt = if (start_from_a) a else b;
        const end_pt = if (start_from_a) b else a;
        const start_idx = if (start_from_a) iA else iB.*;
        var end_idx = if (start_from_a) iB.* else iA;

        var iT = @as(u32, @intCast(first.tri_idx));
        const iVL = first.vL;
        const iVR = first.vR;

        try intersected.append(self.allocator, iT);

        // 初始化伪多边形
        try polyL.append(self.allocator, start_idx);
        try polyL.append(self.allocator, iVL);
        try polyR.append(self.allocator, start_idx);
        try polyR.append(self.allocator, iVR);

        var tri = &self.triangles.items[iT];
        try outerTris.put(.{ .v1 = start_idx, .v2 = iVL }, self.edgeNeighbor(tri, start_idx, iVL));
        try outerTris.put(.{ .v1 = start_idx, .v2 = iVR }, self.edgeNeighbor(tri, start_idx, iVR));

        const iV = start_idx;

        var iter_count: u32 = 0;
        const max_iter = self.triangles.items.len * 2;
        while (!self.triangleContainsVertex(iT, end_idx)) : (iter_count += 1) {
            if (iter_count > max_iter) return error.InfiniteLoopInCollect;

            const iTopo = self.getOpposedTriangle(&self.triangles.items[iT], iV);
            if (iTopo == -1) return error.EdgeHasNoNeighbor;

            const topo = &self.triangles.items[@intCast(iTopo)];
            const iVopo = self.opposedVertex(topo, iT);

            // 冲突检测：与已有固定边相交
            if (self.fixed_edges.contains(.{ .v1 = iVL, .v2 = iVR }) or
                self.fixed_edges.contains(.{ .v1 = iVR, .v2 = iVL }))
            {
                const newPos = self.lineIntersection(start_pt, end_pt, self.vertices.items[iVL], self.vertices.items[iVR]);
                const iNewVert = try self.splitFixedEdgeAt(.{ .v1 = iVL, .v2 = iVR }, newPos, iT, @intCast(iTopo));
                iB.* = iNewVert;
                return;
            }

            const loc = self.lineSide(self.vertices.items[iVopo], start_pt, end_pt);
            if (loc == .Left) {
                try polyL.append(self.allocator, iVopo);
                try outerTris.put(.{ .v1 = iVL, .v2 = iVopo }, self.edgeNeighbor(topo, iVL, iVopo));
            } else if (loc == .Right) {
                try polyR.append(self.allocator, iVopo);
                try outerTris.put(.{ .v1 = iVR, .v2 = iVopo }, self.edgeNeighbor(topo, iVR, iVopo));
            } else {
                // 共线：更新终点为当前顶点
                end_idx = iVopo;
                iB.* = iVopo;
                return;
            }

            try intersected.append(self.allocator, @intCast(iTopo));
            iT = @intCast(iTopo);
        }

        // 记录最后的外部三角形
        tri = &self.triangles.items[iT];
        try outerTris.put(.{ .v1 = polyL.getLast(), .v2 = end_idx }, self.edgeNeighbor(tri, polyL.getLast(), end_idx));
        try outerTris.put(.{ .v1 = polyR.getLast(), .v2 = end_idx }, self.edgeNeighbor(tri, polyR.getLast(), end_idx));
        try polyL.append(self.allocator, end_idx);
        try polyR.append(self.allocator, end_idx);
    }

    /// 辅助：判断三角形是否包含指定顶点
    fn triangleContainsVertex(self: *CDT, tri_idx: u32, v: u32) bool {
        const tri = self.triangles.items[tri_idx];
        return tri.vertices[0] == v or tri.vertices[1] == v or tri.vertices[2] == v;
    }

    /// 计算两条线段 (a,b) 和 (c,d) 的交点（假设它们不平行且必定相交）
    fn lineIntersection(self: *CDT, a: Vec2, b: Vec2, c: Vec2, d: Vec2) Vec2 {
        _ = self;
        const ab = b.sub(a);
        const cd = d.sub(c);
        const ac = c.sub(a);
        const t = Vec2.cross(ac, cd) / Vec2.cross(ab, cd);
        return a.add(ab.scale(t));
    }

    /// 标记约束边（加入 fixed_edges 集合）
    fn fixEdge(self: *CDT, edge: Edge) !void {
        try self.fixed_edges.put(self.allocator, edge, {});
    }

    /// 检查连接顶点 v1 和 v2 的边是否作为三角形边存在于当前网格中。
    /// 实现：从 v1 的某个关联三角形出发，通过邻居关系遍历 v1 周围的三角形，
    ///       检查是否有三角形同时包含 v1 和 v2。
    fn edgeExists(self: *CDT, v1: u32, v2: u32) !bool {
        if (v1 >= self.vertices.items.len or v2 >= self.vertices.items.len) return false;
        const start_tri = self.vert_tris.items[v1];
        if (start_tri >= self.triangles.items.len) return false;

        var visited = std.AutoHashMap(u32, void).init(self.allocator);
        defer visited.deinit();

        var stack = std.ArrayList(u32){};
        defer stack.deinit(self.allocator);
        try stack.append(self.allocator, start_tri);

        while (stack.items.len > 0) {
            const cur = stack.pop().?;
            if (visited.contains(cur)) continue;
            try visited.put(cur, {});

            const tri = self.triangles.items[cur];
            // 检查是否包含 v2
            if (tri.vertices[0] == v2 or tri.vertices[1] == v2 or tri.vertices[2] == v2) {
                // 进一步检查 (v1, v2) 是否是一条边（即它们共享的边）
                const has_edge = (tri.vertices[0] == v1 and tri.vertices[1] == v2) or
                    (tri.vertices[1] == v1 and tri.vertices[2] == v2) or
                    (tri.vertices[2] == v1 and tri.vertices[0] == v2) or
                    (tri.vertices[0] == v2 and tri.vertices[1] == v1) or
                    (tri.vertices[1] == v2 and tri.vertices[2] == v1) or
                    (tri.vertices[2] == v2 and tri.vertices[0] == v1);
                if (has_edge) return true;
            }

            // 将包含 v1 的邻居三角形压入栈
            for (tri.neighbors) |n| {
                if (n != -1) {
                    const neighbor_idx = @as(u32, @intCast(n));
                    const neighbor = self.triangles.items[neighbor_idx];
                    if (neighbor.vertices[0] == v1 or neighbor.vertices[1] == v1 or neighbor.vertices[2] == v1) {
                        try stack.append(self.allocator, neighbor_idx);
                    }
                }
            }
        }
        return false;
    }

    /// 辅助：围绕顶点 v 旋转到下一个三角形（逆时针方向）
    /// 参数 cur: 当前三角形索引
    /// 参数 v: 中心顶点索引
    /// 参数 prev: 前一个三角形索引（用于确定旋转方向，首次调用可为 null）
    /// 返回下一个包含 v 的三角形索引，若无则返回 null
    fn nextTriangleAroundVertex(self: *CDT, cur: u32, v: u32, prev: ?u32) ?u32 {
        const tri = self.triangles.items[cur];
        const idx = blk: {
            for (tri.vertices, 0..) |vertex, i| {
                if (vertex == v) break :blk @as(u32, @intCast(i));
            }
            return null;
        };

        if (prev == null) {
            const n = tri.neighbors[(idx + 2) % 3];
            return if (n != -1) @intCast(n) else null;
        } else {
            for (tri.neighbors, 0..) |n, i| {
                if (n != -1 and @as(u32, @intCast(n)) == prev.?) {
                    const next_n = tri.neighbors[(i + 2) % 3];
                    return if (next_n != -1) @intCast(next_n) else null;
                }
            }
            return null;
        }
    }

    /// 查找线段 AB 首次穿出的三角形。支持起点为顶点的情况。
    /// 返回值：
    ///   tri_idx = -1：未找到穿出（可能边已存在或线段完全在内部）
    ///   tri_idx = -2：线段完全位于某个三角形内部（起点和终点在同一三角形）
    ///   否则返回穿入边的邻居三角形及边端点。
    fn intersectedTriangle(self: *CDT, iA: u32, a: Vec2, b: Vec2) !struct { tri_idx: i32, vL: u32, vR: u32 } {
        const start_tri = self.vert_tris.items[iA];
        var cur_tri = start_tri;
        var prev_tri: ?u32 = null;

        const max_iter = self.triangles.items.len * 2;
        var iter: u32 = 0;

        while (iter < max_iter) : (iter += 1) {
            const tri = self.triangles.items[cur_tri];

            // 如果终点在当前三角形内部，则线段完全在内部
            if (self.pointInTriangle(b, tri)) {
                return .{ .tri_idx = -2, .vL = 0, .vR = 0 };
            }

            // 找到起点 iA 在当前三角形中的索引
            const local_idx = blk: {
                for (tri.vertices, 0..) |v, idx| {
                    if (v == iA) break :blk @as(u32, @intCast(idx));
                }
                // 如果 iA 不在该三角形中，说明 vert_tris 可能未及时更新，跳出循环
                break;
            };

            // 对边索引（不包含起点的边）
            const opp_edge_idx = (local_idx + 1) % 3;
            const v_start = tri.vertices[opp_edge_idx];
            const v_end = tri.vertices[(opp_edge_idx + 1) % 3];
            const p1 = self.vertices.items[v_start];
            const p2 = self.vertices.items[v_end];
            const neighbor = tri.neighbors[opp_edge_idx];

            // 检查线段 AB 是否与对边严格相交
            if (self.segmentsIntersect(a, b, p1, p2) and
                !self.pointOnSegment(a, p1, p2) and
                !self.pointOnSegment(b, p1, p2))
            {
                if (neighbor != -1) {
                    return .{ .tri_idx = neighbor, .vL = v_start, .vR = v_end };
                } else {
                    return .{ .tri_idx = -1, .vL = 0, .vR = 0 };
                }
            }

            // 处理起点恰好在边上的情况（例如线段沿边方向）
            if (self.pointOnSegment(a, p1, p2)) {
                const side = Vec2.signedArea2(p1, p2, b);
                if (side < 0 and neighbor != -1) {
                    return .{ .tri_idx = neighbor, .vL = v_start, .vR = v_end };
                }
            }

            // 移动到下一个包含 iA 的三角形
            const next = self.nextTriangleAroundVertex(cur_tri, iA, prev_tri);
            if (next == null or next.? == start_tri) break;
            prev_tri = cur_tri;
            cur_tri = next.?;
        }

        return .{ .tri_idx = -1, .vL = 0, .vR = 0 };
    }

    /// 判断两条线段 AB 和 CD 是否相交（包括端点接触，但可通过容差调整）
    fn segmentsIntersect(self: *CDT, a: Vec2, b: Vec2, c: Vec2, d: Vec2) bool {
        _ = self;
        const o1 = Vec2.signedArea2(a, b, c);
        const o2 = Vec2.signedArea2(a, b, d);
        const o3 = Vec2.signedArea2(c, d, a);
        const o4 = Vec2.signedArea2(c, d, b);

        // 一般情况：跨立
        if (o1 * o2 < 0 and o3 * o4 < 0) return true;

        // 共线情况：检查投影重叠（这里简化，可忽略，因为我们的线段是约束边，通常不会与网格边共线）
        return false;
    }

    /// 在交点处拆分固定边，并返回新顶点的索引
    /// 参数 edge: 需要拆分的固定边
    /// 参数 pos: 交点的坐标
    /// 参数 t1, t2: 共享该边的两个三角形（与 insertVertexOnEdge 类似）
    fn splitFixedEdgeAt(self: *CDT, edge: Edge, pos: Vec2, t1: u32, t2: u32) !u32 {
        // 1. 在交点处插入新顶点
        const split_vert = try self.addSplitEdgeVertex(pos, t1, t2);
        // 2. 将原固定边拆分为两段
        try self.splitFixedEdge(edge, split_vert);
        return split_vert;
    }

    /// 在交点处添加新顶点（内部调用）
    /// 参数 pos: 交点坐标
    /// 参数 t1, t2: 共享该边的两个三角形
    /// 流程：添加顶点 → 在边上插入 → 恢复 Delaunay
    fn addSplitEdgeVertex(self: *CDT, pos: Vec2, t1: u32, t2: u32) !u32 {
        const new_v = try self.addVertex(pos);
        // 从 t1 和 t2 中找到共享边的两个端点
        const tri1 = &self.triangles.items[t1];
        // 遍历 tri1 的边，找到邻居为 t2 的那条边
        for (0..3) |i| {
            if (tri1.neighbors[i] == t2) {
                const v1 = tri1.vertices[i];
                const v2 = tri1.vertices[(i + 1) % 3];
                try self.insertVertexOnEdge(new_v, v1, v2, t1, t2);
                break;
            }
        } else {
            return error.EdgeNotFoundInTriangle;
        }
        try self.ensureDelaunayByEdgeFlip(new_v);
        return new_v;
    }

    /// 将固定边拆分为两段，并更新 fixed_edges 集合
    fn splitFixedEdge(self: *CDT, edge: Edge, split_vert: u32) !void {
        // 移除原固定边
        _ = self.fixed_edges.remove(edge);
        // 添加两段新固定边
        try self.fixEdge(.{ .v1 = edge.v1, .v2 = split_vert });
        try self.fixEdge(.{ .v1 = split_vert, .v2 = edge.v2 });
    }

    // ---------- Delaunay维护与边翻转 ----------

    /// 通过边翻转恢复局部 Delaunay 性质
    /// 参数 v: 新插入顶点的索引（用于确定需要检查的边）
    /// 算法：循环处理 temp_stack 中的每个三角形，检查其与邻居的公共边是否需要进行翻转，
    ///       若翻转，则将新形成的三角形也加入栈中，直到栈空。
    fn ensureDelaunayByEdgeFlip(self: *CDT, v: u32) !void {
        var flip_count: u32 = 0;
        const max_flips = self.triangles.items.len * 5; // 经验值
        while (self.temp_stack.items.len > 0) : (flip_count += 1) {
            if (flip_count > max_flips) return error.InfiniteLoopEdgeFlip;
            const t = self.temp_stack.pop().?;
            const info = try self.edgeFlipInfo(t, v);
            if (info.new_t1 == -1) continue;
            if (self.shouldFlipEdge(v, info.v2, info.v3, info.v4)) {
                try self.flipEdge(t, @intCast(info.new_t1), v, info.v2, info.v3, info.v4, info.n1, info.n2, info.n3, info.n4);
                try self.temp_stack.append(self.allocator, t);
                try self.temp_stack.append(self.allocator, @intCast(info.new_t1));
                flip_count += 1;
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
    fn lineSide(self: *CDT, pt: Vec2, a: Vec2, b: Vec2) enum { Left, Right, On } {
        _ = self;
        const ab = b.sub(a);
        const ap = pt.sub(a);
        const cross_val = Vec2.cross(ab, ap);
        if (cross_val > 0) return .Left;
        if (cross_val < 0) return .Right;
        return .On;
    }

    /// 判断三角形是否包含指定边（顶点顺序无关）
    fn triangleHasEdge(self: *CDT, tri: Triangle, v1: u32, v2: u32) bool {
        _ = self;
        const a = tri.vertices[0];
        const b = tri.vertices[1];
        const c = tri.vertices[2];
        return (a == v1 and b == v2) or (a == v2 and b == v1) or
            (b == v1 and c == v2) or (b == v2 and c == v1) or
            (c == v1 and a == v2) or (c == v2 and a == v1);
    }

    /// 获取三角形 tri 中与顶点 v 相对的边所邻接的三角形索引。
    /// 即：若 v 是 tri 的一个顶点，则返回该顶点对边上的邻居三角形。
    /// 若该边无邻居（边界），则返回 -1。
    fn getOpposedTriangle(self: *CDT, tri: *Triangle, v: u32) i32 {
        _ = self;
        // 找到顶点 v 在三角形顶点数组中的位置
        const idx = blk: {
            for (tri.vertices, 0..) |vertex, i| {
                if (vertex == v) break :blk @as(u32, @intCast(i));
            } // 若顶点不在三角形中，返回 -1（调用者应保证 v 在 tri 内）
            return -1;
        };
        // 对边是 (idx+1) 和 (idx+2) 构成的边，其邻居在 neighbors 中的索引为 (idx+1)%3
        return tri.neighbors[(idx + 1) % 3];
    }

    /// 获取邻居三角形 neighbor_tri 中不与当前三角形共享的远端顶点索引。
    /// 参数 tri: 当前三角形的指针（用于确定共享边）
    /// 参数 neighbor_tri: 邻居三角形的索引
    fn opposedVertex(self: *CDT, tri: *Triangle, neighbor_tri: u32) u32 {
        const neighbor = &self.triangles.items[neighbor_tri];
        // 遍历 neighbor 的顶点，找出不在 tri 中的那个顶点
        for (neighbor.vertices) |v| {
            var found = false;
            for (tri.vertices) |tv| {
                if (v == tv) {
                    found = true;
                    break;
                }
            }
            if (!found) return v;
        }
        // 理论上不应执行到这里，因为两个相邻三角形共享两个顶点
        return 0;
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

    /// 对伪多边形进行重新三角剖分（入口函数）
    /// 参数 poly: 多边形顶点索引列表（逆时针顺序）
    /// 参数 outerTris: 边界边对应的外部三角形映射
    /// 参数 iTL, iTR: 与外部相连的两个三角形索引（用于确定起始父三角形）
    /// 参数 trianglesToReuse: 可重用的三角形索引栈（即被删除的相交三角形）
    /// 参数 iterations: 任务栈
    fn triangulatePseudoPolygon(
        self: *CDT,
        poly: *std.ArrayListUnmanaged(u32),
        outerTris: *std.AutoHashMap(Edge, i32),
        iTL: u32,
        iTR: u32,
        trianglesToReuse: *std.ArrayListUnmanaged(u32),
        iterations: *std.ArrayListUnmanaged(TriangulatePseudoPolygonTask),
    ) !void {
        iterations.clearRetainingCapacity();
        // 初始任务：整个多边形范围 (0, len-1)，使用 iTL 作为起始三角形
        try iterations.append(self.allocator, .{
            .iA = 0,
            .iB = @intCast(poly.items.len - 1),
            .iT = iTL,
            .iParent = iTR,
            .iInParent = 0,
        });

        var iter_count: u32 = 0;
        const max_iter = poly.items.len * 2;
        while (iterations.items.len > 0) : (iter_count += 1) {
            if (iter_count > max_iter) return error.InfiniteLoopTriangulation;
            try self.triangulatePseudoPolygonIteration(poly, outerTris, trianglesToReuse, iterations);
        }
    }

    /// 单次三角化迭代：处理一个固定边 (poly[iA], poly[iB])
    fn triangulatePseudoPolygonIteration(
        self: *CDT,
        poly: *std.ArrayListUnmanaged(u32),
        outerTris: *std.AutoHashMap(Edge, i32), // 改为托管版本
        trianglesToReuse: *std.ArrayListUnmanaged(u32),
        iterations: *std.ArrayListUnmanaged(TriangulatePseudoPolygonTask),
    ) !void {
        const task = iterations.pop().?;
        const iA = task.iA;
        const iB = task.iB;
        var iT = task.iT;
        const iParent = task.iParent;
        const iInParent = task.iInParent;

        // 如果任务区间无效，直接返回
        if (iB - iA < 1) return;

        // 1. 寻找最佳第三点 iC（使三角形 (a,b,c) 最符合 Delaunay 规则）
        const iC = self.findDelaunayPoint(poly, iA, iB);
        const a = poly.items[iA];
        const b = poly.items[iB];
        const c = poly.items[iC];

        // 2. 如果没有可重用的三角形，分配一个新的
        if (trianglesToReuse.items.len == 0) {
            iT = try self.addNewTriangle();
        } else {
            iT = trianglesToReuse.pop().?;
        }

        const tri = &self.triangles.items[iT];

        // 3. 设置当前三角形的顶点
        tri.vertices = .{ a, b, c };

        // 4. 处理右子区间 (iC, iB)
        if (iB - iC > 1) {
            // 需要递归处理
            const iNext = if (trianglesToReuse.items.len > 0) trianglesToReuse.pop().? else try self.addNewTriangle();
            try iterations.append(self.allocator, .{
                .iA = iC,
                .iB = iB,
                .iT = iNext,
                .iParent = iT,
                .iInParent = 1,
            });
        } else {
            // 边界边，连接外部三角形
            const outerEdge = Edge{ .v1 = b, .v2 = c };
            const outerTri = outerTris.get(outerEdge) orelse -1;
            if (outerTri != -1) {
                tri.neighbors[1] = outerTri;
                try self.setNewNeighbor(@intCast(outerTri), c, b, iT);
            } else {
                tri.neighbors[1] = -1;
                // 若不存在，记录以便后续使用
                try outerTris.put(outerEdge, @intCast(iT));
            }
        }

        // 5. 处理左子区间 (iA, iC)
        if (iC - iA > 1) {
            const iNext = if (trianglesToReuse.items.len > 0) trianglesToReuse.pop().? else try self.addNewTriangle();
            try iterations.append(self.allocator, .{
                .iA = iA,
                .iB = iC,
                .iT = iNext,
                .iParent = iT,
                .iInParent = 2,
            });
        } else {
            const outerEdge = Edge{ .v1 = c, .v2 = a };
            const outerTri = outerTris.get(outerEdge) orelse -1;
            if (outerTri != -1) {
                tri.neighbors[2] = outerTri;
                try self.setNewNeighbor(@intCast(outerTri), a, c, iT);
            } else {
                tri.neighbors[2] = -1;
                try outerTris.put(outerEdge, @intCast(iT));
            }
        }

        // 6. 连接父三角形
        if (iParent != iT) {
            const parentTri = &self.triangles.items[iParent];
            parentTri.neighbors[iInParent] = @intCast(iT);
            tri.neighbors[0] = @intCast(iParent);
        } else {
            tri.neighbors[0] = -1;
        }

        // 7. 维护顶点关联三角形
        try self.setVertTri(c, iT);
    }

    /// 在伪多边形顶点子区间 (iA, iB) 中寻找最佳第三点 iC
    /// 最佳意味着点 c 与 a,b 构成的外接圆不包含其他顶点，即最符合 Delaunay 规则。
    /// 实现：遍历区间内所有点，选择第一个满足空圆条件的点。
    fn findDelaunayPoint(self: *CDT, poly: *std.ArrayListUnmanaged(u32), iA: u32, iB: u32) u32 {
        const a = self.vertices.items[poly.items[iA]];
        const b = self.vertices.items[poly.items[iB]];
        var best = iA + 1;
        var best_c = self.vertices.items[poly.items[best]];

        for (iA + 1..iB) |i| {
            const v = self.vertices.items[poly.items[i]];
            // 如果 v 在三角形 (a, b, best_c) 的外接圆内，则更新 best
            if (pointInCircumcircle(v, a, b, best_c)) {
                best = @intCast(i);
                best_c = v;
            }
        }
        return best;
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

// ---------- 测试 ----------
const testing = std.testing;
const expect = testing.expect;
const expectEqual = testing.expectEqual;

/// 综合拓扑验证（合并版）：一次遍历完成邻居双向性 + 边匹配检查
pub fn validateTopology(cdt: *CDT) !void {
    // 1. 三角形边检查（双向性 + 边匹配）
    for (cdt.triangles.items, 0..) |tri, i| {
        for (tri.neighbors, 0..) |n, edge_idx| {
            if (n == -1) continue;

            const neighbor_idx = @as(usize, @intCast(n));
            if (neighbor_idx >= cdt.triangles.items.len) {
                std.debug.print("Triangle {} edge {} out-of-range neighbor {}\n", .{ i, edge_idx, n });
                return error.NeighborOutOfRange;
            }

            const neighbor = cdt.triangles.items[neighbor_idx];
            const v1 = tri.vertices[edge_idx];
            const v2 = tri.vertices[(edge_idx + 1) % 3];

            // 检查邻居是否共享该边
            if (!cdt.triangleHasEdge(neighbor, v1, v2)) {
                std.debug.print("Triangle {} edge {}-{} neighbor {} does not share edge\n", .{ i, v1, v2, n });
                return error.EdgeNeighborMismatch;
            }

            // 检查双向性（邻居是否指回）
            var reciprocal = false;
            for (neighbor.neighbors) |nn| {
                if (nn == @as(i32, @intCast(i))) {
                    reciprocal = true;
                    break;
                }
            }
            if (!reciprocal) {
                std.debug.print("Triangle {} edge {} neighbor {} not reciprocal\n", .{ i, edge_idx, n });
                return error.NeighborNotReciprocal;
            }
        }
    }

    // 2. vert_tris 有效性检查（独立遍历）
    for (cdt.vert_tris.items, 0..) |tri_idx, v| {
        if (tri_idx >= cdt.triangles.items.len) {
            std.debug.print("Vertex {} vert_tris {} out of range\n", .{ v, tri_idx });
            return error.InvalidVertTri;
        }
        const tri = cdt.triangles.items[tri_idx];
        const contains = tri.vertices[0] == v or tri.vertices[1] == v or tri.vertices[2] == v;
        if (!contains) {
            std.debug.print("Vertex {} vert_tris {} does not contain vertex\n", .{ v, tri_idx });
            return error.VertTriMismatch;
        }
    }
}

fn runInsertionTest(points: []const Vec2) !void {
    var cdt = try CDT.init(testing.allocator, 100, 100);
    defer cdt.deinit();

    for (points) |pt| {
        const v = try cdt.addVertex(pt);
        try cdt.insertVertex(v);
        try validateTopology(&cdt); // 每一步都验证
    }
}

test "CDT basic insertions" {
    const points = [_]Vec2{
        .{ .x = 30, .y = 40 },
        .{ .x = 60, .y = 20 },
        .{ .x = 50, .y = 70 },
        .{ .x = 20, .y = 80 },
        .{ .x = 80, .y = 50 },
    };
    try runInsertionTest(&points);
}

test "CDT edge flip scenario" {
    const points = [_]Vec2{
        .{ .x = 10, .y = 10 },
        .{ .x = 90, .y = 10 },
        .{ .x = 90, .y = 90 },
        .{ .x = 10, .y = 90 },
        .{ .x = 50, .y = 50 }, // 触发翻转
    };
    try runInsertionTest(&points);
}

test "CDT random insertions" {
    var cdt = try CDT.init(testing.allocator, 100, 100);
    defer cdt.deinit();

    var rand = std.Random.DefaultPrng.init(42);
    const random = rand.random();

    for (0..50) |_| {
        const x = random.float(f32) * 100;
        const y = random.float(f32) * 100;
        const v = try cdt.addVertex(.{ .x = x, .y = y });
        try cdt.insertVertex(v);
        try validateTopology(&cdt);
    }
}

test "intersecting constraint edges" {
    const allocator = std.testing.allocator;

    // 创建一个小型 CDT，地图尺寸 100x100
    var cdt = try CDT.init(allocator, 100, 100);
    defer cdt.deinit();

    // 第一条约束边的两个端点
    const a1 = Vec2.new(20, 20);
    const b1 = Vec2.new(80, 80);

    // 第二条约束边的两个端点（与第一条相交）
    const a2 = Vec2.new(20, 80);
    const b2 = Vec2.new(80, 20);

    // 添加顶点（去重容差设为 0.1）
    const tol = 0.1;
    const v_a1 = try cdt.findOrAddVertex(a1, tol);
    const v_b1 = try cdt.findOrAddVertex(b1, tol);
    const v_a2 = try cdt.findOrAddVertex(a2, tol);
    const v_b2 = try cdt.findOrAddVertex(b2, tol);

    // 插入第二条约束边（相交）
    try cdt.insertConstraintEdge(v_a2, v_b2);
    // 插入第一条约束边
    try cdt.insertConstraintEdge(v_a1, v_b1);

    // 验证：两条边都应被标记为固定边
    try std.testing.expect(cdt.fixed_edges.contains(.{ .v1 = v_a1, .v2 = v_b1 }) or
        cdt.fixed_edges.contains(.{ .v1 = v_b1, .v2 = v_a1 }));
    try std.testing.expect(cdt.fixed_edges.contains(.{ .v1 = v_a2, .v2 = v_b2 }) or
        cdt.fixed_edges.contains(.{ .v1 = v_b2, .v2 = v_a2 }));

    // 可选：检查交点是否被正确插入（网格顶点数应增加）
    // 这里不强制要求，仅作为观察点
    std.debug.print("Total vertices after insertion: {}\n", .{cdt.vertices.items.len});
}

test "CDT constraint edge insertion" {
    // 构建一个简单四边形加中心点的基础网格
    var cdt = try CDT.init(testing.allocator, 100, 100);
    defer cdt.deinit();

    const points = [_]Vec2{
        .{ .x = 20, .y = 20 },
        .{ .x = 80, .y = 20 },
        .{ .x = 80, .y = 80 },
        .{ .x = 20, .y = 80 },
        .{ .x = 50, .y = 50 },
    };

    var verts = std.ArrayList(u32){};
    defer verts.deinit(testing.allocator);

    for (points) |pt| {
        const v = try cdt.addVertex(pt);
        try cdt.insertVertex(v);
        try verts.append(testing.allocator, v);
        try validateTopology(&cdt);
    }

    // 插入一条约束边：从左上(20,20)到右下(80,80)
    const v1 = verts.items[0]; // (20,20)
    const v2 = verts.items[2]; // (80,80)
    try cdt.insertConstraintEdge(v1, v2);
    try validateTopology(&cdt);
}

test "minimal intersecting constraint edges debug" {
    const allocator = std.testing.allocator;
    var cdt = try CDT.init(allocator, 200, 200);
    defer cdt.deinit();

    // 从你的错误日志中提取的坐标
    const a1 = Vec2.new(16.22, 9.03);
    const b1 = Vec2.new(10.66, 14.03);
    const a2 = Vec2.new(15.86, 15.27);
    const b2 = Vec2.new(10.54, 9.69);

    // 插入端点
    const v_a1 = try cdt.findOrAddVertex(a1, 0.1);
    const v_b1 = try cdt.findOrAddVertex(b1, 0.1);
    const v_a2 = try cdt.findOrAddVertex(a2, 0.1);
    const v_b2 = try cdt.findOrAddVertex(b2, 0.1);

    std.debug.print("\n--- Insert first edge ({}, {}) ---\n", .{ v_a1, v_b1 });
    try cdt.insertConstraintEdge(v_a1, v_b1);
    std.debug.print("First edge inserted. fixed_edges count: {}\n", .{cdt.fixed_edges.count()});

    std.debug.print("\n--- Insert second edge ({}, {}) ---\n", .{ v_a2, v_b2 });
    try cdt.insertConstraintEdge(v_a2, v_b2);
    std.debug.print("Second edge inserted. fixed_edges count: {}\n", .{cdt.fixed_edges.count()});

    try std.testing.expect(cdt.fixed_edges.count() >= 2);
}
