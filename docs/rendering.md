# 渲染管线

## 着色器颜色校正

SRGB 硬件自动做 pow(1/2.2)，shader 做 pow(2.2) 抵消，线性颜色正确显示。

---

## UI 系统

### 文字渲染演进

文字渲染经历了三次迭代：

| 阶段 | 方案 | 问题 |
|------|------|------|
| 1 | SDF（stbtt\_GetCodepointSDF） | 小字号笔画合并（smoothstep 参数未调优） |
| 2 | Coverage bitmap（stbtt\_GetCodepointBitmap）+ 2x/3x/4x 降采样 | Nearest 降采样粗细不匀 |
| 3 | 回到 SDF + 片元着色器调参 | **当前方案** |

### SDF 图集

- 使用 `stb_truetype` 的 `stbtt_GetCodepointSDF` 在**固定字号**（`SDF_SCALE_HEIGHT = 56`）生成所有字形的距离场
- **图集大小**：2048×2048，**R8Unorm** 格式（单通道，距离值 0-255）
- **槽位**：64×64 像素/槽，每行 32 槽，共 1024 槽（ATLAS_ROW_STRIDE = 256 满足 wgpu 行对齐要求）
- **纹理过滤**：`WGPUFilterMode_Linear`（线性）

### SDF 生成参数

| 参数 | 值 | 说明 |
|------|----|------|
| `SDF_SCALE_HEIGHT` | 56 | 标准字号 = GLYPH_SIZE - 2 × SDF_PADDING |
| `SDF_PADDING` | 4 | 位图在字形外的边距，保证距离场有过渡空间 |
| `SDF_ONEDGE` | 128 | 轮廓边缘像素值，0=远外、128=边缘、255=深内 |
| `SDF_PIXEL_DIST_SCALE` | 64 | 距离场精度，越大梯度越快 |

### 字形缓存 LRU (Ring Buffer)

`glyph_slots[GLYPH_SLOTS]` 是一个固定大小的环形缓冲区：

1. **查找**：线性扫描 `glyph_slots`，按 `codepoint` 匹配
2. **未命中**：用 `next_slot` 写入新槽位，`next_slot = (next_slot + 1) % GLYPH_SLOTS`
3. **淘汰**：超过 1024 个不同字符时，新字形覆盖最早生成的槽位
4. **上传**：stb 生成的 SDF 位图居中写入 64×64 槽缓冲区 → `wgpuQueueWriteTexture` 上传到 GPU 纹理

### UV 计算

SDF 位图在槽中**居中放置**（不一定是满槽），UV 只覆盖有效像素区域（`sdf_width` × `sdf_height`），不包含 padding 留白：

```
ox = (GLYPH_SIZE - sdf_width)  / 2.0
oy = (GLYPH_SIZE - sdf_height) / 2.0
u_min = (slot_x + ox) / ATLAS_SIZE
v_min = (slot_y + oy) / ATLAS_SIZE
```

### 片元着色器抗锯齿

```
let sdf = textureSample(sdf_texture, sdf_sampler, in.texcoord).r;
let edge = 0.2 * fwidth(sdf);
alpha = smoothstep(0.25 - edge, 0.6 + edge, sdf);
```

- `fwidth(sdf)` 计算屏幕空间导数 → 自适应边缘宽度
- `smoothstep(0.25, 0.6, sdf)` 在 SDF 距离场中做平滑过渡
- `edge` 参数扩展过渡区域，消除锯齿
- 此参数由用户实测调到视觉效果最优

### 描边文字

当前实现：在 8 个±1px 方向各绘制一次黑色文字，最后在原始位置绘制白色文字（9 次 drawText）：

```
for (dx in [-1, 0, 1]):
    for (dy in [-1, 0, 1]):
        drawText(x + dx, y + dy, text, black)     // 跳过 (0,0)
drawText(x, y, text, white)                        // 填充
```

这种方法简单可靠，对少量描边文字性能足够。未来或许可优化为片元着色器单次绘制方案。

### 图标渲染

- 独立的 RGBA 图集管线（2048×2048，每槽 16×16，R8G8B8A8Unorm）
- 环形缓冲（16384 槽），按 item_id 缓存
- Nearest 过滤采样
- 图标从 `resources/textures/blocks/*_0.png` 和 `resources/textures/items/*.png` 加载

### 顶点格式

```zig
pub const UiVertex = struct {
    pos:      [3]f32,    // 屏幕像素坐标
    color:    [4]f32,    // 前景色
    texcoord: [2]f32,    // SDF 图集 UV 或 (-1,-1) 表示纯色矩形
};
```

### 光标布局 API

游标体系模拟 GUI 框架：`cursor_x` / `cursor_y` 记录当前位置，`row_bottom_y` 追踪当前行最大高度，`button()` / `sameLine()` / `spacing()` / `drawLabel()` 等函数自动推进游标。

- `textButton(x, y, w, h, label, font_size)` — 在指定坐标绘制按钮 + 居中文字 + 点击检测
- `cursor_col_x` — 当前列的起始 X（`spacing` 后自动恢复）
- `splitLayer()` — 标记分层点，在 `render.zig` 中实现先渲染背景层、后渲染图标/文字层

### 渲染流程

每帧：
1. `beginFrame()` 重置顶点/索引计数
2. UI 构建（调用 drawText / drawRect / drawButton 等追加顶点到 `frame_vertices`）
3. `splitLayer()` 记录背景层结束索引
4. 继续添加前景层（图标、文字描边等）
5. `endFrame()` → `wgpuQueueWriteBuffer` 上传顶点/索引/uniform
6. `render.zig`：先 draw 背景层（0 到 bg_index_count），再 draw 图标，最后 draw 前景层

---

## 3D 渲染

- 使用 wgpu-native + GLFW
- 固定光照方向 + Blinn-Phong 光照模型
- 支持 glTF/glb 模型
- 区块使用 greedy mesh 合并同材质面

### 视锥体裁剪

`render.zig` 每帧从 view-projection 矩阵提取 6 个视锥平面，在渲染循环中剔除不可见对象：

```
左平面: clip.x + clip.w ≥ 0    右平面:  clip.w - clip.x ≥ 0
底平面: clip.y + clip.w ≥ 0    顶平面:  clip.w - clip.y ≥ 0
近平面: clip.z ≥ 0            远平面:  clip.w - clip.z ≥ 0
```

- **实体**：检查插值后位置 `containsPoint(render_pos)`，不在视锥内则跳过 draw batch 收集
- **区块**：检查 chunk AABB（16×256×16）与视锥的相交性 `intersectsAABB(min, max)`，不相交则跳过 mesh 遍历
- 模型和 mesh 缓存不因剔除而卸载——视角转回时零延迟

实现见 `src/frustum.zig`（约 100 行）。
