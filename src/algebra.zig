const std = @import("std");

pub const PI = std.math.pi;
pub const EPS = 1e-6;

pub const Vec2 = struct {
    x: f32,
    y: f32,

    pub const zero = Vec2{ .x = 0, .y = 0 };
    pub const one = Vec2{ .x = 1, .y = 1 };
    pub const unit_x = Vec2{ .x = 1, .y = 0 };
    pub const unit_y = Vec2{ .x = 0, .y = 1 };

    pub fn new(x: f32, y: f32) Vec2 {
        return .{ .x = x, .y = y };
    }

    pub fn add(a: Vec2, b: Vec2) Vec2 {
        return .{ .x = a.x + b.x, .y = a.y + b.y };
    }

    pub fn sub(a: Vec2, b: Vec2) Vec2 {
        return .{ .x = a.x - b.x, .y = a.y - b.y };
    }

    pub fn mul(a: Vec2, b: Vec2) Vec2 {
        return .{ .x = a.x * b.x, .y = a.y * b.y };
    }

    pub fn div(a: Vec2, b: Vec2) Vec2 {
        return .{ .x = a.x / b.x, .y = a.y / b.y };
    }

    pub fn scale(v: Vec2, s: f32) Vec2 {
        return .{ .x = v.x * s, .y = v.y * s };
    }

    pub fn neg(v: Vec2) Vec2 {
        return .{ .x = -v.x, .y = -v.y };
    }

    pub fn dot(a: Vec2, b: Vec2) f32 {
        return a.x * b.x + a.y * b.y;
    }

    pub fn len2(v: Vec2) f32 {
        return v.dot(v);
    }

    pub fn len(v: Vec2) f32 {
        return @sqrt(v.len2());
    }

    pub fn norm(v: Vec2) Vec2 {
        const l = v.len();
        if (l < EPS) return zero;
        return v.scale(1 / l);
    }

    pub fn lerp(a: Vec2, b: Vec2, t: f32) Vec2 {
        return a.add(b.sub(a).scale(t));
    }

    pub fn min(a: Vec2, b: Vec2) Vec2 {
        return .{ .x = @min(a.x, b.x), .y = @min(a.y, b.y) };
    }

    pub fn max(a: Vec2, b: Vec2) Vec2 {
        return .{ .x = @max(a.x, b.x), .y = @max(a.y, b.y) };
    }

    pub fn abs(v: Vec2) Vec2 {
        return .{ .x = @abs(v.x), .y = @abs(v.y) };
    }

    pub fn eql(a: Vec2, b: Vec2) bool {
        return a.x == b.x and a.y == b.y;
    }
};

pub const Vec3 = struct {
    x: f32,
    y: f32,
    z: f32,

    pub const zero = Vec3{ .x = 0, .y = 0, .z = 0 };
    pub const one = Vec3{ .x = 1, .y = 1, .z = 1 };
    pub const unit_x = Vec3{ .x = 1, .y = 0, .z = 0 };
    pub const unit_y = Vec3{ .x = 0, .y = 1, .z = 0 };
    pub const unit_z = Vec3{ .x = 0, .y = 0, .z = 1 };
    pub const forward = Vec3{ .x = 0, .y = 0, .z = -1 };
    pub const up = Vec3{ .x = 0, .y = 1, .z = 0 };
    pub const right = Vec3{ .x = 1, .y = 0, .z = 0 };

    pub fn new(x: f32, y: f32, z: f32) Vec3 {
        return .{ .x = x, .y = y, .z = z };
    }

    pub fn add(a: Vec3, b: Vec3) Vec3 {
        return .{ .x = a.x + b.x, .y = a.y + b.y, .z = a.z + b.z };
    }

    pub fn sub(a: Vec3, b: Vec3) Vec3 {
        return .{ .x = a.x - b.x, .y = a.y - b.y, .z = a.z - b.z };
    }

    pub fn mul(a: Vec3, b: Vec3) Vec3 {
        return .{ .x = a.x * b.x, .y = a.y * b.y, .z = a.z * b.z };
    }

    pub fn scale(v: Vec3, s: f32) Vec3 {
        return .{ .x = v.x * s, .y = v.y * s, .z = v.z * s };
    }

    pub fn neg(v: Vec3) Vec3 {
        return .{ .x = -v.x, .y = -v.y, .z = -v.z };
    }

    pub fn dot(a: Vec3, b: Vec3) f32 {
        return a.x * b.x + a.y * b.y + a.z * b.z;
    }

    pub fn cross(a: Vec3, b: Vec3) Vec3 {
        return .{
            .x = a.y * b.z - a.z * b.y,
            .y = a.z * b.x - a.x * b.z,
            .z = a.x * b.y - a.y * b.x,
        };
    }

    pub fn len2(v: Vec3) f32 {
        return v.dot(v);
    }

    pub fn len(v: Vec3) f32 {
        return @sqrt(v.len2());
    }

    pub fn norm(v: Vec3) Vec3 {
        const l = v.len();
        if (l < EPS) return zero;
        return v.scale(1 / l);
    }

    pub fn lerp(a: Vec3, b: Vec3, t: f32) Vec3 {
        return a.add(b.sub(a).scale(t));
    }
};

