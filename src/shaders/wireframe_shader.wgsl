// wireframe_shader.wgsl
// 线框叠加层：在物体上绘制黄色半透明线框，用于调试/选中高亮。
// 只用 position，不做纹理/光照。

struct SceneUniform {
    proj_matrix: mat4x4f,
    view_matrix: mat4x4f,
    camera_pos: vec3f,
    time: f32,
    sun_direction: vec3f,
    sun_intensity: f32,
    sun_color: vec3f,
    moon_brightness: f32,
    ambient_ground: vec3f,
    _pad: f32,
    shadow_vp: mat4x4f,
    moon_color: vec3f,
};

struct VertexInput {
    @location(0) position: vec3f,
};

struct VertexOutput {
    @builtin(position) position: vec4f,
};

@group(0) @binding(0) var<uniform> scene_uniform: SceneUniform;

@vertex
fn vs_main(in: VertexInput) -> VertexOutput {
    var out: VertexOutput;
    out.position = scene_uniform.proj_matrix * scene_uniform.view_matrix * vec4f(in.position, 1.0);
    return out;
}

@fragment
fn fs_main(in: VertexOutput) -> @location(0) vec4f {
    return vec4f(1.0, 1.0, 0.0, 0.3);
}
