// direction.zig
const std = @import("std");
const Algebra = @import("algebra.zig");
const Vec2 = Algebra.Vec2;
const Vec3 = Algebra.Vec3;
const Vec3i = Algebra.Vec3i;
const Quat = Algebra.Quat;

pub const Direction = enum(u3) {
    up,
    down,
    north,
    south,
    west,
    east,

    pub fn normal(self: Direction) Vec3 {
        return switch (self) {
            .up => Vec3.new(0, 1, 0),
            .down => Vec3.new(0, -1, 0),
            .north => Vec3.new(0, 0, -1),
            .south => Vec3.new(0, 0, 1),
            .west => Vec3.new(-1, 0, 0),
            .east => Vec3.new(1, 0, 0),
        };
    }

    pub fn offset(self: Direction) Vec3i {
        return self.normal().toVec3iFloor();
    }
    pub fn rotation(self: Direction) Quat {
        return switch (self) {
            .up => Quat.identity,
            .down => Quat.fromAxisAngle(Vec3.new(1, 0, 0), std.math.pi),
            .north => Quat.fromAxisAngle(Vec3.new(1, 0, 0), -std.math.pi / 2.0),
            .south => Quat.fromAxisAngle(Vec3.new(1, 0, 0), std.math.pi / 2.0),
            .west => Quat.fromAxisAngle(Vec3.new(0, 0, 1), -std.math.pi / 2.0),
            .east => Quat.fromAxisAngle(Vec3.new(0, 0, 1), std.math.pi / 2.0),
        };
    }

    pub fn rotationInverse(self: Direction) Quat {
        return switch (self) {
            .up => Quat.identity,
            .down => Quat.fromAxisAngle(Vec3.new(1, 0, 0), -std.math.pi),
            .north => Quat.fromAxisAngle(Vec3.new(1, 0, 0), std.math.pi / 2.0),
            .south => Quat.fromAxisAngle(Vec3.new(1, 0, 0), -std.math.pi / 2.0),
            .west => Quat.fromAxisAngle(Vec3.new(0, 0, 1), std.math.pi / 2.0),
            .east => Quat.fromAxisAngle(Vec3.new(0, 0, 1), -std.math.pi / 2.0),
        };
    }
};

/// 根据浮点向量最接近的主轴方向，推断对应的 Direction 枚举值。
/// 用于旋转方块时从局部向量反推朝向。
pub fn directionFromVec(v: Vec3) Direction {
    const ax = @abs(v.x);
    const ay = @abs(v.y);
    const az = @abs(v.z);
    if (ay >= ax and ay >= az) return if (v.y > 0) .up else .down;
    if (ax >= ay and ax >= az) return if (v.x > 0) .east else .west;
    return if (v.z > 0) .south else .north;
}

pub const FaceData = struct {
    positions: [4]Vec3,
    uvs: [4]Vec2,
};

const DEFAULT_UVS = [4]Vec2{
    Vec2.new(0, 1), Vec2.new(1, 1), Vec2.new(1, 0), Vec2.new(0, 0),
};

pub fn getStandardFaceData(local_dir: Direction) FaceData {
    const h = 0.5;
    return switch (local_dir) {
        .up => FaceData{
            .positions = .{
                Vec3.new(-h, h, -h),
                Vec3.new(h, h, -h),
                Vec3.new(h, h, h),
                Vec3.new(-h, h, h),
            },
            .uvs = DEFAULT_UVS,
        },
        .down => FaceData{
            .positions = .{
                Vec3.new(-h, -h, h),
                Vec3.new(h, -h, h),
                Vec3.new(h, -h, -h),
                Vec3.new(-h, -h, -h),
            },
            .uvs = .{ Vec2.new(0, 0), Vec2.new(1, 0), Vec2.new(1, 1), Vec2.new(0, 1) },
        },
        .north => FaceData{
            .positions = .{
                Vec3.new(-h, -h, -h),
                Vec3.new(h, -h, -h),
                Vec3.new(h, h, -h),
                Vec3.new(-h, h, -h),
            },
            .uvs = DEFAULT_UVS,
        },
        .south => FaceData{
            .positions = .{
                Vec3.new(h, -h, h),
                Vec3.new(-h, -h, h),
                Vec3.new(-h, h, h),
                Vec3.new(h, h, h),
            },
            .uvs = .{ Vec2.new(1, 1), Vec2.new(0, 1), Vec2.new(0, 0), Vec2.new(1, 0) },
        },
        .east => FaceData{
            .positions = .{
                Vec3.new(h, -h, -h),
                Vec3.new(h, -h, h),
                Vec3.new(h, h, h),
                Vec3.new(h, h, -h),
            },
            .uvs = DEFAULT_UVS,
        },
        .west => FaceData{
            .positions = .{
                Vec3.new(-h, -h, h),
                Vec3.new(-h, -h, -h),
                Vec3.new(-h, h, -h),
                Vec3.new(-h, h, h),
            },
            .uvs = DEFAULT_UVS,
        },
    };
}
