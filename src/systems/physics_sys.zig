// physics.zig - 简单的物理系统
const std = @import("std");
const Imports = @import("../imports.zig");
const Game = Imports.Game;
const Vec3 = Imports.Vec3;
const Comps = Imports.Comps;

pub const PhysicsSystem = struct {
    const GRAVITY: f32 = -9.81;
    const GROUND_OFFSET: f32 = 0.0; // 单位半径（假设单位是球体，半径0.5）

    pub fn update(game: *Game) void {
        const dt = game.window.delta_time;
        // 创建视图：包含 Position 和 Velocity 的实体
        var view = game.registry.view(.{ Comps.Position, Comps.Velocity }, .{});
        var iter = view.entityIterator();

        while (iter.next()) |entity| {
            // 获取组件（可变引用）
            const pos = game.registry.get(Comps.Position, entity);
            const vel = game.registry.get(Comps.Velocity, entity);

            // 应用重力
            vel.vec.y += GRAVITY * dt;

            // 计算新位置
            var new_pos = pos.vec.add(vel.vec.scale(dt));

            // 获取地形高度
            const terrain_height = game.terrain.getHeightAt(new_pos.x, new_pos.z);

            // 地面碰撞检测
            if (new_pos.y - GROUND_OFFSET <= terrain_height) {
                // 碰到地面
                new_pos.y = terrain_height + GROUND_OFFSET;

                // // 如果速度向下，反弹（可选）
                // if (vel.vec.y < 0) {
                //     vel.vec.y = -vel.vec.y * 0.5; // 弹性系数 0.5
                // }

                // 如果速度很小，就停止
                if (@abs(vel.vec.y) < 0.1) {
                    vel.vec.y = 0;
                }
            }

            // 更新位置
            pos.vec = new_pos;
        }
    }
};
