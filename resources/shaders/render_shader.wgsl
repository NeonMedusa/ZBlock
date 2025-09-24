//render_shader.wgsl:
@group(0) @binding(0) var<uniform> scene_uniform : SceneUniform;
//存储每个渲染实例的最终世界变换矩阵，由计算着色器计算和写入
@group(0) @binding(1) var<storage, read> world_matrices : array<mat4x4f>;
struct SceneUniform {
    proj_matrix : mat4x4f,
    view_matrix : mat4x4f,
    time : f32,
    active_entity_count : u32,
};
struct VertexInput {
    @location(0) position : vec3f,
    @location(1) color : vec4f,
};
struct VertexOutput {
    @builtin(position) position : vec4f,
    @location(0) color : vec4f,
};
@vertex
fn vs_main(in : VertexInput, @builtin(instance_index) ins_idx : u32,) -> VertexOutput {
    var out : VertexOutput;
    //计算顶点位置
    out.position =
    scene_uniform.proj_matrix * //投影矩阵
    scene_uniform.view_matrix * //视图矩阵
    world_matrices[ins_idx] *   //模型矩阵
    vec4f(in.position, 1.0);    //顶点位置
    out.color = in.color;       //顶点颜色
    return out;
}
@fragment
fn fs_main(in : VertexOutput) -> @location(0) vec4f {
    let corrected_color = pow(in.color, vec4f(2.2));    //伽玛校正
    return vec4f(corrected_color);
}