pub const Vec4 = struct {
    x: f32,
    y: f32,
    z: f32,
    w: f32,

    pub const zero = Vec4{ .x = 0, .y = 0, .z = 0, .w = 0 };
    pub const one = Vec4{ .x = 1, .y = 1, .z = 1, .w = 1 };

    pub fn new(x: f32, y: f32, z: f32, w: f32) Vec4 {
        return .{ .x = x, .y = y, .z = z, .w = w };
    }

    pub fn add(a: Vec4, b: Vec4) Vec4 {
        return .{ .x = a.x + b.x, .y = a.y + b.y, .z = a.z + b.z, .w = a.w + b.w };
    }

    pub fn sub(a: Vec4, b: Vec4) Vec4 {
        return .{ .x = a.x - b.x, .y = a.y - b.y, .z = a.z - b.z, .w = a.w - b.w };
    }

    pub fn mul(a: Vec4, b: Vec4) Vec4 {
        return .{ .x = a.x * b.x, .y = a.y * b.y, .z = a.z * b.z, .w = a.w * b.w };
    }

    pub fn scale(v: Vec4, s: f32) Vec4 {
        return .{ .x = v.x * s, .y = v.y * s, .z = v.z * s, .w = v.w * s };
    }

    pub fn dot(a: Vec4, b: Vec4) f32 {
        return a.x * b.x + a.y * b.y + a.z * b.z + a.w * b.w;
    }
};

pub const Vec4u = struct {
    x: u32,
    y: u32,
    z: u32,
    w: u32,

    pub const zero = Vec4u{ .x = 0, .y = 0, .z = 0, .w = 0 };
    pub const one = Vec4u{ .x = 1, .y = 1, .z = 1, .w = 1 };

    pub fn init(x: u32, y: u32, z: u32, w: u32) Vec4u {
        return .{ .x = x, .y = y, .z = z, .w = w };
    }

    pub fn add(a: Vec4u, b: Vec4u) Vec4u {
        return .{ .x = a.x + b.x, .y = a.y + b.y, .z = a.z + b.z, .w = a.w + b.w };
    }

    pub fn sub(a: Vec4u, b: Vec4u) Vec4u {
        return .{ .x = a.x - b.x, .y = a.y - b.y, .z = a.z - b.z, .w = a.w - b.w };
    }

    pub fn mul(a: Vec4u, b: Vec4u) Vec4u {
        return .{ .x = a.x * b.x, .y = a.y * b.y, .z = a.z * b.z, .w = a.w * b.w };
    }

    pub fn scale(v: Vec4u, s: u32) Vec4u {
        return .{ .x = v.x * s, .y = v.y * s, .z = v.z * s, .w = v.w * s };
    }

    pub fn eql(a: Vec4u, b: Vec4u) bool {
        return a.x == b.x and a.y == b.y and a.z == b.z and a.w == b.w;
    }

    pub fn toF32(v: Vec4u) Vec4 {
        return Vec4.new(
            @floatFromInt(v.x),
            @floatFromInt(v.y),
            @floatFromInt(v.z),
            @floatFromInt(v.w),
        );
    }
};

