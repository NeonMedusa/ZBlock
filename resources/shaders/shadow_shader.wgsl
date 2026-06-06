struct LightUniform {
    light_vp: mat4x4f,
};

@group(0) @binding(0) var<uniform> shadow: LightUniform;

struct VertexInput {
    @location(0) position: vec3f,
};

@vertex
fn vs_main(in: VertexInput) -> @builtin(position) vec4f {
    return shadow.light_vp * vec4f(in.position, 1.0);
}
