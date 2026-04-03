// systems/player_system.zig
const std = @import("std");
const Game = @import("../game.zig");
const Vec3 = @import("../algebra.zig").Vec3;
const Comps = @import("../components.zig").Components;
const Raycast = @import("../raycast.zig");

pub const PlayerSystem = struct {
    const JUMP_FORCE: f32 = 8.0; // 跳跃初速度（向上）

    pub fn update(game: *Game) void {
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

                // 获取移动方向
                var move_dir = Vec3.zero;
                if (game.input.isKeyPressed(.left)) move_dir.x -= 1;
                if (game.input.isKeyPressed(.right)) move_dir.x += 1;
                if (game.input.isKeyPressed(.up)) move_dir.z -= 1;
                if (game.input.isKeyPressed(.down)) move_dir.z += 1;

                // 归一化对角线移动
                if (move_dir.x != 0 or move_dir.z != 0) {
                    move_dir = move_dir.norm();
                }

                // 应用移动（水平方向）
                const speed = view.get(Comps.Speed, entity);
                const move_speed = speed.value * dt;
                position.vec.x += move_dir.x * move_speed;
                position.vec.z += move_dir.z * move_speed;

                // 跳跃检测
                if (game.input.isKeyPressed(.j)) {
                    // 检查是否在地面上
                    const terrain_height = game.rts_map.terrain.getHeightAt(position.vec.x, position.vec.z);
                    const GROUND_OFFSET: f32 = 0.5;

                    if (position.vec.y - GROUND_OFFSET <= terrain_height + 0.1) {
                        velocity.vec.y = JUMP_FORCE;
                    }
                }
            }
        }
    }
};
