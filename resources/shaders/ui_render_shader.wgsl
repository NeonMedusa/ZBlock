//ui_render_shader.wgsl - 简化版

//硬编码的正交投影矩阵
const ORTHO_MATRIX = mat4x4f(
vec4f(0.003125, 0.0, 0.0, 0.0),        //2 / 1000 = 0.002 (假设屏幕宽度1000)
vec4f(0.0, -0.00416666, 0.0, 0.0),      //2 / 540 = 0.0037, 负号是因为Y轴反转 (假设屏幕高度540)
vec4f(0.0, 0.0, 0.1, 0.0),          //简单的深度缩放
vec4f(-1.0, 1.0, 0.0, 1.0)          //平移，将原点移到左上角
);

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

    //应用硬编码的正交投影矩阵
    out.position = ORTHO_MATRIX * vec4f(in.position, 1.0);

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
