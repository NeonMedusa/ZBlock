//ui_render_shader.wgsl
@group(0) @binding(0) var<uniform> ui_uniform : UiUniform;
@group(0) @binding(1) var sdf_texture : texture_2d<f32>;
@group(0) @binding(2) var sdf_sampler : sampler;

struct UiUniform {
    ortho_matrix : mat4x4f,
};

struct VertexInput {
    @location(0) position : vec3f,
    @location(1) color : vec4f,
    @location(2) texcoord : vec2f,
};

struct VertexOutput {
    @builtin(position) position : vec4f,
    @location(0) color : vec4f,
    @location(1) texcoord : vec2f,
};

@vertex
fn vs_main(in : VertexInput) -> VertexOutput {
    var out : VertexOutput;
    out.position = ui_uniform.ortho_matrix * vec4f(in.position, 1.0);
    out.color = in.color;
    out.texcoord = in.texcoord;
    return out;
}

@fragment
fn fs_main(in : VertexOutput) -> @location(0) vec4f {
    var alpha: f32 = 1.0;
    if (in.texcoord.x >= 0.0) {
        let sdf = textureSample(sdf_texture, sdf_sampler, in.texcoord).r;
        let edge = 0.1 * fwidth(sdf);
        alpha = smoothstep(0.5 - edge, 0.5 + edge, sdf);
    }
    let color = vec4f(in.color.rgb, in.color.a * alpha);
    let corrected = pow(color, vec4f(2.2));
    return corrected;
}
