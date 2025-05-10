// const pyramid_vertex_data = [_]VertexAttribute{
//     // Base vertices
//     .{ .pos = .{ -0.5, -0.5, -0.3 }, .color = .{ 1.0, 1.0, 1.0, 1.0 } }, // bottom-left
//     .{ .pos = .{ 0.5, -0.5, -0.3 }, .color = .{ 1.0, 1.0, 1.0, 1.0 } }, // bottom-right
//     .{ .pos = .{ 0.5, 0.5, -0.3 }, .color = .{ 1.0, 1.0, 1.0, 1.0 } }, // top-right
//     .{ .pos = .{ -0.5, 0.5, -0.3 }, .color = .{ 1.0, 1.0, 1.0, 1.0 } }, // top-left
//     // Apex vertex
//     .{ .pos = .{ 0.0, 0.0, 0.5 }, .color = .{ 0.5, 0.5, 0.5, 1.0 } }, // pyramid top
// };
// const pyramid_index_data = [_]u16{
//     0, 1, 2, // Base
//     0, 2, 3, // Base
//     0, 1, 4, // Sides
//     1, 2, 4, // Sides
//     2, 3, 4, // Sides
//     3, 0, 4, // Sides
// };

// const cube_vertex_data = [_]VertexAttribute{
//     // Front face
//     .{ .pos = .{ -0.3, -0.3, -0.3 }, .color = .{ 1.0, 1.0, 1.0, 1.0 } }, // bottom-left-front
//     .{ .pos = .{ 0.3, -0.3, -0.3 }, .color = .{ 1.0, 1.0, 1.0, 1.0 } }, // bottom-right-front
//     .{ .pos = .{ 0.3, 0.3, -0.3 }, .color = .{ 1.0, 1.0, 1.0, 1.0 } }, // top-right-front
//     .{ .pos = .{ -0.3, 0.3, -0.3 }, .color = .{ 1.0, 1.0, 1.0, 1.0 } }, // top-left-front

//     // Back face
//     .{ .pos = .{ -0.3, -0.3, 0.3 }, .color = .{ 0.8, 0.8, 0.8, 1.0 } }, // bottom-left-back
//     .{ .pos = .{ 0.3, -0.3, 0.3 }, .color = .{ 0.8, 0.8, 0.8, 1.0 } }, // bottom-right-back
//     .{ .pos = .{ 0.3, 0.3, 0.3 }, .color = .{ 0.8, 0.8, 0.8, 1.0 } }, // top-right-back
//     .{ .pos = .{ -0.3, 0.3, 0.3 }, .color = .{ 0.8, 0.8, 0.8, 1.0 } }, // top-left-back
// };
// const cube_index_data = [_]u16{
//     0, 1, 2, // 前面
//     0, 2, 3,
//     4, 6, 5, // 后面
//     4, 7, 6,
//     0, 4, 5, // 底面
//     0, 5, 1,
//     3, 2, 6, // 顶面
//     3, 6, 7,
//     0, 3, 7, // 左侧面
//     0, 7, 4,
//     1, 5, 6, // 右侧面
//     1, 6, 2,
// };

// try all_vertex_data.appendSlice(&pyramid_vertex_data);
// try all_index_data.appendSlice(&pyramid_index_data);
// const pyramid_model = Model{
//     .vertex_offset = 0,
//     .vertex_size = pyramid_vertex_data.len * @sizeOf(VertexAttribute),
//     .vertex_count = pyramid_vertex_data.len,
//     .index_offset = 0,
//     .index_size = pyramid_index_data.len * @sizeOf(u16),
//     .index_count = pyramid_index_data.len,
// };
// try models.put("pyramid", pyramid_model);

// try all_vertex_data.appendSlice(&cube_vertex_data);
// try all_index_data.appendSlice(&cube_index_data);
// const cube_model = Model{
//     .vertex_offset = pyramid_vertex_data.len * @sizeOf(VertexAttribute),
//     .vertex_size = cube_vertex_data.len * @sizeOf(VertexAttribute),
//     .vertex_count = cube_vertex_data.len,
//     .index_offset = pyramid_index_data.len * @sizeOf(u16),
//     .index_size = cube_index_data.len * @sizeOf(u16),
//     .index_count = cube_index_data.len,
// };
// try models.put("cube", cube_model);