pub const Quat = struct {
    x: f32,
    y: f32,
    z: f32,
    w: f32,

    pub const identity = Quat{ .x = 0, .y = 0, .z = 0, .w = 1 };

    pub fn init(x: f32, y: f32, z: f32, w: f32) Quat {
        return .{ .x = x, .y = y, .z = z, .w = w };
    }

    pub fn fromAxisAngle(axis: Vec3, angle: f32) Quat {
        const ha = angle * 0.5;
        const s = @sin(ha);
        const a = axis.norm();
        return .{ .x = a.x * s, .y = a.y * s, .z = a.z * s, .w = @cos(ha) };
    }

    pub fn mul(a: Quat, b: Quat) Quat {
        return .{
            .x = a.w * b.x + a.x * b.w + a.y * b.z - a.z * b.y,
            .y = a.w * b.y - a.x * b.z + a.y * b.w + a.z * b.x,
            .z = a.w * b.z + a.x * b.y - a.y * b.x + a.z * b.w,
            .w = a.w * b.w - a.x * b.x - a.y * b.y - a.z * b.z,
        };
    }

    pub fn rotate(q: Quat, v: Vec3) Vec3 {
        const qn = q.norm();
        const qv = Vec3.new(qn.x, qn.y, qn.z);
        const uv = qv.cross(v);
        const uuv = qv.cross(uv);
        return v.add(uv.scale(2 * q.w)).add(uuv.scale(2));
    }

    pub fn norm(q: Quat) Quat {
        const l = @sqrt(q.x * q.x + q.y * q.y + q.z * q.z + q.w * q.w);
        if (l < EPS) return identity;
        const il = 1 / l;
        return .{ .x = q.x * il, .y = q.y * il, .z = q.z * il, .w = q.w * il };
    }

    pub fn slerp(a: Quat, b: Quat, t: f32) Quat {
        var dot = a.x * b.x + a.y * b.y + a.z * b.z + a.w * b.w;
        var b2 = b;
        if (dot < 0) {
            b2 = .{ .x = -b.x, .y = -b.y, .z = -b.z, .w = -b.w };
            dot = -dot;
        }
        if (dot > 0.9995) {
            const r = Quat{
                .x = a.x + (b2.x - a.x) * t,
                .y = a.y + (b2.y - a.y) * t,
                .z = a.z + (b2.z - a.z) * t,
                .w = a.w + (b2.w - a.w) * t,
            };
            return r.norm();
        }
        const theta = std.math.acos(std.math.clamp(dot, -1, 1));
        const st = @sin(theta);
        const s0 = @cos(theta * t) - dot * @sin(theta * t) / st;
        const s1 = @sin(theta * t) / st;
        return .{
            .x = a.x * s0 + b2.x * s1,
            .y = a.y * s0 + b2.y * s1,
            .z = a.z * s0 + b2.z * s1,
            .w = a.w * s0 + b2.w * s1,
        };
    }

    pub fn toMat4(q: Quat) Mat4 {
        const xx = q.x * q.x;
        const yy = q.y * q.y;
        const zz = q.z * q.z;
        const xy = q.x * q.y;
        const xz = q.x * q.z;
        const yz = q.y * q.z;
        const wx = q.w * q.x;
        const wy = q.w * q.y;
        const wz = q.w * q.z;

        return Mat4{
            .m = .{
                .{ 1 - 2 * (yy + zz), 2 * (xy + wz), 2 * (xz - wy), 0 },
                .{ 2 * (xy - wz), 1 - 2 * (xx + zz), 2 * (yz + wx), 0 },
                .{ 2 * (xz + wy), 2 * (yz - wx), 1 - 2 * (xx + yy), 0 },
                .{ 0, 0, 0, 1 },
            },
        };
    }
};

