// block_registry.zig
const std = @import("std");
const Direction = @import("direction.zig").Direction;

/// 方块原型
pub const BlockProtoType = struct {
    name: [:0]const u8,
    face_variants: [6]u3 = [1]u3{0} ** 6,
    occludes: bool = true,
    opacity: f32 = 1.0,
    is_solid: bool = true,
    is_swimmable: bool = false,
    fluid_resistance: f32 = 0.0,
    durability: u32 = 32,
    is_directional: bool = true,
};

/// 方块注册表
pub const block_infos = [_]BlockProtoType{
    .{
        .name = "air",
        .occludes = false,
        .is_solid = false,
    },
    .{
        .name = "grass",
        .face_variants = .{ 0, 1, 2, 2, 2, 2 },
        .is_directional = false,
    },
    .{ .name = "stone" },
    .{ .name = "dirt" },
    .{ .name = "sand" },
    .{
        .name = "water",
        .occludes = false,
        .opacity = 0.5,
        .is_solid = false,
        .is_swimmable = true,
        .fluid_resistance = 0.3,
    },
    .{ .name = "foo" },
};

pub const MAX_BLOCKS = block_infos.len;

pub const BlockNames = blk: {
    var fields: [MAX_BLOCKS]std.builtin.Type.EnumField = undefined;
    for (&fields, block_infos, 0..) |*field, def, i|
        field.* = .{ .name = def.name, .value = i };
    break :blk @Type(.{ .@"enum" = .{
        .tag_type = u32,
        .fields = &fields,
        .decls = &.{},
        .is_exhaustive = true,
    } });
};

pub const BlockId = enum(u32) {
    _,
    pub fn fromInt(i: anytype) BlockId {
        return @enumFromInt(i);
    }
    pub fn fromName(comptime str: []const u8) BlockId {
        const block_name_val = @field(BlockNames, str);
        return @enumFromInt(@intFromEnum(block_name_val));
    }
    pub fn prototype(self: BlockId) BlockProtoType {
        return block_infos[@intFromEnum(self)];
    }
    pub fn name(self: BlockId) [:0]const u8 {
        return self.prototype().name;
    }
};

pub const BlockState = struct {
    block_id: BlockId = BlockId.fromName("air"),
    facing: Direction = .up,
    // durability: u32 = 10,
    pub fn init(block_id: BlockId) BlockState {
        return .{
            .block_id = block_id,
            .facing = .up,
            // .durability = block_id.prototype().durability,
        };
    }
};
