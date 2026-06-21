// drops.zig — 掉落物结算公共函数
const std = @import("std");
const io = @import("imports.zig").io;
const registries = @import("registries.zig");

pub const DropRoll = struct {
    item_id: u32,
    count: u32,
};

/// 结算实体掉落，返回掉落数组（items[0..count] 为有效项）
pub fn rollEntityDrops(entity_type_id: usize) struct { items: [8]DropRoll, count: usize } {
    var items: [8]DropRoll = undefined;
    var count: usize = 0;
    for (registries.getEntityDrops(entity_type_id)) |d| {
        if (count >= 8) break;
        var rbuf: [4]u8 = undefined;
        io.random(&rbuf);
        const rnd = @as(f32, @floatFromInt(std.mem.readInt(u32, &rbuf, .little))) / @as(f32, @floatFromInt(std.math.maxInt(u32)));
        if (rnd >= d.probability) continue;
        io.random(&rbuf);
        const rf2 = @as(f32, @floatFromInt(std.mem.readInt(u32, &rbuf, .little))) / @as(f32, @floatFromInt(std.math.maxInt(u32)));
        const extra: u32 = @intFromFloat(rf2 * @as(f32, @floatFromInt(d.max_count - d.min_count + 1)));
        items[count] = .{ .item_id = d.item_id, .count = d.min_count + extra };
        count += 1;
    }
    return .{ .items = items, .count = count };
}