pub const Mat4 = struct {
    // 列主序: m[column][row]
    m: [4][4]f32,

    pub const identity = Mat4{
        .m = .{
            .{ 1, 0, 0, 0 }, // 列0
            .{ 0, 1, 0, 0 }, // 列1
            .{ 0, 0, 1, 0 }, // 列2
            .{ 0, 0, 0, 1 }, // 列3
        },
    };

    pub fn zero() Mat4 {
        return Mat4{ .m = .{
            .{ 0, 0, 0, 0 },
            .{ 0, 0, 0, 0 },
            .{ 0, 0, 0, 0 },
            .{ 0, 0, 0, 0 },
        } };
    }

    pub fn fromSlice(data: *const [16]f32) Mat4 {
        return Mat4{
            .m = .{
                data[0..4].*,
                data[4..8].*,
                data[8..12].*,
                data[12..16].*,
            },
        };
    }

    pub fn mul(a: Mat4, b: Mat4) Mat4 {
        var result: Mat4 = undefined;
        for (0..4) |col| { // 目标矩阵的列
            for (0..4) |row| { // 目标矩阵的行
                var sum: f32 = 0;
                for (0..4) |k| { // 遍历左矩阵的列和右矩阵的行
                    sum += a.m[k][row] * b.m[col][k];
                }
                result.m[col][row] = sum;
            }
        }
        return result;
    }

    pub fn mulVec(m: Mat4, v: Vec4) Vec4 {
        return Vec4.new(
            m.m[0][0] * v.x + m.m[1][0] * v.y + m.m[2][0] * v.z + m.m[3][0] * v.w,
            m.m[0][1] * v.x + m.m[1][1] * v.y + m.m[2][1] * v.z + m.m[3][1] * v.w,
            m.m[0][2] * v.x + m.m[1][2] * v.y + m.m[2][2] * v.z + m.m[3][2] * v.w,
            m.m[0][3] * v.x + m.m[1][3] * v.y + m.m[2][3] * v.z + m.m[3][3] * v.w,
        );
    }

    pub fn fromTranslate(t: Vec3) Mat4 {
        return Mat4{
            .m = .{
                .{ 1, 0, 0, 0 }, // 列0
                .{ 0, 1, 0, 0 }, // 列1
                .{ 0, 0, 1, 0 }, // 列2
                .{ t.x, t.y, t.z, 1 }, // 列3（平移列）
            },
        };
    }

    pub fn translate(self: Mat4, t: Vec3) Mat4 {
        const trans = fromTranslate(t);
        return mul(trans, self); // 注意顺序: translation * self
    }

    pub fn fromScale(s: Vec3) Mat4 {
        return Mat4{
            .m = .{
                .{ s.x, 0, 0, 0 }, // 列0
                .{ 0, s.y, 0, 0 }, // 列1
                .{ 0, 0, s.z, 0 }, // 列2
                .{ 0, 0, 0, 1 }, // 列3
            },
        };
    }

    pub fn scale(self: Mat4, s: Vec3) Mat4 {
        const scale_mat = fromScale(s);
        return mul(scale_mat, self); // 注意顺序: scale * self
    }

    pub fn perspective(fovy: f32, aspect: f32, near: f32, far: f32) Mat4 {
        const f = 1.0 / @tan(fovy * 0.5 * PI / 180.0);
        const nf = 1.0 / (near - far);

        return Mat4{
            .m = .{
                .{ f / aspect, 0, 0, 0 },
                .{ 0, f, 0, 0 },
                .{ 0, 0, (near + far) * nf, -1 },
                .{ 0, 0, 2 * near * far * nf, 0 },
            },
        };
    }

    pub fn orthographic(left: f32, right: f32, bottom: f32, top: f32, near: f32, far: f32) Mat4 {
        var result = zero();

        result.m[0][0] = 2.0 / (right - left);
        result.m[1][1] = 2.0 / (top - bottom);
        result.m[2][2] = 2.0 / (near - far);
        result.m[3][3] = 1.0;

        result.m[3][0] = (left + right) / (left - right);
        result.m[3][1] = (bottom + top) / (bottom - top);
        result.m[3][2] = (far + near) / (near - far);

        return result;
    }

    pub fn lookAt(eye: Vec3, target: Vec3, up: Vec3) Mat4 {
        const f = target.sub(eye).norm();
        const s = f.cross(up).norm();
        const u = s.cross(f);

        var result: Mat4 = undefined;
        result.m[0][0] = s.x;
        result.m[0][1] = u.x;
        result.m[0][2] = -f.x;
        result.m[0][3] = 0;

        result.m[1][0] = s.y;
        result.m[1][1] = u.y;
        result.m[1][2] = -f.y;
        result.m[1][3] = 0;

        result.m[2][0] = s.z;
        result.m[2][1] = u.z;
        result.m[2][2] = -f.z;
        result.m[2][3] = 0;

        result.m[3][0] = -s.dot(eye);
        result.m[3][1] = -u.dot(eye);
        result.m[3][2] = f.dot(eye);
        result.m[3][3] = 1;

        return result;
    }

    pub fn inverse(self: Mat4) Mat4 {
        const m = self.m;

        // 计算代数余子式矩阵的转置
        var inv: Mat4 = undefined;

        // 辅助宏：计算3x3行列式
        const det3 = struct {
            fn calc(a: f32, b: f32, c: f32, d: f32, e: f32, f: f32, g: f32, h: f32, i: f32) f32 {
                return a * (e * i - f * h) - b * (d * i - f * g) + c * (d * h - e * g);
            }
        }.calc;

        // 计算每个元素的余子式
        inv.m[0][0] = det3(m[1][1], m[1][2], m[1][3], m[2][1], m[2][2], m[2][3], m[3][1], m[3][2], m[3][3]);
        inv.m[1][0] = -det3(m[1][0], m[1][2], m[1][3], m[2][0], m[2][2], m[2][3], m[3][0], m[3][2], m[3][3]);
        inv.m[2][0] = det3(m[1][0], m[1][1], m[1][3], m[2][0], m[2][1], m[2][3], m[3][0], m[3][1], m[3][3]);
        inv.m[3][0] = -det3(m[1][0], m[1][1], m[1][2], m[2][0], m[2][1], m[2][2], m[3][0], m[3][1], m[3][2]);

        inv.m[0][1] = -det3(m[0][1], m[0][2], m[0][3], m[2][1], m[2][2], m[2][3], m[3][1], m[3][2], m[3][3]);
        inv.m[1][1] = det3(m[0][0], m[0][2], m[0][3], m[2][0], m[2][2], m[2][3], m[3][0], m[3][2], m[3][3]);
        inv.m[2][1] = -det3(m[0][0], m[0][1], m[0][3], m[2][0], m[2][1], m[2][3], m[3][0], m[3][1], m[3][3]);
        inv.m[3][1] = det3(m[0][0], m[0][1], m[0][2], m[2][0], m[2][1], m[2][2], m[3][0], m[3][1], m[3][2]);

        inv.m[0][2] = det3(m[0][1], m[0][2], m[0][3], m[1][1], m[1][2], m[1][3], m[3][1], m[3][2], m[3][3]);
        inv.m[1][2] = -det3(m[0][0], m[0][2], m[0][3], m[1][0], m[1][2], m[1][3], m[3][0], m[3][2], m[3][3]);
        inv.m[2][2] = det3(m[0][0], m[0][1], m[0][3], m[1][0], m[1][1], m[1][3], m[3][0], m[3][1], m[3][3]);
        inv.m[3][2] = -det3(m[0][0], m[0][1], m[0][2], m[1][0], m[1][1], m[1][2], m[3][0], m[3][1], m[3][2]);

        inv.m[0][3] = -det3(m[0][1], m[0][2], m[0][3], m[1][1], m[1][2], m[1][3], m[2][1], m[2][2], m[2][3]);
        inv.m[1][3] = det3(m[0][0], m[0][2], m[0][3], m[1][0], m[1][2], m[1][3], m[2][0], m[2][2], m[2][3]);
        inv.m[2][3] = -det3(m[0][0], m[0][1], m[0][3], m[1][0], m[1][1], m[1][3], m[2][0], m[2][1], m[2][3]);
        inv.m[3][3] = det3(m[0][0], m[0][1], m[0][2], m[1][0], m[1][1], m[1][2], m[2][0], m[2][1], m[2][2]);

        // 计算行列式
        const det = m[0][0] * inv.m[0][0] + m[0][1] * inv.m[1][0] + m[0][2] * inv.m[2][0] + m[0][3] * inv.m[3][0];

        if (@abs(det) < 1e-6) @panic("Matrix cannot be inverted");

        const inv_det = 1.0 / det;
        for (0..4) |col| {
            for (0..4) |row| {
                inv.m[col][row] *= inv_det;
            }
        }

        return inv;
    }
};

