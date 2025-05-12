@group(0) @binding(0)
var<uniform> ubo : UniformBufferObject;
struct UniformBufferObject {
    projection_matrix : mat4x4 < f32>,
    view_matrix : mat4x4 < f32>,
    model_matrix : mat4x4 < f32>,
    color : vec4f,
    time : f32,
};

struct VertexInput {
    @location(0) position : vec3f,
    @location(1) normal : vec3f,
    @location(2) color : vec4f,
};

struct VertexOutput {
    @builtin(position) position : vec4f,
    @location(0) color : vec4f,
};

@vertex
fn vs_main(in : VertexInput) -> VertexOutput {
    var out : VertexOutput;
    out.position = ubo.projection_matrix * ubo.view_matrix * ubo.model_matrix * vec4f(in.position, 1.0);
    out.color = in.color;
    return out;
}

@fragment
fn fs_main(in : VertexOutput) -> @location(0) vec4f {
    //伽玛校正
    let corrected_color = pow(in.color, vec4f(2.2));
    return vec4f(corrected_color);
}
