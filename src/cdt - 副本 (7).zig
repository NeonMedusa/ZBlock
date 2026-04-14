const std = @import("std");
const Vec2 = @import("imports.zig").Vec2;

pub const Edge = struct {
    v1: u32,
    v2: u32,

    /// 返回规范化后的边（v1 < v2）
    pub fn normalized(self: Edge) Edge {
        if (self.v1 < self.v2) return self;
        return .{ .v1 = self.v2, .v2 = self.v1 };
    }
};

pub const Triangle = struct {
    vertices: [3]u32 = .{ 0, 0, 0 },
    neighbors: [3]i32 = .{ -1, -1, -1 },
};

pub const CDT = struct {
    allocator: std.mem.Allocator,
    triangles: std.ArrayListUnmanaged(Triangle) = .{},
    vertices: std.ArrayListUnmanaged(Vec2) = .{},
    vert_tris: std.ArrayListUnmanaged(u32) = .{}, // 每个顶点的一个邻接三角形
    fixed_edges: std.AutoHashMapUnmanaged(Edge, void) = .{}, // 已存在的约束边集合

    // 临时缓冲区（使用前 clearRetainingCapacity）
    temp_stack: std.ArrayListUnmanaged(u32) = .{}, // 边翻转栈
    temp_intersected: std.ArrayListUnmanaged(u32) = .{}, // 与约束边相交的三角形列表
    temp_poly_l: std.ArrayListUnmanaged(u32) = .{}, // 左侧多边形顶点
    temp_poly_r: std.ArrayListUnmanaged(u32) = .{}, // 右侧多边形顶点
    temp_outer_tris: std.AutoHashMapUnmanaged(Edge, i32) = .{}, // 多边形边界对应的外部三角形
    temp_iterations: std.ArrayListUnmanaged(TriangulatePseudoPolygonTask) = .{}, // 重三角化任务栈

    const TriangulatePseudoPolygonTask = struct {
        iA: u32, // 多边形中起始顶点索引
        iB: u32, // 多边形中结束顶点索引
        iT: u32, // 当前三角形索引
        iParent: u32, // 父三角形索引
        iInParent: u32, // 在父三角形中的邻居索引
    };

    const PointLocation = enum { Inside, OnEdge, Outside };
    const LineSide = enum { Left, Right, On };

    // ---------- 初始化 ----------
    pub fn init(allocator: std.mem.Allocator, map_width: u32, map_height: u32) !CDT {
        var cdt = CDT{ .allocator = allocator };

        const width_f: f32 = @floatFromInt(map_width);
        const height_f: f32 = @floatFromInt(map_height);
        const center = Vec2{ .x = width_f / 2, .y = height_f / 2 };
        const radius = @sqrt(center.x * center.x + center.y * center.y) * 2.5;

        // 超三角形 (逆时针)
        const angles = [_]f32{ 150, 270, 30 };
        var super_verts: [3]u32 = undefined;
        for (angles, 0..) |deg, i| {
            const rad = deg * std.math.pi / 180.0;
            const x = center.x + radius * @cos(rad);
            const y = center.y + radius * @sin(rad);
            super_verts[i] = try cdt.addVertex(.{ .x = x, .y = y });
        }

        const super_tri = Triangle{
            .vertices = .{ super_verts[0], super_verts[1], super_verts[2] },
            .neighbors = .{ -1, -1, -1 },
        };
        try cdt.triangles.append(allocator, super_tri);
        for (super_verts) |v| cdt.vert_tris.items[v] = 0;

        // 地图边界矩形角点
        const corners = [_]Vec2{
            .{ .x = 0, .y = 0 },
            .{ .x = width_f, .y = 0 },
            .{ .x = width_f, .y = height_f },
            .{ .x = 0, .y = height_f },
        };
        var corner_verts: [4]u32 = undefined;
        for (corners, 0..) |pt, i| {
            corner_verts[i] = try cdt.addVertex(pt);
            try cdt.insertVertex(corner_verts[i]);
        }

        // 插入四条边界约束边
        inline for (.{ .{ 0, 1 }, .{ 1, 2 }, .{ 2, 3 }, .{ 3, 0 } }) |pair| {
            try cdt.insertConstraintEdge(corner_verts[pair[0]], corner_verts[pair[1]]);
        }

        return cdt;
    }

    pub fn deinit(self: *CDT) void {
        self.vertices.deinit(self.allocator);
        self.triangles.deinit(self.allocator);
        self.vert_tris.deinit(self.allocator);
        self.fixed_edges.deinit(self.allocator);
        self.temp_stack.deinit(self.allocator);
        self.temp_intersected.deinit(self.allocator);
        self.temp_poly_l.deinit(self.allocator);
        self.temp_poly_r.deinit(self.allocator);
        self.temp_outer_tris.deinit(self.allocator);
        self.temp_iterations.deinit(self.allocator);
    }

    // ---------- 顶点基本操作 ----------
    pub fn addVertex(self: *CDT, pt: Vec2) !u32 {
        const idx = @as(u32, @intCast(self.vertices.items.len));
        try self.vertices.append(self.allocator, pt);
        try self.vert_tris.resize(self.allocator, idx + 1);
        self.vert_tris.items[idx] = 0;
        return idx;
    }

    /// 插入顶点并维护 Delaunay 性质
    pub fn insertVertex(self: *CDT, v_idx: u32) !void {
        const v = self.vertices.items[v_idx];
        const nearest = self.findNearestVertex(v); // 暴力搜索最近顶点
        const start_tri = self.vert_tris.items[nearest];
        try self.insertVertexWithStart(v_idx, start_tri);
    }

    fn insertVertexWithStart(self: *CDT, v_idx: u32, start_tri: u32) !void {
        const result = try self.walkToTriangle(v_idx, start_tri);
        self.temp_stack.clearRetainingCapacity();

        if (result.on_edge) |edge| {
            const t1 = result.tri_idx;
            const t2 = self.edgeNeighbor(&self.triangles.items[t1], edge[0], edge[1]);
            if (t2 == -1) return error.EdgeHasNoNeighbor;
            try self.insertVertexOnEdge(v_idx, edge[0], edge[1], t1, @intCast(t2));
        } else {
            try self.insertVertexInTriangle(v_idx, result.tri_idx);
        }
        try self.ensureDelaunayByEdgeFlip(v_idx);
    }

    /// 行走法定位点所在三角形或边
    fn walkToTriangle(self: *CDT, v_idx: u32, start_tri: u32) !struct { tri_idx: u32, on_edge: ?[2]u32 } {
        const pt = self.vertices.items[v_idx];
        var cur_tri = start_tri;
        var visited = std.AutoHashMap(u32, void).init(self.allocator);
        defer visited.deinit();

        while (true) {
            if (visited.contains(cur_tri)) return error.InfiniteLoop;
            try visited.put(cur_tri, {});
            const tri = self.triangles.items[cur_tri];
            const a = self.vertices.items[tri.vertices[0]];
            const b = self.vertices.items[tri.vertices[1]];
            const c = self.vertices.items[tri.vertices[2]];

            if (self.pointInTriangle(pt, a, b, c)) {
                return .{ .tri_idx = cur_tri, .on_edge = null };
            }
            if (self.pointOnSegment(pt, a, b)) return .{ .tri_idx = cur_tri, .on_edge = .{ tri.vertices[0], tri.vertices[1] } };
            if (self.pointOnSegment(pt, b, c)) return .{ .tri_idx = cur_tri, .on_edge = .{ tri.vertices[1], tri.vertices[2] } };
            if (self.pointOnSegment(pt, c, a)) return .{ .tri_idx = cur_tri, .on_edge = .{ tri.vertices[2], tri.vertices[0] } };

            const next = self.nextTriangleTowardsPoint(pt, a, b, c, tri.neighbors) orelse return error.PointOutsideMesh;
            cur_tri = next;
        }
    }

    /// 暴力搜索最近顶点（无 KD 树）
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

    /// 在边上插入顶点
    fn insertVertexOnEdge(self: *CDT, v: u32, v1: u32, v2: u32, t1: u32, t2: u32) !void {
        const newt1 = try self.addNewTriangle();
        const newt2 = try self.addNewTriangle();

        const tri1 = &self.triangles.items[t1];
        const tri2 = &self.triangles.items[t2];

        const local1 = try self.getEdgeLocalInfo(tri1, v1, v2, t2);
        const local2 = try self.getEdgeLocalInfo(tri2, v1, v2, t1);

        const n1 = tri1.neighbors[local1.idx];
        const n4 = tri1.neighbors[(local1.idx + 2) % 3];
        const v3 = tri2.vertices[local2.opposite];
        const n2 = tri2.neighbors[(local2.idx + 2) % 3];
        const n3 = tri2.neighbors[local2.idx];

        const a = v1;
        const b = v2;
        const c = tri1.vertices[(local1.idx + 2) % 3];
        const d = v3;

        tri1.vertices = .{ a, b, v };
        tri1.neighbors = .{ n1, @intCast(t2), @intCast(newt1) };
        tri2.vertices = .{ b, d, v };
        tri2.neighbors = .{ n2, @intCast(newt2), @intCast(t1) };
        self.triangles.items[newt1] = .{
            .vertices = .{ c, a, v },
            .neighbors = .{ n4, @intCast(t1), @intCast(newt2) },
        };
        self.triangles.items[newt2] = .{
            .vertices = .{ d, c, v },
            .neighbors = .{ n3, @intCast(newt1), @intCast(t2) },
        };

        try self.setVertTri(v, t1);
        try self.setVertTri(c, newt1);
        if (n4 != -1) try self.setNewNeighbor(@intCast(n4), c, a, newt1);
        if (n3 != -1) try self.setNewNeighbor(@intCast(n3), d, c, newt2);

        try self.temp_stack.append(self.allocator, t1);
        try self.temp_stack.append(self.allocator, t2);
        try self.temp_stack.append(self.allocator, newt1);
        try self.temp_stack.append(self.allocator, newt2);
    }

    /// 获取边在三角形中的局部信息
    fn getEdgeLocalInfo(self: *CDT, tri: *Triangle, v1: u32, v2: u32, neighbor_tri: u32) !struct { idx: u32, opposite: u32 } {
        _ = self;
        for (0..3) |i| {
            const a = tri.vertices[i];
            const b = tri.vertices[(i + 1) % 3];
            if ((a == v1 and b == v2) or (a == v2 and b == v1)) {
                if (tri.neighbors[i] != neighbor_tri) return error.InconsistentNeighbor;
                return .{ .idx = @intCast(i), .opposite = @intCast((i + 2) % 3) };
            }
        }
        return error.EdgeNotFoundInTriangle;
    }

    /// 在三角形内部插入顶点
    fn insertVertexInTriangle(self: *CDT, v: u32, t: u32) !void {
        const newt1 = try self.addNewTriangle();
        const newt2 = try self.addNewTriangle();

        const tri = &self.triangles.items[t];
        const v0 = tri.vertices[0];
        const v1 = tri.vertices[1];
        const v2 = tri.vertices[2];
        const n0 = tri.neighbors[0];
        const n1 = tri.neighbors[1];
        const n2 = tri.neighbors[2];

        tri.vertices = .{ v0, v1, v };
        tri.neighbors = .{ n0, @intCast(newt1), @intCast(newt2) };
        self.triangles.items[newt1] = .{
            .vertices = .{ v1, v2, v },
            .neighbors = .{ n1, @intCast(newt2), @intCast(t) },
        };
        self.triangles.items[newt2] = .{
            .vertices = .{ v2, v0, v },
            .neighbors = .{ n2, @intCast(t), @intCast(newt1) },
        };

        try self.setVertTri(v, t);
        try self.setVertTri(v2, newt1);
        if (n1 != -1) try self.setNewNeighbor(@intCast(n1), v1, v2, newt1);
        if (n2 != -1) try self.setNewNeighbor(@intCast(n2), v2, v0, newt2);

        try self.temp_stack.append(self.allocator, t);
        try self.temp_stack.append(self.allocator, newt1);
        try self.temp_stack.append(self.allocator, newt2);
    }

    /// 更新邻居关系
    fn setNewNeighbor(self: *CDT, tri_idx: u32, old_v1: u32, old_v2: u32, new_neighbor: u32) !void {
        const tri = &self.triangles.items[tri_idx];
        for (0..3) |i| {
            const a = tri.vertices[i];
            const b = tri.vertices[(i + 1) % 3];
            if ((a == old_v1 and b == old_v2) or (a == old_v2 and b == old_v1)) {
                tri.neighbors[i] = @intCast(new_neighbor);
                return;
            }
        }
        return error.EdgeNotFoundInTriangle;
    }

    // ---------- 约束边插入 ----------
    pub fn insertConstraintEdge(self: *CDT, v1: u32, v2: u32) !void {
        if (v1 == v2) return;
        if (try self.edgeExists(v1, v2)) {
            try self.fixEdge(.{ .v1 = v1, .v2 = v2 });
            return;
        }
        try self.insertEdgeIteration(.{ .v1 = v1, .v2 = v2 });
    }

    /// 约束边插入主循环（与教程一致）
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

            // 清空复用缓冲区
            self.temp_intersected.clearRetainingCapacity();
            self.temp_poly_l.clearRetainingCapacity();
            self.temp_poly_r.clearRetainingCapacity();
            self.temp_outer_tris.clearRetainingCapacity();

            try self.collectIntersectedTriangles(
                iA,
                &iB,
                &self.temp_intersected,
                &self.temp_poly_l,
                &self.temp_poly_r,
                &self.temp_outer_tris,
            );

            // 若线段被固定边分割，将剩余部分重新入栈
            if (iB != cur_edge.v2) {
                try self.fixEdge(.{ .v1 = iA, .v2 = iB });
                try remaining.append(self.allocator, .{ .v1 = iB, .v2 = cur_edge.v2 });
                continue;
            }

            // 维护顶点邻接三角形，防止引用即将被删除的三角形
            if (self.vert_tris.items[iA] == self.temp_intersected.items[0])
                try self.pivotVertexTriangleCW(iA);
            if (self.vert_tris.items[iB] == self.temp_intersected.items[self.temp_intersected.items.len - 1])
                try self.pivotVertexTriangleCW(iB);

            const iTL = self.temp_intersected.items[0];
            const iTR = self.temp_intersected.items[self.temp_intersected.items.len - 1];
            std.mem.reverse(u32, self.temp_poly_r.items);

            // 待复用的三角形索引（即被删除的相交三角形）
            var trianglesToReuse = std.ArrayList(u32){};
            defer trianglesToReuse.deinit(self.allocator);
            try trianglesToReuse.appendSlice(self.allocator, self.temp_intersected.items);

            self.temp_iterations.clearRetainingCapacity();

            try self.triangulatePseudoPolygon(&self.temp_poly_l, &self.temp_outer_tris, iTL, iTR, &trianglesToReuse, &self.temp_iterations);
            try self.triangulatePseudoPolygon(&self.temp_poly_r, &self.temp_outer_tris, iTR, iTL, &trianglesToReuse, &self.temp_iterations);

            try self.fixEdge(.{ .v1 = iA, .v2 = iB });
        }
    }

    /// 将顶点的 vert_tris 顺时针旋转到下一个三角形
    fn pivotVertexTriangleCW(self: *CDT, v: u32) !void {
        const cur_tri = self.vert_tris.items[v];
        const tri = self.triangles.items[cur_tri];
        const idx = for (tri.vertices, 0..) |vertex, i| {
            if (vertex == v) break @as(u32, @intCast(i));
        } else return error.VertexNotInTriangle;

        // 顺时针方向沿边 (idx+1)%3 的邻居
        const next = tri.neighbors[(idx + 1) % 3];
        if (next == -1) return error.NoAdjacentTriangle;
        self.vert_tris.items[v] = @intCast(next);
    }

    /// 收集与线段相交的三角形，填充左右多边形及外部邻居（教程核心步骤）
    fn collectIntersectedTriangles(
        self: *CDT,
        iA: u32,
        iB: *u32,
        intersected: *std.ArrayListUnmanaged(u32),
        polyL: *std.ArrayListUnmanaged(u32),
        polyR: *std.ArrayListUnmanaged(u32),
        outerTris: *std.AutoHashMapUnmanaged(Edge, i32),
    ) !void {
        const a = self.vertices.items[iA];
        const b = self.vertices.items[iB.*];

        var first = try self.intersectedTriangle(iA, a, b);
        var start_from_a = true;

        // 如果从 A 出发找不到，尝试从 B 出发
        if (first.tri_idx == -1) {
            const first_rev = try self.intersectedTriangle(iB.*, b, a);
            if (first_rev.tri_idx == -1) {
                if (try self.edgeExists(iA, iB.*)) return;
                return;
            }
            first = first_rev;
            start_from_a = false;
        }

        // 如果边已经存在（返回-2），直接返回
        if (first.tri_idx == -2) {
            return;
        }

        const start_pt = if (start_from_a) a else b;
        const end_pt = if (start_from_a) b else a;
        const start_idx = if (start_from_a) iA else iB.*;
        var end_idx = if (start_from_a) iB.* else iA;

        var iT = @as(u32, @intCast(first.tri_idx));
        const iVL = first.vL;
        const iVR = first.vR;

        try intersected.append(self.allocator, iT);
        try polyL.append(self.allocator, start_idx);
        try polyL.append(self.allocator, iVL);
        try polyR.append(self.allocator, start_idx);
        try polyR.append(self.allocator, iVR);

        var tri = &self.triangles.items[iT];
        try self.putOuterTris(outerTris, start_idx, iVL, self.edgeNeighbor(tri, start_idx, iVL));
        try self.putOuterTris(outerTris, start_idx, iVR, self.edgeNeighbor(tri, start_idx, iVR));

        var iV = start_idx;
        var iter_count: u32 = 0;
        const max_iter = self.triangles.items.len * 2;

        while (!self.triangleContainsVertex(iT, end_idx)) : (iter_count += 1) {
            if (iter_count > max_iter) return error.InfiniteLoopInCollect;

            const iTopo = self.getOpposedTriangle(&self.triangles.items[iT], iV);
            if (iTopo == -1) return error.EdgeHasNoNeighbor;
            const topo = &self.triangles.items[@intCast(iTopo)];
            const iVopo = self.opposedVertex(topo, iT);

            // 冲突检测：遇到已存在的固定边
            if (self.fixed_edges.contains(.{ .v1 = iVL, .v2 = iVR }) or
                self.fixed_edges.contains(.{ .v1 = iVR, .v2 = iVL }))
            {
                const newPos = self.lineIntersection(start_pt, end_pt, self.vertices.items[iVL], self.vertices.items[iVR]);
                const iNewVert = try self.splitFixedEdgeAt(.{ .v1 = iVL, .v2 = iVR }, newPos);
                iB.* = iNewVert;
                return;
            }

            const loc = self.lineSide(self.vertices.items[iVopo], start_pt, end_pt);
            if (loc == .Left) {
                try polyL.append(self.allocator, iVopo);
                try self.putOuterTris(outerTris, iVL, iVopo, self.edgeNeighbor(topo, iVL, iVopo));
            } else if (loc == .Right) {
                try polyR.append(self.allocator, iVopo);
                try self.putOuterTris(outerTris, iVR, iVopo, self.edgeNeighbor(topo, iVR, iVopo));
            } else {
                // 共线，端点落在 iVopo 上
                end_idx = iVopo;
                iB.* = iVopo;
                return;
            }

            try intersected.append(self.allocator, @intCast(iTopo));
            iT = @intCast(iTopo);
            iV = iVopo;
        }

        tri = &self.triangles.items[iT];
        const lastL = polyL.items[polyL.items.len - 1];
        const lastR = polyR.items[polyR.items.len - 1];
        try self.putOuterTris(outerTris, lastL, end_idx, self.edgeNeighbor(tri, lastL, end_idx));
        try self.putOuterTris(outerTris, lastR, end_idx, self.edgeNeighbor(tri, lastR, end_idx));
        try polyL.append(self.allocator, end_idx);
        try polyR.append(self.allocator, end_idx);
    }

    /// 规范化边后存入 outerTris
    fn putOuterTris(self: *CDT, map: *std.AutoHashMapUnmanaged(Edge, i32), v1: u32, v2: u32, tri_idx: i32) !void {
        const edge = Edge{ .v1 = v1, .v2 = v2 };
        const norm = edge.normalized();
        try map.put(self.allocator, norm, tri_idx);
    }

    /// 从 outerTris 获取外部邻居（使用规范化边）
    fn getOuterTri(self: *CDT, map: *std.AutoHashMapUnmanaged(Edge, i32), v1: u32, v2: u32) i32 {
        _ = self;
        const edge = Edge{ .v1 = v1, .v2 = v2 };
        const norm = edge.normalized();
        return map.get(norm) orelse -1;
    }

    /// 检查三角形是否包含顶点
    fn triangleContainsVertex(self: *CDT, tri_idx: u32, v: u32) bool {
        const tri = self.triangles.items[tri_idx];
        return tri.vertices[0] == v or tri.vertices[1] == v or tri.vertices[2] == v;
    }

    /// 计算两线段交点
    fn lineIntersection(self: *CDT, a: Vec2, b: Vec2, c: Vec2, d: Vec2) Vec2 {
        _ = self;
        const ab = b.sub(a);
        const cd = d.sub(c);
        const ac = c.sub(a);
        const t = Vec2.cross(ac, cd) / Vec2.cross(ab, cd);
        return a.add(ab.scale(t));
    }

    /// 将边标记为固定（约束）
    fn fixEdge(self: *CDT, edge: Edge) !void {
        try self.fixed_edges.put(self.allocator, edge.normalized(), {});
    }

    /// 检查边是否已存在于网格中
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
            if (tri.vertices[0] == v2 or tri.vertices[1] == v2 or tri.vertices[2] == v2) {
                const has_edge = (tri.vertices[0] == v1 and tri.vertices[1] == v2) or
                    (tri.vertices[1] == v1 and tri.vertices[2] == v2) or
                    (tri.vertices[2] == v1 and tri.vertices[0] == v2) or
                    (tri.vertices[0] == v2 and tri.vertices[1] == v1) or
                    (tri.vertices[1] == v2 and tri.vertices[2] == v1) or
                    (tri.vertices[2] == v2 and tri.vertices[0] == v1);
                if (has_edge) return true;
            }
            for (tri.neighbors) |n| {
                if (n != -1) {
                    const nb = self.triangles.items[@intCast(n)];
                    if (nb.vertices[0] == v1 or nb.vertices[1] == v1 or nb.vertices[2] == v1) {
                        try stack.append(self.allocator, @intCast(n));
                    }
                }
            }
        }
        return false;
    }

    /// 寻找从顶点出发与线段相交的第一个三角形
    fn intersectedTriangle(self: *CDT, iA: u32, a: Vec2, b: Vec2) !struct { tri_idx: i32, vL: u32, vR: u32 } {
        const start_tri = self.vert_tris.items[iA];
        var cur_tri = start_tri;
        var prev_tri: ?u32 = null;
        const max_iter = self.triangles.items.len * 2;
        var iter: u32 = 0;

        while (iter < max_iter) : (iter += 1) {
            const tri = self.triangles.items[cur_tri];
            const v0 = self.vertices.items[tri.vertices[0]];
            const v1 = self.vertices.items[tri.vertices[1]];
            const v2 = self.vertices.items[tri.vertices[2]];

            // 如果目标点B在三角形内，说明边已经存在
            if (self.pointInTriangle(b, v0, v1, v2)) {
                return .{ .tri_idx = -2, .vL = 0, .vR = 0 };
            }

            const local_idx = for (tri.vertices, 0..) |v, idx| {
                if (v == iA) break @as(u32, @intCast(idx));
            } else break;

            const opp_edge_idx = (local_idx + 1) % 3;
            const v_start = tri.vertices[opp_edge_idx];
            const v_end = tri.vertices[(opp_edge_idx + 1) % 3];
            const p1 = self.vertices.items[v_start];
            const p2 = self.vertices.items[v_end];
            const neighbor = tri.neighbors[opp_edge_idx];

            if (self.segmentsIntersect(a, b, p1, p2) and
                !self.pointOnSegment(a, p1, p2) and
                !self.pointOnSegment(b, p1, p2))
            {
                return if (neighbor != -1)
                    .{ .tri_idx = neighbor, .vL = v_start, .vR = v_end }
                else
                    .{ .tri_idx = -1, .vL = 0, .vR = 0 };
            }

            if (self.pointOnSegment(a, p1, p2)) {
                const side = Vec2.signedArea2(p1, p2, b);
                if (side < 0 and neighbor != -1) {
                    return .{ .tri_idx = neighbor, .vL = v_start, .vR = v_end };
                }
            }

            const next = self.nextTriangleAroundVertex(cur_tri, iA, prev_tri);
            if (next == null or next.? == start_tri) break;
            prev_tri = cur_tri;
            cur_tri = next.?;
        }
        return .{ .tri_idx = -1, .vL = 0, .vR = 0 };
    }

    /// 绕顶点获取下一个三角形（逆时针方向）
    fn nextTriangleAroundVertex(self: *CDT, cur: u32, v: u32, prev: ?u32) ?u32 {
        const tri = self.triangles.items[cur];
        const idx = for (tri.vertices, 0..) |vertex, i| {
            if (vertex == v) break @as(u32, @intCast(i));
        } else return null;

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

    /// 线段相交测试
    fn segmentsIntersect(self: *CDT, a: Vec2, b: Vec2, c: Vec2, d: Vec2) bool {
        _ = self;
        const o1 = Vec2.signedArea2(a, b, c);
        const o2 = Vec2.signedArea2(a, b, d);
        const o3 = Vec2.signedArea2(c, d, a);
        const o4 = Vec2.signedArea2(c, d, b);
        return (o1 * o2 < 0) and (o3 * o4 < 0);
    }

    /// 在交点处分割已存在的固定边
    fn splitFixedEdgeAt(self: *CDT, edge: Edge, pos: Vec2) !u32 {
        var t1: ?u32 = null;
        var t2: ?u32 = null;
        const start_tri = self.vert_tris.items[edge.v1];
        var cur = start_tri;
        var prev: ?u32 = null;
        var iter: u32 = 0;
        const max_iter = self.triangles.items.len * 2;

        while (iter < max_iter) : (iter += 1) {
            const tri = self.triangles.items[cur];
            const idx = for (tri.vertices, 0..) |v, i| {
                if (v == edge.v1) break @as(u32, @intCast(i));
            } else break;

            const v_start = tri.vertices[(idx + 1) % 3];
            const v_end = tri.vertices[(idx + 2) % 3];
            if ((v_start == edge.v2 or v_end == edge.v2) and tri.neighbors[idx] != -1) {
                t1 = cur;
                t2 = @intCast(tri.neighbors[idx]);
                break;
            }

            const next = self.nextTriangleAroundVertex(cur, edge.v1, prev);
            if (next == null or next.? == start_tri) break;
            prev = cur;
            cur = next.?;
        }

        if (t1 == null or t2 == null) return error.FixedEdgeNotFound;

        const split_vert = try self.addVertex(pos);
        try self.insertVertexOnEdge(split_vert, edge.v1, edge.v2, t1.?, t2.?);
        try self.ensureDelaunayByEdgeFlip(split_vert);

        _ = self.fixed_edges.remove(edge.normalized());
        try self.fixEdge(.{ .v1 = edge.v1, .v2 = split_vert });
        try self.fixEdge(.{ .v1 = split_vert, .v2 = edge.v2 });

        return split_vert;
    }

    // ---------- Delaunay 边翻转 ----------
    fn ensureDelaunayByEdgeFlip(self: *CDT, v: u32) !void {
        var flip_count: u32 = 0;
        const max_flips = self.triangles.items.len * 5;
        while (self.temp_stack.items.len > 0) : (flip_count += 1) {
            if (flip_count > max_flips) return error.InfiniteLoopEdgeFlip;
            const t = self.temp_stack.pop().?;
            const info = try self.edgeFlipInfo(t, v);
            if (info.new_t1 == -1) continue;
            if (self.shouldFlipEdge(v, info.v2, info.v3, info.v4)) {
                try self.flipEdge(t, @intCast(info.new_t1), v, info.v2, info.v3, info.v4, info.n1, info.n2, info.n3, info.n4);
                try self.temp_stack.append(self.allocator, t);
                try self.temp_stack.append(self.allocator, @intCast(info.new_t1));
            }
        }
    }

    fn flipEdge(self: *CDT, t1: u32, t2: u32, v1: u32, v2: u32, v3: u32, v4: u32, n1: i32, n2: i32, n3: i32, n4: i32) !void {
        const tri1 = &self.triangles.items[t1];
        const tri2 = &self.triangles.items[t2];
        tri1.vertices = .{ v4, v1, v3 };
        tri1.neighbors = .{ n3, @intCast(t2), n4 };
        tri2.vertices = .{ v2, v3, v1 };
        tri2.neighbors = .{ n2, @intCast(t1), n1 };
        if (n4 != -1) try self.setNewNeighbor(@intCast(n4), v3, v4, t1);
        if (n1 != -1) try self.setNewNeighbor(@intCast(n1), v1, v2, t2);
        try self.setVertTri(v4, t1);
        try self.setVertTri(v2, t2);
    }

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
        const idx = for (tri.vertices, 0..) |vertex, i| {
            if (vertex == v1) break @as(u32, @intCast(i));
        } else return error.VertexNotInTriangle;

        const v2 = tri.vertices[(idx + 1) % 3];
        const v4 = tri.vertices[(idx + 2) % 3];
        const n1 = tri.neighbors[idx];
        const n3 = tri.neighbors[(idx + 2) % 3];
        const new_t1 = tri.neighbors[(idx + 1) % 3];
        if (new_t1 == -1) return .{ .new_t1 = -1, .n1 = -1, .n2 = -1, .n3 = -1, .n4 = -1, .v2 = 0, .v3 = 0, .v4 = 0 };

        const new_tri = &self.triangles.items[@intCast(new_t1)];
        const new_idx = for (new_tri.neighbors, 0..) |n, i| {
            if (n == t) break @as(u32, @intCast(i));
        } else return error.NeighborNotReciprocal;

        const v3 = new_tri.vertices[(new_idx + 2) % 3];
        const n2 = new_tri.neighbors[(new_idx + 1) % 3];
        const n4 = new_tri.neighbors[(new_idx + 2) % 3];

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

    fn shouldFlipEdge(self: *CDT, v1: u32, v2: u32, v3: u32, v4: u32) bool {
        const a = self.vertices.items[v1];
        const b = self.vertices.items[v2];
        const c = self.vertices.items[v3];
        const d = self.vertices.items[v4];
        return pointInCircumcircle(a, b, c, d);
    }

    // ---------- 几何查询辅助 ----------
    fn nextTriangleTowardsPoint(self: *CDT, pt: Vec2, a: Vec2, b: Vec2, c: Vec2, neighbors: [3]i32) ?u32 {
        _ = self;
        const verts = [3]Vec2{ a, b, c };
        for (0..3) |i| {
            if (Vec2.signedArea2(verts[i], verts[(i + 1) % 3], pt) < 0) {
                return if (neighbors[i] != -1) @intCast(neighbors[i]) else null;
            }
        }
        return null;
    }

    fn pointInTriangle(self: *CDT, pt: Vec2, a: Vec2, b: Vec2, c: Vec2) bool {
        _ = self;
        const eps = 1e-9;
        return Vec2.signedArea2(a, b, pt) > -eps and
            Vec2.signedArea2(b, c, pt) > -eps and
            Vec2.signedArea2(c, a, pt) > -eps;
    }

    fn pointOnSegment(self: *CDT, pt: Vec2, a: Vec2, b: Vec2) bool {
        _ = self;
        const ab = b.sub(a);
        const ap = pt.sub(a);
        if (@abs(ab.cross(ap)) > 1e-9) return false;
        const dot = ap.dot(ab);
        return dot >= -1e-9 and dot <= ab.len2() + 1e-9;
    }

    fn lineSide(self: *CDT, pt: Vec2, a: Vec2, b: Vec2) LineSide {
        _ = self;
        const cross = Vec2.cross(b.sub(a), pt.sub(a));
        if (cross > 0) return .Left;
        if (cross < 0) return .Right;
        return .On;
    }

    fn getOpposedTriangle(self: *CDT, tri: *Triangle, v: u32) i32 {
        _ = self;
        const idx = for (tri.vertices, 0..) |vertex, i| {
            if (vertex == v) break @as(u32, @intCast(i));
        } else return -1;
        return tri.neighbors[(idx + 1) % 3];
    }

    fn opposedVertex(self: *CDT, tri: *Triangle, neighbor_tri: u32) u32 {
        const neighbor = &self.triangles.items[neighbor_tri];
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
        return 0;
    }

    fn edgeNeighbor(self: *CDT, tri: *Triangle, v1: u32, v2: u32) i32 {
        for (tri.neighbors) |n| {
            if (n == -1) continue;
            const nb = &self.triangles.items[@intCast(n)];
            const has_v1 = nb.vertices[0] == v1 or nb.vertices[1] == v1 or nb.vertices[2] == v1;
            const has_v2 = nb.vertices[0] == v2 or nb.vertices[1] == v2 or nb.vertices[2] == v2;
            if (has_v1 and has_v2) return n;
        }
        return -1;
    }

    fn setVertTri(self: *CDT, v: u32, t: u32) !void {
        if (self.vert_tris.items.len <= v) try self.vert_tris.resize(self.allocator, v + 1);
        self.vert_tris.items[v] = t;
    }

    fn pointInCircumcircle(pt: Vec2, a: Vec2, b: Vec2, c: Vec2) bool {
        const ax = a.x - pt.x;
        const ay = a.y - pt.y;
        const bx = b.x - pt.x;
        const by = b.y - pt.y;
        const cx = c.x - pt.x;
        const cy = c.y - pt.y;
        const det = (ax * ax + ay * ay) * (bx * cy - cx * by) -
            (bx * bx + by * by) * (ax * cy - cx * ay) +
            (cx * cx + cy * cy) * (ax * by - bx * ay);
        return det > 0;
    }

    fn addNewTriangle(self: *CDT) !u32 {
        const idx = @as(u32, @intCast(self.triangles.items.len));
        try self.triangles.append(self.allocator, .{});
        return idx;
    }

    // ---------- 伪多边形重三角化 ----------
    fn triangulatePseudoPolygon(
        self: *CDT,
        poly: *std.ArrayListUnmanaged(u32),
        outerTris: *std.AutoHashMapUnmanaged(Edge, i32),
        iTL: u32,
        iTR: u32,
        trianglesToReuse: *std.ArrayListUnmanaged(u32),
        iterations: *std.ArrayListUnmanaged(TriangulatePseudoPolygonTask),
    ) !void {
        iterations.clearRetainingCapacity();
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

    fn triangulatePseudoPolygonIteration(
        self: *CDT,
        poly: *std.ArrayListUnmanaged(u32),
        outerTris: *std.AutoHashMapUnmanaged(Edge, i32),
        trianglesToReuse: *std.ArrayListUnmanaged(u32),
        iterations: *std.ArrayListUnmanaged(TriangulatePseudoPolygonTask),
    ) !void {
        const task = iterations.pop().?;
        const iA = task.iA;
        const iB = task.iB;
        var iT = task.iT;
        const iParent = task.iParent;
        const iInParent = task.iInParent;

        if (iB - iA < 1) return;

        const iC = self.findDelaunayPoint(poly, iA, iB);
        const a = poly.items[iA];
        const b = poly.items[iB];
        const c = poly.items[iC];

        if (trianglesToReuse.items.len == 0) {
            iT = try self.addNewTriangle();
        } else {
            iT = trianglesToReuse.pop().?;
        }

        const tri = &self.triangles.items[iT];
        tri.vertices = .{ a, b, c };

        // 右子区间 (iC, iB)
        if (iB - iC > 1) {
            const iNext = if (trianglesToReuse.items.len > 0) trianglesToReuse.pop().? else try self.addNewTriangle();
            try iterations.append(self.allocator, .{
                .iA = iC,
                .iB = iB,
                .iT = iNext,
                .iParent = iT,
                .iInParent = 1,
            });
        } else {
            const outerTri = self.getOuterTri(outerTris, b, c);
            if (outerTri != -1) {
                tri.neighbors[1] = outerTri;
                try self.setNewNeighbor(@intCast(outerTri), c, b, iT);
            } else {
                tri.neighbors[1] = -1;
                try self.putOuterTris(outerTris, b, c, @intCast(iT));
            }
        }

        // 左子区间 (iA, iC)
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
            const outerTri = self.getOuterTri(outerTris, c, a);
            if (outerTri != -1) {
                tri.neighbors[2] = outerTri;
                try self.setNewNeighbor(@intCast(outerTri), a, c, iT);
            } else {
                tri.neighbors[2] = -1;
                try self.putOuterTris(outerTris, c, a, @intCast(iT));
            }
        }

        // 连接父三角形
        if (iParent != iT) {
            const parentTri = &self.triangles.items[iParent];
            parentTri.neighbors[iInParent] = @intCast(iT);
            tri.neighbors[0] = @intCast(iParent);
        } else {
            tri.neighbors[0] = -1;
        }

        try self.setVertTri(c, iT);
    }

    /// 在多边形顶点区间 (iA, iB) 内寻找最符合 Delaunay 条件的第三点
    fn findDelaunayPoint(self: *CDT, poly: *std.ArrayListUnmanaged(u32), iA: u32, iB: u32) u32 {
        const a = self.vertices.items[poly.items[iA]];
        const b = self.vertices.items[poly.items[iB]];
        var best = iA + 1;
        var best_c = self.vertices.items[poly.items[best]];

        var i = iA + 1;
        while (i < iB) : (i += 1) {
            const v = self.vertices.items[poly.items[i]];
            if (pointInCircumcircle(v, a, b, best_c)) {
                best = @intCast(i);
                best_c = v;
            }
        }
        return best;
    }

    /// 查找或添加顶点（带容差）
    pub fn findOrAddVertex(self: *CDT, pt: Vec2, tolerance: f32) !u32 {
        const nearest = self.findNearestVertex(pt);
        const dx = self.vertices.items[nearest].x - pt.x;
        const dy = self.vertices.items[nearest].y - pt.y;
        const dist_sq = dx * dx + dy * dy;
        if (dist_sq <= tolerance * tolerance) return nearest;

        const new_idx = try self.addVertex(pt);
        try self.insertVertex(new_idx);
        return new_idx;
    }
};
