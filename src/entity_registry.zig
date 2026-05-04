// entity_registry.zig
const std = @import("std");
const ModelId = @import("rend_ctx.zig").ModelId;

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
};

const entity_infos = [_]EntityTypeInfo{
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
        .collider_width = 0.4,
        .collider_height = 1.8,
    },
    .{
        .name = "wolf",
        .model_id = ModelId.fromName("Wolf"),
        .health = 30,
        .move_speed = 3.5,
        .jump_vel = 8.5,
        .attack_damage = 8,
        .attack_range = 2.5,
        .attack_interval = 0.6,
        .wander_interval = 2.0,
        .detect_range = 20.0,
        .collider_width = 0.4,
        .collider_height = 1.2,
    },
};

pub const MAX_ENTITY_TYPES = entity_infos.len;

pub const EntityTypeNames = blk: {
    var fields: [MAX_ENTITY_TYPES]std.builtin.Type.EnumField = undefined;
    for (&fields, entity_infos, 0..) |*field, def, i|
        field.* = .{ .name = def.name, .value = i };
    break :blk @Type(.{ .@"enum" = .{
        .tag_type = u32,
        .fields = &fields,
        .decls = &.{},
        .is_exhaustive = true,
    } });
};

pub const EntityTypeId = enum(u32) {
    _,
    pub fn fromInt(i: anytype) EntityTypeId {
        return @enumFromInt(i);
    }
    pub fn fromName(comptime str: []const u8) EntityTypeId {
        return @enumFromInt(@intFromEnum(@field(EntityTypeNames, str)));
    }
    pub fn info(self: EntityTypeId) EntityTypeInfo {
        return entity_infos[@intFromEnum(self)];
    }
};
