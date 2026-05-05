// pathfind.zig — 三维 A* 寻路
//
// GridPos 为 3D (x,y,z)，不同高度视为不同节点，支持多层建筑内寻路。
// 邻居展开通过 findGroundBelow 找落点，向上最多 1 格（跳跃），向下不限（重力下落）。
// 分步执行（stepAStar），每帧推进有限步数，不阻塞主循环。
//
// 核心数据结构：
//   AStarState  — 持久化寻路状态，跨帧保存 open_set / nodes / 搜索进度
//   GridPos      — 3D 网格坐标 {x, y, z}，y 是脚底高度
//   Node         — A* 节点，存 g 值和父节点引用

const std = @import("std");
const Vec3 = @import("algebra.zig").Vec3;
const BlockWorld = @import("block_world.zig").BlockWorld;
const CHUNK_SIZE_Y = @import("block_world.zig").CHUNK_SIZE_Y;

// 移动成本：轴向 10，对角线 14（≈10×√2，与 1.41 对应）
const G_CARDINAL = 10;
const G_DIAGONAL = 14;
const H_MULT = 10;
const H_HEIGHT_MULT = 15;

pub const GridPos = struct {
    x: i32,
    y: i32, // 脚底高度
    z: i32,

    pub fn eql(a: GridPos, b: GridPos) bool {
        return a.x == b.x and a.y == b.y and a.z == b.z;
    }
};

/// 判断指定位置是否为固体方块
fn isSolidAt(world: *BlockWorld, x: i32, y: i32, z: i32) bool {
    return world.getBlockAt(Vec3.new(
        @as(f32, @floatFromInt(x)) + 0.5,
        @as(f32, @floatFromInt(y)) + 0.5,
        @as(f32, @floatFromInt(z)) + 0.5,
    )).prototype().is_solid;
}

/// 从 from_y 向下扫描，找到第一个固体方块，返回其上方可站立的脚底 Y（方块 y+1）。
/// 保证 foot 开始的 entity_height_blocks 格都是空气（匹配实体身高）。
/// 向下不限落差（重力自然下落），用于邻居列的落点计算。
pub fn findGroundBelow(world: *BlockWorld, x: i32, z: i32, from_y: i32, entity_height_blocks: i32) ?i32 {
    var y: i32 = from_y;
    while (y >= 0) : (y -= 1) {
        if (isSolidAt(world, x, y, z)) {
            const foot = y + 1;
            if (foot + entity_height_blocks >= CHUNK_SIZE_Y) return null;
            var fy: i32 = foot;
            while (fy < foot + entity_height_blocks) : (fy += 1) {
                if (isSolidAt(world, x, fy, z)) return null;
            }
            return foot;
        }
    }
    return null;
}

/// A* 节点：g 值和父节点引用（高度信息已包含在 GridPos.y 中）
pub const Node = struct {
    g: i32,
    parent: ?GridPos,
};

// 8 方向邻居：4 个轴向 + 4 个对角线
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

/// Octile 距离启发函数：对角方向用对角线成本，剩余轴向用直线成本。
/// 加上高度差的权重，使 A* 倾向于同高度移动，同时在多层建筑中能向上/下搜索。
fn heuristic(a: GridPos, b: GridPos) i32 {
    const dx: i32 = @intCast(@abs(a.x - b.x));
    const dz: i32 = @intCast(@abs(a.z - b.z));
    const dy: i32 = @intCast(@abs(a.y - b.y));
    const d_min = @min(dx, dz);
    const d_max = @max(dx, dz);
    const h_horiz = d_min * G_DIAGONAL + (d_max - d_min) * G_CARDINAL;
    return h_horiz + dy * H_HEIGHT_MULT;
}

pub const AStarResult = enum { pending, found, failed };

