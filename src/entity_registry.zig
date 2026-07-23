// entity_registry.zig
const std = @import("std");
const ModelId = @import("rend_ctx.zig").ModelId;
const ItemDropVal = @import("block_registry.zig").ItemDropVal;

pub const EntityTypeInfo = struct {
    name: [:0]const u8,
    model_id: ModelId,
    health: f32,
    move_speed: f32,
    run_speed: f32, // 跑步移速（追逐/逃跑时）
    jump_vel: f32,
    attack_damage: f32,
    attack_range: f32,
    attack_interval: f32,
    wander_interval: f32,
    wander_radius: f32 = 0,
    detect_range: f32,
    behavior: enum { hostile, neutral } = .hostile,
    flee_on_attack: bool = false,
    flee_on_detect: bool = true,
    collider_width: f32,
    collider_height: f32,
    drops: []const ItemDropVal = &.{},
};

pub const entity_infos = [_]EntityTypeInfo{
    .{
        .name = "player",
        .model_id = ModelId.fromName("Human"),
        .health = 100,
        .move_speed = 4.0,
        .run_speed = 6.0,
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
        .model_id = ModelId.fromName("Zombie"),
        .health = 50,
        .move_speed = 1.0,
        .run_speed = 2.0,
        .jump_vel = 8.0,
        .attack_damage = 5,
        .attack_range = 2.5,
        .attack_interval = 1.0,
        .wander_interval = 3.0,
        .wander_radius = 8.0,
        .detect_range = 16.0,
        .behavior = .hostile,
        .collider_width = 0.5,
        .collider_height = 1.7,
        .drops = &.{.{ .item_name = "apple", .min_count = 1, .max_count = 2 }},
    },
    .{
        .name = "wolf",
        .model_id = ModelId.fromName("Wolf"),
        .health = 30,
        .move_speed = 2.0,
        .run_speed = 4.0,
        .jump_vel = 12,
        .attack_damage = 8,
        .attack_range = 2.5,
        .attack_interval = 0.6,
        .wander_interval = 2.0,
        .wander_radius = 12.0,
        .detect_range = 20.0,
        .behavior = .hostile,
        .collider_width = 0.5,
        .collider_height = 0.6,
    },
    .{
        .name = "fox",
        .model_id = ModelId.fromName("Fox"),
        .health = 15,
        .move_speed = 2.0,
        .run_speed = 4.0,
        .jump_vel = 10.0,
        .attack_damage = 0,
        .attack_range = 0,
        .attack_interval = 0,
        .wander_interval = 2.0,
        .wander_radius = 10.0,
        .detect_range = 12.0,
        .behavior = .neutral,
        .flee_on_attack = true,
        .collider_width = 0.4,
        .collider_height = 0.6,
    },
    .{
        .name = "deer",
        .model_id = ModelId.fromName("Deer"),
        .health = 25,
        .move_speed = 2.0,
        .run_speed = 5.0,
        .jump_vel = 10.0,
        .attack_damage = 0,
        .attack_range = 0,
        .attack_interval = 0,
        .wander_interval = 3.0,
        .wander_radius = 15.0,
        .detect_range = 8.0,
        .behavior = .neutral,
        .flee_on_attack = true,
        .flee_on_detect = false,
        .collider_width = 0.5,
        .collider_height = 1.2,
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
