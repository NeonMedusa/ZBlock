const std = @import("std");
const Imports = @import("imports.zig");
const Vec2 = Imports.Vec2;
const Vec3 = Imports.Vec3;
const Terrain = Imports.Terrain;
const Gctx = Imports.Gctx;
const RenderPipeline = Imports.RenderPipeline;

pub const RTSMap = struct {
    allocator: std.mem.Allocator,
    width: u32,
    height: u32,
    cells: []Cell,
    terrain: Terrain,

    pub const MAX_HEIGHT = 20;
    pub const MAX_LAYER = 10;
    pub const CELL_SIZE: f32 = 1.0;

    pub const Cell = struct {
        passable: bool = true,
        layer: u32 = 0,
        slope_mask: u4 = 0, // bit0:上, bit1:右, bit2:下, bit3:左
    };

    const DIR_UP = 0;
    const DIR_RIGHT = 1;
    const DIR_DOWN = 2;
    const DIR_LEFT = 3;
    const DIR_DX = [_]i32{ 0, 1, 0, -1 };
    const DIR_DZ = [_]i32{ -1, 0, 1, 0 };
    const OPPOSITE_DIR = [_]u4{ 2, 3, 0, 1 };

    // --- 初始化与销毁 ---
    pub fn init(allocator: std.mem.Allocator, gctx: *Gctx, width: u32, height: u32, pipeline: *RenderPipeline) !RTSMap {
        const terrain_size_x = @as(f32, @floatFromInt(width)) * CELL_SIZE;
        const terrain_size_z = @as(f32, @floatFromInt(height)) * CELL_SIZE;
        const segments = width * 4; // 每个格子4x4细分，可调
        const terrain = try Terrain.init(allocator, gctx, Vec3.zero, 0, terrain_size_x, terrain_size_z, segments, MAX_HEIGHT, pipeline);
        const cells = try allocator.alloc(Cell, width * height);
        for (cells) |*c| c.* = .{};
        return .{
            .allocator = allocator,
            .width = width,
            .height = height,
            .cells = cells,
            .terrain = terrain,
        };
    }

    pub fn deinit(self: *RTSMap) void {
        self.terrain.deinit();
        self.allocator.free(self.cells);
    }

    // --- 坐标转换 ---
    pub fn worldToCell(self: *RTSMap, world: Vec2) ?struct { x: u32, z: u32 } {
        const half_x = @as(f32, @floatFromInt(self.width)) * CELL_SIZE * 0.5;
        const half_z = @as(f32, @floatFromInt(self.height)) * CELL_SIZE * 0.5;
        const local_x = world.x + half_x;
        const local_z = world.z + half_z; // 注意：world.y 是世界 Z 轴
        if (local_x < 0 or local_z < 0) return null;
        const x = @as(u32, @intFromFloat(@floor(local_x / CELL_SIZE)));
        const z = @as(u32, @intFromFloat(@floor(local_z / CELL_SIZE)));
        if (x >= self.width or z >= self.height) return null;
        return .{ .x = x, .z = z };
    }

    pub fn cellToWorld(self: *RTSMap, x: u32, z: u32) Vec2 {
        const half_x = @as(f32, @floatFromInt(self.width)) * CELL_SIZE * 0.5;
        const half_z = @as(f32, @floatFromInt(self.height)) * CELL_SIZE * 0.5;
        const cx = -half_x + (@as(f32, @floatFromInt(x)) + 0.5) * CELL_SIZE;
        const cz = -half_z + (@as(f32, @floatFromInt(z)) + 0.5) * CELL_SIZE;
        return Vec2.new(cx, cz);
    }

    // --- 层级与高度转换 ---
    fn layerToHeight(layer: u32) f32 {
        const step = 1.0 / @as(f32, @floatFromInt(MAX_LAYER));
        return @as(f32, @floatFromInt(layer)) * step + step * 0.5;
    }

    // --- 地形视觉刷新 ---
    fn refreshCell(self: *RTSMap, cx: u32, cz: u32) void {
        const seg = self.terrain.segments;
        const seg_f = @as(f32, @floatFromInt(seg));
        const target = layerToHeight(self.cells[cz * self.width + cx].layer);
        const u_min = @as(f32, @floatFromInt(cx)) / @as(f32, @floatFromInt(self.width));
        const u_max = @as(f32, @floatFromInt(cx + 1)) / @as(f32, @floatFromInt(self.width));
        const v_min = @as(f32, @floatFromInt(cz)) / @as(f32, @floatFromInt(self.height));
        const v_max = @as(f32, @floatFromInt(cz + 1)) / @as(f32, @floatFromInt(self.height));
        for (0..seg + 1) |iz| {
            for (0..seg + 1) |ix| {
                const u = @as(f32, @floatFromInt(ix)) / seg_f;
                const v = @as(f32, @floatFromInt(iz)) / seg_f;
                if (u >= u_min and u <= u_max and v >= v_min and v <= v_max) {
                    const idx = iz * (seg + 1) + ix;
                    self.terrain.heights[idx] = target;
                }
            }
        }
    }

    fn refreshRect(self: *RTSMap, min_x: u32, min_z: u32, max_x: u32, max_z: u32) void {
        for (min_z..max_z + 1) |z| {
            for (min_x..max_x + 1) |x| {
                self.refreshCell(@intCast(x), @intCast(z));
            }
        }
    }

    // --- 逻辑层操作 ---
    pub fn setLayer(self: *RTSMap, center: Vec2, radius: f32, target_layer: u32) void {
        const cell_radius = @as(u32, @intFromFloat(@ceil(radius / CELL_SIZE)));
        const center_cell = self.worldToCell(center) orelse return;
        const min_x = if (center_cell.x >= cell_radius) center_cell.x - cell_radius else 0;
        const max_x = @min(center_cell.x + cell_radius, self.width - 1);
        const min_z = if (center_cell.z >= cell_radius) center_cell.z - cell_radius else 0;
        const max_z = @min(center_cell.z + cell_radius, self.height - 1);

        for (min_z..max_z + 1) |z| {
            for (min_x..max_x + 1) |x| {
                const world = self.cellToWorld(@intCast(x), @intCast(z));
                const dx = world.x - center.x;
                const dz = world.z - center.z;
                if (dx * dx + dz * dz <= radius * radius) {
                    self.cells[z * self.width + x].layer = target_layer;
                }
            }
        }
        // 清除斜坡
        for (min_z..max_z + 1) |z| {
            for (min_x..max_x + 1) |x| {
                const world = self.cellToWorld(@intCast(x), @intCast(z));
                const dx = world.x - center.x;
                const dz = world.z - center.z;
                if (dx * dx + dz * dz <= radius * radius) {
                    self.cells[z * self.width + x].slope_mask = 0;
                }
            }
        }
        self.refreshRect(min_x, min_z, max_x, max_z);
        self.terrain.calculateNormals();
        self.terrain.generateColors();
        self.terrain.updateBuffers() catch {};
    }

    pub fn markUnreachable(self: *RTSMap, center: Vec2, radius: f32) void {
        const cell_radius = @ceil(radius / CELL_SIZE);
        const center_cell = self.worldToCell(center) orelse return;
        const r = @as(usize, @intFromFloat(cell_radius));
        for (0..r) |dz| {
            for (0..r) |dx| {
                for (0..2) |sz| {
                    for (0..2) |sx| {
                        const z = if (sz == 0) center_cell.z - dz else center_cell.z + dz;
                        const x = if (sx == 0) center_cell.x - dx else center_cell.x + dx;
                        if (x < self.width and z < self.height) {
                            const world = self.cellToWorld(@intCast(x), @intCast(z));
                            const dxw = world.x - center.x;
                            const dzw = world.z - center.z;
                            if (dxw * dxw + dzw * dzw <= radius * radius) {
                                self.cells[z * self.width + x].passable = false;
                            }
                        }
                    }
                }
            }
        }
    }

    pub fn sculptAndBlock(self: *RTSMap, center: Vec2, radius: f32, strength: f32) void {
        self.terrain.modifyHeightWorld(center, radius, strength);
        self.markUnreachable(center, radius);
    }

    // --- 斜坡系统 ---
    fn setRampBetween(self: *RTSMap, x1: u32, z1: u32, x2: u32, z2: u32, dir_from_1: u4) void {
        const idx1 = z1 * self.width + x1;
        const idx2 = z2 * self.width + x2;
        self.cells[idx1].slope_mask |= @as(u4, 1) << @intCast(dir_from_1);
        self.cells[idx2].slope_mask |= @as(u4, 1) << @intCast(OPPOSITE_DIR[dir_from_1]);
    }

    fn applyVisualSlope(self: *RTSMap, a: struct { x: u32, z: u32 }, b: struct { x: u32, z: u32 }, h1: f32, h2: f32) void {
        const start = self.cellToWorld(a.x, a.z);
        const end = self.cellToWorld(b.x, b.z);
        const dx = end.x - start.x;
        const dz = end.z - start.z;
        const len = @sqrt(dx * dx + dz * dz);
        if (len < 0.001) return;
        const dir_x = dx / len;
        const dir_z = dz / len;
        const perp_x = -dir_z;
        const perp_z = dir_x;
        const half_width = CELL_SIZE * 1; // 斜坡宽度

        const seg = self.terrain.segments;
        const seg_f = @as(f32, @floatFromInt(seg));
        const size_x = self.terrain.size_x;
        const size_z = self.terrain.size_z;

        for (0..seg + 1) |iz| {
            for (0..seg + 1) |ix| {
                const u = @as(f32, @floatFromInt(ix)) / seg_f;
                const v = @as(f32, @floatFromInt(iz)) / seg_f;
                const wx = (u - 0.5) * size_x;
                const wz = (v - 0.5) * size_z;
                const dxw = wx - start.x;
                const dzw = wz - start.z;
                const t = dxw * dir_x + dzw * dir_z;
                const perp = @abs(dxw * perp_x + dzw * perp_z);
                if (perp < half_width and t >= 0 and t <= len) {
                    const blend = t / len;
                    const target = h1 + (h2 - h1) * blend;
                    const idx = iz * (seg + 1) + ix;
                    self.terrain.heights[idx] = target;
                }
            }
        }
    }

    pub fn createRampBrush(self: *RTSMap, center: Vec2, radius: f32) void {
        const cell_radius = @as(u32, @intFromFloat(@ceil(radius / CELL_SIZE)));
        const center_cell = self.worldToCell(center) orelse return;
        const min_x = if (center_cell.x >= cell_radius) center_cell.x - cell_radius else 0;
        const max_x = @min(center_cell.x + cell_radius, self.width - 1);
        const min_z = if (center_cell.z >= cell_radius) center_cell.z - cell_radius else 0;
        const max_z = @min(center_cell.z + cell_radius, self.height - 1);

        var affected = std.AutoHashMap(u32, void).init(self.allocator);
        defer affected.deinit();
        var ramps = std.ArrayList(struct { x1: u32, z1: u32, x2: u32, z2: u32, dir: u4 }){};
        defer ramps.deinit(self.allocator);

        for (min_z..max_z + 1) |z| {
            for (min_x..max_x + 1) |x| {
                const world = self.cellToWorld(@intCast(x), @intCast(z));
                const dx = world.x - center.x;
                const dz = world.z - center.z;
                if (dx * dx + dz * dz <= radius * radius) {
                    const cur_layer = self.cells[z * self.width + x].layer;
                    for (0..4) |dir| {
                        const nx = @as(i32, @intCast(x)) + DIR_DX[dir];
                        const nz = @as(i32, @intCast(z)) + DIR_DZ[dir];
                        if (nx >= 0 and nx < self.width and nz >= 0 and nz < self.height) {
                            const neigh_layer = self.cells[@as(usize, @intCast(nz)) * self.width + @as(usize, @intCast(nx))].layer;
                            if (neigh_layer != cur_layer) {
                                self.setRampBetween(@intCast(x), @intCast(z), @intCast(nx), @intCast(nz), @intCast(dir));
                                ramps.append(self.allocator, .{
                                    .x1 = @intCast(x),
                                    .z1 = @intCast(z),
                                    .x2 = @intCast(nx),
                                    .z2 = @intCast(nz),
                                    .dir = @intCast(dir),
                                }) catch unreachable;
                                affected.put(@as(u32, @intCast(z)) * self.width + @as(u32, @intCast(x)), {}) catch unreachable;
                                affected.put(@as(u32, @intCast(nz)) * self.width + @as(u32, @intCast(nx)), {}) catch unreachable;
                            }
                        }
                    }
                }
            }
        }

        var it = affected.iterator();
        while (it.next()) |entry| {
            const idx = entry.key_ptr.*;
            const x = idx % self.width;
            const z = idx / self.width;
            self.refreshCell(x, z);
        }

        for (ramps.items) |r| {
            const h1 = layerToHeight(self.cells[r.z1 * self.width + r.x1].layer);
            const h2 = layerToHeight(self.cells[r.z2 * self.width + r.x2].layer);
            self.applyVisualSlope(.{ .x = r.x1, .z = r.z1 }, .{ .x = r.x2, .z = r.z2 }, h1, h2);
        }

        self.terrain.calculateNormals();
        self.terrain.generateColors();
        self.terrain.updateBuffers() catch {};
    }

    // --- 寻路系统 ---
    const neighbors_4 = [_][2]i32{ .{ 0, -1 }, .{ 1, 0 }, .{ 0, 1 }, .{ -1, 0 } };

    fn heuristic(self: *RTSMap, a: usize, b: usize) f32 {
        const ax = @as(f32, @floatFromInt(a % self.width));
        const az = @as(f32, @floatFromInt(a / self.width));
        const bx = @as(f32, @floatFromInt(b % self.width));
        const bz = @as(f32, @floatFromInt(b / self.width));
        const dx = ax - bx;
        const dz = az - bz;
        return @sqrt(dx * dx + dz * dz);
    }

    fn getNeighbors(self: *RTSMap, idx: usize, alloc: std.mem.Allocator) ![]usize {
        const x = idx % self.width;
        const z = idx / self.width;
        var list = std.ArrayList(usize){};
        errdefer list.deinit(alloc);
        for (neighbors_4, 0..) |delta, dir| {
            const nx = @as(i32, @intCast(x)) + delta[0];
            const nz = @as(i32, @intCast(z)) + delta[1];
            if (nx >= 0 and nx < self.width and nz >= 0 and nz < self.height) {
                const nidx = @as(usize, @intCast(nz)) * self.width + @as(usize, @intCast(nx));
                if (!self.cells[nidx].passable) continue;
                const cur_layer = self.cells[idx].layer;
                const neigh_layer = self.cells[nidx].layer;
                if (cur_layer == neigh_layer) {
                    try list.append(alloc, nidx);
                } else {
                    const mask = @as(u4, 1) << @intCast(dir);
                    if ((self.cells[idx].slope_mask & mask) != 0) {
                        try list.append(alloc, nidx);
                    }
                }
            }
        }
        return list.toOwnedSlice(alloc);
    }

    fn reconstructPath(self: *RTSMap, came_from: std.AutoHashMap(u32, u32), start_idx: u32, goal_idx: u32, alloc: std.mem.Allocator) ![]Vec2 {
        var path = std.ArrayList(Vec2){};
        defer {
            if (path.items.len == 0) path.deinit(alloc);
        }
        var idx = goal_idx;
        while (came_from.get(idx)) |parent| {
            const world = self.cellToWorld(@intCast(idx % self.width), @intCast(idx / self.width));
            try path.append(alloc, world);
            idx = parent;
        }
        // 添加起点
        const start_world = self.cellToWorld(@intCast(start_idx % self.width), @intCast(start_idx / self.width));
        try path.append(alloc, start_world);
        // 反转
        var rev = std.ArrayList(Vec2){};
        for (path.items) |p| try rev.insert(alloc, 0, p);
        path.deinit(alloc);
        return rev.toOwnedSlice(alloc);
    }

    pub fn findPath(self: *RTSMap, start: Vec2, goal: Vec2, alloc: std.mem.Allocator) ![]Vec2 {
        const start_cell = self.worldToCell(start) orelse return error.OutOfBounds;
        const goal_cell = self.worldToCell(goal) orelse return error.OutOfBounds;
        const start_idx = start_cell.z * self.width + start_cell.x;
        const goal_idx = goal_cell.z * self.width + goal_cell.x;
        if (!self.cells[start_idx].passable or !self.cells[goal_idx].passable) return error.Unreachable;

        var open_set = PriorityQueue.init(alloc);
        defer open_set.deinit();
        var closed_set = std.AutoHashMap(u32, void).init(alloc);
        defer closed_set.deinit();
        var came_from = std.AutoHashMap(u32, u32).init(alloc);
        defer came_from.deinit();
        var g_score = std.AutoHashMap(u32, f32).init(alloc);
        defer g_score.deinit();

        try g_score.put(start_idx, 0);
        try open_set.push(PathNode{ .index = start_idx, .g = 0, .h = self.heuristic(start_idx, goal_idx), .parent = null });

        while (open_set.pop()) |current| {
            if (current.index == goal_idx) {
                return self.reconstructPath(came_from, start_idx, goal_idx, alloc);
            }
            try closed_set.put(current.index, {});
            const neighbors = try self.getNeighbors(current.index, alloc);
            defer alloc.free(neighbors);
            for (neighbors) |n| {
                const nb = @as(u32, @intCast(n));
                if (closed_set.contains(nb)) continue;
                const tentative = current.g + self.cellDistance(current.index, nb);
                const cur_g = g_score.get(nb) orelse std.math.floatMax(f32);
                if (tentative < cur_g) {
                    try came_from.put(nb, current.index);
                    try g_score.put(nb, tentative);
                    const h = self.heuristic(nb, goal_idx);
                    const node = PathNode{ .index = nb, .g = tentative, .h = h, .parent = current.index };
                    if (open_set.contains(nb)) {
                        open_set.update(node);
                    } else {
                        try open_set.push(node);
                    }
                }
            }
        }
        return error.NoPath;
    }

    pub fn findPathOrClosest(self: *RTSMap, start: Vec2, goal: Vec2, alloc: std.mem.Allocator) ![]Vec2 {
        return self.findPath(start, goal, alloc) catch |err| {
            if (err == error.Unreachable or err == error.NoPath) {
                const goal_cell = self.worldToCell(goal) orelse return error.OutOfBounds;
                var queue = std.ArrayList([2]u32){};
                defer queue.deinit(alloc);
                var visited = std.AutoHashMap(u32, void).init(alloc);
                defer visited.deinit();
                try queue.append(alloc, [2]u32{ goal_cell.x, goal_cell.z });
                while (queue.items.len > 0) {
                    const cell = queue.orderedRemove(0);
                    const idx = cell[1] * self.width + cell[0];
                    if (self.cells[idx].passable) {
                        const nearest = self.cellToWorld(cell[0], cell[1]);
                        return self.findPath(start, nearest, alloc);
                    }
                    for (neighbors_4) |delta| {
                        const nx = @as(i32, @intCast(cell[0])) + delta[0];
                        const nz = @as(i32, @intCast(cell[1])) + delta[1];
                        if (nx >= 0 and nx < self.width and nz >= 0 and nz < self.height) {
                            const nidx = @as(u32, @intCast(nz)) * self.width + @as(u32, @intCast(nx));
                            if (!visited.contains(nidx)) {
                                try visited.put(nidx, {});
                                try queue.append(alloc, [2]u32{ @intCast(nx), @intCast(nz) });
                            }
                        }
                    }
                }
                return error.NoReachableCell;
            }
            return err;
        };
    }

    fn cellDistance(self: *RTSMap, a: usize, b: usize) f32 {
        const ax = @as(f32, @floatFromInt(a % self.width));
        const az = @as(f32, @floatFromInt(a / self.width));
        const bx = @as(f32, @floatFromInt(b % self.width));
        const bz = @as(f32, @floatFromInt(b / self.width));
        const dx = ax - bx;
        const dz = az - bz;
        return @sqrt(dx * dx + dz * dz) * CELL_SIZE;
    }
};

