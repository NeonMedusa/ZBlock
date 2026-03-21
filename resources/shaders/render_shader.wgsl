//render_shader.wgsl:
//group0全局绑定，这些都是每帧更新的
@group(0) @binding(0) var<uniform> scene_uniform : SceneUniform;                //场景常量数据
@group(0) @binding(1) var<storage, read> entities_data : array<EntitiesData>;   //游戏实例数据
@group(0) @binding(2) var<storage, read> ins_data : array<InstanceData>;        //渲染实例数据
//group1纹理绑定
@group(1) @binding(0) var<uniform> texture_uniform : MaterialConstants;         //纹理常量
@group(1) @binding(1) var color_texture : texture_2d<f32>;                      //色彩纹理
@group(1) @binding(2) var normal_texture : texture_2d<f32>;                     //法线纹理

struct SceneUniform {
    proj_matrix : mat4x4f,  //投影矩阵
    view_matrix : mat4x4f,  //视图矩阵
    time : f32,             //游戏时间
};

struct MaterialConstants{
    has_base_color: u32,
    has_normal: u32,
};

struct EntitiesData {
    transform : mat4x4f,    //游戏实体的变换
};

struct InstanceData{
    transform : mat4x4f,    // 渲染实例的变换
    entity_idx: u32,        // 该渲染实例属于哪个游戏实体
};

struct VertexInput {
    @location(0) position : vec3f,      //顶点位置
    @location(1) color_uv : vec2f,      //色彩纹理UV
    @location(2) joint_indices : vec4u, //关节矩阵索引（暂未使用）
    @location(3) joint_weights : vec4f, //关节权重（暂未使用）
};

struct VertexOutput {
    @builtin(position) position : vec4f,
    @location(0) color_uv : vec2f,
};

//顶点着色器
@vertex
fn vs_main(in: VertexInput, @builtin(instance_index) ins_idx: u32) -> VertexOutput {
    // 获取实例数据
    let ins = ins_data[ins_idx];
    // 通过entity_idx获取游戏实体数据
    let entity = entities_data[ins.entity_idx];
    
    var out: VertexOutput;
    
    // 计算顶点位置：先应用实体变换，再应用实例变换
    let model_matrix = entity.transform * ins.transform;
    
    // 计算世界坐标
    let world_pos = model_matrix * vec4f(in.position, 1.0);
    
    // 计算裁剪空间坐标
    out.position = scene_uniform.proj_matrix * scene_uniform.view_matrix * world_pos;
    
    // 传递UV坐标（需要转换为纹素坐标）
    out.color_uv = in.color_uv;
    
    return out;
}

//片段着色器
@fragment
fn fs_main(in: VertexOutput) -> @location(0) vec4f {
    var final_color: vec4f = vec4f(1.0, 0.0, 1.0, 1.0); // 默认洋红色（表示错误）
    
    // 如果有基础色纹理
    if (texture_uniform.has_base_color != 0u) {
        // 获取纹理尺寸
        let texture_dims = textureDimensions(color_texture);
        
        // 将UV坐标转换为纹素坐标
        // UV范围是[0,1]，纹素坐标范围是[0, width-1]
        let texel_coords = vec2i(
            i32(in.color_uv.x * f32(texture_dims.x)),
            i32(in.color_uv.y * f32(texture_dims.y))
        );
        
        // 使用textureLoad采样纹理（需要指定mip级别，这里用0）
        final_color = textureLoad(color_texture, texel_coords, 0);
    } else {
        // 没有纹理时使用白色
        final_color = vec4f(1.0, 1.0, 1.0, 1.0);
    }
    
    // 简单的伽玛校正
    final_color = pow(final_color, vec4f(2.2));

    return final_color;
}