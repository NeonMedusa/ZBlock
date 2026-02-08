// components.zig
const std = @import("std");
const Algebra = @import("zalgebra");
const Vec3 = Algebra.Vec3;
const Input = @import("input.zig");
const ShaderType = @import("shader_types.zig");
const AnimType = ShaderType.AnimType;
// 在这里定义所有组件类型
pub const Components = struct {
    // 玩家组件
    pub const Player = struct {
        player_id: u32 = 0,
        input: *Input,
    };
    // 模型组件
    pub const Model = @import("model.zig").ModelName;
    // 位置组件
    pub const Position = struct {
        vec: Vec3,
    };
    // 移动目标组件
    pub const MovingTarget = struct {
        vec: Vec3,
    };
    // 速度组件
    pub const Speed = struct {
        value: f32,
    };
    // 生命值组件
    pub const Health = struct {
        current: f32,
        max: f32,
    };
    // 动画状态组件
    pub const AnimationState = struct {
        cur_anim: AnimType = .idle,
        cur_time: f32 = 0,
        speed: f32 = 1.0,
        looping: bool = true,
    };

    // 碰撞体组件
    pub const Collider = struct {
        shape_type: enum {
            sphere,
            box,
            capsule,
        },
        // 球体: radius
        // 盒子: width, height, depth
        // 胶囊: radius, height
        dimensions: Vec3,
        offset: Vec3 = Vec3.zero(),
    };
    // 物理属性组件
    pub const PhysicsBody = struct {
        velocity: Vec3 = Vec3.zero(),
        acceleration: Vec3 = Vec3.zero(),
        mass: f32 = 1.0,
        restitution: f32 = 0.5, // 弹性系数 (0-1)
        friction: f32 = 0.8, // 摩擦系数 (0-1)
        gravity_scale: f32 = 1.0,
        is_static: bool = false,
    };
    // 地面组件 (静态碰撞体)
    pub const Ground = struct {
        normal: Vec3 = Vec3.new(0, 1, 0),
    };
};
