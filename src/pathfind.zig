// pathfind.zig — 三维 A* 寻路
// 优化：8 方向 + 高度感知 + 步进/跌落检查
const std = @import("std");
const Vec2 = @import("algebra.zig").Vec2;
const Vec3 = @import("algebra.zig").Vec3;
const Vec3i = @import("algebra.zig").Vec3i;
const BlockWorld = @import("block_world.zig").BlockWorld;
const CHUNK_SIZE_Y = @import("block_world.zig").CHUNK_SIZE_Y;

const G_CARDINAL = 10;
const G_DIAGONAL = 14;
const H_MULT = 10;
const H_HEIGHT_MULT = 15; // 高度差的额外权重，倾向于保持同高度

pub const GridPos = struct {
    x: i32,
    z: i32,

    pub fn eql(a: GridPos, b: GridPos) bool {
        return a.x == b.x and a.z == b.z;
    }
};

/// 检查脚底 Y 处是否可站立：脚底和头顶（+1,+2）都是非固体
fn isSolidAt(world: *BlockWorld, x: i32, y: i32, z: i32) bool {
    return world.getBlockAt(Vec3.new(@as(f32, @floatFromInt(x)) + 0.5, @as(f32, @floatFromInt(y)) + 0.5, @as(f32, @floatFromInt(z)) + 0.5)).prototype().is_solid;
}

pub fn reachableFootY(world: *BlockWorld, x: i32, z: i32, from_foot_y: i32) ?i32 {
    // 1. 目标列有实体方块 → 直接站在它上面（如果头顶没有被阻挡）
    for ([_]i32{ 0, -1, 1 }) |dy| {
        const fy = from_foot_y + dy;
        if (fy <= 0 or fy + 2 >= CHUNK_SIZE_Y) continue;
        const block = world.getBlockAt(Vec3.new(@as(f32, @floatFromInt(x)) + 0.5, @as(f32, @floatFromInt(fy)) + 0.5, @as(f32, @floatFromInt(z)) + 0.5));
        if (block.prototype().is_solid) {
            // 脚底站这个方块上方
            const foot = fy + 1;
            if (foot + 2 >= CHUNK_SIZE_Y) continue;
            if (!isSolidAt(world, x, foot, z) and !isSolidAt(world, x, foot + 1, z)) {
                // 检查落差：不能超过 1 格高差
                const diff = foot - from_foot_y;
                if (diff >= -3 and diff <= 1) return foot;
            }
        }
    }

    // 2. 目标列没有实体方块 → 向下寻找地面
    var fy = from_foot_y;
    while (fy > 0) : (fy -= 1) {
        if (isSolidAt(world, x, fy, z)) {
            const foot = fy + 1;
            if (foot + 2 >= CHUNK_SIZE_Y) break;
            if (!isSolidAt(world, x, foot, z) and !isSolidAt(world, x, foot + 1, z)) {
                const diff = foot - from_foot_y;
                if (diff >= -3 and diff <= 1) return foot;
            }
            break;
        }
    }

    // 3. 向上找阶梯地面
    fy = from_foot_y;
    while (fy + 2 < CHUNK_SIZE_Y) : (fy += 1) {
        if (isSolidAt(world, x, fy, z)) {
            const foot = fy + 1;
            if (foot + 2 >= CHUNK_SIZE_Y) break;
            if (!isSolidAt(world, x, foot, z) and !isSolidAt(world, x, foot + 1, z)) {
                const diff = foot - from_foot_y;
                if (diff <= 1) return foot;
            }
        }
    }

    return null;
}

pub const Node = struct {
    g: i32,
    foot_y: i32,
    parent: ?GridPos,
};

const DIRS = [_]struct { dx: i32, dz: i32, cost: i32 }{
    .{ .dx = 1, .dz = 0, .cost = G_CARDINAL },
    .{ .dx = -1, .dz = 0, .cost = G_CARDINAL },
    .{ .dx = 0, .dz = 1, .cost = G_CARDINAL },
    .{ .dx = 0, .dz = -1, .cost = G_CARDINAL },
    .{ .dx = 1, .dz = 1, .cost = G_DIAGONAL },
    .{ .dx = 1, .dz = -1, .cost = G_DIAGONAL },
    .{ .dx = -1, .dz = 1, .cost = G_DIAGONAL },
    .{ .dx = -1, .dz = -1, .cost = G_DIAGONAL },
};

fn heuristic(dx: i32, dz: i32, h_diff: i32) i32 {
    const manhattan: i32 = (@as(i32, @intCast(@abs(dx))) + @as(i32, @intCast(@abs(dz)))) * H_MULT;
    const h_pen: i32 = @as(i32, @intCast(@abs(h_diff))) * H_HEIGHT_MULT;
    return manhattan + h_pen;
}

pub const AStarResult = enum { pending, found, failed };

