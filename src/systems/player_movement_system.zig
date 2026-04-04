// systems/player_system.zig
const std = @import("std");
const Game = @import("../game.zig");
const Vec2 = @import("../algebra.zig").Vec2;
const Vec3 = @import("../algebra.zig").Vec3;
const Comps = @import("../components.zig").Components;
const Raycast = @import("../raycast.zig");

pub const PlayerSystem = struct {
    const JUMP_FORCE: f32 = 8.0;
    const GROUND_OFFSET: f32 = 0.5;
    const REACHED_THRESHOLD: f32 = 0.5; // 到达路径点的距离阈值

    pub fn update(game: *Game) !void {
        const dt = game.window.delta_time;
        var view = game.registry.view(.{
            Comps.Player,
            Comps.Position,
            Comps.Velocity,
            Comps.Speed,
        }, .{});
        var iter = view.entityIterator();

        while (iter.next()) |entity| {
            const player = view.get(Comps.Player, entity);
            if (player.id == game.player_id) {
                const position = view.get(Comps.Position, entity);
                const velocity = view.get(Comps.Velocity, entity);
                const speed = view.get(Comps.Speed, entity);

                // ---------- 设置移动目标（F键） ----------
                if (game.input.isKeyPressed(.f)) {
                    const ray = game.camera.getForwardRay();
                    const hit = Raycast.raycast(ray, 100.0, &game.rts_map.terrain);
                    if (hit.hit and hit.hit_type == .terrain) {
                        // 移除旧订单
                        if (game.registry.has(Comps.MoveOrder, entity)) {
                            var old = game.registry.get(Comps.MoveOrder, entity);
                            old.deinit();
                            game.registry.remove(Comps.MoveOrder, entity);
                        }
                        const start = Vec2.new(position.vec.x, position.vec.z);
                        const goal = Vec2.new(hit.point.x, hit.point.z);
                        const waypoints = game.rts_map.findPathOrClosest(start, goal, game.allocator) catch |err| {
                            std.debug.print("寻路失败: {}\n", .{err});
                            continue;
                        };
                        defer game.allocator.free(waypoints); // 释放 Vec2 数组

                        // 转换 Vec2 路径点到 Vec3
                        var waypoints_3d = try game.allocator.alloc(Vec3, waypoints.len);
                        errdefer game.allocator.free(waypoints_3d); // 如果后面失败，释放
                        for (waypoints, 0..) |wp, i| {
                            waypoints_3d[i] = Vec3.new(wp.x, 0, wp.z);
                        }
                        const order = Comps.MoveOrder.init(game.allocator, hit.point, waypoints_3d);
                        // 注意：此时 waypoints_3d 的所有权已转移给 order，不需要再释放
                        game.registry.add(entity, order);
                    }
                }

                // ---------- 处理移动订单 ----------
                if (game.registry.has(Comps.MoveOrder, entity)) {
                    const order = game.registry.get(Comps.MoveOrder, entity);
                    const target = order.currentTarget();
                    // 计算水平距离
                    const dx = target.x - position.vec.x;
                    const dz = target.z - position.vec.z;
                    const dist = @sqrt(dx * dx + dz * dz);
                    if (dist < REACHED_THRESHOLD) {
                        order.advance();
                        if (order.isCompleted()) {
                            order.deinit();
                            game.registry.remove(Comps.MoveOrder, entity);
                        }
                    } else {
                        // 向目标点移动
                        const dir = Vec2.new(dx / dist, dz / dist);
                        const move = speed.value * dt;
                        position.vec.x += dir.x * move;
                        position.vec.z += dir.z * move;
                    }
                } else {
                    // ---------- 键盘直接控制（无订单时） ----------
                    var move_dir = Vec3.zero;
                    if (game.input.isKeyPressed(.left)) move_dir.x -= 1;
                    if (game.input.isKeyPressed(.right)) move_dir.x += 1;
                    if (game.input.isKeyPressed(.up)) move_dir.z -= 1;
                    if (game.input.isKeyPressed(.down)) move_dir.z += 1;
                    if (move_dir.x != 0 or move_dir.z != 0) move_dir = move_dir.norm();
                    const move_speed = speed.value * dt;
                    position.vec.x += move_dir.x * move_speed;
                    position.vec.z += move_dir.z * move_speed;
                }

                // 在跳跃逻辑处修改
                if (game.input.isKeyPressed(.j)) {
                    const terrain_height = game.rts_map.terrain.getHeightAt(Vec2.new(position.vec.x, position.vec.z));
                    if (position.vec.y - GROUND_OFFSET <= terrain_height + 0.1) {
                        velocity.vec.y = JUMP_FORCE;
                    }
                }
            }
        }
    }
};
