// block_registry.zig
const std = @import("std");
const Direction = @import("direction.zig").Direction;

/// 掉落物配置（用字符串名避免循环依赖 item_registry）
pub const ItemDropVal = struct {
    item_name: [:0]const u8,
    min_count: u32 = 1,
    max_count: u32 = 1,
    probability: f32 = 1.0,
};

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
    drops: []const ItemDropVal = &.{},
};

/// 方块注册表（每个方块手动指定掉落物）
pub const block_infos = [_]BlockProtoType{
    .{ // 第一个方块必须是空气方块，永远不要把其他方块定义在它的前面
        .name = "air",
        .occludes = false,
        .is_solid = false,
    },
    .{
        .name = "grass",
        .face_variants = .{ 0, 1, 2, 2, 2, 2 },
        .is_directional = false,
        .drops = &.{.{
            .item_name = "grass",
        }},
    },
    .{
        .name = "stone",
        .drops = &.{.{ .item_name = "stone" }},
    },
    .{
        .name = "dirt",
        .drops = &.{.{ .item_name = "dirt" }},
    },
    .{
        .name = "sand",
        .drops = &.{.{ .item_name = "sand" }},
    },
    .{
        .name = "water",
        .occludes = false,
        .opacity = 0.5,
        .is_solid = false,
        .is_swimmable = true,
        .fluid_resistance = 0.3,
    },
    .{
        .name = "snow",
        .drops = &.{.{ .item_name = "snow" }},
    },
    .{ .name = "foo", .drops = &.{.{ .item_name = "foo" }} },
};

pub const MAX_BLOCKS = block_infos.len;

pub const BlockNames = blk: {
    var fields: [MAX_BLOCKS]std.builtin.Type.EnumField = undefined;
    for (&fields, block_infos, 0..) |*field, def, i|
        field.* = .{ .name = def.name, .value = i };
    break :blk @Type(.{ .@"enum" = .{
        .tag_type = u16,
        .fields = &fields,
        .decls = &.{},
        .is_exhaustive = true,
    } });
};

pub const BlockId = enum(u16) {
    _,
    pub fn fromInt(i: anytype) BlockId {
        return @enumFromInt(i);
    }
    pub fn fromName(comptime str: []const u8) BlockId {
        const block_name_val = @field(BlockNames, str);
        return @enumFromInt(@intFromEnum(block_name_val));
    }
    /// 运行时按名字查找（用于存档加载）
    pub fn fromNameRuntime(block_name: []const u8) ?BlockId {
        for (&block_infos, 0..) |info, i| {
            if (std.mem.eql(u8, info.name, block_name)) return @enumFromInt(i);
        }
        return null;
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
    pub fn init(block_id: BlockId) BlockState {
        return .{
            .block_id = block_id,
            .facing = .up,
        };
    }
    pub fn fromName(comptime name: []const u8) BlockState {
        return .{
            .block_id = BlockId.fromName(name),
            .facing = .up,
        };
    }
};
