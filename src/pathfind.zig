// pathfind.zig
const std = @import("std");
const Vec2 = @import("algebra.zig").Vec2;
const Vec3 = @import("algebra.zig").Vec3;
const BlockWorld = @import("block_world.zig").BlockWorld;
const CHUNK_SIZE_Y = @import("block_world.zig").CHUNK_SIZE_Y;

const GridPos = struct {
    x: i32,
    z: i32,
};

/// 返回 (x,z) 列的地表 Y——从最高处向下扫描第一个非固体方块上方的空气位置
pub fn getSurfaceY(world: *BlockWorld, x: i32, z: i32) ?i32 {
    var y: i32 = @intCast(CHUNK_SIZE_Y - 1);
    while (y >= 0) : (y -= 1) {
        const pos = Vec3.new(@as(f32, @floatFromInt(x)) + 0.5, @as(f32, @floatFromInt(y)) + 0.5, @as(f32, @floatFromInt(z)) + 0.5);
        const block = world.getBlockAt(pos);
        if (block.prototype().is_solid) {
            const above: i32 = @intCast(y + 1);
            if (above >= CHUNK_SIZE_Y) return null;
            const above_pos = Vec3.new(@as(f32, @floatFromInt(x)) + 0.5, @as(f32, @floatFromInt(above)) + 0.5, @as(f32, @floatFromInt(z)) + 0.5);
            const above_block = world.getBlockAt(above_pos);
            if (!above_block.prototype().is_solid) return above;
            return null;
        }
    }
    return null;
}

fn canWalkAt(world: *BlockWorld, x: i32, z: i32) bool {
    const sy = getSurfaceY(world, x, z) orelse return false;
    const pos = Vec3.new(@as(f32, @floatFromInt(x)) + 0.5, @as(f32, @floatFromInt(sy)), @as(f32, @floatFromInt(z)) + 0.5);
    const head_pos = Vec3.new(@as(f32, @floatFromInt(x)) + 0.5, @as(f32, @floatFromInt(sy + 2)), @as(f32, @floatFromInt(z)) + 0.5);
    const feet = world.getBlockAt(pos);
    const head = world.getBlockAt(head_pos);
    return (!feet.prototype().is_solid) and (!head.prototype().is_solid);
}

const DIRS = [_]GridPos{
    .{ .x = 1, .z = 0 },
    .{ .x = -1, .z = 0 },
    .{ .x = 0, .z = 1 },
    .{ .x = 0, .z = -1 },
};

fn heuristic(a: GridPos, b: GridPos) i32 {
    const dx = a.x - b.x;
    const dz = a.z - b.z;
    return @intCast(@abs(dx) + @abs(dz));
}

/// 简化的 2D A*，返回下一步移动方向（单位向量），失败返回 null
pub fn findPathStep(allocator: std.mem.Allocator, world: *BlockWorld, from: Vec3, to: Vec3) !?Vec2 {
    const start = GridPos{ .x = @intFromFloat(@floor(from.x)), .z = @intFromFloat(@floor(from.z)) };
    const end = GridPos{ .x = @intFromFloat(@floor(to.x)), .z = @intFromFloat(@floor(to.z)) };

    if (start.x == end.x and start.z == end.z) return null;

    var open_set = std.ArrayListUnmanaged(GridPos){};
    defer open_set.deinit(allocator);
    var g_score = std.AutoHashMap(GridPos, i32).init(allocator);
    defer g_score.deinit();
    var came_from = std.AutoHashMap(GridPos, GridPos).init(allocator);
    defer came_from.deinit();

    try open_set.append(allocator, start);
    try g_score.put(start, 0);

    var steps: u32 = 0;
    const max_steps: u32 = 200;

    while (open_set.items.len > 0 and steps < max_steps) : (steps += 1) {
        var best_idx: usize = 0;
        var best_f: i32 = std.math.maxInt(i32);
        for (open_set.items, 0..) |node, i| {
            const g = g_score.get(node) orelse std.math.maxInt(i32);
            const f = g + heuristic(node, end);
            if (f < best_f) { best_f = f; best_idx = i; }
        }
        const current = open_set.swapRemove(best_idx);

        if (current.x == end.x and current.z == end.z) {
            var node = current;
            while (came_from.get(node)) |prev| {
                if (prev.x == start.x and prev.z == start.z) {
                    const dx = @as(f32, @floatFromInt(current.x - start.x));
                    const dz = @as(f32, @floatFromInt(current.z - start.z));
                    const len = @sqrt(dx * dx + dz * dz);
                    if (len < 0.001) return null;
                    return Vec2.new(dx / len, dz / len);
                }
                node = prev;
            }
            return null;
        }

        for (DIRS) |dir| {
            const nx = current.x + dir.x;
            const nz = current.z + dir.z;
            if (!canWalkAt(world, nx, nz)) continue;
            const neighbor = GridPos{ .x = nx, .z = nz };
            const tent_g = (g_score.get(current) orelse std.math.maxInt(i32)) + 1;
            const prev_g = g_score.get(neighbor) orelse std.math.maxInt(i32);
            if (tent_g < prev_g) {
                try came_from.put(neighbor, current);
                try g_score.put(neighbor, tent_g);
                var found = false;
                for (open_set.items) |item| {
                    if (item.x == nx and item.z == nz) { found = true; break; }
                }
                if (!found) try open_set.append(allocator, neighbor);
            }
        }
    }

    // 兜底：贪心方向
    const dx = @as(f32, @floatFromInt(end.x - start.x));
    const dz = @as(f32, @floatFromInt(end.z - start.z));
    const len = @sqrt(dx * dx + dz * dz);
    if (len < 0.001) return null;
    return Vec2.new(dx / len, dz / len);
}