pub const AStarState = struct {
    allocator: std.mem.Allocator,
    start: GridPos,
    end: GridPos,
    start_y: i32,
    end_y: i32,
    open_set: std.ArrayListUnmanaged(GridPos),
    nodes: std.AutoHashMapUnmanaged(GridPos, Node),
    steps_done: u32,
    max_steps: u32,
    result: AStarResult,
};

pub fn initAStar(allocator: std.mem.Allocator, from: Vec3, to: Vec3) !AStarState {
    const start_x: i32 = @intFromFloat(@floor(from.x));
    const start_z: i32 = @intFromFloat(@floor(from.z));
    const start_y: i32 = @intFromFloat(@round(from.y));
    const end_x: i32 = @intFromFloat(@floor(to.x));
    const end_z: i32 = @intFromFloat(@floor(to.z));
    const end_y: i32 = @intFromFloat(@round(to.y));

    const start = GridPos{ .x = start_x, .z = start_z };
    const end = GridPos{ .x = end_x, .z = end_z };

    var state = AStarState{
        .allocator = allocator,
        .start = start,
        .end = end,
        .start_y = start_y,
        .end_y = end_y,
        .open_set = .{},
        .nodes = .{},
        .steps_done = 0,
        .max_steps = 300,
        .result = .pending,
    };
    errdefer {
        state.open_set.deinit(allocator);
        state.nodes.deinit(allocator);
    }

    try state.open_set.append(allocator, start);
    try state.nodes.put(allocator, start, .{ .g = 0, .foot_y = start_y, .parent = null });

    return state;
}

pub fn deinitAStar(state: *AStarState) void {
    state.open_set.deinit(state.allocator);
    state.nodes.deinit(state.allocator);
}

pub fn stepAStar(state: *AStarState, world: *BlockWorld, max_steps_this_frame: u16) void {
    if (state.result != .pending) return;

    var frame_steps: u16 = 0;
    while (state.open_set.items.len > 0 and state.steps_done < state.max_steps and frame_steps < max_steps_this_frame) {
        frame_steps += 1;
        state.steps_done += 1;

        var best_idx: usize = 0;
        var best_f: i32 = std.math.maxInt(i32);
        for (state.open_set.items, 0..) |npos, i| {
            const n = state.nodes.get(npos).?;
            const h = heuristic(npos.x - state.end.x, npos.z - state.end.z, n.foot_y - state.end_y);
            const f = n.g + h;
            if (f < best_f) {
                best_f = f;
                best_idx = i;
            }
        }
        const current = state.open_set.swapRemove(best_idx);
        const cur_node = state.nodes.get(current).?;

        if (current.eql(state.end)) {
            state.result = .found;
            return;
        }

        for (DIRS) |dir| {
            const nx = current.x + dir.dx;
            const nz = current.z + dir.dz;
            const neighbor = GridPos{ .x = nx, .z = nz };

            if (dir.dx != 0 and dir.dz != 0) {
                const cx = current.x + dir.dx;
                const cz = current.z;
                if (reachableFootY(world, cx, cz, cur_node.foot_y) == null) continue;
                const fx = current.x;
                const fz = current.z + dir.dz;
                if (reachableFootY(world, fx, fz, cur_node.foot_y) == null) continue;
            }

            const reach = reachableFootY(world, nx, nz, cur_node.foot_y) orelse continue;
            const tent_g = cur_node.g + dir.cost;
            const old_g = if (state.nodes.get(neighbor)) |n| n.g else std.math.maxInt(i32);
            if (tent_g < old_g) {
                state.nodes.put(state.allocator, neighbor, .{ .g = tent_g, .foot_y = reach, .parent = current }) catch {
                    state.result = .failed;
                    return;
                };
                var found = false;
                for (state.open_set.items) |item| {
                    if (item.eql(neighbor)) {
                        found = true;
                        break;
                    }
                }
                if (!found) {
                    state.open_set.append(state.allocator, neighbor) catch {
                        state.result = .failed;
                        return;
                    };
                }
            }
        }
    }

    if (state.open_set.items.len == 0 or state.steps_done >= state.max_steps) {
        state.result = .failed;
    }
}

pub fn buildAStarPath(state: *AStarState) !std.ArrayListUnmanaged(Vec3) {
    var path = std.ArrayListUnmanaged(Vec3){};
    errdefer path.deinit(state.allocator);

    var node: GridPos = state.end;
    while (state.nodes.get(node).?.parent) |prev| {
        const foot = state.nodes.get(node).?.foot_y;
        try path.append(state.allocator, Vec3.new(
            @as(f32, @floatFromInt(node.x)) + 0.5,
            @as(f32, @floatFromInt(foot)),
            @as(f32, @floatFromInt(node.z)) + 0.5,
        ));
        node = prev;
    }

    std.mem.reverse(Vec3, path.items);
    return path;
}

