// components.zig
const std = @import("std");
const Algebra = @import("algebra.zig");
const Vec3 = Algebra.Vec3;
const Input = @import("input.zig");
// 在这里定义所有组件类型
pub const Components = struct {
    // 玩家组件
    pub const Player = struct {
        player_id: u32 = 0,
        input: *Input,
    };
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
    // 模型
    pub const ModelName = struct {
        string: []const u8,
    };
    pub const Velocity = struct {
        vec: Vec3 = Vec3.zero,
    };
};
