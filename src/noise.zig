const std = @import("std");
const Vec3 = @import("algebra.zig").Vec3;

// 算法参考 Stefan Gustavson 的 webgl-noise（MIT）
// https://github.com/ashima/webgl-noise

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

// ─── 3D 值噪声（CPU 端 trilerp，用于 cubemap 烘培）───

// 3D 伪随机 hash（sin 法，返回 [0,1]）
pub fn hash3(v: Vec3) f32 {
    return @mod(@sin(Vec3.dot(v, Vec3.new(12.9898, 78.233, 45.5432))) * 43758.5453, 1.0);
}

// 3D 值噪声：8 顶点 trilerp + smoothstep，返回 [0,1]
pub fn noise3(v: Vec3) f32 {
    const i = Vec3.new(@floor(v.x), @floor(v.y), @floor(v.z));
    const f = Vec3.new(v.x - i.x, v.y - i.y, v.z - i.z);
    const u = f.x * f.x * (3.0 - 2.0 * f.x);
    const ut = Vec3.new(u, f.y * f.y * (3.0 - 2.0 * f.y), f.z * f.z * (3.0 - 2.0 * f.z));
    const a = hash3(Vec3.add(i, Vec3.new(0, 0, 0)));
    const b = hash3(Vec3.add(i, Vec3.new(1, 0, 0)));
    const c = hash3(Vec3.add(i, Vec3.new(0, 1, 0)));
    const d = hash3(Vec3.add(i, Vec3.new(1, 1, 0)));
    const e = hash3(Vec3.add(i, Vec3.new(0, 0, 1)));
    const f_ = hash3(Vec3.add(i, Vec3.new(1, 0, 1)));
    const g = hash3(Vec3.add(i, Vec3.new(0, 1, 1)));
    const h = hash3(Vec3.add(i, Vec3.new(1, 1, 1)));
    const mix1a = a + (b - a) * ut.x;
    const mix1b = c + (d - c) * ut.x;
    const mix1c = e + (f_ - e) * ut.x;
    const mix1d = g + (h - g) * ut.x;
    const mix2a = mix1a + (mix1b - mix1a) * ut.y;
    const mix2b = mix1c + (mix1d - mix1c) * ut.y;
    return mix2a + (mix2b - mix2a) * ut.z;
}

// 3D FBM：多层 noise3 叠加（用于 cubemap 烘培值噪声方案）
pub fn fbm3(v: Vec3, octaves: u32) f32 {
    var total: f32 = 0.0;
    var a: f32 = 0.5;
    var pos = v;
    for (0..octaves) |_| {
        total += a * noise3(pos);
        pos = Vec3.new(pos.x * 2.0 + 1.7, pos.y * 2.0 + 9.2, pos.z * 2.0 + 4.3);
        a *= 0.5;
    }
    return total;
}

// Simplex 噪声
const GRAD3 = [_]f32{
    1, 1, 0, -1, 1,  0, 1, -1, 0,  -1, -1, 0,
    1, 0, 1, -1, 0,  1, 1, 0,  -1, -1, 0,  -1,
    0, 1, 1, 0,  -1, 1, 0, 1,  -1, 0,  -1, -1,
};