// --- 辅助结构 ---
const PathNode = struct {
    index: u32,
    g: f32,
    h: f32,
    parent: ?u32,
};

const PriorityQueue = struct {
    items: std.ArrayList(PathNode),
    allocator: std.mem.Allocator,

    fn init(alloc: std.mem.Allocator) PriorityQueue {
        return .{ .items = std.ArrayList(PathNode){}, .allocator = alloc };
    }
    fn deinit(self: *PriorityQueue) void {
        self.items.deinit(self.allocator);
    }
    fn push(self: *PriorityQueue, node: PathNode) !void {
        try self.items.append(self.allocator, node);
        var i = self.items.items.len - 1;
        while (i > 0) {
            const p = (i - 1) / 2;
            if (self.items.items[p].g + self.items.items[p].h <= node.g + node.h) break;
            const tmp = self.items.items[p];
            self.items.items[p] = self.items.items[i];
            self.items.items[i] = tmp;
            i = p;
        }
    }
    fn pop(self: *PriorityQueue) ?PathNode {
        if (self.items.items.len == 0) return null;
        const ret = self.items.items[0];
        self.items.items[0] = self.items.items[self.items.items.len - 1];
        _ = self.items.pop();
        var i: usize = 0;
        const len = self.items.items.len;
        while (true) {
            const left = i * 2 + 1;
            const right = i * 2 + 2;
            var smallest = i;
            if (left < len and (self.items.items[left].g + self.items.items[left].h) < (self.items.items[smallest].g + self.items.items[smallest].h)) smallest = left;
            if (right < len and (self.items.items[right].g + self.items.items[right].h) < (self.items.items[smallest].g + self.items.items[smallest].h)) smallest = right;
            if (smallest == i) break;
            const tmp = self.items.items[i];
            self.items.items[i] = self.items.items[smallest];
            self.items.items[smallest] = tmp;
            i = smallest;
        }
        return ret;
    }
    fn contains(self: *PriorityQueue, idx: u32) bool {
        for (self.items.items) |n| if (n.index == idx) return true;
        return false;
    }
    fn update(self: *PriorityQueue, node: PathNode) void {
        for (self.items.items, 0..) |*n, i| {
            if (n.index == node.index) {
                n.* = node;
                var j = i;
                while (j > 0) {
                    const p = (j - 1) / 2;
                    if (self.items.items[p].g + self.items.items[p].h <= node.g + node.h) break;
                    const tmp = self.items.items[p];
                    self.items.items[p] = self.items.items[j];
                    self.items.items[j] = tmp;
                    j = p;
                }
                break;
            }
        }
    }
};
