const std = @import("std");
const Vec2 = @import("imports.zig").Vec2;

// ---------- 基础结构 ----------
pub const Edge = struct {
    v1: u32,
    v2: u32,

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
    vert_tris: std.ArrayListUnmanaged(u32) = .{}, // 每个顶点的任一邻接三角形
    vert_ref_counts: std.ArrayListUnmanaged(u32) = .{}, // 顶点被约束边引用的次数

    // crep: 约束边 → 约束 ID 列表
    constrained_edges: std.AutoArrayHashMapUnmanaged(Edge, std.ArrayListUnmanaged(u32)) = .{},

    // 临时缓冲区（每次使用前 clearRetainingCapacity）
    temp_stack: std.ArrayListUnmanaged(u32) = .{},
    temp_intersected: std.ArrayListUnmanaged(u32) = .{},
    temp_poly_l: std.ArrayListUnmanaged(u32) = .{},
    temp_poly_r: std.ArrayListUnmanaged(u32) = .{},
    temp_outer_tris: std.AutoHashMapUnmanaged(Edge, i32) = .{},
    temp_iterations: std.ArrayListUnmanaged(TriangulatePseudoPolygonTask) = .{},

    const TriangulatePseudoPolygonTask = struct {
        iA: u32,
        iB: u32,
        iT: u32,
        iParent: u32,
        iInParent: u32,
    };

    const LineSide = enum { Left, Right, On };

    const EPSILON: f32 = 1e-6;

    // ---------- 初始化 ----------
    pub fn init(allocator: std.mem.Allocator, map_width: u32, map_height: u32) !CDT {
        var cdt = CDT{ .allocator = allocator };

        const width_f: f32 = @floatFromInt(map_width);
        const height_f: f32 = @floatFromInt(map_height);
        const center = Vec2{ .x = width_f / 2, .y = height_f / 2 };
        const radius = @sqrt(center.x * center.x + center.y * center.y) * 2.5;

        // 超三角形（逆时针）
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
        for (super_verts) |v| {
            cdt.vert_tris.items[v] = 0;
            cdt.vert_ref_counts.items[v] = 0;
        }

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

        // 插入四条边界约束边（ID=0 表示地图边界）
        inline for (.{ .{ 0, 1 }, .{ 1, 2 }, .{ 2, 3 }, .{ 3, 0 } }) |pair| {
            try cdt.insertConstraintEdge(corner_verts[pair[0]], corner_verts[pair[1]], 0);
        }

        return cdt;
    }

    pub fn deinit(self: *CDT) void {
        var it = self.constrained_edges.iterator();
        while (it.next()) |list| {
            list.value_ptr.deinit(self.allocator);
        }
        self.constrained_edges.deinit(self.allocator);
        self.vertices.deinit(self.allocator);
        self.triangles.deinit(self.allocator);
        self.vert_tris.deinit(self.allocator);
        self.vert_ref_counts.deinit(self.allocator);
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
        try self.vert_ref_counts.resize(self.allocator, idx + 1);
        self.vert_ref_counts.items[idx] = 0;
        return idx;
    }

    pub fn insertVertex(self: *CDT, v_idx: u32) !void {
        const v = self.vertices.items[v_idx];
        const nearest = self.findNearestVertex(v);
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

    fn walkToTriangle(self: *CDT, v_idx: u32, start_tri: u32) !struct { tri_idx: u32, on_edge: ?[2]u32 } {
        const pt = self.vertices.items[v_idx];
        var cur_tri = start_tri;
        var visited = std.AutoHashMap(u32, void).init(self.allocator);
        defer visited.deinit();

        var iter: u32 = 0;
        const max_iter = self.triangles.items.len * 2;
        while (iter < max_iter) : (iter += 1) {
            if (visited.contains(cur_tri)) return error.InfiniteLoop;
            try visited.put(cur_tri, {});
            const tri = self.triangles.items[cur_tri];
            const a = self.vertices.items[tri.vertices[0]];
            const b = self.vertices.items[tri.vertices[1]];
            const c = self.vertices.items[tri.vertices[2]];

            if (self.pointInTriangle(pt, a, b, c))
                return .{ .tri_idx = cur_tri, .on_edge = null };
            if (self.pointOnSegment(pt, a, b))
                return .{ .tri_idx = cur_tri, .on_edge = .{ tri.vertices[0], tri.vertices[1] } };
            if (self.pointOnSegment(pt, b, c))
                return .{ .tri_idx = cur_tri, .on_edge = .{ tri.vertices[1], tri.vertices[2] } };
            if (self.pointOnSegment(pt, c, a))
                return .{ .tri_idx = cur_tri, .on_edge = .{ tri.vertices[2], tri.vertices[0] } };

            const next = self.nextTriangleTowardsPoint(pt, a, b, c, tri.neighbors) orelse
                return error.PointOutsideMesh;
            cur_tri = next;
        }
        return error.PointOutsideMesh;
    }

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

    fn insertVertexOnEdge(self: *CDT, v: u32, v1: u32, v2: u32, t1: u32, t2: u32) !void {
        const e = Edge{ .v1 = v1, .v2 = v2 };
        const norm_edge = e.normalized();
        const has_crep = self.constrained_edges.get(norm_edge) != null;

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

        if (has_crep) {
            var crep_list = self.constrained_edges.fetchSwapRemove(norm_edge).?.value;
            try self.addConstraintToEdgeWithCrep(.{ .v1 = v1, .v2 = v }, &crep_list);
            try self.addConstraintToEdgeWithCrep(.{ .v1 = v, .v2 = v2 }, &crep_list);
            crep_list.deinit(self.allocator);
        }
    }

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

    // ---------- 约束边插入（三步法，严格遵循论文 Section 4） ----------
    pub fn insertConstraintEdge(self: *CDT, v1: u32, v2: u32, constraint_id: u32) !void {
        if (v1 == v2) return;
        self.vert_ref_counts.items[v1] += 1;
        self.vert_ref_counts.items[v2] += 1;

        // 如果边已存在于网格中，直接添加约束 ID
        if (try self.edgeExistsInMesh(v1, v2)) {
            try self.addConstraintToExistingEdge(.{ .v1 = v1, .v2 = v2 }, constraint_id);
            return;
        }

        // 否则递归处理可能因与现有约束边相交而被截断的情况
        try self.insertConstraintEdgeRecursive(.{ .v1 = v1, .v2 = v2 }, constraint_id);
    }

    fn insertConstraintEdgeRecursive(self: *CDT, edge: Edge, constraint_id: u32) !void {
        var remaining = std.ArrayList(Edge){};
        defer remaining.deinit(self.allocator);
        try remaining.append(self.allocator, edge);

        while (remaining.items.len > 0) {
            const cur = remaining.pop().?;
            const iA = cur.v1;
            const iB = cur.v2;

            // Step 1: 分裂所有与 iA-iB 相交的已有约束边（论文 Figure 3b）
            const split_result = try self.splitIntersectingConstraints(iA, iB);
            if (split_result.split_vertex) |new_v| {
                // 当前段被截断，插入已处理部分，剩余部分加入队列
                try self.addConstraintToExistingEdge(.{ .v1 = iA, .v2 = new_v }, constraint_id);
                try remaining.append(self.allocator, .{ .v1 = new_v, .v2 = cur.v2 });
                continue;
            }

            // Step 2 & 3: 删除交叉三角形，插入约束边并重三角化（论文 Figure 3c, 3d）
            try self.removeAndRetriangulate(iA, iB, constraint_id);
        }
    }

    /// 检测当前线段 iA-iB 是否与已有的约束边相交（端点除外），若相交则在交点处插入新顶点，
    /// 并分裂该约束边。返回截断顶点（若存在），否则 null。
    fn splitIntersectingConstraints(self: *CDT, iA: u32, iB: u32) !struct { split_vertex: ?u32 } {
        const a = self.vertices.items[iA];
        const b = self.vertices.items[iB];
        const ab = b.sub(a);
        const ab_len_sq = ab.len2();
        if (ab_len_sq < EPSILON * EPSILON) return .{ .split_vertex = null };

        // 收集与 iA-iB 内部相交的约束边（不含端点）
        var candidates = std.ArrayList(struct { edge: Edge, pos: Vec2 }){};
        defer candidates.deinit(self.allocator);

        var cur_tri = self.vert_tris.items[iA];
        var prev: ?u32 = null;
        while (true) {
            const tri = self.triangles.items[cur_tri];
            const local_idx = for (tri.vertices, 0..) |v, idx| {
                if (v == iA) break @as(u32, @intCast(idx));
            } else break;

            const opp_edge_idx = (local_idx + 1) % 3;
            const v_start = tri.vertices[opp_edge_idx];
            const v_end = tri.vertices[(opp_edge_idx + 1) % 3];
            const p1 = self.vertices.items[v_start];
            const p2 = self.vertices.items[v_end];
            const e = Edge{ .v1 = v_start, .v2 = v_end };

            if (self.segmentsIntersect(a, b, p1, p2) and
                !self.pointOnSegment(a, p1, p2) and
                !self.pointOnSegment(b, p1, p2))
            {
                const norm_e = e.normalized();
                if (self.constrained_edges.contains(norm_e)) {
                    const pos = self.lineIntersection(a, b, p1, p2);
                    try candidates.append(self.allocator, .{ .edge = e, .pos = pos });
                }
            }

            const next = self.nextTriangleAroundVertex(cur_tri, iA, prev);
            if (next == null or next.? == self.vert_tris.items[iA]) break;
            prev = cur_tri;
            cur_tri = next.?;
        }

        if (candidates.items.len == 0) return .{ .split_vertex = null };

        // 选择参数 t 最小的交点（沿 iA→iB 方向第一个交点）
        var best_idx: usize = 0;
        var best_t: f32 = 2.0;
        for (candidates.items, 0..) |cand, idx| {
            const t = cand.pos.sub(a).dot(ab) / ab_len_sq;
            if (t > EPSILON and t < 1.0 - EPSILON and t < best_t) {
                best_t = t;
                best_idx = idx;
            }
        }

        if (best_t > 1.0) return .{ .split_vertex = null };

        const best = candidates.items[best_idx];
        const new_vert = try self.splitConstrainedEdgeAt(best.edge, best.pos);

        // 检查该交点是否位于 iA-iB 内部（非端点）
        const t = best.pos.sub(a).dot(ab) / ab_len_sq;
        if (t > EPSILON and t < 1.0 - EPSILON) {
            return .{ .split_vertex = new_vert };
        }

        return .{ .split_vertex = null };
    }

    fn removeAndRetriangulate(self: *CDT, iA: u32, iB: u32, constraint_id: u32) !void {
        self.temp_intersected.clearRetainingCapacity();
        self.temp_poly_l.clearRetainingCapacity();
        self.temp_poly_r.clearRetainingCapacity();
        self.temp_outer_tris.clearRetainingCapacity();

        // 收集所有与 iA-iB 相交的三角形
        try self.collectIntersectedTriangles(iA, iB);

        // 调整 iA, iB 的 vert_tris 避免指向即将删除的三角形
        if (self.vert_tris.items[iA] == self.temp_intersected.items[0])
            try self.pivotVertexTriangleCW(iA);
        if (self.vert_tris.items[iB] == self.temp_intersected.items[self.temp_intersected.items.len - 1])
            try self.pivotVertexTriangleCW(iB);

        const iTL = self.temp_intersected.items[0];
        const iTR = self.temp_intersected.items[self.temp_intersected.items.len - 1];
        std.mem.reverse(u32, self.temp_poly_r.items);

        var trianglesToReuse = std.ArrayList(u32){};
        defer trianglesToReuse.deinit(self.allocator);
        try trianglesToReuse.appendSlice(self.allocator, self.temp_intersected.items);

        self.temp_iterations.clearRetainingCapacity();

        // 重三角化左右两侧伪多边形
        try self.triangulatePseudoPolygon(&self.temp_poly_l, &self.temp_outer_tris, iTL, iTR, &trianglesToReuse, &self.temp_iterations);
        try self.triangulatePseudoPolygon(&self.temp_poly_r, &self.temp_outer_tris, iTR, iTL, &trianglesToReuse, &self.temp_iterations);

        // 将新生成的约束边记录到 crep
        try self.addConstraintToExistingEdge(.{ .v1 = iA, .v2 = iB }, constraint_id);
    }

    fn collectIntersectedTriangles(self: *CDT, iA: u32, iB: u32) !void {
        const a = self.vertices.items[iA];
        const b = self.vertices.items[iB];

        const first = try self.findFirstIntersectedTriangle(iA, a, b);
        var iT = first.tri_idx;
        var iVL = first.vL;
        var iVR = first.vR;

        try self.temp_intersected.append(self.allocator, iT);
        try self.temp_poly_l.append(self.allocator, iA);
        try self.temp_poly_l.append(self.allocator, iVL);
        try self.temp_poly_r.append(self.allocator, iA);
        try self.temp_poly_r.append(self.allocator, iVR);

        var tri = &self.triangles.items[iT];
        try self.putOuterTris(&self.temp_outer_tris, iA, iVL, self.edgeNeighbor(tri, iA, iVL));
        try self.putOuterTris(&self.temp_outer_tris, iA, iVR, self.edgeNeighbor(tri, iA, iVR));

        var iV = iA;
        var iter: u32 = 0;
        const max_iter = self.triangles.items.len * 2;

        while (!self.triangleContainsVertex(iT, iB)) : (iter += 1) {
            if (iter > max_iter) return error.InfiniteLoopInCollect;

            const iTopo = self.getOpposedTriangle(&self.triangles.items[iT], iV);
            if (iTopo == -1) return error.EdgeHasNoNeighbor;
            const topo = &self.triangles.items[@intCast(iTopo)];
            const iVopo = self.opposedVertex(topo, iT);

            const loc = self.lineSide(self.vertices.items[iVopo], a, b);
            if (loc == .Left) {
                try self.temp_poly_l.append(self.allocator, iVopo);
                try self.putOuterTris(&self.temp_outer_tris, iVL, iVopo, self.edgeNeighbor(topo, iVL, iVopo));
                iVL = iVopo;
            } else if (loc == .Right) {
                try self.temp_poly_r.append(self.allocator, iVopo);
                try self.putOuterTris(&self.temp_outer_tris, iVR, iVopo, self.edgeNeighbor(topo, iVR, iVopo));
                iVR = iVopo;
            } else {
                return error.UnexpectedCollinearVertex;
            }

            try self.temp_intersected.append(self.allocator, @intCast(iTopo));
            iT = @intCast(iTopo);
            iV = iVopo;
        }

        tri = &self.triangles.items[iT];
        try self.putOuterTris(&self.temp_outer_tris, iVL, iB, self.edgeNeighbor(tri, iVL, iB));
        try self.putOuterTris(&self.temp_outer_tris, iVR, iB, self.edgeNeighbor(tri, iVR, iB));
        try self.temp_poly_l.append(self.allocator, iB);
        try self.temp_poly_r.append(self.allocator, iB);
    }

    fn findFirstIntersectedTriangle(self: *CDT, iA: u32, a: Vec2, b: Vec2) !struct { tri_idx: u32, vL: u32, vR: u32 } {
        var cur_tri = self.vert_tris.items[iA];
        var prev: ?u32 = null;
        var iter: u32 = 0;
        const max_iter = self.triangles.items.len * 2;

        while (iter < max_iter) : (iter += 1) {
            const tri = self.triangles.items[cur_tri];
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
                if (neighbor != -1) {
                    const side1 = self.lineSide(p1, a, b);
                    const iVL, const iVR = if (side1 == .Left) .{ v_start, v_end } else .{ v_end, v_start };
                    return .{ .tri_idx = @intCast(neighbor), .vL = iVL, .vR = iVR };
                }
            }

            const next = self.nextTriangleAroundVertex(cur_tri, iA, prev);
            if (next == null or next.? == self.vert_tris.items[iA]) break;
            prev = cur_tri;
            cur_tri = next.?;
        }
        return error.NoIntersectedTriangleFound;
    }

    fn pivotVertexTriangleCW(self: *CDT, v: u32) !void {
        const cur_tri = self.vert_tris.items[v];
        const tri = self.triangles.items[cur_tri];
        const idx = for (tri.vertices, 0..) |vertex, i| {
            if (vertex == v) break @as(u32, @intCast(i));
        } else return error.VertexNotInTriangle;

        const next = tri.neighbors[(idx + 1) % 3];
        if (next == -1) return error.NoAdjacentTriangle;
        self.vert_tris.items[v] = @intCast(next);
    }

    fn putOuterTris(self: *CDT, map: *std.AutoHashMapUnmanaged(Edge, i32), v1: u32, v2: u32, tri_idx: i32) !void {
        const edge = Edge{ .v1 = v1, .v2 = v2 };
        const ne = edge.normalized();
        try map.put(self.allocator, ne, tri_idx);
    }

    fn getOuterTri(self: *CDT, map: *std.AutoHashMapUnmanaged(Edge, i32), v1: u32, v2: u32) i32 {
        _ = self;
        const edge = Edge{ .v1 = v1, .v2 = v2 };
        const ne = edge.normalized();
        return map.get(ne) orelse -1;
    }

    fn triangleContainsVertex(self: *CDT, tri_idx: u32, v: u32) bool {
        const tri = self.triangles.items[tri_idx];
        return tri.vertices[0] == v or tri.vertices[1] == v or tri.vertices[2] == v;
    }

    fn lineIntersection(self: *CDT, a: Vec2, b: Vec2, c: Vec2, d: Vec2) Vec2 {
        _ = self;
        const ab = b.sub(a);
        const cd = d.sub(c);
        const ac = c.sub(a);
        const t = Vec2.cross(ac, cd) / Vec2.cross(ab, cd);
        return a.add(ab.scale(t));
    }

    fn edgeExistsInMesh(self: *CDT, v1: u32, v2: u32) !bool {
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

    fn addConstraintToExistingEdge(self: *CDT, edge: Edge, constraint_id: u32) !void {
        const norm = edge.normalized();
        const gop = try self.constrained_edges.getOrPut(self.allocator, norm);
        if (!gop.found_existing) {
            gop.value_ptr.* = .{};
        }
        for (gop.value_ptr.items) |id| {
            if (id == constraint_id) return;
        }
        try gop.value_ptr.append(self.allocator, constraint_id);
    }

    fn splitConstrainedEdgeAt(self: *CDT, edge: Edge, pos: Vec2) !u32 {
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
        return split_vert;
    }

    fn addConstraintToEdgeWithCrep(self: *CDT, edge: Edge, crep: *std.ArrayListUnmanaged(u32)) !void {
        const norm = edge.normalized();
        const gop = try self.constrained_edges.getOrPut(self.allocator, norm);
        if (!gop.found_existing) {
            gop.value_ptr.* = .{};
            try gop.value_ptr.appendSlice(self.allocator, crep.items);
        } else {
            for (crep.items) |id| {
                var found = false;
                for (gop.value_ptr.items) |existing| {
                    if (existing == id) {
                        found = true;
                        break;
                    }
                }
                if (!found) try gop.value_ptr.append(self.allocator, id);
            }
        }
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

    // ---------- 约束边移除（论文 Section 5） ----------
    pub fn removeConstraint(self: *CDT, constraint_id: u32) !void {
        // Step 1: 遍历所有约束边，移除指定 ID，收集完全无约束的边
        var affected_edges = std.ArrayList(Edge).init(self.allocator);
        defer affected_edges.deinit();

        var it = self.constrained_edges.iterator();
        while (it.next()) |entry| {
            var list = entry.value_ptr;
            var i: usize = 0;
            while (i < list.items.len) {
                if (list.items[i] == constraint_id) {
                    _ = list.swapRemove(i);
                } else {
                    i += 1;
                }
            }
            if (list.items.len == 0) {
                try affected_edges.append(entry.key_ptr.*);
            }
        }

        // 对每个完全解除约束的边进行处理
        for (affected_edges.items) |edge| {
            _ = self.constrained_edges.swapRemove(edge);
            try self.tryRemoveUnconstrainedEdge(edge);
        }

        // Step 2: 删除引用计数为 0 且无任何约束边相邻的孤立顶点
        for (self.vert_ref_counts.items, 0..) |ref, idx| {
            if (ref == 0) {
                const v = @as(u32, @intCast(idx));
                if (!try self.vertexHasConstrainedEdges(v)) {
                    try self.removeIsolatedVertex(v);
                }
            }
        }
    }

    fn tryRemoveUnconstrainedEdge(self: *CDT, edge: Edge) !void {
        if (!try self.edgeExistsInMesh(edge.v1, edge.v2)) return;

        // 递减两端点引用计数
        if (self.vert_ref_counts.items[edge.v1] > 0)
            self.vert_ref_counts.items[edge.v1] -= 1;
        if (self.vert_ref_counts.items[edge.v2] > 0)
            self.vert_ref_counts.items[edge.v2] -= 1;

        // 检查是否可以合并共线边（如论文 Figure 5）
        if (try self.canMergeVertices(edge.v1, edge.v2)) {
            try self.mergeCollinearEdge(edge);
        }
    }

    fn vertexHasConstrainedEdges(self: *CDT, v: u32) !bool {
        var cur_tri = self.vert_tris.items[v];
        var prev: ?u32 = null;
        var iter: u32 = 0;
        const max_iter = self.triangles.items.len * 2;

        while (iter < max_iter) : (iter += 1) {
            const tri = self.triangles.items[cur_tri];
            const idx = for (tri.vertices, 0..) |vert, i| {
                if (vert == v) break @as(u32, @intCast(i));
            } else break;

            const v_start = tri.vertices[idx];
            const v_end = tri.vertices[(idx + 1) % 3];

            const e = Edge{ .v1 = v_start, .v2 = v_end };
            const n = e.normalized();
            if (self.constrained_edges.contains(n)) return true;

            const next = self.nextTriangleAroundVertex(cur_tri, v, prev);
            if (next == null or next.? == self.vert_tris.items[v]) break;
            prev = cur_tri;
            cur_tri = next.?;
        }
        return false;
    }

    fn canMergeVertices(self: *CDT, v1: u32, v2: u32) !bool {
        if (!try self.edgeExistsInMesh(v1, v2)) return false;

        const t1 = self.vert_tris.items[v1];
        const tri1 = self.triangles.items[t1];
        const neighbor = self.edgeNeighbor(&tri1, v1, v2);
        if (neighbor == -1) return false;

        const opp1 = self.opposedVertex(&tri1, @intCast(neighbor));
        const opp2 = self.opposedVertex(&self.triangles.items[@intCast(neighbor)], t1);
        const c = self.vertices.items[opp1];
        const d = self.vertices.items[opp2];
        const a = self.vertices.items[v1];
        const b = self.vertices.items[v2];

        return self.lineSide(c, a, b) == .On and self.lineSide(d, a, b) == .On;
    }

    fn mergeCollinearEdge(self: *CDT, edge: Edge) !void {
        const keep = edge.v1;
        const remove = edge.v2;

        // 将所有与 remove 相连的约束边改为连接到 keep
        var edges_to_update = std.ArrayList(Edge).init(self.allocator);
        defer edges_to_update.deinit();

        var cur_tri = self.vert_tris.items[remove];
        var prev: ?u32 = null;
        while (true) {
            const tri = self.triangles.items[cur_tri];
            const idx = for (tri.vertices, 0..) |v, i| {
                if (v == remove) break @as(u32, @intCast(i));
            } else break;

            const v1_ = tri.vertices[idx];
            const v2_ = tri.vertices[(idx + 1) % 3];
            const tmp = Edge{ .v1 = v1_, .v2 = v2_ };
            const e = tmp.normalized();
            if (self.constrained_edges.contains(e)) {
                try edges_to_update.append(e);
            }

            const next = self.nextTriangleAroundVertex(cur_tri, remove, prev);
            if (next == null or next.? == self.vert_tris.items[remove]) break;
            prev = cur_tri;
            cur_tri = next.?;
        }

        // 移除顶点 remove（这会重三角化空洞）
        try self.removeVertex(remove);

        // 更新约束边列表
        for (edges_to_update.items) |e| {
            var list = self.constrained_edges.fetchSwapRemove(e).?.value;
            const new_edge = if (e.v1 == remove) Edge{ .v1 = keep, .v2 = e.v2 } else Edge{ .v1 = e.v1, .v2 = keep };
            try self.addConstraintToEdgeWithCrep(new_edge, &list);
            list.deinit(self.allocator);
        }
    }

    fn removeIsolatedVertex(self: *CDT, v: u32) !void {
        if (try self.vertexHasConstrainedEdges(v)) return;
        try self.removeVertex(v);
    }

    fn removeVertex(self: *CDT, v: u32) !void {
        // 收集 v 周围的三角形（形成一个空洞）
        var hole_verts = std.ArrayList(u32).init(self.allocator);
        defer hole_verts.deinit();
        var hole_tris = std.ArrayList(u32).init(self.allocator);
        defer hole_tris.deinit();

        var cur_tri = self.vert_tris.items[v];
        var prev: ?u32 = null;
        while (true) {
            try hole_tris.append(cur_tri);
            const tri = self.triangles.items[cur_tri];
            const idx = for (tri.vertices, 0..) |vert, i| {
                if (vert == v) break @as(u32, @intCast(i));
            } else break;
            const next_vert = tri.vertices[(idx + 1) % 3];
            try hole_verts.append(next_vert);
            const next = self.nextTriangleAroundVertex(cur_tri, v, prev);
            if (next == null or next.? == self.vert_tris.items[v]) break;
            prev = cur_tri;
            cur_tri = next.?;
        }

        // 删除空洞中的三角形（标记为可复用）
        var trianglesToReuse = std.ArrayList(u32).init(self.allocator);
        defer trianglesToReuse.deinit();
        try trianglesToReuse.appendSlice(self.allocator, hole_tris.items);

        // 重三角化空洞（伪多边形）
        self.temp_outer_tris.clearRetainingCapacity();
        self.temp_iterations.clearRetainingCapacity();

        // 构建伪多边形顶点列表（顺时针）
        var poly = std.ArrayList(u32).init(self.allocator);
        defer poly.deinit();
        for (hole_verts.items) |hv| {
            try poly.append(hv);
        }

        // 获取空洞边界外的三角形映射
        for (0..poly.items.len) |i| {
            const v1 = poly.items[i];
            const v2 = poly.items[(i + 1) % poly.items.len];
            const e = Edge{ .v1 = v1, .v2 = v2 };
            const outer_tri = self.findOuterTriangleForEdge(e, v);
            if (outer_tri != -1) {
                try self.putOuterTris(&self.temp_outer_tris, v1, v2, outer_tri);
            }
        }

        // 重三角化
        try self.triangulatePseudoPolygon(&poly, &self.temp_outer_tris, 0, 0, &trianglesToReuse, &self.temp_iterations);

        // 更新受影响的 vert_tris
        for (poly.items) |pv| {
            const tri_opt = self.findAnyTriangleContainingVertex(pv);
            if (tri_opt) |t| {
                self.vert_tris.items[pv] = t;
            }
        }

        // 最后移除 v 的记录（顶点列表保留，但引用计数为 0）
    }

    fn findOuterTriangleForEdge(self: *CDT, edge: Edge, v_to_remove: u32) i32 {
        _ = v_to_remove;
        // 遍历与边两端点相邻的三角形，找出不包含 v_to_remove 的那个
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
                return tri.neighbors[idx];
            }
            const next = self.nextTriangleAroundVertex(cur, edge.v1, prev);
            if (next == null or next.? == start_tri) break;
            prev = cur;
            cur = next.?;
        }
        return -1;
    }

    fn findAnyTriangleContainingVertex(self: *CDT, v: u32) ?u32 {
        for (self.triangles.items, 0..) |tri, idx| {
            if (tri.vertices[0] == v or tri.vertices[1] == v or tri.vertices[2] == v) {
                return @intCast(idx);
            }
        }
        return null;
    }

    // ---------- 几何查询辅助 ----------
    fn nextTriangleTowardsPoint(self: *CDT, pt: Vec2, a: Vec2, b: Vec2, c: Vec2, neighbors: [3]i32) ?u32 {
        _ = self;
        const verts = [3]Vec2{ a, b, c };
        for (0..3) |i| {
            if (Vec2.signedArea2(verts[i], verts[(i + 1) % 3], pt) < -EPSILON) {
                return if (neighbors[i] != -1) @intCast(neighbors[i]) else null;
            }
        }
        return null;
    }

    fn pointInTriangle(self: *CDT, pt: Vec2, a: Vec2, b: Vec2, c: Vec2) bool {
        _ = self;
        return Vec2.signedArea2(a, b, pt) >= -EPSILON and
            Vec2.signedArea2(b, c, pt) >= -EPSILON and
            Vec2.signedArea2(c, a, pt) >= -EPSILON;
    }

    fn pointOnSegment(self: *CDT, pt: Vec2, a: Vec2, b: Vec2) bool {
        _ = self;
        const ab = b.sub(a);
        const ap = pt.sub(a);
        if (@abs(Vec2.cross(ab, ap)) > EPSILON) return false;
        const dot = ap.dot(ab);
        return dot >= -EPSILON and dot <= ab.len2() + EPSILON;
    }

    fn lineSide(self: *CDT, pt: Vec2, a: Vec2, b: Vec2) LineSide {
        _ = self;
        const cross = Vec2.cross(b.sub(a), pt.sub(a));
        if (cross > EPSILON) return .Left;
        if (cross < -EPSILON) return .Right;
        return .On;
    }

    fn segmentsIntersect(self: *CDT, a: Vec2, b: Vec2, c: Vec2, d: Vec2) bool {
        _ = self;
        const o1 = Vec2.signedArea2(a, b, c);
        const o2 = Vec2.signedArea2(a, b, d);
        const o3 = Vec2.signedArea2(c, d, a);
        const o4 = Vec2.signedArea2(c, d, b);
        return (o1 * o2 < -EPSILON) and (o3 * o4 < -EPSILON);
    }

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
        return det > EPSILON;
    }

    fn addNewTriangle(self: *CDT) !u32 {
        const idx = @as(u32, @intCast(self.triangles.items.len));
        try self.triangles.append(self.allocator, .{});
        return idx;
    }

    // ---------- 实用函数 ----------
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
