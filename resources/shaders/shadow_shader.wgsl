struct LightUniform {
    light_vp: mat4x4f,
};

@group(0) @binding(0) var<uniform> shadow: LightUniform;

struct VertexInput {
    @location(0) position: vec3f,
};

@vertex
fn vs_main(in: VertexInput) -> @builtin(position) vec4f {
    var clip_pos = shadow.light_vp * vec4f(in.position, 1.0);
    let df = length(clip_pos.xy) + 0.1; // 径向畸变：中心纹素更密
    clip_pos.x /= df;
    clip_pos.y /= df;
    return clip_pos;
}