/// 持久化寻路状态，跨帧保存
pub const AStarState = struct {
    allocator: std.mem.Allocator,
    start: GridPos, // 起点
    end: GridPos, // 目标（搜索中可能被折中终点覆盖）
    open_set: std.ArrayListUnmanaged(GridPos),
    nodes: std.AutoHashMapUnmanaged(GridPos, Node),
    steps_done: u32, // 已执行步数
    max_steps: u32, // 最大步数（超过后取最近可达点）
    result: AStarResult,
    entity_height_blocks: i32, // 实体占用的竖直方块数：ceil(collider_height)
    max_step_up: i32, // 最大向上跳跃高度（方块数）
};

/// 初始化 A* 寻路状态。
/// end 的 y 通过 findGroundBelow 计算，确保目标站在实际地面上，而非空中或墙内。
/// entity_height_blocks = ceil(collider_height)，决定需要的竖直空间格数。
/// max_step_up = 最大向上跳跃高度（方块数），由 jump_vel²/(2*gravity) 计算。
pub fn initAStar(allocator: std.mem.Allocator, world: *BlockWorld, from: Vec3, to: Vec3, entity_height_blocks: i32, max_step_up: i32) !AStarState {
    const start = GridPos{
        .x = @intFromFloat(@floor(from.x)),
        .y = @intFromFloat(@round(from.y)),
        .z = @intFromFloat(@floor(from.z)),
    };
    // 终点的 y 需要找实际地面，因为传入的 to.y 可能是眼高或空中坐标
    const end_x: i32 = @intFromFloat(@floor(to.x));
    const end_z: i32 = @intFromFloat(@floor(to.z));
    const end_y = findGroundBelow(world, end_x, end_z, @as(i32, @intFromFloat(@round(to.y))) - 1, entity_height_blocks) orelse
        @as(i32, @intFromFloat(@round(to.y)));
    const end = GridPos{
        .x = end_x,
        .y = end_y,
        .z = end_z,
    };

    var state = AStarState{
        .allocator = allocator,
        .start = start,
        .end = end,
        .open_set = .{},
        .nodes = .{},
        .steps_done = 0,
        .max_steps = 3000,
        .result = .pending,
        .entity_height_blocks = entity_height_blocks,
        .max_step_up = max_step_up,
    };
    errdefer {
        state.open_set.deinit(allocator);
        state.nodes.deinit(allocator);
    }

    try state.open_set.append(allocator, start);
    try state.nodes.put(allocator, start, .{ .g = 0, .parent = null });

    return state;
}

/// 释放 A* 状态的内部内存
pub fn deinitAStar(state: *AStarState) void {
    state.open_set.deinit(state.allocator);
    state.nodes.deinit(state.allocator);
}

