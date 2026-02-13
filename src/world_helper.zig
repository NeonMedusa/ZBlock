const std = @import("std");
const Algebra = @import("zalgebra");
const Vec3 = Algebra.Vec3;
const Mat4 = Algebra.Mat4;
const Input = @import("input.zig");
const Key = Input.Key;
const Comps = @import("components.zig").Components;
const ECS = @import("generated_ecs.zig");
const Entity = ECS.Entity;
const Signature = ECS.Signature;
const ComponentType = ECS.ComponentType;
const World = @import("generated_ecs.zig").World;
// 获取变换矩阵（用于渲染）
pub fn getTransformMatrix(entity: Entity) ?Mat4 {
    if (entity.getCompPtr(Comps.Position)) |position|
        return Mat4.fromTranslate(position.vec);
    return null;
}
