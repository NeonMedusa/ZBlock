// 位置组件
pub const Position3D = Vec3;
// 旋转组件
pub const Rotation3D = Vec3;
// 缩放组件
pub const Scale3D = Vec3;
// 速度组件
pub const Velocity3D = Vec3;
// 生命值组件
pub const Health = struct {
    current: i32,
    max: i32,
    // 如果生命值小于零则死亡
    pub fn isAlive(self: Health) bool {
        return self.current > 0;
    }
    // 获取生命值百分比
    pub fn getHealthPercentage(self: Health) f32 {
        return @as(f32, @floatFromInt(self.current)) / @as(f32, @floatFromInt(self.max));
    }
};
// 玩家标记组件（空结构体作为标签）
pub const Player = struct {};

// 敌人类别组件
// pub const Enemy = struct {
//     enemy_type: EnemyType,
//     score_value: u32 = 100,
//     pub const EnemyType = enum {
//         grunt,
//         elite,
//         boss,
//     };
// };

// 精灵渲染组件，可用于UI制作，暂时用不到
// pub const Sprite = struct {
//     texture_id: []const u8,
//     width: u32,
//     height: u32,
//     color: u32 = 0xFFFFFF,
// };

const Algebra = @import("zalgebra");
const Vec3 = Algebra.Vec3;
const Mat4 = Algebra.Mat4;
