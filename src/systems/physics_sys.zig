// physics.zig - 简单的物理系统
const std = @import("std");
const Imports = @import("../imports.zig");
const Game = Imports.Game;
const Vec2 = Imports.Vec2; // 添加导入
const Vec3 = Imports.Vec3;
const Comps = Imports.Comps;

pub const PhysicsSystem = struct {
    const GRAVITY: f32 = -9.81;
    const GROUND_OFFSET: f32 = 0.0;

    pub fn update(game: *Game) void {
        const dt = game.window.delta_time;
        var view = game.registry.view(.{ Comps.Position, Comps.Velocity }, .{});
        var iter = view.entityIterator();

        while (iter.next()) |entity| {
            const pos = game.registry.get(Comps.Position, entity);
            const vel = game.registry.get(Comps.Velocity, entity);

            vel.vec.y += GRAVITY * dt;

            var new_pos = pos.vec.add(vel.vec.scale(dt));

            // 修改：使用 Vec2 调用 getHeightAt
            const terrain_height = game.rts_map.terrain.getHeightAt(Vec2.new(new_pos.x, new_pos.z));

            if (new_pos.y - GROUND_OFFSET <= terrain_height) {
                new_pos.y = terrain_height + GROUND_OFFSET;
                if (@abs(vel.vec.y) < 0.1) {
                    vel.vec.y = 0;
                }
            }

            pos.vec = new_pos;
        }
    }
};
