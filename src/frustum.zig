// frustum.zig — 视锥体裁剪
const Vec3 = @import("algebra.zig").Vec3;
const Mat4 = @import("algebra.zig").Mat4;

const Plane = struct {
    nx: f32,
    ny: f32,
    nz: f32,
    d: f32,
    fn dot(self: Plane, p: Vec3) f32 {
        return self.nx * p.x + self.ny * p.y + self.nz * p.z + self.d;
    }
};

pub const Frustum = struct {
    left: Plane,
    right: Plane,
    bottom: Plane,
    top: Plane,
    near: Plane,
    far: Plane,

    pub fn fromViewProj(vp: Mat4) Frustum {
        const m = vp.m;
        // left:   clip.x + clip.w >= 0
        const left = Plane{
            .nx = m[0][0] + m[0][3],
            .ny = m[1][0] + m[1][3],
            .nz = m[2][0] + m[2][3],
            .d = m[3][0] + m[3][3],
        };
        // right:  clip.w - clip.x >= 0
        const right = Plane{
            .nx = m[0][3] - m[0][0],
            .ny = m[1][3] - m[1][0],
            .nz = m[2][3] - m[2][0],
            .d = m[3][3] - m[3][0],
        };
        // bottom: clip.y + clip.w >= 0
        const bottom = Plane{
            .nx = m[0][1] + m[0][3],
            .ny = m[1][1] + m[1][3],
            .nz = m[2][1] + m[2][3],
            .d = m[3][1] + m[3][3],
        };
        // top:    clip.w - clip.y >= 0
        const top = Plane{
            .nx = m[0][3] - m[0][1],
            .ny = m[1][3] - m[1][1],
            .nz = m[2][3] - m[2][1],
            .d = m[3][3] - m[3][1],
        };
        // near:   clip.z >= 0 (reversed Z: near→1, far→0)
        const near = Plane{
            .nx = m[0][2],
            .ny = m[1][2],
            .nz = m[2][2],
            .d = m[3][2],
        };
        // far:    clip.z <= clip.w  →  clip.w - clip.z >= 0
        const far = Plane{
            .nx = m[0][3] - m[0][2],
            .ny = m[1][3] - m[1][2],
            .nz = m[2][3] - m[2][2],
            .d = m[3][3] - m[3][2],
        };
        return Frustum{ .left = left, .right = right, .bottom = bottom, .top = top, .near = near, .far = far };
    }

    /// 测试 AABB 是否与视锥相交（8 顶点对 6 平面的排除测试）
    pub fn intersectsAABB(self: Frustum, min: Vec3, max: Vec3) bool {
        const corners = [_]Vec3{
            Vec3.new(min.x, min.y, min.z),
            Vec3.new(max.x, min.y, min.z),
            Vec3.new(min.x, max.y, min.z),
            Vec3.new(max.x, max.y, min.z),
            Vec3.new(min.x, min.y, max.z),
            Vec3.new(max.x, min.y, max.z),
            Vec3.new(min.x, max.y, max.z),
            Vec3.new(max.x, max.y, max.z),
        };
        const planes = [_]Plane{ self.left, self.right, self.bottom, self.top, self.near, self.far };
        for (planes) |plane| {
            var all_outside = true;
            for (corners) |c| {
                if (plane.dot(c) >= 0) {
                    all_outside = false;
                    break;
                }
            }
            if (all_outside) return false;
        }
        return true;
    }
};
