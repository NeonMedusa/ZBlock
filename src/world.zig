const std = @import("std");
// 从组件文件导入所有组件类型
const Components = @import("components.zig");
// 实体只是一个唯一的标识符
pub const Entity = u32;
// 世界结构体
pub const World = struct {
    allocator: std.mem.Allocator,
    entities: std.ArrayList(Entity),
    next_entity_id: Entity = 0,
    // 组件存储
    positions: std.ArrayList(?Components.Position3D),
    velocities: std.ArrayList(?Components.Velocity3D),
    healths: std.ArrayList(?Components.Health),
    // 初始化
    pub fn init(allocator: std.mem.Allocator) !World {
        return .{
            .allocator = allocator,
            .entities = std.ArrayList(Entity){},
            .positions = std.ArrayList(?Components.Position3D){},
            .velocities = std.ArrayList(?Components.Velocity3D){},
            .healths = std.ArrayList(?Components.Health){},
        };
    }
    // 析构
    pub fn deinit(self: *World) void {
        self.entities.deinit(self.allocator);
        self.positions.deinit(self.allocator);
        self.velocities.deinit(self.allocator);
        self.healths.deinit(self.allocator);
    }
    // 创建实体
    pub fn createEntity(self: *World) !Entity {
        const id = self.next_entity_id;
        self.next_entity_id += 1;
        try self.entities.append(id);
        try self.positions.append(null);
        try self.velocities.append(null);
        try self.healths.append(null);
        return id;
    }
    // 添加组件
    pub fn addComponent(self: *World, entity: Entity, component: anytype) !void {
        const T = @TypeOf(component);
        if (T == Components.Position3D) {
            self.positions.items[entity] = component;
        } else if (T == Components.Velocity3D) {
            self.velocities.items[entity] = component;
        } else if (T == Components.Health) {
            self.healths.items[entity] = component;
        } else {
            @compileError("Unsupported component type: " ++ @typeName(T));
        }
    }
    // 获取组件
    pub fn getComponent(self: *World, entity: Entity, comptime T: type) ?*T {
        return switch (T) {
            Components.Position3D => if (self.positions.items[entity]) |*pos| pos else null,
            Components.Velocity3D => if (self.velocities.items[entity]) |*vel| vel else null,
            Components.Health => if (self.healths.items[entity]) |*h| h else null,
            else => null,
        };
    }
    // 检查实体是否拥有某个组件
    pub fn hasComponent(self: *World, entity: Entity, comptime T: type) bool {
        return self.getComponent(entity, T) != null;
    }
};
