@group(0) @binding(0) var<storage, read> uniform : Uniform;
struct Uniform {
    projection_matrix : mat4x4 < f32>,
    view_matrix : mat4x4 < f32>,
    time : f32,

};
@group(0) @binding(1) var<storage, read> instances_data : array<InstanceData>;
struct InstanceData {
    entity_transform : mat4x4 < f32>,
    joint_matrices : array<mat4x4 < f32>, 50>,
};

struct VertexInput {
    @location(0) position : vec3f,
    @location(1) normal : vec3f,
    @location(2) color : vec4f,
    @location(3) joint_indices : vec4u, //关节矩阵索引
    @location(4) joint_weights : vec4f, //关节权重
};

struct VertexOutput {
    @builtin(position) position : vec4f,
    @location(0) color : vec4f,
};

@vertex
fn vs_main(in : VertexInput, @builtin(instance_index) ins_idx : u32,) -> VertexOutput {
    //通过instance索引获取对应的数据
    let ins_data = instances_data[ins_idx];

    let skin_matrix =
    in.joint_weights.x * ins_data.joint_matrices[in.joint_indices.x] +
    in.joint_weights.y * ins_data.joint_matrices[in.joint_indices.y] +
    in.joint_weights.z * ins_data.joint_matrices[in.joint_indices.z] +
    in.joint_weights.w * ins_data.joint_matrices[in.joint_indices.w];

    var out : VertexOutput;
    out.position = uniform.projection_matrix *
    uniform.view_matrix *
    ins_data.entity_transform *             //实体变换
    skin_matrix *                           //骨骼变换
    vec4f(in.position, 1.0);

    out.color = in.color;
    return out;
}

@fragment
fn fs_main(in : VertexOutput) -> @location(0) vec4f {
    //伽玛校正
    let corrected_color = pow(in.color, vec4f(2.2));
    return vec4f(corrected_color);
}
