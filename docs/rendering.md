# 渲染管线

## UI 系统

### 文字渲染演进

文字渲染经历了三次迭代：

| 阶段 | 方案 | 问题 |
|------|------|------|
| 1 | SDF（stbtt\_GetCodepointSDF） | 小字号笔画合并 |
| 2 | Coverage bitmap（stbtt\_GetCodepointBitmap）+ 2x/3x/4x 生成 | Nearest 降采样粗细不匀 |
| 3 | 回到 SDF + 片元着色器微调 | 当前方案 |

### SDF 文字渲染

- 使用 stb\_truetype 的 `stbtt_GetCodepointSDF` 在固定字号（SDF_SCALE_HEIGHT）生成 SDF 图集
- 图集大小 2048×2048，每槽 64×64，R8Unorm 格式
- 渲染时线性采样（`WGPUFilterMode_Linear`），通过 smoothstep + fwidth 实现子像素抗锯齿
- SDF onedge=128，pixel\_dist\_scale=64.0，padding=4

### 纹理颜色校正

- 渲染目标格式：`BGRA8UnormSrgb`
- Shader 输出经过 `pow(color, vec4f(2.2))`
- SRGB 硬件做 `pow(1/2.2)` → 两者抵消，线性颜色正确显示

### 描边文字

使用片元着色器单次绘制完成（不在 CPU 端绘制多个图层）：

```
if (顶点标记为描边模式):
    outline_alpha = smoothstep(0.05, outline_hi, sdf)
    fill_alpha    = smoothstep(0.5 - AA, 0.5 + AA, sdf)
    alpha = mix(outline_alpha, 1.0, fill_alpha)
    color = mix(outline_color, fill_color, fill_alpha)
```

- 描边粗细通过顶点属性 `outline_color.a` 控制（单位：屏幕像素，最大 8px）
- 一次 drawText 即可同时输出描边和填充

### 图标渲染

- 独立的 RGBA 图集管线（2048×2048，每槽 16×16，R8G8B8A8Unorm）
- Nearest 过滤采样
- 从 `resources/textures/blocks/*_0.png` 和 `resources/textures/items/*.png` 加载

## 3D 渲染

- 使用 wgpu-native + GLFW
- 固定光照方向 + Blinn-Phong 光照模型
- 支持 glTF/glb 模型
- 区块使用 greedy mesh 合并同材质面
