// target_movement_system.zig
const std = @import("std");
const Algebra = @import("../algebra.zig");
const Vec3 = Algebra.Vec3;
const Mat4 = Algebra.Mat4;
const ECS = @import("zigecs");
const Comps = @import("../components.zig").Components;

pub fn update(registry: *ECS.Registry, delta_time: f32) !void {
    var view = registry.view(
        .{
            Comps.Position,
            Comps.Speed,
            Comps.MovingTarget,
        },
        .{},
    );
    var iter = view.entityIterator();
    while (iter.next()) |entity| {
        const position = view.get(Comps.Position, entity);
        const speed = view.get(Comps.Speed, entity);
        const target = view.get(Comps.MovingTarget, entity);
        const to_target = target.vec.sub(position.vec);
        const distance = to_target.length();
        // 如果距离目标点已经足够近，则判定为已经到达目标点，停止移动并移除目标点组件
        if (distance < 0.01) {
            position.vec = target.vec;
            registry.remove(Comps.MovingTarget, entity);
            continue;
        }
        // 如果本次帧移动距离大于到目标的距离，直接到达
        const move_distance = speed.value * delta_time;
        if (move_distance >= distance) {
            position.vec = target.vec;
            registry.remove(Comps.MovingTarget, entity);
            continue;
        }
        // 否则沿方向移动
        const direction = to_target.norm();
        position.vec = position.vec.add(direction.scale(move_distance));
    }
}
