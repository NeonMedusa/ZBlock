// pathfind.zig — 三维 A* 寻路
// GridPos 为 3D (x,y,z)，邻居通过 findGroundBelow 找落点
const std = @import("std");
const Vec3 = @import("algebra.zig").Vec3;
const BlockWorld = @import("block_world.zig").BlockWorld;
const CHUNK_SIZE_Y = @import("block_world.zig").CHUNK_SIZE_Y;

const G_CARDINAL = 10;
const G_DIAGONAL = 14;
const H_MULT = 10;
const H_HEIGHT_MULT = 15;

pub const GridPos = struct {
    x: i32,
    y: i32,
    z: i32,

    pub fn eql(a: GridPos, b: GridPos) bool {
        return a.x == b.x and a.y == b.y and a.z == b.z;
    }
};

fn isSolidAt(world: *BlockWorld, x: i32, y: i32, z: i32) bool {
    return world.getBlockAt(Vec3.new(
        @as(f32, @floatFromInt(x)) + 0.5,
        @as(f32, @floatFromInt(y)) + 0.5,
        @as(f32, @floatFromInt(z)) + 0.5,
    )).prototype().is_solid;
}

/// 从 from_y 向下扫描，找到第一个固体方块，返回其上方可站立的脚底 Y (方块 y+1)。
/// 只返回 foot 和 foot+1 都是空气的位置，保证实体（2格高）能站立。
pub fn findGroundBelow(world: *BlockWorld, x: i32, z: i32, from_y: i32) ?i32 {
    var y: i32 = from_y;
    while (y >= 0) : (y -= 1) {
        if (isSolidAt(world, x, y, z)) {
            const foot = y + 1;
            if (foot + 2 >= CHUNK_SIZE_Y) return null;
            if (!isSolidAt(world, x, foot, z) and !isSolidAt(world, x, foot + 1, z)) {
                return foot;
            }
            return null;
        }
    }
    return null;
}

pub const Node = struct {
    g: i32,
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

pub const AStarState = struct {
    allocator: std.mem.Allocator,
    start: GridPos,
    end: GridPos,
    open_set: std.ArrayListUnmanaged(GridPos),
    nodes: std.AutoHashMapUnmanaged(GridPos, Node),
    steps_done: u32,
    max_steps: u32,
    result: AStarResult,
};

pub fn initAStar(allocator: std.mem.Allocator, world: *BlockWorld, from: Vec3, to: Vec3) !AStarState {
    const start = GridPos{
        .x = @intFromFloat(@floor(from.x)),
        .y = @intFromFloat(@round(from.y)),
        .z = @intFromFloat(@floor(from.z)),
    };
    const end_x: i32 = @intFromFloat(@floor(to.x));
    const end_z: i32 = @intFromFloat(@floor(to.z));
    const end_y = findGroundBelow(world, end_x, end_z, @as(i32, @intFromFloat(@round(to.y))) - 1) orelse
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
    };
    errdefer {
        state.open_set.deinit(allocator);
        state.nodes.deinit(allocator);
    }

    try state.open_set.append(allocator, start);
    try state.nodes.put(allocator, start, .{ .g = 0, .parent = null });

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
            const h = heuristic(npos, state.end);
            const f = n.g + h;
            if (f < best_f) {
                best_f = f;
                best_idx = i;
            }
        }
        const current = state.open_set.swapRemove(best_idx);
        const cur_g = state.nodes.get(current).?.g;

        if (current.eql(state.end)) {
            state.result = .found;
            return;
        }

        for (DIRS) |dir| {
            const nx = current.x + dir.dx;
            const nz = current.z + dir.dz;

            // 对角线检查：中间列必须两格空气，防止穿墙
            if (dir.dx != 0 and dir.dz != 0) {
                const cx = current.x + dir.dx;
                const cz = current.z;
                if (isSolidAt(world, cx, current.y, cz) or
                    isSolidAt(world, cx, current.y + 1, cz)) continue;
                const fx = current.x;
                const fz = current.z + dir.dz;
                if (isSolidAt(world, fx, current.y, fz) or
                    isSolidAt(world, fx, current.y + 1, fz)) continue;
            }

            // 先找落点：从当前脚底高度开始向下扫描（能扫到高处 1 格的方块）
            const landing = findGroundBelow(world, nx, nz, current.y) orelse continue;

            // 高度差：向上最多 1 格（跳跃），向下不限（重力下落）
            const height_diff = landing - current.y;
            if (height_diff > 1) continue;

            // 用落点高度验空间：脚底和头顶必须是空气
            if (isSolidAt(world, nx, landing, nz) or
                isSolidAt(world, nx, landing + 1, nz)) continue;

            const neighbor = GridPos{ .x = nx, .y = landing, .z = nz };
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

    if (state.open_set.items.len == 0 or state.steps_done >= state.max_steps) {
        // 取最接近目标的已探索节点作为折中终点
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
