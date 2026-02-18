const Game = @import("game.zig");
const Algebra = @import("zalgebra");
const Comps = @import("components.zig").Components;
const Vec3 = Algebra.Vec3;
const Mat4 = Algebra.Mat4;

pub fn initTestWorld(game: *Game) !void {
    // 玩家
    const player = game.registry.create();
    game.registry.add(player, Comps.Model.CesiumMan);
    game.registry.add(player, Comps.Position{ .vec = .new(0, 0, 0) });
    game.registry.add(player, Comps.Speed{ .value = 2.0 });
    game.registry.add(player, Comps.Health{ .current = 3, .max = 3 });
    game.registry.add(player, Comps.Player{ .input = &game.input, .player_id = 1 });

    // 狼
    const entity1 = game.registry.create();
    game.registry.add(entity1, Comps.Model.Wolf);
    game.registry.add(entity1, Comps.Position{ .vec = .new(0, 0, 0) });
    game.registry.add(entity1, Comps.Speed{ .value = 2.0 });
    game.registry.add(entity1, Comps.Health{ .current = 3, .max = 100 });
    game.registry.add(entity1, Comps.MovingTarget{ .vec = .new(10, 0, 0) });

    // 鱼
    const entity2 = game.registry.create();
    game.registry.add(entity2, Comps.Model.BarramundiFish);
    game.registry.add(entity2, Comps.Position{ .vec = .new(0, 0, 0) });
    game.registry.add(entity2, Comps.Speed{ .value = 1.0 });
    game.registry.add(entity2, Comps.Health{ .current = 3, .max = 80 });
    game.registry.add(entity2, Comps.MovingTarget{ .vec = .new(-10, 0, 0) });

    // 物理测试用实体
    const physicEntity = game.registry.create();
    game.registry.add(physicEntity, Comps.Position{ .vec = .new(1, 0, 0) });
    game.registry.add(physicEntity, Comps.Model.CesiumMan);
    game.registry.add(physicEntity, Comps.Collider{
        .shape_type = .sphere,
        .dimensions = Vec3.new(1, 0, 0), // x存储半径
    });
    game.registry.add(physicEntity, Comps.PhysicsBody{
        .mass = 1,
    });

    // 物理测试用地面
    const ground = game.registry.create();
    game.registry.add(ground, Comps.Collider{
        .shape_type = .box,
        .dimensions = Vec3.new(64, 1, 64),
    });
    game.registry.add(ground, Comps.Position{ .vec = Vec3.new(-10, -10, -10) });
    game.registry.add(ground, Comps.PhysicsBody{
        .is_static = true,
        .restitution = 0.2,
    });
    game.registry.add(ground, Comps.Ground{});
}
