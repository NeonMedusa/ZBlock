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
/// face_variants 0 到 5 个索引分别对应
// 上、下、北、南、西、东 六个面的贴图，与direction.zig中的方向顺序一致
pub const block_infos = [_]BlockProtoType{
    .{ // 第一个方块必须是空气方块，永远不要把其他方块定义在它的前面
        .name = "air",
        .occludes = false,
        .is_solid = false,
    },
    .{ // 草方块
        .name = "grass",
        .face_variants = .{ 0, 1, 2, 2, 2, 2 },
        // .is_directional = false,
        .drops = &.{.{
            .item_name = "grass",
        }},
    },
    .{ // 石
        .name = "stone",
        .drops = &.{.{ .item_name = "stone" }},
    },
    .{ // 土
        .name = "dirt",
        .drops = &.{.{ .item_name = "dirt" }},
    },
    .{ // 沙
        .name = "sand",
        .drops = &.{.{ .item_name = "sand" }},
    },
    .{ // 水
        .name = "water",
        .is_directional = false,
        .occludes = false,
        .opacity = 0.5,
        .is_solid = false,
        .is_swimmable = true,
        .fluid_resistance = 0.3,
    },
    .{ // 雪
        .name = "snow",
        .drops = &.{.{ .item_name = "snow" }},
    },
    .{ // 基岩：无法破坏（创造模式除外），不掉落
        .name = "bedrock",
        .is_solid = true,
        .durability = 0, // 0 = 不可破坏
        .drops = &.{},
    },
    .{ // 调试用方块
        .name = "foo",
        .drops = &.{.{ .item_name = "foo" }},
    },
    .{ // 榕树木头：横切面（上/下）≈ trunk_0，侧面 ≈ trunk_2
        .name = "banyan_trunk",
        .face_variants = .{ 0, 0, 2, 2, 2, 2 },
        .drops = &.{.{ .item_name = "banyan_trunk" }},
    },
    .{ // 榕树树叶：半透明，不遮挡邻接面
        .name = "banyan_leaves",
        .occludes = false,
        .opacity = 0.8,
        .is_directional = false,
        .drops = &.{.{ .item_name = "banyan_leaves" }},
    },
};

pub const MAX_BLOCKS = block_infos.len;

pub const BlockId = packed struct(u16) {
    id: u16,
    pub fn fromInt(i: anytype) BlockId {
        return .{ .id = @intCast(i) };
    }
    pub fn fromName(comptime str: []const u8) BlockId {
        inline for (&block_infos, 0..) |info, i| {
            if (comptime std.mem.eql(u8, info.name, str)) return .{ .id = i };
        }
        @compileError("unknown block: " ++ str);
    }
    pub fn fromNameRuntime(block_name: []const u8) ?BlockId {
        for (&block_infos, 0..) |info, i| {
            if (std.mem.eql(u8, info.name, block_name)) return .{ .id = i };
        }
        return null;
    }
    pub fn prototype(self: BlockId) BlockProtoType {
        return block_infos[self.id];
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
