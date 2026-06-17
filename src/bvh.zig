// bvh.zig — Dynamic AABB Tree (BVH) 宽相位碰撞检测与射线检测
// 参考: Box2D DynamicBVH (Erin Catto), Allen Chou Dynamic AABB Tree
//
// 使用说明:
//   1. 每 tick 开头 .clear()，然后 .insert() 全部实体
//   2. queryPairs() 获取可能碰撞的实体对（回调精筛）
//   3. 物理 tick 之间 .raycast() 检测射线命中（O(log n)）

const std = @import("std");
const Vec3 = @import("algebra.zig").Vec3;
const AABB = @import("aabb.zig").AABB;

/// 空节点索引
const NULL_NODE: i32 = -1;

/// BVH 树，管理一组动态实体的 AABB 层级
pub const Bvh = struct {
    nodes: std.ArrayListUnmanaged(Node),
    root: i32,
    /// 胖 AABB 的边距倍数：fat = aabb.expand(extent * margin_ratio)
    margin_ratio: f32,
    allocator: std.mem.Allocator,

    const Self = @This();

    pub const Node = struct {
        aabb: AABB,
        entity: u32,    // 叶子节点关联的实体 ID
        parent: i32,    // 父节点索引，-1 = 根或游离
        child1: i32,    // -1 = 叶子节点
        child2: i32,
        height: i32,    // 叶⼦高度为 0，内部节点 = max(child) + 1
        crossed: bool,  // queryPairs 临时标志，防重复交叉
    };

    pub fn init(allocator: std.mem.Allocator, margin_ratio: f32) Self {
        return .{
            .nodes = .empty,
            .root = NULL_NODE,
            .margin_ratio = margin_ratio,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Self) void {
        self.nodes.deinit(self.allocator);
    }

    /// 清空树，复用已分配的内存
    pub fn clear(self: *Self) void {
        self.nodes.clearRetainingCapacity();
        self.root = NULL_NODE;
    }

    /// 叶⼦树数量
    pub fn size(self: *const Self) usize {
        var count: usize = 0;
        for (self.nodes.items) |n| {
            if (n.child1 == NULL_NODE) count += 1;
        }
        return count;
    }

    // ─── 分配 / 释放节点 ───

    fn allocNode(self: *Self) !i32 {
        const idx = @as(i32, @intCast(self.nodes.items.len));
        try self.nodes.append(self.allocator, undefined);
        return idx;
    }

    fn freeNode(self: *Self, idx: i32) void {
        // 标记为非叶子，使 findLeaf 跳过（节点可被后续 allocNode 覆盖）
        self.nodes.items[@as(usize, @intCast(idx))].child1 = 0;
    }

    // ─── 创建胖 AABB ───

    fn fatAABB(self: *const Self, aabb: AABB) AABB {
        const sx = (aabb.max_x - aabb.min_x) * self.margin_ratio;
        const sy = (aabb.max_y - aabb.min_y) * self.margin_ratio;
        const sz = (aabb.max_z - aabb.min_z) * self.margin_ratio;
        const m = @max(sx, @max(sy, sz));
        const margin = @max(m, 0.1); // 最少 0.1 格
        return .{
            .min_x = aabb.min_x - margin,
            .max_x = aabb.max_x + margin,
            .min_y = aabb.min_y - margin,
            .max_y = aabb.max_y + margin,
            .min_z = aabb.min_z - margin,
            .max_z = aabb.max_z + margin,
        };
    }

    // ─── 插入 ───

    pub fn insert(self: *Self, entity: u32, aabb: AABB) !void {
        const leaf = try self.allocNode();
        const fat = self.fatAABB(aabb);
        self.nodes.items[@as(usize, @intCast(leaf))] = .{
            .aabb = fat,
            .entity = entity,
            .parent = NULL_NODE,
            .child1 = NULL_NODE,
            .child2 = NULL_NODE,
            .height = 0,
            .crossed = false,
        };

        if (self.root == NULL_NODE) {
            self.root = leaf;
            return;
        }

        // Stage 1: 找最佳兄弟节点
        const sibling = self.findBestSibling(leaf);

        // Stage 2: 创建新父节点
        const old_parent = self.nodes.items[@as(usize, @intCast(sibling))].parent;
        const new_parent = try self.allocNode();
        self.nodes.items[@as(usize, @intCast(new_parent))] = .{
            .aabb = unionAABB(self.nodes.items[@as(usize, @intCast(sibling))].aabb, fat),
            .entity = undefined,
            .parent = old_parent,
            .child1 = sibling,
            .child2 = leaf,
            .height = 0,
            .crossed = false,
        };
        self.nodes.items[@as(usize, @intCast(leaf))].parent = new_parent;
        self.nodes.items[@as(usize, @intCast(sibling))].parent = new_parent;

        if (old_parent != NULL_NODE) {
            const op = @as(usize, @intCast(old_parent));
            if (self.nodes.items[op].child1 == sibling) {
                self.nodes.items[op].child1 = new_parent;
            } else {
                self.nodes.items[op].child2 = new_parent;
            }
        } else {
            self.root = new_parent;
        }

        // Stage 3: 向上裁剪 AABB 并更新高度
        var idx = new_parent;
        while (idx != NULL_NODE) {
            self.syncNode(idx);
            idx = self.nodes.items[@as(usize, @intCast(idx))].parent;
        }
    }

    /// 从根向下找插入新叶子时的最佳兄弟（SAH 启发）
    fn findBestSibling(self: *const Self, leaf: i32) i32 {
        const leaf_aabb = self.nodes.items[@as(usize, @intCast(leaf))].aabb;

        var idx = self.root;
        while (self.nodes.items[@as(usize, @intCast(idx))].child1 != NULL_NODE) {
            const n = &self.nodes.items[@as(usize, @intCast(idx))];
            const child1 = n.child1;
            const child2 = n.child2;

            // 计算选择 child1 或 child2 的 SAH 代价
            const area1 = surfaceArea(self.nodes.items[@as(usize, @intCast(child1))].aabb);
            const area2 = surfaceArea(self.nodes.items[@as(usize, @intCast(child2))].aabb);
            const union1 = surfaceArea(unionAABB(self.nodes.items[@as(usize, @intCast(child1))].aabb, leaf_aabb));
            const union2 = surfaceArea(unionAABB(self.nodes.items[@as(usize, @intCast(child2))].aabb, leaf_aabb));

            const cost1 = union1 - area1;
            const cost2 = union2 - area2;

            // 选代价更小的分支
            if (cost1 < cost2) {
                idx = child1;
            } else {
                idx = child2;
            }
        }
        return idx;
    }

    // ─── 移除 ───

    pub fn remove(self: *Self, entity: u32) void {
        const leaf = self.findLeaf(entity) orelse return;
        self.removeLeaf(leaf);
    }

    fn findLeaf(self: *const Self, entity: u32) ?i32 {
        for (self.nodes.items, 0..) |n, i| {
            if (n.child1 == NULL_NODE and n.entity == entity) {
                return @as(i32, @intCast(i));
            }
        }
        return null;
    }

    fn removeLeaf(self: *Self, leaf: i32) void {
        if (leaf == self.root) {
            self.root = NULL_NODE;
            self.freeNode(leaf);
            return;
        }

        const parent = self.nodes.items[@as(usize, @intCast(leaf))].parent;
        const sibling = self.getSibling(leaf);
        const grandparent = self.nodes.items[@as(usize, @intCast(parent))].parent;

        if (grandparent != NULL_NODE) {
            const gp = @as(usize, @intCast(grandparent));
            if (self.nodes.items[gp].child1 == parent) {
                self.nodes.items[gp].child1 = sibling;
            } else {
                self.nodes.items[gp].child2 = sibling;
            }
            self.nodes.items[@as(usize, @intCast(sibling))].parent = grandparent;
        } else {
            self.root = sibling;
            self.nodes.items[@as(usize, @intCast(sibling))].parent = NULL_NODE;
        }

        self.freeNode(parent);
        self.freeNode(leaf);

        // 向上裁剪（仅内部节点需要）
        var idx = grandparent;
        while (idx != NULL_NODE) {
            self.syncNode(idx);
            idx = self.nodes.items[@as(usize, @intCast(idx))].parent;
        }
    }

    fn getSibling(self: *const Self, idx: i32) i32 {
        const p = self.nodes.items[@as(usize, @intCast(idx))].parent;
        const n = &self.nodes.items[@as(usize, @intCast(p))];
        return if (n.child1 == idx) n.child2 else n.child1;
    }

    // ─── 更新位置 ───

    pub fn update(self: *Self, entity: u32, new_aabb: AABB) !void {
        const leaf = self.findLeaf(entity) orelse {
            try self.insert(entity, new_aabb);
            return;
        };
        const fat = self.nodes.items[@as(usize, @intCast(leaf))].aabb;

        // 如果新 AABB 仍在胖 AABB 内，只更新 AABB + 向上裁剪
        if (containsAABB(fat, new_aabb)) {
            self.nodes.items[@as(usize, @intCast(leaf))].aabb = self.fatAABB(new_aabb);
            var idx = self.nodes.items[@as(usize, @intCast(leaf))].parent;
            while (idx != NULL_NODE) {
                self.syncNode(idx);
                idx = self.nodes.items[@as(usize, @intCast(idx))].parent;
            }
        } else {
            // 移出胖 AABB → remove + re-insert
            self.removeLeaf(leaf);
            try self.insert(entity, new_aabb);
        }
    }

    // ─── 查询所有可能碰撞对 ───

    /// 遍历 BVH，找出所有 AABB 重叠的实体对。
    /// ctx 为运行时上下文，callback 为编译期函数，签名 fn(ctx: C, a: u32, b: u32) void
    /// 先递归遍历所有内部节点，交叉检测其两个孩子的子树，
    /// 再逐一检测所有可能重叠的实体对。
    pub fn queryPairs(self: *Self, ctx: anytype, comptime callback: fn(@TypeOf(ctx), u32, u32) void) void {
        if (self.root == NULL_NODE) return;
        self.clearCrossFlags();
        // crossAll 递归遍历所有内部节点，自动交叉每个节点的两个孩子
        self.crossAll(ctx, callback, self.root);
    }

    fn clearCrossFlags(self: *Self) void {
        for (0..self.nodes.items.len) |i| {
            self.nodes.items[i].crossed = false;
        }
    }

    /// 递归遍历所有内部节点，交叉检测其两个孩子
    fn crossAll(self: *Self, ctx: anytype, comptime callback: fn(@TypeOf(ctx), u32, u32) void, node_idx: i32) void {
        const n = &self.nodes.items[@as(usize, @intCast(node_idx))];
        if (n.child1 == NULL_NODE or n.crossed) return;
        n.crossed = true;
        self.queryInternal(ctx, callback, n.child1, n.child2);
        self.crossAll(ctx, callback, n.child1);
        self.crossAll(ctx, callback, n.child2);
    }

    fn queryInternal(self: *Self, ctx: anytype, comptime callback: fn(@TypeOf(ctx), u32, u32) void, a: i32, b: i32) void {
        const na = &self.nodes.items[@as(usize, @intCast(a))];
        const nb = &self.nodes.items[@as(usize, @intCast(b))];
        if (!overlapAABB(na.aabb, nb.aabb)) return;

        if (na.child1 == NULL_NODE and nb.child1 == NULL_NODE) {
            callback(ctx, na.entity, nb.entity);
            return;
        }

        if (na.child1 == NULL_NODE) {
            self.queryInternal(ctx, callback, a, nb.child1);
            self.queryInternal(ctx, callback, a, nb.child2);
        } else if (nb.child1 == NULL_NODE) {
            self.queryInternal(ctx, callback, na.child1, b);
            self.queryInternal(ctx, callback, na.child2, b);
        } else {
            self.queryInternal(ctx, callback, na.child1, nb.child1);
            self.queryInternal(ctx, callback, na.child1, nb.child2);
            self.queryInternal(ctx, callback, na.child2, nb.child1);
            self.queryInternal(ctx, callback, na.child2, nb.child2);
        }
    }

    // ─── 工具 ───

    /// 同步节点的 AABB 和 height
    fn syncNode(self: *Self, idx: i32) void {
        const u = @as(usize, @intCast(idx));
        const c1 = @as(usize, @intCast(self.nodes.items[u].child1));
        const c2 = @as(usize, @intCast(self.nodes.items[u].child2));
        self.nodes.items[u].aabb = unionAABB(self.nodes.items[c1].aabb, self.nodes.items[c2].aabb);
        const h1 = self.nodes.items[c1].height;
        const h2 = self.nodes.items[c2].height;
        self.nodes.items[u].height = @max(h1, h2) + 1;
    }

    // ─── 射线检测 ───

    /// 遍历 BVH，找到射线命中的最近实体。
    /// ctx 为运行时上下文，callback 签名 fn(ctx, entity: u32, t: f32) bool
    /// callback 返回 true 表示已找到（停止继续搜索）
    pub fn raycast(self: *const Self, ctx: anytype, comptime callback: fn(@TypeOf(ctx), u32, f32) bool, origin: Vec3, dir: Vec3) void {
        if (self.root == NULL_NODE) return;
        self.raycastNode(ctx, callback, self.root, origin, dir);
    }

    fn raycastNode(self: *const Self, ctx: anytype, comptime callback: fn(@TypeOf(ctx), u32, f32) bool, node_idx: i32, origin: Vec3, dir: Vec3) void {
        const n = &self.nodes.items[@as(usize, @intCast(node_idx))];
        const t = rayAABB(n.aabb, origin, dir);
        if (t == null or t.? < 0) return;

        if (n.child1 == NULL_NODE) {
            _ = callback(ctx, n.entity, t.?);
        } else {
            const c1_t = rayAABB(self.nodes.items[@as(usize, @intCast(n.child1))].aabb, origin, dir);
            const c2_t = rayAABB(self.nodes.items[@as(usize, @intCast(n.child2))].aabb, origin, dir);
            if (c1_t != null and c2_t != null) {
                if (c1_t.? < c2_t.?) {
                    self.raycastNode(ctx, callback, n.child1, origin, dir);
                    self.raycastNode(ctx, callback, n.child2, origin, dir);
                } else {
                    self.raycastNode(ctx, callback, n.child2, origin, dir);
                    self.raycastNode(ctx, callback, n.child1, origin, dir);
                }
            } else if (c1_t != null) {
                self.raycastNode(ctx, callback, n.child1, origin, dir);
            } else if (c2_t != null) {
                self.raycastNode(ctx, callback, n.child2, origin, dir);
            }
        }
    }
};

// ─── 全局 AABB 工具函数 ───

/// AABB 合并
fn unionAABB(a: AABB, b: AABB) AABB {
    return .{
        .min_x = @min(a.min_x, b.min_x),
        .max_x = @max(a.max_x, b.max_x),
        .min_y = @min(a.min_y, b.min_y),
        .max_y = @max(a.max_y, b.max_y),
        .min_z = @min(a.min_z, b.min_z),
        .max_z = @max(a.max_z, b.max_z),
    };
}

/// AABB 表面积（用对角线长度的平方代替，省 sqrt）
fn surfaceArea(a: AABB) f32 {
    const dx = a.max_x - a.min_x;
    const dy = a.max_y - a.min_y;
    const dz = a.max_z - a.min_z;
    // 表面积 = 2*(dx*dy + dy*dz + dz*dx)，但用于比较时去掉 2 不影响
    return dx * dy + dy * dz + dz * dx;
}

/// AABB 重叠检测
fn overlapAABB(a: AABB, b: AABB) bool {
    return a.min_x < b.max_x and a.max_x > b.min_x and
        a.min_y < b.max_y and a.max_y > b.min_y and
        a.min_z < b.max_z and a.max_z > b.min_z;
}

/// 检测 container 是否完全包含 contained
fn containsAABB(container: AABB, contained: AABB) bool {
    return container.min_x <= contained.min_x and
        container.max_x >= contained.max_x and
        container.min_y <= contained.min_y and
        container.max_y >= contained.max_y and
        container.min_z <= contained.min_z and
        container.max_z >= contained.max_z;
}

/// 射线-AABB 相交检测（slab 法）。返回 t 值，null=不相交
fn rayAABB(aabb: AABB, origin: Vec3, dir: Vec3) ?f32 {
    const tx1 = (aabb.min_x - origin.x) / dir.x;
    const tx2 = (aabb.max_x - origin.x) / dir.x;
    var tmin = @min(tx1, tx2);
    var tmax = @max(tx1, tx2);

    const ty1 = (aabb.min_y - origin.y) / dir.y;
    const ty2 = (aabb.max_y - origin.y) / dir.y;
    tmin = @max(tmin, @min(ty1, ty2));
    tmax = @min(tmax, @max(ty1, ty2));

    const tz1 = (aabb.min_z - origin.z) / dir.z;
    const tz2 = (aabb.max_z - origin.z) / dir.z;
    tmin = @max(tmin, @min(tz1, tz2));
    tmax = @min(tmax, @max(tz1, tz2));

    if (tmax >= tmin and tmax >= 0) return @max(tmin, 0);
    return null;
}

// ─── 测试 ───
// 在 `zig build test` 下编译，主程序 import 时排除

const PairSet = std.AutoHashMap(u64, void);

fn fatAABB(a: AABB, margin: f32) AABB {
    return .{
        .min_x = a.min_x - margin,
        .max_x = a.max_x + margin,
        .min_y = a.min_y - margin,
        .max_y = a.max_y + margin,
        .min_z = a.min_z - margin,
        .max_z = a.max_z + margin,
    };
}

fn collectBvhPairs(bvh: *Bvh, allocator: std.mem.Allocator) !PairSet {
    var pairs = PairSet.init(allocator);
    const Ctx = struct {
        pairs: *PairSet,
        fn callback(ctx: @This(), a: u32, b: u32) void {
            const key = if (a < b) (@as(u64, a) << 32) | b else (@as(u64, b) << 32) | a;
            ctx.pairs.put(key, {}) catch {};
        }
    };
    bvh.queryPairs(Ctx{ .pairs = &pairs }, Ctx.callback);
    return pairs;
}

fn collectBruteFatPairs(entities: []const u32, aabbs: []const AABB, margin: f32, allocator: std.mem.Allocator) !PairSet {
    var pairs = PairSet.init(allocator);
    for (0..entities.len) |i| {
        const fi = fatAABB(aabbs[i], margin);
        for (i + 1..entities.len) |j| {
            const fj = fatAABB(aabbs[j], margin);
            if (overlapAABB(fi, fj)) {
                const key = (@as(u64, entities[i]) << 32) | entities[j];
                try pairs.put(key, {});
            }
        }
    }
    return pairs;
}

fn verifyMatch(bvh_pairs: *PairSet, brute_pairs: *PairSet) !void {
    var it = brute_pairs.keyIterator();
    while (it.next()) |key| {
        if (!bvh_pairs.contains(key.*)) {
            std.debug.print("\n  BVH 漏报一对 {}\n", .{key.*});
            return error.TestUnexpectedResult;
        }
    }
}

fn runOneTest(count: usize, area: f32, margin: f32, label: []const u8) !void {
    const allocator = std.testing.allocator;
    var bvh = Bvh.init(allocator, margin);
    defer bvh.deinit();

    var rng = std.Random.DefaultPrng.init(@as(u64, @intCast(count * 12345)));
    const rand = rng.random();
    var entities = try allocator.alloc(u32, count);
    defer allocator.free(entities);
    var aabbs = try allocator.alloc(AABB, count);
    defer allocator.free(aabbs);

    for (0..count) |i| {
        entities[i] = @as(u32, @intCast(i + 1));
        const x = rand.float(f32) * area;
        const z = rand.float(f32) * area;
        aabbs[i] = .{
            .min_x = x - 0.3,
            .max_x = x + 0.3,
            .min_y = 50,
            .max_y = 51.8,
            .min_z = z - 0.3,
            .max_z = z + 0.3,
        };
        try bvh.insert(entities[i], aabbs[i]);
    }

    var bvh_pairs = try collectBvhPairs(&bvh, allocator);
    defer bvh_pairs.deinit();
    var brute_pairs = try collectBruteFatPairs(entities, aabbs, margin, allocator);
    defer brute_pairs.deinit();
    try verifyMatch(&bvh_pairs, &brute_pairs);

    std.debug.print("  {s} ({d} 个, {d:.0}×{d:.0} 区域, margin={d:.1}): {d} 对 ✓\n", .{ label, count, area, area, margin, bvh_pairs.count() });
}

fn runDenseTest(count: usize, label: []const u8) !void {
    const allocator = std.testing.allocator;
    var bvh = Bvh.init(allocator, 0.5);
    defer bvh.deinit();

    var entities = try allocator.alloc(u32, count);
    defer allocator.free(entities);
    var aabbs = try allocator.alloc(AABB, count);
    defer allocator.free(aabbs);

    for (0..count) |i| {
        entities[i] = @as(u32, @intCast(i + 1));
        const x = @as(f32, @floatFromInt(i % 4)) * 0.6;
        const z = @as(f32, @floatFromInt(i / 4)) * 0.6;
        aabbs[i] = .{
            .min_x = x,
            .max_x = x + 0.6,
            .min_y = 50,
            .max_y = 51.8,
            .min_z = z,
            .max_z = z + 0.6,
        };
        try bvh.insert(entities[i], aabbs[i]);
    }

    var bvh_pairs = try collectBvhPairs(&bvh, allocator);
    defer bvh_pairs.deinit();
    var brute_pairs = try collectBruteFatPairs(entities, aabbs, 0.5, allocator);
    defer brute_pairs.deinit();
    try verifyMatch(&bvh_pairs, &brute_pairs);

    std.debug.print("  {s} ({d} 个挤在 2×2): {d} 对 ✓\n", .{ label, count, bvh_pairs.count() });
}

test "BVH sparse — 10 entities in 100×100" { try runOneTest(10, 100, 0.5, "稀疏"); }
test "BVH sparse — 50 entities in 100×100" { try runOneTest(50, 100, 0.5, "稀疏"); }
test "BVH sparse — 200 entities in 100×100" { try runOneTest(200, 100, 0.5, "稀疏"); }
test "BVH medium — 50 entities in 20×20" { try runOneTest(50, 20, 0.5, "中等"); }
test "BVH medium — 200 entities in 20×20" { try runOneTest(200, 20, 0.5, "中等"); }
test "BVH dense — 50 entities cluster" { try runDenseTest(50, "密集"); }
test "BVH dense — 200 entities cluster" { try runDenseTest(200, "密集"); }

test "BVH insert 2 overlapping" {
    var bvh = Bvh.init(std.heap.page_allocator, 0.5);
    defer bvh.deinit();
    try bvh.insert(1, AABB{ .min_x = 0, .max_x = 1, .min_y = 0, .max_y = 1, .min_z = 0, .max_z = 1 });
    var pair_count: u32 = 0;
    const Ctx = struct {
        count: *u32,
        fn callback(ctx: @This(), a: u32, b: u32) void { _ = a; _ = b; ctx.count.* += 1; }
    };
    bvh.queryPairs(Ctx{ .count = &pair_count }, Ctx.callback);
    try std.testing.expect(pair_count == 0);
    try bvh.insert(2, AABB{ .min_x = 0.5, .max_x = 1.5, .min_y = 0, .max_y = 1, .min_z = 0, .max_z = 1 });
    pair_count = 0;
    bvh.queryPairs(Ctx{ .count = &pair_count }, Ctx.callback);
    try std.testing.expect(pair_count == 1);
    std.debug.print("  2 个重叠实体: 1 对 ✓\n", .{});
}

test "BVH insert 2 non-overlapping" {
    var bvh = Bvh.init(std.heap.page_allocator, 0.5);
    defer bvh.deinit();
    try bvh.insert(1, AABB{ .min_x = 0, .max_x = 1, .min_y = 0, .max_y = 1, .min_z = 0, .max_z = 1 });
    try bvh.insert(2, AABB{ .min_x = 10, .max_x = 11, .min_y = 0, .max_y = 1, .min_z = 0, .max_z = 1 });
    var pair_count: u32 = 0;
    const Ctx = struct {
        count: *u32,
        fn callback(ctx: @This(), a: u32, b: u32) void { _ = a; _ = b; ctx.count.* += 1; }
    };
    bvh.queryPairs(Ctx{ .count = &pair_count }, Ctx.callback);
    try std.testing.expect(pair_count == 0);
    std.debug.print("  2 个分开实体: {d} 对 ✓\n", .{pair_count});
}

test "BVH update and re-insert" {
    var bvh = Bvh.init(std.heap.page_allocator, 0.5);
    defer bvh.deinit();
    try bvh.insert(1, AABB{ .min_x = 0, .max_x = 1, .min_y = 0, .max_y = 1, .min_z = 0, .max_z = 1 });
    try bvh.insert(2, AABB{ .min_x = 0.5, .max_x = 1.5, .min_y = 0, .max_y = 1, .min_z = 0, .max_z = 1 });
    var pair_count: u32 = 0;
    const Ctx = struct {
        count: *u32,
        fn callback(ctx: @This(), a: u32, b: u32) void { _ = a; _ = b; ctx.count.* += 1; }
    };
    try bvh.update(2, AABB{ .min_x = 100, .max_x = 101, .min_y = 0, .max_y = 1, .min_z = 0, .max_z = 1 });
    bvh.queryPairs(Ctx{ .count = &pair_count }, Ctx.callback);
    try std.testing.expect(pair_count == 0);
    try bvh.update(2, AABB{ .min_x = 0.5, .max_x = 1.5, .min_y = 0, .max_y = 1, .min_z = 0, .max_z = 1 });
    pair_count = 0;
    bvh.queryPairs(Ctx{ .count = &pair_count }, Ctx.callback);
    try std.testing.expect(pair_count == 1);
    try bvh.update(2, AABB{ .min_x = 0.6, .max_x = 1.6, .min_y = 0, .max_y = 1, .min_z = 0, .max_z = 1 });
    pair_count = 0;
    bvh.queryPairs(Ctx{ .count = &pair_count }, Ctx.callback);
    try std.testing.expect(pair_count == 1);
    std.debug.print("  update 各种情况测试通过 ✓\n", .{});
}
