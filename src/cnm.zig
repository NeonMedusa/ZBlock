const Model = struct {
    nodes: std.ArrayList(Node),
};
const Node = struct {
    transform: ?Mat4,
    mesh_idx: ?usize,
};
const Mesh = struct {
    primitives: std.ArrayList(Primitive),
};

const Primitive = struct {
    vertex_offset: u32,
    vertex_size: u32,
    vertex_count: u32,
    index_offset: u32,
    index_size: u32,
    index_count: u32,
    // 可继续添加材质、纹理引用等
};

const std = @import("std");
const Algebra = @import("zalgebra");
const Vec3 = Algebra.Vec3;
const Mat4 = Algebra.Mat4;
const VertexAttribute = @import("vertex_attribute.zig");