// 3D Simplex 噪声。径向衰减半径 0.6（比 Perlin 原始的 0.5 更柔和）
pub fn snoise3(xin: f32, yin: f32, zin: f32) f32 {
    const F3 = 1.0 / 3.0;
    const G3 = 1.0 / 6.0;
    const s = (xin + yin + zin) * F3;
    const i = @floor(xin + s);
    const j = @floor(yin + s);
    const k = @floor(zin + s);
    const t = (i + j + k) * G3;
    const X0 = i - t;
    const Y0 = j - t;
    const Z0 = k - t;
    const x0 = xin - X0;
    const y0 = yin - Y0;
    const z0 = zin - Z0;

    // 四面体顶点坐标偏移（取决于哪个单纯形）
    var i1v: i32 = 0;
    var j1v: i32 = 0;
    var k1v: i32 = 0;
    var i2v: i32 = 0;
    var j2v: i32 = 0;
    var k2v: i32 = 0;
    if (x0 >= y0) {
        if (y0 >= z0) {
            i1v = 1;
            j1v = 0;
            k1v = 0;
            i2v = 1;
            j2v = 1;
            k2v = 0;
        } else if (x0 >= z0) {
            i1v = 1;
            j1v = 0;
            k1v = 0;
            i2v = 1;
            j2v = 0;
            k2v = 1;
        } else {
            i1v = 0;
            j1v = 0;
            k1v = 1;
            i2v = 1;
            j2v = 0;
            k2v = 1;
        }
    } else {
        if (y0 < z0) {
            i1v = 0;
            j1v = 0;
            k1v = 1;
            i2v = 0;
            j2v = 1;
            k2v = 1;
        } else if (x0 < z0) {
            i1v = 0;
            j1v = 1;
            k1v = 0;
            i2v = 0;
            j2v = 1;
            k2v = 1;
        } else {
            i1v = 0;
            j1v = 1;
            k1v = 0;
            i2v = 1;
            j2v = 1;
            k2v = 0;
        }
    }

    // 四个顶点的距离向量
    const x1 = x0 - @as(f32, @floatFromInt(i1v)) + G3;
    const y1 = y0 - @as(f32, @floatFromInt(j1v)) + G3;
    const z1 = z0 - @as(f32, @floatFromInt(k1v)) + G3;
    const x2 = x0 - @as(f32, @floatFromInt(i2v)) + 2.0 * G3;
    const y2 = y0 - @as(f32, @floatFromInt(j2v)) + 2.0 * G3;
    const z2 = z0 - @as(f32, @floatFromInt(k2v)) + 2.0 * G3;
    const x3 = x0 - 1.0 + 3.0 * G3;
    const y3 = y0 - 1.0 + 3.0 * G3;
    const z3 = z0 - 1.0 + 3.0 * G3;

    const ii = @as(usize, @as(u8, @intFromFloat(@mod(i, 256.0))));
    const jj = @as(usize, @as(u8, @intFromFloat(@mod(j, 256.0))));
    const kk = @as(usize, @as(u8, @intFromFloat(@mod(k, 256.0))));

    // 四个顶点的贡献：径向衰减 t = 0.6 - d²，m = max(t,0)⁴
    var n0: f32 = 0;
    var t0 = 0.6 - x0 * x0 - y0 * y0 - z0 * z0;
    if (t0 >= 0) {
        const gi = permMod12[(ii +% perm[(jj +% perm[kk]) & 255]) & 255] * 3;
        t0 *= t0;
        n0 = t0 * t0 * (GRAD3[gi] * x0 + GRAD3[gi + 1] * y0 + GRAD3[gi + 2] * z0);
    }

    var n1: f32 = 0;
    var t1 = 0.6 - x1 * x1 - y1 * y1 - z1 * z1;
    if (t1 >= 0) {
        const gi = permMod12[(ii +% @as(usize, @intCast(i1v)) +% perm[(jj +% @as(usize, @intCast(j1v)) +% perm[(kk +% @as(usize, @intCast(k1v))) & 255]) & 255]) & 255] * 3;
        t1 *= t1;
        n1 = t1 * t1 * (GRAD3[gi] * x1 + GRAD3[gi + 1] * y1 + GRAD3[gi + 2] * z1);
    }

    var n2: f32 = 0;
    var t2 = 0.6 - x2 * x2 - y2 * y2 - z2 * z2;
    if (t2 >= 0) {
        const gi = permMod12[(ii +% @as(usize, @intCast(i2v)) +% perm[(jj +% @as(usize, @intCast(j2v)) +% perm[(kk +% @as(usize, @intCast(k2v))) & 255]) & 255]) & 255] * 3;
        t2 *= t2;
        n2 = t2 * t2 * (GRAD3[gi] * x2 + GRAD3[gi + 1] * y2 + GRAD3[gi + 2] * z2);
    }

    var n3: f32 = 0;
    var t3 = 0.6 - x3 * x3 - y3 * y3 - z3 * z3;
    if (t3 >= 0) {
        const gi = permMod12[(ii +% 1 +% perm[(jj +% 1 +% perm[(kk +% 1) & 255]) & 255]) & 255] * 3;
        t3 *= t3;
        n3 = t3 * t3 * (GRAD3[gi] * x3 + GRAD3[gi + 1] * y3 + GRAD3[gi + 2] * z3);
    }

    return 32.0 * (n0 + n1 + n2 + n3);
}

// FBM（分形布朗运动）：多层 snoise3 叠加，频率倍增、振幅衰减
pub fn fbmSnoise3(v: Vec3, octaves: u32) f32 {
    var total: f32 = 0.0;
    var a: f32 = 0.5;
    var pos = v;
    for (0..octaves) |_| {
        total += a * snoise3(pos.x, pos.y, pos.z);
        pos = Vec3.new(pos.x * 2.0 + 1.7, pos.y * 2.0 + 9.2, pos.z * 2.0 + 4.3);
        a *= 0.5;
    }
    return total;
}
