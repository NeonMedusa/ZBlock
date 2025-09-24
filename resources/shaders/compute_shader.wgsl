//computer_shader.wgsl:
//间接绘制命令缓冲区，存储最终的绘制命令，由计算着色器写入
@group(0) @binding(0) var<storage, read_write> indexed_indirect_cmds : array<IndexedIndirectCmd>;
//entities_data由CPU传入，包含实例的模型矩阵等信息
@group(0) @binding(1) var<storage, read_write> entities_data : array<EntityData>;
//models_data由CPU传入，包含模型的mesh信息等
@group(0) @binding(2) var<storage, read_write> models_data : array<ModelData>;
//meshes_data由CPU传入，包含每个mesh的顶点和索引信息
@group(0) @binding(3) var<storage, read_write> meshes_data : array<MeshData>;
//gltf_nodes_data由CPU传入，包含场景节点的层级关系和局部变换
@group(0) @binding(4) var<storage, read_write> gltf_nodes_data : array<GltfNodeData>;
//存储每个渲染实例的最终世界变换矩阵，由计算着色器计算和写入
@group(0) @binding(5) var<storage, read_write> world_matrices : array<mat4x4f>;
//由CPU传入当前活动实例总数，用于剔除缓冲区尾部的无效数据
@group(0) @binding(6) var<uniform> scene_uniform : SceneUniform;
//用于原子操作的mesh计数器
@group(0) @binding(7) var<storage, read_write> instance_counter : atomic < u32>;
struct SceneUniform {
    proj_matrix : mat4x4f,
    view_matrix : mat4x4f,
    time : f32,
    active_entity_count : u32,
};
struct EntityData {
    transform : mat4x4f,//实例的变换矩阵
    model_idx : u32,    //实例的模型索引
};
struct ModelData {
    first_node_idx : u32,   //模型的第一个mesh索引
    node_count : u32,   //模型的mesh数量
    mesh_count : u32,   //模型实际需要渲染多少个mesh
};
struct MeshData {
    first_vertex_idx : u32, //mesh的第一个顶点索引
    first_index_idx : u32,  //mesh的第一个索引索引
    vertex_count : u32, //mesh的顶点数量
    index_count : u32,      //mesh的索引数量
};
struct GltfNodeData {
    parent_idx : u32,   //父节点索引，最大值0xFFFFFFFF表示无父节点
    local_matrix : mat4x4f, //节点的局部变换矩阵
    mesh_idx : u32,     //mesh索引，最大值0xFFFFFFFF表示无父节点
};
struct IndexedIndirectCmd {
    indexCount : u32,
    instanceCount : u32,
    firstIndex : u32,
    baseVertex : u32,
    firstInstance : u32,
};
//计算节点全局变换的函数
fn calculate_global_transform(node_idx : u32) -> mat4x4f {
    var current_idx = node_idx;
    var global_matrix = mat4x4f(
    1.0, 0.0, 0.0, 0.0,
    0.0, 1.0, 0.0, 0.0,
    0.0, 0.0, 1.0, 0.0,
    0.0, 0.0, 0.0, 1.0
    );
    //从当前节点向上遍历到根节点
    while (current_idx != 0xFFFFFFFF)
    {
        let node = gltf_nodes_data[current_idx];
        global_matrix = node.local_matrix * global_matrix;
        current_idx = node.parent_idx;
    }
    return global_matrix;
}
//计算着色器主函数
@compute @workgroup_size(64)
fn cs_main(@builtin(global_invocation_id) global_id : vec3 < u32>)
{
    let entity_idx = global_id.x;
    if (entity_idx >= scene_uniform.active_entity_count)
    {
        return;
    }
    let entity = entities_data[entity_idx];
    let model = models_data[entity.model_idx];
    //原子分配连续的实例索引范围，根据AI的回答，atomicAdd返回的是相加前的旧值
    let base_instance = atomicAdd(&instance_counter, model.mesh_count);
    var current_instance = base_instance;
    for (var node_idx : u32 = model.first_node_idx; node_idx < model.first_node_idx + model.node_count; node_idx++)
    {
        let node = gltf_nodes_data[node_idx];
        if (node.mesh_idx == 0xFFFFFFFF)
        {
            continue;
        }
        let mesh = meshes_data[node.mesh_idx];
        //计算世界矩阵
        let node_global_transform = calculate_global_transform(node_idx);
        let final_world_matrix = node_global_transform * entity.transform;
        //存储数据 - 使用分配的范围内的连续索引
        world_matrices[current_instance] = final_world_matrix;
        //设置绘制命令
        indexed_indirect_cmds[current_instance].indexCount = mesh.index_count;
        indexed_indirect_cmds[current_instance].instanceCount = 1;
        indexed_indirect_cmds[current_instance].firstIndex = mesh.first_index_idx;
        indexed_indirect_cmds[current_instance].baseVertex = mesh.first_vertex_idx;
        indexed_indirect_cmds[current_instance].firstInstance = current_instance;
        current_instance++;
    }
}