pub const Transform = struct {
    pos: Vec3,
    rot: Quat,
    scale: Vec3,

    pub const identity = Transform{ .pos = Vec3.zero, .rot = Quat.identity, .scale = Vec3.one };

    pub fn init(pos: Vec3, rot: Quat, scale: Vec3) Transform {
        return .{ .pos = pos, .rot = rot, .scale = scale };
    }

    pub fn toMat4(t: Transform) Mat4 {
        // 先获取旋转矩阵
        var rot_mat = t.rot.toMat4();

        // 应用缩放
        rot_mat.m[0][0] *= t.scale.x;
        rot_mat.m[0][1] *= t.scale.x;
        rot_mat.m[0][2] *= t.scale.x;

        rot_mat.m[1][0] *= t.scale.y;
        rot_mat.m[1][1] *= t.scale.y;
        rot_mat.m[1][2] *= t.scale.y;

        rot_mat.m[2][0] *= t.scale.z;
        rot_mat.m[2][1] *= t.scale.z;
        rot_mat.m[2][2] *= t.scale.z;

        // 设置平移（最后一列）
        rot_mat.m[3][0] = t.pos.x;
        rot_mat.m[3][1] = t.pos.y;
        rot_mat.m[3][2] = t.pos.z;

        return rot_mat;
    }
};

pub fn toRadians(degrees: f32) f32 {
    return degrees * PI / 180.0;
}

pub fn toDegrees(radians: f32) f32 {
    return radians * 180.0 / PI;
}
