const std = @import("std");

// 排列表（运行时由 init(seed) 生成）
var perm: [256]u8 = undefined;
var permMod12: [256]u8 = undefined;

// 初始化 根据种子生成排列表（Fisher-Yates洗牌）
pub fn init(seed: u64) void {
    for (0..256) |i| perm[i] = @intCast(i);
    var rng = std.Random.DefaultPrng.init(seed);
    for (0..254) |i| {
        const j = i + @as(usize, rng.random().uintLessThan(usize, 256 - i));
        const tmp = perm[i];
        perm[i] = perm[j];
        perm[j] = tmp;
    }
    for (0..256) |i| permMod12[i] = perm[i] % 12;
}

// Perlin 噪声：fade 曲线（Quintic，一/二阶导在 0/1 处为 0）
fn fade(t: f32) f32 {
    return t * t * t * (t * (t * 6.0 - 15.0) + 10.0);
}

// 3D Perlin 梯度（hash 低 4 位决定方向）
fn grad3d(hash: u8, x: f32, y: f32, z: f32) f32 {
    const h = hash & 15;
    const u = if (h < 8) x else y;
    const v = if (h < 4) y else if (h == 12 or h == 14) x else z;
    const sign_u = if ((h & 1) == 0) u else -u;
    const sign_v = if ((h & 2) == 0) v else -v;
    return sign_u + sign_v;
}

// 2D Perlin 梯度（hash 低 2 位决定方向）
fn grad2d(hash: u8, x: f32, y: f32) f32 {
    return switch (hash & 3) {
        0 => x + y,
        1 => -x + y,
        2 => x - y,
        3 => -x - y,
        else => unreachable,
    };
}

// 2D Perlin 噪声（返回 [0,1]）
pub fn perlin2d(x: f32, y: f32) f32 {
    const xi: i32 = @intFromFloat(@floor(x));
    const yi: i32 = @intFromFloat(@floor(y));
    const xi_u8: u8 = @intCast(xi & 255);
    const yi_u8: u8 = @intCast(yi & 255);

    const xf = x - @floor(x);
    const yf = y - @floor(y);

    const u = fade(xf);
    const v = fade(yf);

    const aa = perm[perm[xi_u8] +% yi_u8];
    const ba = perm[perm[xi_u8 +% 1] +% yi_u8];
    const ab = perm[perm[xi_u8] +% yi_u8 +% 1];
    const bb = perm[perm[xi_u8 +% 1] +% yi_u8 +% 1];

    const x1 = grad2d(aa, xf, yf) + u * (grad2d(ba, xf - 1.0, yf) - grad2d(aa, xf, yf));
    const x2 = grad2d(ab, xf, yf - 1.0) + u * (grad2d(bb, xf - 1.0, yf - 1.0) - grad2d(ab, xf, yf - 1.0));

    return (x1 + v * (x2 - x1) + 1.0) / 2.0;
}

// 3D Perlin 噪声（返回 [0,1]）
pub fn perlin3d(x: f32, y: f32, z: f32) f32 {
    const xi: i32 = @intFromFloat(@floor(x));
    const yi: i32 = @intFromFloat(@floor(y));
    const zi: i32 = @intFromFloat(@floor(z));
    const xi_u8: u8 = @intCast(xi & 255);
    const yi_u8: u8 = @intCast(yi & 255);
    const zi_u8: u8 = @intCast(zi & 255);

    const xf = x - @floor(x);
    const yf = y - @floor(y);
    const zf = z - @floor(z);

    const u = fade(xf);
    const v = fade(yf);
    const w = fade(zf);

    const a = perm[xi_u8] +% yi_u8;
    const aa = perm[a] +% zi_u8;
    const ab = perm[a +% 1] +% zi_u8;
    const b = perm[xi_u8 +% 1] +% yi_u8;
    const ba = perm[b] +% zi_u8;
    const bb = perm[b +% 1] +% zi_u8;

    const g0 = grad3d(perm[aa], xf, yf, zf);
    const g1 = grad3d(perm[ba], xf - 1.0, yf, zf);
    const g2 = grad3d(perm[ab], xf, yf - 1.0, zf);
    const g3 = grad3d(perm[bb], xf - 1.0, yf - 1.0, zf);
    const x1 = g0 + u * (g1 - g0);
    const x2 = g2 + u * (g3 - g2);
    const y1 = x1 + v * (x2 - x1);

    const g4 = grad3d(perm[aa +% 1], xf, yf, zf - 1.0);
    const g5 = grad3d(perm[ba +% 1], xf - 1.0, yf, zf - 1.0);
    const g6 = grad3d(perm[ab +% 1], xf, yf - 1.0, zf - 1.0);
    const g7 = grad3d(perm[bb +% 1], xf - 1.0, yf - 1.0, zf - 1.0);
    const x3 = g4 + u * (g5 - g4);
    const x4 = g6 + u * (g7 - g6);
    const y2 = x3 + v * (x4 - x3);

    return (y1 + w * (y2 - y1) + 1.0) / 2.0;
}

// 2D FBM：多层 perlin2d 叠加
pub fn octavePerlin2d(x: f32, y: f32, octaves: u32, persistence: f32) f32 {
    var total: f32 = 0.0;
    var frequency: f32 = 1.0;
    var amplitude: f32 = 1.0;
    var max_value: f32 = 0.0;

    for (0..octaves) |_| {
        total += perlin2d(x * frequency, y * frequency) * amplitude;
        max_value += amplitude;
        amplitude *= persistence;
        frequency *= 2.0;
    }

    return total / max_value;
}

// 3D FBM：多层 perlin3d 叠加
pub fn octavePerlin3d(x: f32, y: f32, z: f32, octaves: u32, persistence: f32) f32 {
    var total: f32 = 0.0;
    var frequency: f32 = 1.0;
    var amplitude: f32 = 1.0;
    var max_value: f32 = 0.0;

    for (0..octaves) |_| {
        total += perlin3d(x * frequency, y * frequency, z * frequency) * amplitude;
        max_value += amplitude;
        amplitude *= persistence;
        frequency *= 2.0;
    }

    return total / max_value;
}
