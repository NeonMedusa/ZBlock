const std = @import("std");
const Algebra = @import("zalgebra");
const Vec3 = Algebra.Vec3;
const Mat4 = Algebra.Mat4;
const Input = @import("input.zig");
const Key = Input.Key;
const Comps = @import("components.zig").Components;
const ECS = @import("zigecs");
const Entity = ECS.Entity;
// 获取变换矩阵（用于渲染）
pub fn getTransformMatrix(registry: *ECS.Registry, entity: Entity) ?Mat4 {
    if (registry.tryGetConst(Comps.Position, entity)) |pos|
        return Mat4.fromTranslate(pos.vec);
    return null;
}
