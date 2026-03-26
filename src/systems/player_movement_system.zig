// player_system.zig
const std = @import("std");
const Algebra = @import("../algebra.zig");
const Vec3 = Algebra.Vec3;
const Mat4 = Algebra.Mat4;
const ECS = @import("zigecs");
const Comps = @import("../components.zig").Components;

pub fn update(registry: *ECS.Registry, delta_time: f32) !void {
    var view = registry.view(.{
        Comps.Player,
        Comps.Position,
        Comps.Speed,
    }, .{});
    var iter = view.entityIterator();
    while (iter.next()) |entity| {
        const player = view.get(Comps.Player, entity);
        const position = view.get(Comps.Position, entity);
        const speed = view.get(Comps.Speed, entity);
        const velocity = speed.value * delta_time;
        if (player.input.isKeyPressed(.left))
            position.vec = position.vec.add(.new(-velocity, 0, 0));
        if (player.input.isKeyPressed(.right))
            position.vec = position.vec.add(.new(velocity, 0, 0));
        if (player.input.isKeyPressed(.up))
            position.vec = position.vec.add(.new(0, 0, -velocity));
        if (player.input.isKeyPressed(.down))
            position.vec = position.vec.add(.new(0, 0, velocity));
    }
}
