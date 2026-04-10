struct SceneUniform {
    proj_matrix: mat4x4f,
    view_matrix: mat4x4f,
    time: f32,
};
struct VertexInput {
    @location(0) position: vec3f,
    @location(1) normal: vec3f,
    @location(2) tangent: vec4f,
    @location(3) texcoord: vec2f,
    @location(4) color: vec4f,      // 顶点颜色
    @location(5) joint_indices: vec4u,
    @location(6) joint_weights: vec4f,
};

struct VertexOutput {
    @builtin(position) position: vec4f,
    @location(0) color: vec4f,
};

@group(0) @binding(0) var<uniform> scene_uniform: SceneUniform;

@vertex
fn vs_main(in: VertexInput) -> VertexOutput {
    var out: VertexOutput;
    out.position = scene_uniform.proj_matrix * scene_uniform.view_matrix * vec4f(in.position, 1.0);
    out.color = in.color;
    return out;
}

@fragment
fn fs_main(in: VertexOutput) -> @location(0) vec4f {
    return vec4f(in.color.rgb, 0.5); // 使用顶点颜色，alpha=0.5
}