/// 三维 A* 寻路，返回下一步移动方向（XZ 单位向量）。失败返回 null。
pub fn findPathStep(allocator: std.mem.Allocator, world: *BlockWorld, from: Vec3, to: Vec3) !?Vec2 {
    const start_x: i32 = @intFromFloat(@floor(from.x));
    const start_z: i32 = @intFromFloat(@floor(from.z));
    const start_y: i32 = @intFromFloat(@round(from.y));
    const end_x: i32 = @intFromFloat(@floor(to.x));
    const end_z: i32 = @intFromFloat(@floor(to.z));
    const end_y: i32 = @intFromFloat(@round(to.y));

    const start = GridPos{ .x = start_x, .z = start_z };
    const end = GridPos{ .x = end_x, .z = end_z };

    if (start.eql(end)) return null;

    var open_set = std.ArrayListUnmanaged(GridPos){};
    defer open_set.deinit(allocator);
    var nodes = std.AutoHashMap(GridPos, Node).init(allocator);
    defer nodes.deinit();

    try open_set.append(allocator, start);
    try nodes.put(start, .{ .g = 0, .foot_y = start_y, .parent = null });

    var steps: u32 = 0;
    const max_steps: u32 = 300;

    while (open_set.items.len > 0 and steps < max_steps) : (steps += 1) {
        // 找最小 F 值
        var best_idx: usize = 0;
        var best_f: i32 = std.math.maxInt(i32);
        for (open_set.items, 0..) |node_pos, i| {
            const n = nodes.get(node_pos).?;
            const h = heuristic(node_pos.x - end_x, node_pos.z - end_z, n.foot_y - end_y);
            const f = n.g + h;
            if (f < best_f) {
                best_f = f;
                best_idx = i;
            }
        }
        const current = open_set.swapRemove(best_idx);
        const cur_node = nodes.get(current).?;

        // 到达终点？
        if (current.eql(end)) {
            var node = current;
            while (nodes.get(node).?.parent) |prev| {
                if (prev.eql(start)) {
                    const dx = @as(f32, @floatFromInt(node.x - start_x));
                    const dz = @as(f32, @floatFromInt(node.z - start_z));
                    const len = @sqrt(dx * dx + dz * dz);
                    if (len < 0.001) return null;
                    return Vec2.new(dx / len, dz / len);
                }
                node = prev;
            }
            return null;
        }

        // 展开邻居
        for (DIRS) |dir| {
            const nx = current.x + dir.dx;
            const nz = current.z + dir.dz;
            const neighbor = GridPos{ .x = nx, .z = nz };

            // 对角线检查：两边必须都可通行
            if (dir.dx != 0 and dir.dz != 0) {
                const cx = current.x + dir.dx;
                const cz = current.z;
                if (reachableFootY(world, cx, cz, cur_node.foot_y) == null) continue;
                const fx = current.x;
                const fz = current.z + dir.dz;
                if (reachableFootY(world, fx, fz, cur_node.foot_y) == null) continue;
            }

            const reach = reachableFootY(world, nx, nz, cur_node.foot_y) orelse continue;
            const tent_g = cur_node.g + dir.cost;
            const old_g = if (nodes.get(neighbor)) |n| n.g else std.math.maxInt(i32);
            if (tent_g < old_g) {
                try nodes.put(neighbor, .{ .g = tent_g, .foot_y = reach, .parent = current });
                var found = false;
                for (open_set.items) |item| {
                    if (item.eql(neighbor)) {
                        found = true;
                        break;
                    }
                }
                if (!found) try open_set.append(allocator, neighbor);
            }
        }
    }

    // 兜底：贪心方向
    const dx = @as(f32, @floatFromInt(end_x - start_x));
    const dz = @as(f32, @floatFromInt(end_z - start_z));
    const len = @sqrt(dx * dx + dz * dz);
    if (len < 0.001) return null;
    return Vec2.new(dx / len, dz / len);
}

/// 返回 (x,z) 列从最高处向下扫描找到的可站立方块顶部 Y
pub fn getSurfaceY(world: *BlockWorld, x: i32, z: i32) ?i32 {
    var y: i32 = @intCast(CHUNK_SIZE_Y - 1);
    while (y >= 0) : (y -= 1) {
        const pos = Vec3.new(@as(f32, @floatFromInt(x)) + 0.5, @as(f32, @floatFromInt(y)) + 0.5, @as(f32, @floatFromInt(z)) + 0.5);
        const block = world.getBlockAt(pos);
        if (block.prototype().is_solid) {
            const above: i32 = y + 1;
            if (above >= CHUNK_SIZE_Y) return null;
            const above_pos = Vec3.new(@as(f32, @floatFromInt(x)) + 0.5, @as(f32, @floatFromInt(above)) + 0.5, @as(f32, @floatFromInt(z)) + 0.5);
            const above_block = world.getBlockAt(above_pos);
            if (!above_block.prototype().is_solid) return above;
            return null;
        }
    }
    return null;
}
