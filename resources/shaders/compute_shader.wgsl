// 最简单的静态层级计算：
@group(0) @binding(0) var<storage> nodes : array<GpuNode>;
@group(0) @binding(1) var<storage, read_write> world_matrices : array<mat4x4<f32>>;

@compute @workgroup_size(64)
fn main(@builtin(global_invocation_id) global_id: vec3<u32>) {
    let node_index = global_id.x;
    if (node_index >= arrayLength(&world_matrices)) { return; }
    
    let node = nodes[node_index];
    var world_matrix = node.local_matrix;
    
    // 简单的层级计算（假设节点按父->子顺序排列）
    var parent_index = node.parent_index;
    while (parent_index >= 0) {
        world_matrix = world_matrices[parent_index] * world_matrix;
        parent_index = nodes[parent_index].parent_index;
    }
    
    world_matrices[node_index] = world_matrix;
}