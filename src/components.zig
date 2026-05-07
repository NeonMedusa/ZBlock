// components.zig
const std = @import("std");
const Imports = @import("imports.zig");
const Algebra = Imports.Algebra;
const Vec3 = Algebra.Vec3;
const ModelId = Imports.RendCTX.ModelId;
const EntityTypeId = @import("entity_registry.zig").EntityTypeId;
// 在这里定义所有组件类型
pub const Components = struct {
    // ---- 身份 ----
    pub const Player = struct { id: u32 = 0 }; // 标记哪个实体是玩家
    pub const ModelName = struct { id: ModelId }; // 渲染用模型
    pub const AIAgent = struct {
        type_id: EntityTypeId,                          // 实体类型（僵尸/狼等）
        target: Vec3 = Vec3.zero,                       // 当前追逐目标（玩家脚底位置）
        path: ?std.ArrayListUnmanaged(Vec3) = null,     // 当前路径 waypoint 列表（世界坐标）
        path_index: u32 = 0,                            // 当前正在走向的 waypoint 索引
        stuck_timer: f32 = 0,                           // waypoint 超时计时器，正计时，到达时归零
        astar_cooldown: f32 = 0,                        // A* 完成后的冷却计时，限制重算频率（1 秒）
    };

    // ---- 物理状态 ----
    pub const Position = struct { vec: Vec3 };
    pub const Velocity = struct { vec: Vec3 = Vec3.zero };
    pub const Collider = struct { // 物理碰撞箱（相对于位置）
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
        jump: bool = false,         // 是否按下跳跃
        jump_power: f32 = 8.0,     // 跳跃初速度（AI 可按需调整跳跃高度）
        sprint: bool = false,       // 是否按住 shift 冲刺
        sneak: bool = false,        // 是否按住 ctrl 静步
    };

    // ---- 战斗/生命 ----
    pub const Health = struct { current: f32, max: f32 };
    pub const AttackCooldown = struct { interval: f32 = 1.0, timer: f32 = 0 };

    // ---- 玩法 ----
    pub const SpawnPos = struct { pos: Vec3 }; // 重生点
};
