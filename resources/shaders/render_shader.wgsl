//render_shader.wgsl:
@group(0) @binding(0) var<uniform> scene_uniform : SceneUniform;
@group(0) @binding(1) var<storage, read> entities_data : array<EntityData>;
@group(0) @binding(2) var textures : texture_2d_array<f32>;
struct SceneUniform {
    proj_matrix : mat4x4f,
    view_matrix : mat4x4f,
    time : f32,
};
struct EntityData {
    transform : mat4x4f,            //实例的世界变换
    texture_size : vec2f,           //纹理的实际大小
    texel_coords_offset : vec2i,    //纹理坐标偏移量
    texture_index : u32,            //纹理在数组中的索引
};
struct VertexInput {
    @location(0) position : vec3f,
    @location(1) uv : vec2f,
};
struct VertexOutput {
    @builtin(position) position : vec4f,
    @location(0) uv : vec2f,
    @location(1) texture_size : vec2f,
    @location(2) texel_coords_offset : vec2i,
    @location(3) texture_index : u32,

};
@vertex
fn vs_main(in : VertexInput, @builtin(instance_index) ins_idx : u32,) -> VertexOutput {
    let entity = entities_data[ins_idx];
    var out : VertexOutput;
    //计算顶点位置
    out.position =
    scene_uniform.proj_matrix * //投影矩阵
    scene_uniform.view_matrix * //视图矩阵
    entity.transform *          //模型矩阵
    vec4f(in.position, 1.0);    //顶点位置

    out.uv = in.uv; //基础颜色UV
    out.texture_index = entity.texture_index;
    out.texture_size = entity.texture_size;
    out.texel_coords_offset = entity.texel_coords_offset;
    return out;
}
@fragment
fn fs_main(in : VertexOutput) -> @location(0) vec4f {
    //计算纹素坐标
    let texelCoords = vec2i(in.uv * in.texture_size) + in.texel_coords_offset;
    //纹理采样，参数：textures, texelCoords, texture_index，mip_level
    let color = textureLoad(textures, texelCoords, in.texture_index, 0).rgba;
    //伽玛校正
    let corrected_color = pow(color, vec4f(2.2));
    return vec4f(corrected_color);
}
