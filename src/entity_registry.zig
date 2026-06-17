// entity_registry.zig
const std = @import("std");
const ModelId = @import("rend_ctx.zig").ModelId;
const ItemDropVal = @import("block_registry.zig").ItemDropVal;

pub const EntityTypeInfo = struct {
    name: [:0]const u8,
    model_id: ModelId,
    health: f32,
    move_speed: f32,
    jump_vel: f32,
    attack_damage: f32,
    attack_range: f32,
    attack_interval: f32,
    wander_interval: f32,
    detect_range: f32,
    collider_width: f32,
    collider_height: f32,
    drops: []const ItemDropVal = &.{},
};

pub const entity_infos = [_]EntityTypeInfo{
    .{
        .name = "player",
        .model_id = ModelId.fromName("CesiumMan"),
        .health = 100,
        .move_speed = 4.0,
        .jump_vel = 14.0,
        .attack_damage = 0,
        .attack_range = 0,
        .attack_interval = 0,
        .wander_interval = 0,
        .detect_range = 0,
        .collider_width = 0.6,
        .collider_height = 1.8,
    },
    .{
        .name = "zombie",
        .model_id = ModelId.fromName("CesiumMan"),
        .health = 50,
        .move_speed = 2.0,
        .jump_vel = 8.0,
        .attack_damage = 5,
        .attack_range = 2.5,
        .attack_interval = 1.0,
        .wander_interval = 3.0,
        .detect_range = 16.0,
        .collider_width = 0.5,
        .collider_height = 1.7,
        .drops = &.{.{ .item_name = "apple", .min_count = 1, .max_count = 2 }},
    },
    .{
        .name = "wolf",
        .model_id = ModelId.fromName("Wolf"),
        .health = 30,
        .move_speed = 3.5,
        .jump_vel = 12,
        .attack_damage = 8,
        .attack_range = 2.5,
        .attack_interval = 0.6,
        .wander_interval = 2.0,
        .detect_range = 20.0,
        .collider_width = 0.5,
        .collider_height = 0.6,
    },
};

pub const MAX_ENTITY_TYPES = entity_infos.len;

pub const EntityTypeId = packed struct(u32) {
    id: u32,
    pub fn fromInt(i: anytype) EntityTypeId {
        return .{ .id = @intCast(i) };
    }
    pub fn fromName(comptime str: []const u8) EntityTypeId {
        inline for (&entity_infos, 0..) |ent, i| {
            if (comptime std.mem.eql(u8, ent.name, str)) return .{ .id = i };
        }
        @compileError("unknown entity: " ++ str);
    }
    pub fn info(self: EntityTypeId) EntityTypeInfo {
        return entity_infos[self.id];
    }
    pub fn fromNameRuntime(name: []const u8) ?EntityTypeId {
        for (&entity_infos, 0..) |ent, i| {
            if (std.mem.eql(u8, ent.name, name)) return .{ .id = i };
        }
        return null;
    }
};
