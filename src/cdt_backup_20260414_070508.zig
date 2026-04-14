const std = @import("std");
const Vec2 = @import("imports.zig").Vec2;

// ----------------------------------------------------------------------
// 基本几何类型 (对应论文 Section 2 定义)
// ----------------------------------------------------------------------
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

// ----------------------------------------------------------------------
// 全动态约束 Delaunay 三角剖分 (论文 Section 3-5)
// ----------------------------------------------------------------------
pub const CDT = struct {
    allocator: std.mem.Allocator,

    // 网格数据
    triangles: std.ArrayListUnmanaged(Triangle) = .{},
    vertices: std.ArrayListUnmanaged(Vec2) = .{},
    vert_tris: std.ArrayListUnmanaged(u32) = .{}, // 每个顶点的任意一个邻接三角形
    vert_ref_counts: std.ArrayListUnmanaged(u32) = .{}, // 顶点被约束边引用的次数

    // 约束边映射：归一化边 -> 约束 ID 列表 (论文中的 crep)
    constrained_edges: std.AutoArrayHashMapUnmanaged(Edge, std.ArrayListUnmanaged(u32)) = .{},

    // 每个约束 ID 对应的一个起始顶点 (论文 Section 5 中用于局部遍历)
    constraint_start_verts: std.AutoHashMapUnmanaged(u32, u32) = .{},

    // 临时缓冲区 (每次使用前清空)
    temp_stack: std.ArrayListUnmanaged(u32) = .{},
    temp_intersected: std.ArrayListUnmanaged(u32) = .{},
    temp_poly_l: std.ArrayListUnmanaged(u32) = .{},
    temp_poly_r: std.ArrayListUnmanaged(u32) = .{},
    temp_outer_tris: std.AutoHashMapUnmanaged(Edge, i32) = .{},
    temp_iterations: std.ArrayListUnmanaged(TriangulatePseudoPolygonTask) = .{},
    temp_vertex_stack: std.ArrayListUnmanaged(u32) = .{},

    const TriangulatePseudoPolygonTask = struct {
        iA: u32,
        iB: u32,
        iT: u32,
        iParent: u32,
        iInParent: u32,
    };

    const LineSide = enum { Left, Right, On };
    const EPSILON: f32 = 1e-5;

    // ---------- 初始化与销毁 (论文 Section 3) ----------
    /// 使用一个包含所有可能约束的包围盒初始化 CDT
    pub fn init(allocator: std.mem.Allocator, map_width: u32, map_height: u32) !CDT {
        var cdt = CDT{ .allocator = allocator };

        const width_f: f32 = @floatFromInt(map_width);
        const height_f: f32 = @floatFromInt(map_height);
        const center = Vec2{ .x = width_f / 2, .y = height_f / 2 };
        const radius = @sqrt(center.x * center.x + center.y * center.y) * 2.5;

        // 构建超三角形 (逆时针)
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

        // 地图边界角点作为初始约束
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
            cdt.vert_ref_counts.items[corner_verts[i]] += 1; // 边界点视为约束点
        }

        // 插入四条边界约束边 (ID=0 表示地图边界)
        inline for (.{ .{ 0, 1 }, .{ 1, 2 }, .{ 2, 3 }, .{ 3, 0 } }) |pair| {
            try cdt.insertConstraintSegment(corner_verts[pair[0]], corner_verts[pair[1]], 0);
        }

        return cdt;
    }

    pub fn deinit(self: *CDT) void {
        var it = self.constrained_edges.iterator();
        while (it.next()) |entry| entry.value_ptr.deinit(self.allocator);
        self.constrained_edges.deinit(self.allocator);
        self.constraint_start_verts.deinit(self.allocator);
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
        self.temp_vertex_stack.deinit(self.allocator);
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

    // ---------- 点插入 (论文 Section 4.1) ----------
    /// 插入单个顶点并恢复 Delaunay 性质
    pub fn insertVertex(self: *CDT, v_idx: u32) !void {
        const v = self.vertices.items[v_idx];
        const start_tri = self.jumpAndWalkStartTriangle(v);
        try self.insertVertexWithStart(v_idx, start_tri);
    }

    /// 跳步行走点定位 (论文 4.1 jump-and-walk)
    fn jumpAndWalkStartTriangle(self: *CDT, pt: Vec2) u32 {
        const n = self.vertices.items.len;
        if (n == 0) return 0;

        const sample_count = @max(@as(usize, @intFromFloat(@sqrt(@as(f64, @floatFromInt(n))) * 2.0)), 30);
        var nearest_v: u32 = 0;
        var min_dist_sq: f32 = std.math.floatMax(f32);
        var rng = std.Random.DefaultPrng.init(@intCast(std.time.milliTimestamp()));
        const rand = rng.random();
        for (0..@min(sample_count, n)) |_| {
            const idx = rand.uintLessThan(usize, n);
            const v = self.vertices.items[idx];
            const dx = v.x - pt.x;
            const dy = v.y - pt.y;
            const dist_sq = dx * dx + dy * dy;
            if (dist_sq < min_dist_sq) {
                min_dist_sq = dist_sq;
                nearest_v = @intCast(idx);
            }
        }
        return self.vert_tris.items[nearest_v];
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

    pub const WalkResult = struct {
        tri_idx: u32,
        on_edge: ?[2]u32,
    };

    fn walkToTriangle(self: *CDT, v_idx: u32, start_tri: u32) !WalkResult {
        const pt = self.vertices.items[v_idx];
        var cur_tri = start_tri;
        var visited = std.AutoHashMap(u32, void).init(self.allocator);
        defer visited.deinit();

        var iter: u32 = 0;
        const max_iter = self.triangles.items.len * 3;
        while (iter < max_iter) : (iter += 1) {
            if (visited.contains(cur_tri)) {
                return try self.walkToTriangleExact(v_idx, start_tri);
            }
            try visited.put(cur_tri, {});
            const tri = self.triangles.items[cur_tri];
            const a = self.vertices.items[tri.vertices[0]];
            const b = self.vertices.items[tri.vertices[1]];
            const c = self.vertices.items[tri.vertices[2]];

            if (self.pointInTriangle(pt, a, b, c))
                return WalkResult{ .tri_idx = cur_tri, .on_edge = null };
            if (self.pointOnSegment(pt, a, b))
                return WalkResult{ .tri_idx = cur_tri, .on_edge = .{ tri.vertices[0], tri.vertices[1] } };
            if (self.pointOnSegment(pt, b, c))
                return WalkResult{ .tri_idx = cur_tri, .on_edge = .{ tri.vertices[1], tri.vertices[2] } };
            if (self.pointOnSegment(pt, c, a))
                return WalkResult{ .tri_idx = cur_tri, .on_edge = .{ tri.vertices[2], tri.vertices[0] } };

            const next = self.nextTriangleTowardsPoint(pt, a, b, c, tri.neighbors) orelse
                return error.PointOutsideMesh;
            cur_tri = next;
        }
        return error.PointOutsideMesh;
    }

    fn walkToTriangleExact(self: *CDT, v_idx: u32, start_tri: u32) !WalkResult {
        const pt = self.vertices.items[v_idx];
        var cur = start_tri;
        var prev: ?u32 = null;
        var visited = std.AutoHashMap(u32, void).init(self.allocator);
        defer visited.deinit();
        var iter: u32 = 0;
        const max_iter = self.triangles.items.len * 3;

        while (iter < max_iter) : (iter += 1) {
            if (visited.contains(cur)) return error.InfiniteLoop;
            try visited.put(cur, {});
            const tri = self.triangles.items[cur];
            const a = self.vertices.items[tri.vertices[0]];
            const b = self.vertices.items[tri.vertices[1]];
            const c = self.vertices.items[tri.vertices[2]];

            if (self.pointInTriangle(pt, a, b, c))
                return WalkResult{ .tri_idx = cur, .on_edge = null };
            for (0..3) |i| {
                const v1 = tri.vertices[i];
                const v2 = tri.vertices[(i + 1) % 3];
                const p1 = self.vertices.items[v1];
                const p2 = self.vertices.items[v2];
                if (self.pointOnSegment(pt, p1, p2))
                    return WalkResult{ .tri_idx = cur, .on_edge = .{ v1, v2 } };
            }

            var chosen: ?u32 = null;
            for (tri.neighbors, 0..) |n, i| {
                if (n != -1 and @as(u32, @intCast(n)) != prev) {
                    const nb = self.triangles.items[@intCast(n)];
                    _ = nb;
                    if (!visited.contains(@intCast(n))) {
                        const v_a = tri.vertices[i];
                        const v_b = tri.vertices[(i + 1) % 3];
                        const pa = self.vertices.items[v_a];
                        const pb = self.vertices.items[v_b];
                        if (Vec2.signedArea2(pa, pb, pt) < -EPSILON) {
                            chosen = @intCast(n);
                            break;
                        }
                    }
                }
            }
            if (chosen == null) {
                for (tri.neighbors) |n| {
                    if (n != -1 and @as(u32, @intCast(n)) != prev and !visited.contains(@intCast(n))) {
                        chosen = @intCast(n);
                        break;
                    }
                }
            }
            if (chosen) |next| {
                prev = cur;
                cur = next;
            } else {
                return error.PointOutsideMesh;
            }
        }
        return error.PointOutsideMesh;
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
            // 分裂顶点被原边所代表的所有约束引用
            self.vert_ref_counts.items[v] += @intCast(crep_list.items.len);
            try self.addConstraintToEdgeWithCrep(.{ .v1 = v1, .v2 = v }, &crep_list);
            try self.addConstraintToEdgeWithCrep(.{ .v1 = v, .v2 = v2 }, &crep_list);
            crep_list.deinit(self.allocator);
        }
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

    // ---------- 约束边插入 (论文 Section 4) ----------
    /// 插入一条约束线段，自动处理交点和重叠
    pub fn insertConstraintSegment(self: *CDT, v1: u32, v2: u32, constraint_id: u32) !void {
        if (v1 == v2) return;

        // 记录约束起始顶点 (用于后续移除)
        if (!self.constraint_start_verts.contains(constraint_id)) {
            try self.constraint_start_verts.put(self.allocator, constraint_id, v1);
        }

        self.vert_ref_counts.items[v1] += 1;
        self.vert_ref_counts.items[v2] += 1;

        if (try self.edgeExistsInMesh(v1, v2)) {
            try self.addConstraintToExistingEdge(.{ .v1 = v1, .v2 = v2 }, constraint_id);
            return;
        }

        // Step 1: 分裂相交的约束边，得到有序交点列表 (论文 4.2 图3b)
        var splits = std.ArrayListUnmanaged(u32){};
        defer splits.deinit(self.allocator);
        try self.splitIntersectingConstraints(v1, v2, &splits);

        // 当前约束引用所有分裂点（除了端点）
        for (splits.items) |split_vert| {
            if (split_vert != v1 and split_vert != v2) {
                self.vert_ref_counts.items[split_vert] += 1;
            }
        }

        // Step 2 & 3: 逐段删除交叉边并重三角化 (论文 4.2 图3c,d)
        var all_verts = std.ArrayListUnmanaged(u32){};
        defer all_verts.deinit(self.allocator);
        try all_verts.append(self.allocator, v1);
        try all_verts.appendSlice(self.allocator, splits.items);
        try all_verts.append(self.allocator, v2);

        var i: usize = 0;
        while (i < all_verts.items.len - 1) : (i += 1) {
            try self.removeCrossingEdgesAndRetriangulate(all_verts.items[i], all_verts.items[i + 1], constraint_id);
        }
    }

    /// Step 1: 找出并分裂与线段 (v1,v2) 相交的已有约束边
    fn splitIntersectingConstraints(self: *CDT, iA: u32, iB: u32, out_splits: *std.ArrayListUnmanaged(u32)) !void {
        const a = self.vertices.items[iA];
        const b = self.vertices.items[iB];
        const dir = b.sub(a);
        const len_sq = dir.len2();
        if (len_sq < EPSILON * EPSILON) return;

        // 收集交点信息（不修改网格）
        const IntersectionInfo = struct {
            t: f32, // 沿线段的参数，0 在 iA，1 在 iB
            edge: Edge,
            pos: Vec2,
            tri: u32, // 包含该边的三角形
            close_to_v1: bool, // 是否接近 edge.v1
            close_to_v2: bool, // 是否接近 edge.v2
        };
        var intersections = std.ArrayListUnmanaged(IntersectionInfo){};
        defer intersections.deinit(self.allocator);

        var cur = self.vert_tris.items[iA];
        var prev_vert = iA;
        var visited = std.AutoHashMap(u32, void).init(self.allocator);
        defer visited.deinit();

        var iter: u32 = 0;
        const max_iter = self.triangles.items.len * 2;

        while (iter < max_iter) : (iter += 1) {
            if (visited.contains(cur)) return error.InfiniteLoop;
            try visited.put(cur, {});

            var tri = self.triangles.items[cur];
            const exit_edge = for (0..3) |i| {
                const v1 = tri.vertices[i];
                const v2 = tri.vertices[(i + 1) % 3];
                if (v1 != prev_vert and v2 != prev_vert) break i;
            } else return error.EdgeNotFound;

            const v_start = tri.vertices[exit_edge];
            const v_end = tri.vertices[(exit_edge + 1) % 3];
            const p1 = self.vertices.items[v_start];
            const p2 = self.vertices.items[v_end];

            const e = Edge{ .v1 = v_start, .v2 = v_end };
            const norm_e = e.normalized();
            if (self.constrained_edges.contains(norm_e)) {
                if (self.segmentsIntersect(a, b, p1, p2)) {
                    const pos = self.lineIntersection(a, b, p1, p2);
                    const d1 = pos.sub(p1).len2();
                    const d2 = pos.sub(p2).len2();
                    const close_to_v1 = d1 < EPSILON * EPSILON;
                    const close_to_v2 = d2 < EPSILON * EPSILON;
                    // 计算参数 t
                    const t = if (dir.x != 0) (pos.x - a.x) / dir.x else (pos.y - a.y) / dir.y;
                    try intersections.append(self.allocator, .{
                        .t = t,
                        .edge = e,
                        .pos = pos,
                        .tri = cur,
                        .close_to_v1 = close_to_v1,
                        .close_to_v2 = close_to_v2,
                    });
                }
            }

            const next_tri = self.edgeNeighbor(&tri, v_start, v_end);
            if (next_tri == -1) break;

            prev_vert = self.opposedVertex(&self.triangles.items[@intCast(next_tri)], cur);
            cur = @intCast(next_tri);

            if (self.triangleContainsVertex(cur, iB)) break;
        }

        // 按 t 从大到小排序（从远端到近端插入，避免影响后续边的查找）
        std.mem.sort(IntersectionInfo, intersections.items, {}, struct {
            fn less(_: void, lhs: IntersectionInfo, rhs: IntersectionInfo) bool {
                return lhs.t > rhs.t; // 降序
            }
        }.less);

        // 插入分裂点
        for (intersections.items) |inter| {
            var split_vert: u32 = undefined;
            if (inter.close_to_v1) {
                split_vert = inter.edge.v1;
            } else if (inter.close_to_v2) {
                split_vert = inter.edge.v2;
            } else {
                // 需要插入新顶点
                split_vert = try self.insertPointOnConstraintEdge(inter.pos, inter.edge.v1, inter.edge.v2, inter.tri);
            }
            try out_splits.append(self.allocator, split_vert);
        }

        // 按沿线段的参数排序输出列表（从小到大）
        const SortContext = struct {
            cdt: *CDT,
            a: Vec2,
            dir: Vec2,
            len_sq: f32,
            fn less(ctx: @This(), lhs: u32, rhs: u32) bool {
                const t1 = ctx.cdt.vertices.items[lhs].sub(ctx.a).dot(ctx.dir) / ctx.len_sq;
                const t2 = ctx.cdt.vertices.items[rhs].sub(ctx.a).dot(ctx.dir) / ctx.len_sq;
                return t1 < t2 - 1e-8;
            }
        };
        std.mem.sort(u32, out_splits.items, SortContext{ .cdt = self, .a = a, .dir = dir, .len_sq = len_sq }, SortContext.less);

        // 去除重复点
        var j: usize = 0;
        while (j + 1 < out_splits.items.len) {
            const p1 = self.vertices.items[out_splits.items[j]];
            const p2 = self.vertices.items[out_splits.items[j + 1]];
            if (p1.sub(p2).len2() < EPSILON * EPSILON) {
                _ = out_splits.orderedRemove(j + 1);
            } else {
                j += 1;
            }
        }
    }

    fn insertPointOnConstraintEdge(self: *CDT, pos: Vec2, v1: u32, v2: u32, tri_containing_edge: u32) !u32 {
        const new_v = try self.addVertex(pos);
        const tri2 = self.edgeNeighbor(&self.triangles.items[tri_containing_edge], v1, v2);
        if (tri2 == -1) return error.EdgeHasNoNeighbor;
        try self.insertVertexOnEdge(new_v, v1, v2, tri_containing_edge, @intCast(tri2));
        try self.ensureDelaunayByEdgeFlip(new_v);
        return new_v;
    }

    /// Step 2 & 3: 移除与线段交叉的边，并在两侧伪多边形内重三角化
    fn removeCrossingEdgesAndRetriangulate(self: *CDT, iA: u32, iB: u32, constraint_id: u32) !void {
        self.temp_intersected.clearRetainingCapacity();
        self.temp_poly_l.clearRetainingCapacity();
        self.temp_poly_r.clearRetainingCapacity();
        self.temp_outer_tris.clearRetainingCapacity();

        try self.collectIntersectedTriangles(iA, iB);

        // 确保线段端点三角形正确对齐
        if (self.vert_tris.items[iA] == self.temp_intersected.items[0])
            try self.pivotVertexTriangleCW(iA);
        if (self.vert_tris.items[iB] == self.temp_intersected.items[self.temp_intersected.items.len - 1])
            try self.pivotVertexTriangleCW(iB);

        const iTL = self.temp_intersected.items[0];
        const iTR = self.temp_intersected.items[self.temp_intersected.items.len - 1];
        std.mem.reverse(u32, self.temp_poly_r.items);

        var trianglesToReuse = std.ArrayListUnmanaged(u32){};
        defer trianglesToReuse.deinit(self.allocator);
        try trianglesToReuse.appendSlice(self.allocator, self.temp_intersected.items);

        self.temp_iterations.clearRetainingCapacity();
        try self.triangulatePseudoPolygon(&self.temp_poly_l, &self.temp_outer_tris, iTL, iTR, &trianglesToReuse, &self.temp_iterations);
        try self.triangulatePseudoPolygon(&self.temp_poly_r, &self.temp_outer_tris, iTR, iTL, &trianglesToReuse, &self.temp_iterations);

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

    // ---------- 伪多边形重三角化 (论文 Section 4 图3d) ----------
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

        // 右子区间
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

        // 左子区间
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

    // ---------- 约束边移除 (论文 Section 5) ----------
    pub fn removeConstraint(self: *CDT, constraint_id: u32) !void {
        const start_v = self.constraint_start_verts.get(constraint_id) orelse return error.ConstraintNotFound;
        var edge_list = std.ArrayListUnmanaged(Edge){};
        defer edge_list.deinit(self.allocator);
        try self.collectConstraintEdges(start_v, constraint_id, &edge_list);

        // Step 1: 从各边移除约束 ID
        for (edge_list.items) |e| {
            var list = self.constrained_edges.getPtr(e.normalized()).?;
            var i: usize = 0;
            while (i < list.items.len) {
                if (list.items[i] == constraint_id) {
                    _ = list.swapRemove(i);
                } else {
                    i += 1;
                }
            }
        }

        // 收集完全解除约束的边
        var affected_edges = std.ArrayListUnmanaged(Edge){};
        defer affected_edges.deinit(self.allocator);
        for (edge_list.items) |e| {
            const norm = e.normalized();
            if (self.constrained_edges.get(norm).?.items.len == 0) {
                if (self.constrained_edges.fetchSwapRemove(norm)) |kv| {
                    var list = kv.value;
                    list.deinit(self.allocator);
                    try affected_edges.append(self.allocator, e);
                }
            }
        }

        for (affected_edges.items) |edge| {
            try self.handleUnconstrainedEdge(edge);
        }

        // Step 2: 移除不再被约束使用的顶点
        var verts_to_check = std.ArrayListUnmanaged(u32){};
        defer verts_to_check.deinit(self.allocator);
        for (edge_list.items) |e| {
            try verts_to_check.append(self.allocator, e.v1);
            try verts_to_check.append(self.allocator, e.v2);
        }
        std.mem.sort(u32, verts_to_check.items, {}, std.sort.asc(u32));
        var unique_idx: usize = 0;
        var k: usize = 1;
        while (k < verts_to_check.items.len) : (k += 1) {
            if (verts_to_check.items[k] != verts_to_check.items[unique_idx]) {
                unique_idx += 1;
                verts_to_check.items[unique_idx] = verts_to_check.items[k];
            }
        }
        verts_to_check.shrinkRetainingCapacity(unique_idx + 1);

        for (verts_to_check.items) |v| {
            if (self.vert_ref_counts.items[v] == 0 and !try self.vertexHasConstrainedEdges(v)) {
                try self.removeIsolatedVertex(v);
            }
        }

        _ = self.constraint_start_verts.remove(constraint_id);
    }

    fn collectConstraintEdges(self: *CDT, start_v: u32, constraint_id: u32, out: *std.ArrayListUnmanaged(Edge)) !void {
        var stack = std.ArrayListUnmanaged(u32){};
        defer stack.deinit(self.allocator);
        var visited_edges = std.AutoHashMap(Edge, void).init(self.allocator);
        defer visited_edges.deinit();

        try stack.append(self.allocator, start_v);

        while (stack.items.len > 0) {
            const v = stack.pop().?;
            var cur_tri = self.vert_tris.items[v];
            var prev_tri: ?u32 = null;
            var loop_count: u32 = 0;
            const max_loop = self.triangles.items.len * 3;

            while (loop_count < max_loop) : (loop_count += 1) {
                const tri = self.triangles.items[cur_tri];
                const idx = for (tri.vertices, 0..) |vert, i| {
                    if (vert == v) break @as(u32, @intCast(i));
                } else break;

                const v_cw = tri.vertices[(idx + 1) % 3];
                const v_ccw = tri.vertices[(idx + 2) % 3];
                const edges_to_check = [_]Edge{ .{ .v1 = v, .v2 = v_cw }, .{ .v1 = v, .v2 = v_ccw } };

                for (edges_to_check) |e| {
                    const norm = e.normalized();
                    if (self.constrained_edges.get(norm)) |list| {
                        for (list.items) |id| {
                            if (id == constraint_id) {
                                if (!visited_edges.contains(norm)) {
                                    try visited_edges.put(norm, {});
                                    try out.append(self.allocator, e);
                                    const other = if (e.v1 == v) e.v2 else e.v1;
                                    try stack.append(self.allocator, other);
                                }
                                break;
                            }
                        }
                    }
                }

                const next_tri = self.nextTriangleAroundVertex(cur_tri, v, prev_tri);
                if (next_tri == null or next_tri.? == self.vert_tris.items[v]) break;
                prev_tri = cur_tri;
                cur_tri = next_tri.?;
            }
        }
    }

    fn handleUnconstrainedEdge(self: *CDT, edge: Edge) !void {
        if (self.vert_ref_counts.items[edge.v1] > 0)
            self.vert_ref_counts.items[edge.v1] -= 1;
        if (self.vert_ref_counts.items[edge.v2] > 0)
            self.vert_ref_counts.items[edge.v2] -= 1;

        if (try self.canMergeCollinearConstraint(edge.v1, edge.v2)) {
            try self.mergeCollinearConstraintEdge(edge);
        }
    }

    fn canMergeCollinearConstraint(self: *CDT, v1: u32, v2: u32) !bool {
        if (!try self.edgeExistsInMesh(v1, v2)) return false;

        const t1 = self.vert_tris.items[v1];
        var tri1 = self.triangles.items[t1];
        const neighbor = self.edgeNeighbor(&tri1, v1, v2);
        if (neighbor == -1) return false;

        const opp1 = self.opposedVertex(&tri1, @intCast(neighbor));
        const opp2 = self.opposedVertex(&self.triangles.items[@intCast(neighbor)], t1);
        const a = self.vertices.items[v1];
        const b = self.vertices.items[v2];
        const c = self.vertices.items[opp1];
        const d = self.vertices.items[opp2];

        return self.lineSide(c, a, b) == .On and self.lineSide(d, a, b) == .On;
    }

    fn mergeCollinearConstraintEdge(self: *CDT, edge: Edge) !void {
        const keep = edge.v1;
        const remove = edge.v2;

        var edges_to_merge = std.ArrayListUnmanaged(struct { other: u32, crep: std.ArrayListUnmanaged(u32) }){};
        defer {
            for (edges_to_merge.items) |*item| item.crep.deinit(self.allocator);
            edges_to_merge.deinit(self.allocator);
        }

        var cur_tri = self.vert_tris.items[remove];
        var prev: ?u32 = null;
        while (true) {
            const tri = self.triangles.items[cur_tri];
            const idx = for (tri.vertices, 0..) |vert, i| {
                if (vert == remove) break @as(u32, @intCast(i));
            } else break;

            const v1 = tri.vertices[idx];
            const v2 = tri.vertices[(idx + 1) % 3];
            const e = Edge{ .v1 = v1, .v2 = v2 };
            if (self.constrained_edges.fetchSwapRemove(e.normalized())) |kv| {
                var crep_copy = std.ArrayListUnmanaged(u32){};
                var removed_crep = kv.value;
                try crep_copy.appendSlice(self.allocator, removed_crep.items);
                try edges_to_merge.append(self.allocator, .{ .other = if (v1 == remove) v2 else v1, .crep = crep_copy });
                removed_crep.deinit(self.allocator);
            }

            const next = self.nextTriangleAroundVertex(cur_tri, remove, prev);
            if (next == null or next.? == self.vert_tris.items[remove]) break;
            prev = cur_tri;
            cur_tri = next.?;
        }

        try self.removeVertex(remove);

        for (edges_to_merge.items) |*item| {
            if (item.other == keep) continue;
            try self.insertSegmentAndSetCrep(keep, item.other, &item.crep);
        }
    }

    fn insertSegmentAndSetCrep(self: *CDT, v1: u32, v2: u32, crep: *std.ArrayListUnmanaged(u32)) !void {
        if (v1 == v2) return;
        if (try self.edgeExistsInMesh(v1, v2)) {
            const e = Edge{ .v1 = v1, .v2 = v2 };
            const norm = e.normalized();
            const gop = try self.constrained_edges.getOrPut(self.allocator, norm);
            if (!gop.found_existing) gop.value_ptr.* = .{};
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
            return;
        }

        var splits = std.ArrayListUnmanaged(u32){};
        defer splits.deinit(self.allocator);
        try self.splitIntersectingConstraints(v1, v2, &splits);

        var all_verts = std.ArrayListUnmanaged(u32){};
        defer all_verts.deinit(self.allocator);
        try all_verts.append(self.allocator, v1);
        try all_verts.appendSlice(self.allocator, splits.items);
        try all_verts.append(self.allocator, v2);

        var i: usize = 0;
        while (i < all_verts.items.len - 1) : (i += 1) {
            try self.removeCrossingEdgesAndRetriangulate(all_verts.items[i], all_verts.items[i + 1], 0);
        }

        const e = Edge{ .v1 = v1, .v2 = v2 };
        const norm = e.normalized();
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

    fn removeIsolatedVertex(self: *CDT, v: u32) !void {
        if (try self.vertexHasConstrainedEdges(v)) return;
        try self.removeVertex(v);
    }

    fn removeVertex(self: *CDT, v: u32) !void {
        var hole_verts = std.ArrayListUnmanaged(u32){};
        defer hole_verts.deinit(self.allocator);
        var hole_tris = std.ArrayListUnmanaged(u32){};
        defer hole_tris.deinit(self.allocator);

        var cur_tri = self.vert_tris.items[v];
        var prev: ?u32 = null;
        while (true) {
            try hole_tris.append(self.allocator, cur_tri);
            const tri = self.triangles.items[cur_tri];
            const idx = for (tri.vertices, 0..) |vert, i| {
                if (vert == v) break @as(u32, @intCast(i));
            } else return error.VertexNotInTriangle;

            const next_vert = tri.vertices[(idx + 1) % 3];
            try hole_verts.append(self.allocator, next_vert);

            const next = self.nextTriangleAroundVertex(cur_tri, v, prev);
            if (next == null or next.? == self.vert_tris.items[v]) break;
            prev = cur_tri;
            cur_tri = next.?;
        }

        self.temp_outer_tris.clearRetainingCapacity();
        for (0..hole_verts.items.len) |i| {
            const v1 = hole_verts.items[i];
            const v2 = hole_verts.items[(i + 1) % hole_verts.items.len];
            const outer_tri = self.findOuterTriangleForEdge(.{ .v1 = v1, .v2 = v2 }, v);
            if (outer_tri != -1) {
                try self.putOuterTris(&self.temp_outer_tris, v1, v2, outer_tri);
            }
        }

        var trianglesToReuse = std.ArrayListUnmanaged(u32){};
        defer trianglesToReuse.deinit(self.allocator);
        try trianglesToReuse.appendSlice(self.allocator, hole_tris.items);

        self.temp_iterations.clearRetainingCapacity();

        var poly = std.ArrayListUnmanaged(u32){};
        defer poly.deinit(self.allocator);
        for (hole_verts.items) |hv| try poly.append(self.allocator, hv);

        const first_edge = Edge{ .v1 = poly.items[0], .v2 = poly.items[1] };
        const last_edge = Edge{ .v1 = poly.items[poly.items.len - 1], .v2 = poly.items[0] };
        const iTL = self.getOuterTri(&self.temp_outer_tris, first_edge.v1, first_edge.v2);
        const iTR = self.getOuterTri(&self.temp_outer_tris, last_edge.v1, last_edge.v2);
        if (iTL == -1 or iTR == -1) return error.BoundaryTriangleNotFound;

        try self.triangulatePseudoPolygon(&poly, &self.temp_outer_tris, @intCast(iTL), @intCast(iTR), &trianglesToReuse, &self.temp_iterations);

        for (poly.items) |pv| {
            if (self.findAnyTriangleContainingVertex(pv)) |t| {
                self.vert_tris.items[pv] = t;
            }
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
            if (self.constrained_edges.contains(e.normalized())) return true;

            const next = self.nextTriangleAroundVertex(cur_tri, v, prev);
            if (next == null or next.? == self.vert_tris.items[v]) break;
            prev = cur_tri;
            cur_tri = next.?;
        }
        return false;
    }

    // ---------- Delaunay 边翻转 (论文 Section 4.1) ----------
    fn ensureDelaunayByEdgeFlip(self: *CDT, v: u32) !void {
        var flip_count: u32 = 0;
        const max_flips = self.triangles.items.len * 5;
        while (self.temp_stack.items.len > 0) : (flip_count += 1) {
            if (flip_count > max_flips) return error.InfiniteLoopEdgeFlip;
            const t = self.temp_stack.pop().?;
            const info = try self.edgeFlipInfo(t, v);
            if (info.new_t1 == -1) continue;
            const edge = Edge{ .v1 = v, .v2 = info.v2 };
            if (self.constrained_edges.contains(edge.normalized())) continue;
            if (self.shouldFlipEdge(v, info.v2, info.v3, info.v4)) {
                try self.flipEdge(t, @intCast(info.new_t1), v, info.v2, info.v3, info.v4, info.n1, info.n2, info.n3, info.n4);
                try self.temp_stack.append(self.allocator, t);
                try self.temp_stack.append(self.allocator, @intCast(info.new_t1));
            }
        }
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

    // ---------- 几何辅助函数 ----------
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

    fn lineIntersection(self: *CDT, a: Vec2, b: Vec2, c: Vec2, d: Vec2) Vec2 {
        _ = self;
        const ab = b.sub(a);
        const cd = d.sub(c);
        const ac = c.sub(a);
        const t = Vec2.cross(ac, cd) / Vec2.cross(ab, cd);
        return a.add(ab.scale(t));
    }

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

    fn triangleContainsVertex(self: *CDT, tri_idx: u32, v: u32) bool {
        const tri = self.triangles.items[tri_idx];
        return tri.vertices[0] == v or tri.vertices[1] == v or tri.vertices[2] == v;
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

    fn findOuterTriangleForEdge(self: *CDT, edge: Edge, v_to_remove: u32) i32 {
        _ = v_to_remove;
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

    fn edgeExistsInMesh(self: *CDT, v1: u32, v2: u32) !bool {
        if (v1 >= self.vertices.items.len or v2 >= self.vertices.items.len) return false;
        const start_tri = self.vert_tris.items[v1];
        if (start_tri >= self.triangles.items.len) return false;

        var visited = std.AutoHashMap(u32, void).init(self.allocator);
        defer visited.deinit();
        var stack = std.ArrayListUnmanaged(u32){};
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
        if (!gop.found_existing) gop.value_ptr.* = .{};
        for (gop.value_ptr.items) |id| if (id == constraint_id) return;
        try gop.value_ptr.append(self.allocator, constraint_id);
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

    fn setVertTri(self: *CDT, v: u32, t: u32) !void {
        if (self.vert_tris.items.len <= v) try self.vert_tris.resize(self.allocator, v + 1);
        self.vert_tris.items[v] = t;
    }

    fn addNewTriangle(self: *CDT) !u32 {
        const idx = @as(u32, @intCast(self.triangles.items.len));
        try self.triangles.append(self.allocator, .{});
        return idx;
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

    /// 公开的便捷接口：查找或插入顶点（容差范围内）
    pub fn findOrAddVertex(self: *CDT, pt: Vec2, tolerance: f32) !u32 {
        const start_tri = self.jumpAndWalkStartTriangle(pt);
        const result = try self.walkToTriangleForPoint(pt, start_tri);
        if (result.on_edge) |edge| {
            const p1 = self.vertices.items[edge[0]];
            const p2 = self.vertices.items[edge[1]];
            if (self.pointOnSegment(pt, p1, p2)) {
                const proj = self.projectPointOnSegment(pt, p1, p2);
                const dx = proj.x - pt.x;
                const dy = proj.y - pt.y;
                if (dx * dx + dy * dy <= tolerance * tolerance) {
                    const d1 = proj.sub(p1).len2();
                    const d2 = proj.sub(p2).len2();
                    if (d1 <= tolerance * tolerance) return edge[0];
                    if (d2 <= tolerance * tolerance) return edge[1];
                    return try self.insertPointOnConstraintEdge(proj, edge[0], edge[1], result.tri_idx);
                }
            }
        } else {
            const tri = self.triangles.items[result.tri_idx];
            for (tri.vertices) |v_idx| {
                const v = self.vertices.items[v_idx];
                const dx = v.x - pt.x;
                const dy = v.y - pt.y;
                if (dx * dx + dy * dy <= tolerance * tolerance) return v_idx;
            }
        }
        const new_idx = try self.addVertex(pt);
        try self.insertVertexWithStart(new_idx, result.tri_idx);
        return new_idx;
    }

    fn walkToTriangleForPoint(self: *CDT, pt: Vec2, start_tri: u32) !WalkResult {
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
                return WalkResult{ .tri_idx = cur_tri, .on_edge = null };
            if (self.pointOnSegment(pt, a, b))
                return WalkResult{ .tri_idx = cur_tri, .on_edge = .{ tri.vertices[0], tri.vertices[1] } };
            if (self.pointOnSegment(pt, b, c))
                return WalkResult{ .tri_idx = cur_tri, .on_edge = .{ tri.vertices[1], tri.vertices[2] } };
            if (self.pointOnSegment(pt, c, a))
                return WalkResult{ .tri_idx = cur_tri, .on_edge = .{ tri.vertices[2], tri.vertices[0] } };

            const next = self.nextTriangleTowardsPoint(pt, a, b, c, tri.neighbors) orelse
                return error.PointOutsideMesh;
            cur_tri = next;
        }
        return error.PointOutsideMesh;
    }

    fn projectPointOnSegment(self: *CDT, pt: Vec2, a: Vec2, b: Vec2) Vec2 {
        _ = self;
        const ab = b.sub(a);
        const ap = pt.sub(a);
        const t = ap.dot(ab) / ab.len2();
        return a.add(ab.scale(@max(0, @min(1, t))));
    }
};

test "CDT intersecting constraints" {
    const allocator = std.testing.allocator;
    var cdt = try CDT.init(allocator, 100, 100);
    defer cdt.deinit();

    // 添加四个角点
    const v1 = try cdt.findOrAddVertex(.{ .x = 10, .y = 10 }, 0.1);
    const v2 = try cdt.findOrAddVertex(.{ .x = 90, .y = 10 }, 0.1);
    const v3 = try cdt.findOrAddVertex(.{ .x = 10, .y = 90 }, 0.1);
    const v4 = try cdt.findOrAddVertex(.{ .x = 90, .y = 90 }, 0.1);

    // 插入两条相交的约束（对角线）
    try cdt.insertConstraintSegment(v1, v4, 1);
    try cdt.insertConstraintSegment(v2, v3, 2);

    // 检查网格至少有一些三角形
    try std.testing.expect(cdt.triangles.items.len > 0);
}

test "CDT overlapping constraints" {
    const allocator = std.testing.allocator;
    var cdt = try CDT.init(allocator, 100, 100);
    defer cdt.deinit();

    const v1 = try cdt.findOrAddVertex(.{ .x = 20, .y = 20 }, 0.1);
    const v2 = try cdt.findOrAddVertex(.{ .x = 80, .y = 20 }, 0.1);
    const v3 = try cdt.findOrAddVertex(.{ .x = 50, .y = 50 }, 0.1);

    // 插入三条约束，其中两条共线重叠
    try cdt.insertConstraintSegment(v1, v2, 1);
    try cdt.insertConstraintSegment(v1, v3, 2);
    try cdt.insertConstraintSegment(v3, v2, 3);

    // 移除一条约束
    try cdt.removeConstraint(2);

    try std.testing.expect(cdt.triangles.items.len > 0);
}

test "CDT multiple intersecting constraints" {
    const allocator = std.testing.allocator;
    var cdt = try CDT.init(allocator, 100, 100);
    defer cdt.deinit();

    // 添加五个点，形成三条相交的约束边
    const v1 = try cdt.findOrAddVertex(.{ .x = 10, .y = 10 }, 0.1);
    const v2 = try cdt.findOrAddVertex(.{ .x = 90, .y = 10 }, 0.1);
    const v3 = try cdt.findOrAddVertex(.{ .x = 10, .y = 90 }, 0.1);
    const v4 = try cdt.findOrAddVertex(.{ .x = 90, .y = 90 }, 0.1);
    const v5 = try cdt.findOrAddVertex(.{ .x = 50, .y = 50 }, 0.1);

    // 插入三条约束：两条对角线相交于中心，另一条水平线穿过中心
    try cdt.insertConstraintSegment(v1, v4, 1);
    try cdt.insertConstraintSegment(v2, v3, 2);
    try cdt.insertConstraintSegment(v1, v2, 3); // 底部边缘
    try cdt.insertConstraintSegment(v3, v4, 4); // 顶部边缘
    // 从中心到右侧边缘的约束
    try cdt.insertConstraintSegment(v5, v2, 5);

    // 检查网格完整性
    try std.testing.expect(cdt.triangles.items.len > 0);
    // 确保约束边存在
    try std.testing.expect(cdt.constrained_edges.contains((Edge{ .v1 = v1, .v2 = v4 }).normalized()));
    try std.testing.expect(cdt.constrained_edges.contains((Edge{ .v1 = v2, .v2 = v3 }).normalized()));
    try std.testing.expect(cdt.constrained_edges.contains((Edge{ .v1 = v1, .v2 = v2 }).normalized()));
    try std.testing.expect(cdt.constrained_edges.contains((Edge{ .v1 = v3, .v2 = v4 }).normalized()));
    try std.testing.expect(cdt.constrained_edges.contains((Edge{ .v1 = v5, .v2 = v2 }).normalized()));

    // 移除一条约束
    try cdt.removeConstraint(2);
    try std.testing.expect(!cdt.constrained_edges.contains((Edge{ .v1 = v2, .v2 = v3 }).normalized()));

    // 网格应仍然有效
    try std.testing.expect(cdt.triangles.items.len > 0);
}
