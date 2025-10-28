//render_shader.wgsl:
@group(0) @binding(0) var<uniform> scene_uniform : SceneUniform;            //场景常量数据
@group(0) @binding(1) var<storage, read> entities_data : array<EntityData>; //游戏实例数据
@group(0) @binding(2) var texture_atlas : texture_2d_array<f32>;            //纹理图集数组
struct SceneUniform {
    proj_matrix : mat4x4f,  //投影矩阵
    view_matrix : mat4x4f,  //视图矩阵
    time : f32,             //游戏时间
};
struct EntityData {
    transform : mat4x4f,            //实例的世界变换

    color_texture_size : vec2f,     //色彩纹理在纹理图集中的实际大小
    color_texture_start : vec2i,    //色彩纹理在纹理图集中的起始坐标

    anime_texture_size : vec2f,     //动画纹理在纹理图集中的实际大小
    anime_texture_start : vec2i,    //动画纹理在纹理图集中的起始坐标

    current_frame : f32,            //实例的当前动画时间
    frames_per_second : f32,        //动画帧率

    color_texture_index : u32,      //色彩纹理在纹理图集数组中的索引
    anime_texture_index : u32,      //动画纹理在纹理图集数组中的索引
};
struct VertexInput {
    @location(0) position : vec3f,      //顶点位置
    @location(1) color_uv : vec2f,      //色彩纹理UV
    @location(2) joint_indices : vec4u, //关节矩阵索引
    @location(3) joint_weights : vec4f, //关节权重
};
struct VertexOutput {
    @builtin(position) position : vec4f,
    @location(0) color_uv : vec2f,
    @location(1) color_texture_size : vec2f,
    @location(2) color_texture_start : vec2i,
    @location(3) color_texture_index : u32,
};
//从统一纹理数组读取骨骼矩阵
fn read_bone_matrix_from_texture_atlas(entity : EntityData, bone_index : u32, frame : u32) -> mat4x4f {
    //计算骨骼矩阵在纹理中的位置
    let bone_pixel_x = entity.anime_texture_start.x + i32(bone_index * 4u);
    let frame_pixel_y = entity.anime_texture_start.y + i32(frame);
    var bone_matrix : mat4x4f;
    //读取矩阵的4列
    for (var col : u32 = 0u; col < 4u; col++)
    {
        let texel_coord = vec2i(bone_pixel_x + i32(col), frame_pixel_y);
        let column_data = textureLoad(texture_atlas, texel_coord, entity.anime_texture_index, 0);
        bone_matrix[col] = vec4f(column_data);
    }
    return bone_matrix;
}

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

    out.color_uv = in.color_uv;             //基础颜色UV
    out.color_texture_index = entity.color_texture_index;
    out.color_texture_size = entity.color_texture_size;
    out.color_texture_start = entity.color_texture_start;
    return out;
}

@fragment
fn fs_main(in : VertexOutput) -> @location(0) vec4f {
    //计算纹素坐标
    let texelCoords = vec2i(in.color_uv * in.color_texture_size) + in.color_texture_start;
    //纹理采样，参数：texture_atlas, texelCoords, color_texture_index，mip_level
    let color = textureLoad(texture_atlas, texelCoords, in.color_texture_index, 0).rgba;
    //伽玛校正
    let corrected_color = pow(color, vec4f(2.2));
    return vec4f(corrected_color);
}