/// 分步推进 A*，每帧调用一次，最多执行 max_steps_this_frame 步。
/// 找到终点 → result = .found
/// 步数耗尽或 open_set 空 → 用已探索中离目标最近的节点作为折中终点
pub fn stepAStar(state: *AStarState, world: *BlockWorld, max_steps_this_frame: u16) void {
    if (state.result != .pending) return;

    var frame_steps: u16 = 0;
    while (state.open_set.items.len > 0 and state.steps_done < state.max_steps and frame_steps < max_steps_this_frame) {
        frame_steps += 1;
        state.steps_done += 1;

        // 从 open_set 中选 F = g + h 最小的节点
        var best_idx: usize = 0;
        var best_f: i32 = std.math.maxInt(i32);
        for (state.open_set.items, 0..) |npos, i| {
            const n = state.nodes.get(npos).?;
            const h = heuristic(npos, state.end);
            const f = n.g + h;
            if (f < best_f) {
                best_f = f;
                best_idx = i;
            }
        }
        const current = state.open_set.swapRemove(best_idx);
        const cur_g = state.nodes.get(current).?.g;

        // 到达目标
        if (current.eql(state.end)) {
            state.result = .found;
            return;
        }

        // 展开 8 方向邻居（支持多级跳跃：每个邻居列可能产生多个不同高度的落点）
        for (DIRS) |dir| {
            const nx = current.x + dir.dx;
            const nz = current.z + dir.dz;

            // 对角线防穿墙：中间两个列必须 entity_height_blocks 格空气
            if (dir.dx != 0 and dir.dz != 0) {
                const cx = current.x + dir.dx;
                const cz = current.z;
                var pass_cx: bool = true;
                var fy: i32 = current.y;
                while (fy < current.y + state.entity_height_blocks) : (fy += 1) {
                    if (isSolidAt(world, cx, fy, cz)) {
                        pass_cx = false;
                        break;
                    }
                }
                if (!pass_cx) continue;
                const fx = current.x;
                const fz = current.z + dir.dz;
                var pass_fz: bool = true;
                fy = current.y;
                while (fy < current.y + state.entity_height_blocks) : (fy += 1) {
                    if (isSolidAt(world, fx, fy, fz)) {
                        pass_fz = false;
                        break;
                    }
                }
                if (!pass_fz) continue;
            }

            // 扫描该列所有固体方块，为每个有效落点生成一个邻居节点
            var found_down: bool = false;
            var solid_y: i32 = current.y + state.max_step_up;
            while (solid_y >= 0) : (solid_y -= 1) {
                if (!isSolidAt(world, nx, solid_y, nz)) continue;

                const foot = solid_y + 1;
                const height_diff = foot - current.y;

                // 向上超过跳跃能力 → 跳过（继续往下扫）
                if (height_diff > state.max_step_up) continue;

                // 向下：只取第一个（最高的落点，避免生成过多低处节点）
                if (height_diff < 0 and found_down) continue;

                if (foot + state.entity_height_blocks >= CHUNK_SIZE_Y) continue;

                // 落脚空间验证：foot 开始的 entity_height_blocks 格全部是空气
                var valid: bool = true;
                var fy: i32 = foot;
                while (fy < foot + state.entity_height_blocks) : (fy += 1) {
                    if (isSolidAt(world, nx, fy, nz)) {
                        valid = false;
                        break;
                    }
                }
                if (!valid) continue;

                if (height_diff < 0) found_down = true;

                const neighbor = GridPos{ .x = nx, .y = foot, .z = nz };
                const tent_g = cur_g + dir.cost;
                const old_g = if (state.nodes.get(neighbor)) |n| n.g else std.math.maxInt(i32);
                if (tent_g < old_g) {
                    state.nodes.put(state.allocator, neighbor, .{ .g = tent_g, .parent = current }) catch {
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
    }

    // 步数耗尽或无可达节点：选已探索中离目标最近的作为折中终点
    if (state.open_set.items.len == 0 or state.steps_done >= state.max_steps) {
        var best_key: ?GridPos = null;
        var best_h: i32 = std.math.maxInt(i32);
        var it = state.nodes.keyIterator();
        while (it.next()) |key| {
            const h = heuristic(key.*, state.end);
            if (h < best_h) {
                best_h = h;
                best_key = key.*;
            }
        }
        if (best_key) |k| {
            state.end = k;
            state.result = .found;
        } else {
            state.result = .failed;
        }
    }
}

/// 从 end 回溯父链，生成完整路径（世界坐标 waypoint 列表）。
/// 路径包含从起点之后的第一步到终点，不含起点（实体已在起点位置）。
/// waypoint 位于方块中心 (x+0.5, foot_y, z+0.5)。
pub fn buildAStarPath(state: *AStarState) !std.ArrayListUnmanaged(Vec3) {
    var path = std.ArrayListUnmanaged(Vec3){};
    errdefer path.deinit(state.allocator);

    var node: GridPos = state.end;
    while (state.nodes.get(node).?.parent) |prev| {
        try path.append(state.allocator, Vec3.new(
            @as(f32, @floatFromInt(node.x)) + 0.5,
            @as(f32, @floatFromInt(node.y)),
            @as(f32, @floatFromInt(node.z)) + 0.5,
        ));
        node = prev;
    }

    std.mem.reverse(Vec3, path.items);
    return path;
}
