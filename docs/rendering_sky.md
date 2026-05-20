# 程序化天空盒

## 架构

全屏三角（`@builtin(vertex_index)`），零 vertex/index buffer。
独立 pipeline（`depthWriteEnabled = 0`，`CompareFunction_Always`），
在主 render pass 的实体绘制前先画天空。

相关文件：

- `src/sky.zig` — SkyPipeline / SkyState / SkyUniform
- `resources/shaders/sky_shader.wgsl`

---

## 方向计算

```
sky_mat = transpose(view_rot) × inv(proj)
dir = normalize(sky_mat × ndc)
```

- `view_rot` 是 view 矩阵去掉平移的纯旋转矩阵
- `cached_inv_proj` = `inv(proj)`，在 `rebuildProjMatrix()` 中计算，窗口缩放时自动更新
- 不含相机平移，因此不需要 `camera_pos` 参与，数值稳定、无抖动

---

## 渲染元素

### 天空渐变

`horizon_color` / `zenith_color` 按世界方向 `dir.y` 从地平线到天顶线性混合。
夜间通过 `day_factor = smoothstep(-0.15, 0.25, sun_direction.y)` 渐变为深蓝色
`(0.02, 0.02, 0.08)`。

### 太阳

两层 pow 函数叠加：

- 外层光晕：`pow(sun_dot, 256)` × intensity × 2
- 内层亮盘：`pow(sun_dot, 2048)` × intensity × 4

### 月亮

硬切圆盘：`step(0.998, moon_dot)` × brightness × 3。
位于太阳正对面（`moon_dir = -sun_dir`），不需要独立位置计算。
未来可用贴图替代。

### 星星

基于 3D 方向哈希的程序化星空：

- 将 `normalize(dir)` 映射到 `[-100, 100]³` 整数网格
- 每格用 `hash3d` 判定是否有星；格内随机位置产生圆盘
- 半径 `smoothstep(0.3, 0.0, dist)`，夜间亮度翻倍
- 每颗星有独立的 twinkle 相位，由 `time + hash(cell)` 驱动
- `star_color_strength`：0=全白，>0 时部分星带随机色偏（未来可随季节/日期变化）

---

## 昼夜循环

```
angle = (time / day_length) × 2π
sun_direction = normalize(sin(angle)×0.8, cos(angle)×0.6 + tilt, cos(angle)×0.3)
```

- `day_length` = 60 秒（可在 `SkyPipeline` 的 `.day_length` 中调整）
- `seasonal_tilt`：0=春秋分（默认），+0.3=夏至（昼长），-0.3=冬至（昼短）
- `tilt` 未来可从季节系统获取

---

## 渲染流程

在 `render.zig` 中的位置：

1. 写 scene uniform + 更新天空 uniform（encoder 创建后、render pass 开始前）
2. 创建 render pass
3. **绘制天空**（独立 pipeline，slot 0 绑定天空 bind group）
4. 设置全局 bind group（slot 0 切换为主管线全局组）
5. 绘制实体 / chunk / UI

**不写深度**，因此后续的实体绘制会自然遮挡天空。
