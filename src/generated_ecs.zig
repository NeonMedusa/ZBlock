// generated_ecs.zig
// 此文件由 code_generator.zig 自动生成
// 请勿手动修改此文件

const std = @import("std");
const Algebra = @import("zalgebra");
const Vec3 = Algebra.Vec3;
const Mat4 = Algebra.Mat4;
const Input = @import("input.zig");
const Key = Input.Key;
const ComponentStorage = @import("component_storage.zig").ComponentStorage;
const Components = @import("components.zig").Components;
pub const EntityId = u32;

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

// 世界
pub const World = struct {
    allocator: std.mem.Allocator,
    next_entity_id: EntityId = 0,
    available_ids: std.ArrayList(EntityId), // 可用ID池
    signatures: std.ArrayList(Signature), // 实体签名存储

    // 组件存储
    players: ComponentStorage(Components.Player), // player
    models: ComponentStorage(Components.Model), // model
    positions: ComponentStorage(Components.Position), // position
    moving_targets: ComponentStorage(Components.MovingTarget), // movingtarget
    speeds: ComponentStorage(Components.Speed), // speed
    healths: ComponentStorage(Components.Health), // health
    animation_states: ComponentStorage(Components.AnimationState), // animationstate

    // 初始化
    pub fn init(allocator: std.mem.Allocator) World {
        return .{
            .allocator = allocator,
            .available_ids = std.ArrayList(EntityId){},
            .signatures = std.ArrayList(Signature){},
            .players = ComponentStorage(Components.Player).init(allocator),
            .models = ComponentStorage(Components.Model).init(allocator),
            .positions = ComponentStorage(Components.Position).init(allocator),
            .moving_targets = ComponentStorage(Components.MovingTarget).init(allocator),
            .speeds = ComponentStorage(Components.Speed).init(allocator),
            .healths = ComponentStorage(Components.Health).init(allocator),
            .animation_states = ComponentStorage(Components.AnimationState).init(allocator),
        };
    }

    // 析构
    pub fn deinit(self: *World) void {
        self.available_ids.deinit(self.allocator);
        self.signatures.deinit(self.allocator);
        self.players.deinit(self.allocator);
        self.models.deinit(self.allocator);
        self.positions.deinit(self.allocator);
        self.moving_targets.deinit(self.allocator);
        self.speeds.deinit(self.allocator);
        self.healths.deinit(self.allocator);
        self.animation_states.deinit(self.allocator);
    }

    // 设置组件并更新签名
    pub fn setComponent(self: *World, entity: EntityId, component: anytype) !void {
        const T = @TypeOf(component);
        const comp_type = getComponentType(T);
        // 存储组件数据
        switch (comp_type) {
            .Player => try self.players.set(entity, component),
            .Model => try self.models.set(entity, component),
            .Position => try self.positions.set(entity, component),
            .MovingTarget => try self.moving_targets.set(entity, component),
            .Speed => try self.speeds.set(entity, component),
            .Health => try self.healths.set(entity, component),
            .AnimationState => try self.animation_states.set(entity, component),
        }
        // 更新实体签名（设置对应位为1）
        var sig = self.signatures.items[entity];
        sig.set(@intFromEnum(comp_type));
        self.signatures.items[entity] = sig;
    }

    // 移除组件并更新签名
    pub fn removeComponent(self: *World, entity: EntityId, comp_type: ComponentType) bool {
        var removed = false;
        switch (comp_type) {
            .Player => removed = self.players.remove(entity),
            .Model => removed = self.models.remove(entity),
            .Position => removed = self.positions.remove(entity),
            .MovingTarget => removed = self.moving_targets.remove(entity),
            .Speed => removed = self.speeds.remove(entity),
            .Health => removed = self.healths.remove(entity),
            .AnimationState => removed = self.animation_states.remove(entity),
        }
        // 更新实体签名（清除对应位）
        if (removed) {
            var sig = self.signatures.items[entity];
            sig.unset(@intFromEnum(comp_type));
            self.signatures.items[entity] = sig;
        }
        return removed;
    }

    // 创建实体
    pub fn createEntity(self: *World) !EntityId {
        // 复用已删除的实体ID
        if (self.available_ids.pop()) |id| return id;
        // 如果无可复用ID，则分配新ID并初始化一个空的组件签名
        const id = self.next_entity_id;
        self.next_entity_id += 1;
        try self.signatures.append(self.allocator, Signature.initEmpty());
        return id;
    }

    // 移除实体
    pub fn removeEntity(self: *World, entity: EntityId) !void {
        // 将ID归还给可用ID池
        try self.available_ids.append(self.allocator, entity);
        // 清空组件签名
        self.signatures.items[entity] = Signature.initEmpty();
        // 清理所有组件
        _ = self.players.remove(entity);
        _ = self.models.remove(entity);
        _ = self.positions.remove(entity);
        _ = self.moving_targets.remove(entity);
        _ = self.speeds.remove(entity);
        _ = self.healths.remove(entity);
        _ = self.animation_states.remove(entity);
    }
};
