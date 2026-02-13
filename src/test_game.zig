const Game = @import("game.zig");
const WorldHelper = @import("world_helper.zig");
const Algebra = @import("zalgebra");
const Comps = @import("components.zig").Components;
const Vec3 = Algebra.Vec3;
const Mat4 = Algebra.Mat4;
pub fn initTestWorld(game: *Game) !void {
    // 玩家
    const player = game.world.createEntity();
    player.setComp(Comps.Model.CesiumMan);
    player.setComp(Comps.Position{ .vec = .new(0, 0, 0) });
    player.setComp(Comps.Speed{ .value = 2.0 });
    player.setComp(Comps.Health{ .current = 3, .max = 3 });
    player.setComp(Comps.Player{ .input = &game.input, .player_id = 1 });

    // 狼
    const entity1 = game.world.createEntity();
    entity1.setComp(Comps.Model.Wolf);
    entity1.setComp(Comps.Position{ .vec = .new(0, 0, 0) });
    entity1.setComp(Comps.Speed{ .value = 2.0 });
    entity1.setComp(Comps.Health{ .current = 3.0, .max = 100.0 });
    entity1.setComp(Comps.MovingTarget{ .vec = .new(10, 0, 0) });

    // 鱼
    const entity2 = game.world.createEntity();
    entity2.setComp(Comps.Model.BarramundiFish);
    entity2.setComp(Comps.Position{ .vec = .new(0, 0, 0) });
    entity2.setComp(Comps.Speed{ .value = 1.0 });
    entity2.setComp(Comps.Health{ .current = 3.0, .max = 80.0 });
    entity2.setComp(Comps.MovingTarget{ .vec = .new(-10, 0, 0) });

    // 物理测试用实体
    const physicEntity = game.world.createEntity();
    physicEntity.setComp(Comps.Position{ .vec = .new(1, 0, 0) });
    physicEntity.setComp(Comps.Model.CesiumMan);
    physicEntity.setComp(Comps.Collider{
        .shape_type = .sphere,
        .dimensions = Vec3.new(1, 0, 0), // x存储半径
    });
    physicEntity.setComp(Comps.PhysicsBody{
        .mass = 1,
    });

    // 物理测试用地面
    const ground = game.world.createEntity();
    ground.setComp(Comps.Collider{
        .shape_type = .box,
        .dimensions = Vec3.new(64, 1, 64),
    });
    ground.setComp(Comps.Position{ .vec = Vec3.new(-10, -10, -10) });
    ground.setComp(Comps.PhysicsBody{
        .is_static = true,
        .restitution = 0.2,
    });
    ground.setComp(Comps.Ground{});
}
