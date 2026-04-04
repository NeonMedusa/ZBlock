// components.zig
const std = @import("std");
const Imports = @import("imports.zig");
const Algebra = Imports.Algebra;
const Vec3 = Algebra.Vec3;
// 在这里定义所有组件类型
pub const Components = struct {
    // 玩家组件
    pub const Player = struct {
        id: u32 = 0,
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

    pub const MoveOrder = struct {
        // 最终目标（世界坐标）
        final_target: Vec3,
        // 剩余路径点（世界坐标，不包含当前位置）
        waypoints: []Vec3,
        // 当前正在前往的路径点索引（0 表示第一个 waypoint）
        current_waypoint: usize,
        allocator: std.mem.Allocator,
        pub fn init(allocator: std.mem.Allocator, final_target: Vec3, waypoints: []Vec3) MoveOrder {
            return MoveOrder{
                .final_target = final_target,
                .waypoints = waypoints, // 直接接管，不复制
                .current_waypoint = 0,
                .allocator = allocator,
            };
        }
        pub fn deinit(self: *MoveOrder) void {
            self.allocator.free(self.waypoints);
        }
        /// 获取当前应该移动到的目标点（世界坐标）
        pub fn currentTarget(self: *MoveOrder) Vec3 {
            if (self.current_waypoint < self.waypoints.len) {
                return self.waypoints[self.current_waypoint];
            } else {
                return self.final_target;
            }
        }
        /// 标记当前路径点已到达，移动到下一个
        pub fn advance(self: *MoveOrder) void {
            if (self.current_waypoint < self.waypoints.len) {
                self.current_waypoint += 1;
            }
        }
        /// 是否已完成整个移动（到达最终目标）
        pub fn isCompleted(self: *MoveOrder) bool {
            return self.current_waypoint >= self.waypoints.len;
        }
    };
};
