// components.zig
const std = @import("std");
const Imports = @import("imports.zig");
const Algebra = Imports.Algebra;
const Vec3 = Algebra.Vec3;
// 在这里定义所有组件类型
pub const Components = struct {
    // ---- 身份 ----
    pub const Player = struct { id: u32 = 0 }; // 标记哪个实体是玩家
    pub const ModelName = struct { string: []const u8 }; // 渲染用模型

    // ---- 物理状态 ----
    pub const Position = struct { vec: Vec3 };
    pub const Velocity = struct { vec: Vec3 = Vec3.zero };
    pub const AABB = struct { // 物理碰撞箱（相对于位置）
        width: f32 = 0.6,
        height: f32 = 1.8,
    };
    pub const OnGround = struct { value: bool = false };

    // ---- 移动属性 ----
    pub const MoveSpeed = struct { value: f32 = 4.0 }; // 最大步行速度
    pub const JumpVelocity = struct { value: f32 = 8.0 }; // 跳跃初速度

    // ---- 输入意图（每帧由输入系统产生，物理系统消费后清除）----
    pub const MoveIntent = struct {
        direction: Vec3 = Vec3.zero, // 水平移动方向 + 游泳垂直方向
        jump: bool = false, // 是否按下跳跃
    };

    // 其它
    pub const Health = struct { current: f32, max: f32 };
};
