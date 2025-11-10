//render_shader.wgsl:
@group(0) @binding(0) var<uniform> scene_uniform : SceneUniform;            //场景常量数据
@group(0) @binding(1) var<storage, read> entities_data : array<EntityData>; //游戏实例数据
@group(0) @binding(2) var color_atlas : texture_2d_array<f32>;          //纹理图集数组
@group(0) @binding(3) var anime_atlas : texture_2d_array<f32>;      //动画纹理图集数组
@group(0) @binding(4) var<storage, read> textures_info : array<TextureInfo>;    //动画纹理图集数组
struct SceneUniform {
    proj_matrix : mat4x4f,  //投影矩阵
    view_matrix : mat4x4f,  //视图矩阵
    time : f32,             //游戏时间
};
struct EntityData {
    transform : mat4x4f,            //实例的世界变换

    anime_texture_size : vec2f,     //动画纹理在纹理图集中的实际大小
    anime_texture_start : vec2i,    //动画纹理在纹理图集中的起始坐标

    anime_duration : f32,           //动画的持续时间
    cur_anime_time : f32,           //实例的当前动画时间

    color_texture_index : u32,      //色彩纹理在纹理图集数组中的索引
    anime_texture_index : u32,      //动画纹理在纹理图集数组中的索引
};
struct TextureInfo {
    size : vec2f,           //纹理的实际大小
    coords_offset : vec2i,  //纹理在纹理图集中的坐标偏移量
    index : u32,        //纹理在纹理数组中的索引
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
    @location(1) color_texture_index : u32,
};
//从指定关键帧读取时间戳
fn read_keyframe_time(entity : EntityData, keyframe_index : u32) -> f32 {
    let texel_coord = vec2i(
    entity.anime_texture_start.x,
    entity.anime_texture_start.y + i32(keyframe_index)
    );
    return textureLoad(anime_atlas, texel_coord, entity.anime_texture_index, 0).r;
}
//从指定关键帧读取指定骨骼的矩阵
fn read_bone_matrix_at_keyframe(entity : EntityData, bone_index : u32, keyframe_index : u32) -> mat4x4f {
    let matrix_start_x = entity.anime_texture_start.x + 1 + i32(bone_index * 3u);
    let y_coord = entity.anime_texture_start.y + i32(keyframe_index);
    var bone_matrix : mat4x4f;
    //读取前3行数据，但需要转置到列
    for (var i : u32 = 0u; i < 3u; i++)
    {
        let texel_coord = vec2i(matrix_start_x + i32(i), y_coord);
        let row_data = textureLoad(anime_atlas, texel_coord, i32(entity.anime_texture_index), 0);
        //手动设置矩阵的每一列
        bone_matrix[0][i] = row_data[0];//第0列的第i个分量
        bone_matrix[1][i] = row_data[1];//第1列的第i个分量
        bone_matrix[2][i] = row_data[2];//第2列的第i个分量
        bone_matrix[3][i] = row_data[3];//第3列的第i个分量
    }
    //设置第4行的固定值
    bone_matrix[0][3] = 0.0;
    bone_matrix[1][3] = 0.0;
    bone_matrix[2][3] = 0.0;
    bone_matrix[3][3] = 1.0;
    return bone_matrix;
}
//查找当前时间对应的关键帧索引
fn find_keyframe_indices(entity : EntityData, current_time : f32) -> vec2u {
    var prev_index : u32 = 0u;
    let num_keyframes = u32(entity.anime_texture_size.y);
    var next_index : u32 = num_keyframes - 1u;
    //二分查找或者线性查找关键帧
    for (var i : u32 = 1u; i < num_keyframes; i++)
    {
        let frame_time = read_keyframe_time(entity, i);
        if (frame_time >= current_time)
        {
            prev_index = i - 1u;
            next_index = i;
            break;
        }
    }
    return vec2u(prev_index, next_index);
}
//预计算关键帧信息，避免重复采样
fn get_interpolated_bone_matrix(entity : EntityData, bone_index : u32) -> mat4x4f {
    let normalized_time = entity.cur_anime_time % entity.anime_duration;
    let keyframes = find_keyframe_indices(entity, normalized_time);
    //一次性读取两个关键帧的时间
    let time_prev = read_keyframe_time(entity, keyframes.x);
    let time_next = read_keyframe_time(entity, keyframes.y);
    let t = (normalized_time - time_prev) / (time_next - time_prev);
    //读取骨骼矩阵
    let matrix_prev = read_bone_matrix_at_keyframe(entity, bone_index, keyframes.x);
    let matrix_next = read_bone_matrix_at_keyframe(entity, bone_index, keyframes.y);
    return matrix_prev * (1.0 - t) + matrix_next * t;
}
//顶点着色
@vertex
fn vs_main(in : VertexInput, @builtin(instance_index) ins_idx : u32,) -> VertexOutput {
    let entity = entities_data[ins_idx];
    //应用骨骼动画
    var animated_position = vec3f(0.0);
    var total_weight = 0.0;
    for (var i = 0; i < 4; i++)
    {
        if (in.joint_weights[i] > 0.0)
        {
            let bone_matrix = get_interpolated_bone_matrix(entity, in.joint_indices[i]);
            animated_position += (bone_matrix * vec4f(in.position, 1.0)).xyz * in.joint_weights[i];
            total_weight += in.joint_weights[i];
        }
    }
    if (total_weight > 0.0)
    {
        animated_position /= total_weight;
    } else {
        animated_position = in.position;
    }

    var out : VertexOutput;
    //计算顶点位置
    out.position =
    scene_uniform.proj_matrix * //投影矩阵
    scene_uniform.view_matrix * //视图矩阵
    entity.transform *          //模型矩阵
    vec4f(animated_position, 1.0);  //顶点位置

    out.color_uv = in.color_uv;             //基础颜色UV
    out.color_texture_index = entity.color_texture_index;

    return out;
}
//片元着色
@fragment
fn fs_main(in : VertexOutput) -> @location(0) vec4f {
    let color_texture_info = textures_info[in.color_texture_index];
    //计算纹素坐标
    let texelCoords = vec2i(in.color_uv * color_texture_info.size) + color_texture_info.coords_offset;
    //纹理采样，参数：color_atlas, texelCoords, color_texture_index，mip_level
    let color = textureLoad(color_atlas, texelCoords, color_texture_info.index, 0).rgba;
    //伽玛校正
    let corrected_color = pow(color, vec4f(2.2));
    return vec4f(corrected_color);
}
