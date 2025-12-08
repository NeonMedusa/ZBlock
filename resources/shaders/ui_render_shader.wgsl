//ui_render_shader.wgsl
@group(0) @binding(0) var<uniform> ui_uniform : UiUniform;          //场景常量数据
struct UiUniform {
    ortho_matrix : mat4x4f, //正交投影矩阵
};

struct VertexInput {
    @location(0) position : vec3f,  //位置 (像素坐标)
    @location(1) color : vec4f,     //颜色
};

struct VertexOutput {
    @builtin(position) position : vec4f,
    @location(0) color : vec4f,
};

@vertex
fn vs_main(in : VertexInput) -> VertexOutput {
    var out : VertexOutput;
    //应用正交投影矩阵
    out.position = ui_uniform.ortho_matrix * vec4f(in.position, 1.0);
    //直接传递颜色
    out.color = in.color;
    return out;
}

//片元着色
@fragment
fn fs_main(in : VertexOutput) -> @location(0) vec4f {
    //计算片元颜色
    let color = in.color;
    //伽玛校正
    let corrected_color = pow(color, vec4f(2.2));
    return vec4f(corrected_color);
}
