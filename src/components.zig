// components.zig
const std = @import("std");
const Algebra = @import("algebra.zig");
const ModelId = @import("rend_ctx.zig").ModelId;
const Vec3 = @import("algebra.zig").Vec3;
const EntityTypeId = @import("entity_registry.zig").EntityTypeId;
// 在这里定义所有组件类型
pub const Components = struct {
    // ---- 身份 ----
    pub const Player = struct {
        id: u32 = 0,
        mode: enum(u2) { survival, creative, spectator } = .survival,
    };
    pub const Flying = struct {}; // 标签组件：存在表示实体处于飞行状态
    pub const ModelName = struct { id: ModelId }; // 渲染用模型
    pub const AIAgent = struct {
        type_id: EntityTypeId,
        state: enum { idle, wandering, chasing, fleeing } = .idle,
        target: Vec3 = Vec3.zero,              // 追逐/逃跑目标
        wander_target: Vec3 = Vec3.zero,       // 当前闲逛目的地
        wander_timer: f32 = 0,                 // 闲逛切换倒计时
        flee_timer: f32 = 0,                   // 逃跑持续时间
        path: ?std.ArrayListUnmanaged(Vec3) = null,
        path_index: u32 = 0,
        stuck_timer: f32 = 0,
        astar_cooldown: f32 = 0,
    };

    // ---- 物理状态 ----
    pub const Position = struct {
        vec: Vec3,                // 物理 tick 后的最新位置（服务端线程写）
        prev: Vec3 = Vec3.zero,   // 上一 tick 的位置（仅服务端线程用）
        render_buf_pos: [3]Vec3 = undefined,
        render_buf_time: [3]i64 = undefined,
        render_buf_head: u32 = 0,
        render_buf_count: u32 = 0,

        /// 从 3 槽环形缓冲区查找插值位置，rend_time = now_ns - 33ms
        pub fn interpPos(self: *const @This(), rend_time: i64) Vec3 {
            if (self.render_buf_count >= 2 and self.render_buf_count <= 3) {
                const newest = (self.render_buf_head + 2) % 3;
                var ri: u32 = 0;
                while (ri < self.render_buf_count - 1) {
                    const ni = (newest + 3 - ri) % 3;
                    const oi = (ni + 2) % 3;
                    if (self.render_buf_time[oi] <= rend_time and self.render_buf_time[ni] > rend_time) {
                        const interval = self.render_buf_time[ni] - self.render_buf_time[oi];
                        if (interval > 0) {
                            const alpha = @min(@max(@as(f32, @floatFromInt(rend_time - self.render_buf_time[oi])) / @as(f32, @floatFromInt(interval)), 0.0), 1.0);
                            return Vec3.lerp(self.render_buf_pos[oi], self.render_buf_pos[ni], alpha);
                        } else return self.render_buf_pos[ni];
                    }
                    ri += 1;
                }
            }
            if (self.render_buf_count > 0) return self.render_buf_pos[(self.render_buf_head + 2) % 3];
            return Vec3.zero;
        }
    };
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

    pub const Facing = struct {
        yaw: f32 = 0,   // 弧度
        pitch: f32 = 0, // 弧度
    };

    pub const AnimationState = struct {
        clip_name: []const u8 = "idle",
        time: f32 = 0,
        speed: f32 = 1.0,
        bone_offset: u32 = 0,
    };
};
