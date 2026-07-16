// tree_gen.zig — 程序化树生成
const std = @import("std");
const Vec3i = @import("algebra.zig").Vec3i;
const BlockState = @import("block_registry.zig").BlockState;
const BlockId = @import("block_registry.zig").BlockId;
const Chunk = @import("block_world.zig").Chunk;
const CHUNK_WIDTH = @import("block_world.zig").CHUNK_WIDTH;
const CHUNK_HEIGHT = @import("block_world.zig").CHUNK_HEIGHT;
const Noise = @import("noise.zig");

fn hashSeed(x: i32, y: i32, z: i32) u64 {
    var h: u64 = @as(u64, @as(u32, @bitCast(x)));
    h = h *% 0x9e3779b97f4a7c15;
    h ^= @as(u64, @as(u32, @bitCast(y)));
    h = h *% 0x9e3779b97f4a7c15;
    h ^= @as(u64, @as(u32, @bitCast(z)));
    h = h *% 0x9e3779b97f4a7c15;
    h ^= h >> 31;
    return h;
}

/// 在已生成的 chunk 上添加榕树。
/// 扫描 grass 地表，以噪声密度决定是否生成榕树。
pub fn populateBanyan(chunk: *Chunk, world_origin: Vec3i) void {
    const tree_density_scale: f32 = 0.03;
    const tree_threshold: f32 = 0.25;
    const min_spacing: i32 = 7;
    const margin: u32 = 4; // 树干离边界至少 4 格，确保树冠不跨区块

    const wx0 = world_origin.x;
    const wz0 = world_origin.z;

    // 间距标记网格，标记过的位置不再种树
    var occupied: [CHUNK_WIDTH][CHUNK_WIDTH]bool = [_][CHUNK_WIDTH]bool{[_]bool{false} ** CHUNK_WIDTH} ** CHUNK_WIDTH;

    var x: u32 = margin;
    while (x < CHUNK_WIDTH - margin) : (x += 1) {
        const world_x = wx0 + @as(i32, @intCast(x));

        var z: u32 = margin;
        while (z < CHUNK_WIDTH - margin) : (z += 1) {
            if (occupied[x][z]) continue;
            const world_z = wz0 + @as(i32, @intCast(z));

            // 从上往下扫描地表
            const surface_y = blk: {
                var yy: u32 = CHUNK_HEIGHT;
                while (yy > 0) {
                    yy -= 1;
                    if (chunk.getBlockId(x, yy, z) != BlockId.fromName("air"))
                        break :blk yy;
                }
                break :blk null;
            };
            const sy = surface_y orelse continue;

            if (chunk.getBlockId(x, sy, z) != BlockId.fromName("grass"))
                continue;

            // 密度噪声
            const noise_val = Noise.perlin2d(
                @as(f32, @floatFromInt(world_x)) * tree_density_scale,
                @as(f32, @floatFromInt(world_z)) * tree_density_scale,
            );
            if (noise_val > tree_threshold) continue;

            // 确定性随机
            const seed = hashSeed(world_x, @as(i32, @intCast(sy)), world_z) ^ 0xB4A4A4A;
            var rng = std.Random.DefaultPrng.init(seed);
            const rdm = rng.random();

            const trunk_h: u32 = 4 + rdm.uintLessThan(u32, 3);
            const canopy_r: f32 = 2.0 + @as(f32, @floatFromInt(rdm.uintLessThan(u32, 2))); // 2-3 格，不跨区块
            const canopy_vr: f32 = canopy_r * 0.65; // 竖径比 0.75，更接近球形

            // ——— 树干 ———
            var dy: u32 = 0;
            while (dy < trunk_h and sy + dy < CHUNK_HEIGHT) : (dy += 1) {
                chunk.setBlock(x, sy + dy, z, BlockState.init(BlockId.fromName("banyan_trunk")));
            }

            // ——— 树冠（椭球） ———
            const trunk_top_i32: i32 = @as(i32, @intCast(sy + trunk_h));
            // 树冠中心放在树干顶部偏下一点，让树干穿入树冠内部
            const crown_cy_i32: i32 = trunk_top_i32 - @as(i32, @intFromFloat(canopy_vr * 0.4));
            const cr_i32: i32 = @as(i32, @intFromFloat(@ceil(canopy_r))) + 1;
            const cvr_i32: i32 = @as(i32, @intFromFloat(@ceil(canopy_vr))) + 1;
            const r2 = canopy_r * canopy_r;
            const vr2 = canopy_vr * canopy_vr;
            const xi: i32 = @as(i32, @intCast(x));
            const zi: i32 = @as(i32, @intCast(z));

            var dx: i32 = -cr_i32;
            while (dx <= cr_i32) : (dx += 1) {
                var dly: i32 = -cvr_i32;
                while (dly <= cvr_i32) : (dly += 1) {
                    var dz: i32 = -cr_i32;
                    while (dz <= cr_i32) : (dz += 1) {
                        const fx = @as(f32, @floatFromInt(dx));
                        const fy = @as(f32, @floatFromInt(dly));
                        const fz = @as(f32, @floatFromInt(dz));

                        const dist = (fx * fx) / r2 + (fy * fy) / vr2 + (fz * fz) / r2;
                        if (dist > 1.0) continue;
                        if (dist > 0.75 and rdm.uintLessThan(u32, 10) < 3) continue;

                        const lx = xi + dx;
                        const ly_i32 = crown_cy_i32 + dly;
                        const lz = zi + dz;

                        if (lx < 0 or lx >= CHUNK_WIDTH) continue;
                        if (ly_i32 < 0 or ly_i32 >= CHUNK_HEIGHT) continue;
                        if (lz < 0 or lz >= CHUNK_WIDTH) continue;

                        // 不覆盖树干
                        if (ly_i32 < trunk_top_i32 and lx == xi and lz == zi) continue;

                        chunk.setBlock(
                            @as(u32, @intCast(lx)),
                            @as(u32, @intCast(ly_i32)),
                            @as(u32, @intCast(lz)),
                            BlockState.init(BlockId.fromName("banyan_leaves")),
                        );
                    }
                }
            }
            // 标记间距：以 (x,z) 为中心 min_spacing 半径内不再种树
            const x_start = if (x < min_spacing) 0 else x - min_spacing;
            const x_end = @min(x + min_spacing, CHUNK_WIDTH - 1);
            const z_start = if (z < min_spacing) 0 else z - min_spacing;
            const z_end = @min(z + min_spacing, CHUNK_WIDTH - 1);
            var ox: u32 = @intCast(x_start);
            while (ox <= x_end) : (ox += 1) {
                var oz: u32 = @intCast(z_start);
                while (oz <= z_end) : (oz += 1) {
                    const dx2 = @as(i32, @intCast(ox)) - @as(i32, @intCast(x));
                    const dz2 = @as(i32, @intCast(oz)) - @as(i32, @intCast(z));
                    if (dx2 * dx2 + dz2 * dz2 < min_spacing * min_spacing) {
                        occupied[ox][oz] = true;
                    }
                }
            }
        }
    }
}
