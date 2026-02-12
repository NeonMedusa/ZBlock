const Game = @import("game.zig");
const WorldHelper = @import("world_helper.zig");
const Algebra = @import("zalgebra");
const Components = @import("components.zig").Components;
const Vec3 = Algebra.Vec3;
const Mat4 = Algebra.Mat4;
pub fn initTestWorld(game: *Game) !void {
    const player1 = try WorldHelper.createPlayer(
        &game.world,
        .CesiumMan,
        .{ .vec = Vec3.new(0, 0, 0) },
        .{ .value = 2.0 }, // 基础速度
        .{ .current = 3.0, .max = 3.0 }, // 生命值
        .{ .input = &game.input, .player_id = 1 },
    );
    _ = player1;

    const entity1 = try WorldHelper.createBaseEntity(
        &game.world,
        .Wolf,
        .{ .vec = Vec3.new(0, 0, 0) },
        .{ .value = 2.0 }, // 基础速度
        .{ .current = 3.0, .max = 100.0 }, // 生命值
    );
    try entity1.setComponent(Components.MovingTarget{ .vec = Vec3.new(10, 0, 0) });

    const entity2 = try WorldHelper.createBaseEntity(
        &game.world,
        .BarramundiFish,
        .{ .vec = Vec3.new(0, 0, 0) },
        .{ .value = 1.5 }, // 基础速度
        .{ .current = 3.0, .max = 80.0 }, // 生命值
    );
    try entity2.setComponent(Components.MovingTarget{ .vec = Vec3.new(-10, 0, 0) });

    const ground = try WorldHelper.createGround(&game.world, 64);
    try ground.setComponent(Components.Position{ .vec = Vec3.new(-10, -10, -10) });
}

pub fn initTestPhysicsWorld(game: *Game) !void {
    // 创建实体
    const entity = try game.world.createEntity();

    // 设置组件和获取组件时必须明确类型
    try entity.setComponent(Components.Position{ .vec = Vec3.new(3, 0, 0) });
    _ = entity.getComponent(Components.Position);

    // 方案1:传枚举，在括号中输入.即可调出代码提示
    _ = entity.hasComponent(.Position);
    _ = try entity.removeComponent(.Position);

    // 方案2:传类型，在括号中输入Components.调出代码提示
    // _ = entity.hasComponent(Components.Position);
    // _ = entity.removeComponent(Components.Position);

    // 创建空实体
    const player = try game.world.createEntity();
    // 设置位置
    try player.setComponent(Components.Position{ .vec = Vec3.new(0, 0, 0) });
    // 设置渲染模型
    try player.setComponent(Components.Model.Wolf);
    // 设置碰撞体组件
    try player.setComponent(Components.Collider{
        .shape_type = .sphere,
        .dimensions = Vec3.new(1, 0, 0), // x存储半径
    });
    // 设置物理属性组件
    try player.setComponent(Components.PhysicsBody{
        .mass = 1,
    });

    // 创建地面
    const ground = try WorldHelper.createGround(&game.world, 64);
    try ground.setComponent(Components.Position{ .vec = Vec3.new(-10, -10, -10) });
}
