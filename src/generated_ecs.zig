// generated_ecs.zig
// 此文件由 code_generator.zig 自动生成
// 请勿手动修改此文件

const std = @import("std");
const Components = @import("components.zig").Components;

// 组件类型枚举
pub const ComponentType = enum(u16) {
    Player,
    Model,
    Position,
    MovingTarget,
    Speed,
    Health,
    AnimationState,
};

// 组件数量
pub const component_count = 7;

// 组件签名（bitset）
pub const Signature = std.StaticBitSet(component_count);

// 从组件类型获取枚举值
pub inline fn getComponentType(comptime T: type) ComponentType {
    return switch (T) {
        Components.Player => .Player,
        Components.Model => .Model,
        Components.Position => .Position,
        Components.MovingTarget => .MovingTarget,
        Components.Speed => .Speed,
        Components.Health => .Health,
        Components.AnimationState => .AnimationState,
        else => @compileError("不支持的组件类型: " ++ @typeName(T)),
    };
}

// 从枚举值获取类型名
pub fn getComponentTypeName(comp_type: ComponentType) []const u8 {
    return switch (comp_type) {
        .Player => "Player",
        .Model => "Model",
        .Position => "Position",
        .MovingTarget => "MovingTarget",
        .Speed => "Speed",
        .Health => "Health",
        .AnimationState => "AnimationState",
    };
}
