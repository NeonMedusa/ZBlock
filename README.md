# ZBlock — 那个游戏的又一个仿品

**ZBlock** 是一个用 [Zig](https://ziglang.org/) 编写的3D方块游戏。

这是一款失败的个人独立游戏项目。我低估了游戏开发的工作量，奉劝各位不要轻易入坑独立游戏开发。如果真的想做，建议从简单的、2D 的玩法开始。

如果对这个项目的代码感兴趣，建议用 AI 辅助阅读源码和 `docs/` 下的文档。此项目越到后期AI成分就越高，这导致我自己对项目的理解都出现了大量偏差——这也是烂尾的原因之一，但更直接的原因是：我没有时间、金钱和精力继续学习 Blender 去制作模型和动画了，音效系统和配乐也完全没有做。

虽然项目选用了 [Zig](https://ziglang.org/) 这样高性能的语言，Zig 真的很好用，[WGPU](https://github.com/gfx-rs/wgpu-native) 也很好。但我的代码水平有限，也没有更多时间打磨了，帧数并不高，唯一可圈点的可能只有内存和显存占用了，给 Zig 社区丢脸了，对不起。🤦‍

虽然不太可能，但还是欢迎 PR。

<img width="1920" height="1032" alt="4f7fce34d23cb4abb660ab0113100cf6" src="https://github.com/user-attachments/assets/6220f650-204e-4bff-8ca3-6e1a09a0407a" />
<img width="1920" height="1032" alt="c18a70fb09ba099c44c42444126aa796" src="https://github.com/user-attachments/assets/c2896fc0-1298-43e0-8a11-8b21faf2dc7f" />
<img width="1920" height="1032" alt="3b5235c656f7f1a4cd5fedb2f3316e0d" src="https://github.com/user-attachments/assets/defaeee7-a926-4510-b7bc-d81066e4231b" />
<img width="1920" height="1032" alt="501e7bc9d10f28fb83d2df822fe39c0c" src="https://github.com/user-attachments/assets/f7d31c6c-a0e7-43b7-b5d0-de559e37bb5c" />

---

## 构建

### 环境要求

- **Zig 0.16.0**

### 构建步骤

```bash
git clone --recursive https://github.com/NeonMedusa/ZBlock.git
cd ZBlock
zig build run
```

Release 构建：

```bash
zig build -Dcpu=baseline -Doptimize=ReleaseFast run
```

### 配置

配置文件在 `config/` 目录下，首次运行自动生成默认文件：

- **`config/settings.json`** — 语言、用户名、区块加载距离
  `language` 可选 `zh`（中文）或 `en`（英文）。
  `player_name` 玩家名，留空则每次随机生成。
  `chunk_radius` 控制世界加载半径

- **`config/keybinds.json`** — 按键绑定，默认键位：`WASD` 移动、`Space` 跳跃/飞行切换、`Shift` 冲刺、`Ctrl` 潜行、鼠标左键破坏、右键放置

---

## 功能概览

### ✅ 已实现

- **渲染**
  - 异步生成区块mesh
  - glb模型加载（基于zgltf库）渲染
  - 简陋的骨骼动画渲染（加载与解析同基于基于zgltf库）
  - 按需卸载模型和材质（当初想的是为了能支持海量内容，没有合并顶点缓冲区和纹理，通过切换绑定组渲染区块、模型）
  - 基于shadowmap的动态阴影
  - 水面 SSR（屏幕空间反射）
  - 基于CubeMap+3D噪声的全球无缝天空系统
  - Reverse-Z 深度缓冲
  - 比特打包带来超低的显存占用
  - 逻辑（30Hz）与渲染分离

- **世界**
  - 无限地形生成（噪声驱动）
  - 方块编辑（破坏/放置）
  - 区块异步加载/卸载

- **物理**
  - AABB 碰撞（完整方块）
  - 重力 / 跳跃 / 下落
  - 游泳 / 飞行
  - 速度（步行/奔跑）

- **实体**
  - ECS 架构（基于 zig-ecs）
  - AI 状态机（idle / wandering / chasing / fleeing）
  - 异步分步A*寻路
  - 生物：僵尸、狼、狐狸、鹿
  - 动画 clip：idle / walk / run

- **多人联机**
  - 半成品，需要更新ui界面并在公网环境中测试
  - 30Hz 快照同步
  - 方块增量同步
  - 动画状态同步

- **UI**
  - 即时模式 UI
  - SDF字体渲染
  - 简陋的i18n
  - 热栏 / 背包栏
  - 主菜单 / 暂停菜单 / 存档选择 / 加载画面

- **系统**
  - 存档管理（基于 fridge/SQLite）
  - 每次世界方块数据持久化
  - 实体数据持久化

### ❌ 未实现（仅列出我觉得比较重要的项）

- 武器、工具、盔甲系统，配套的第一/第三人称动画（简单来说，是不同mesh、模型对同一套骨骼的绑定）
- 骨骼动画淡入淡出、多动画混合
- 真正可远程游玩的多人游戏（目前仅测试过本地回环联机，未测试远程联机的可用性，一个比较简单可做的改进是，先实现可手动输入的ip和端口。将来可能需要重写整个网络层，改用udp协议实现失败重发、服务器验算、分叉回退等）
- 跨区块的树、洞穴、建筑生成
- 水的流动与蔓延
- 非完整方块、非 AABB 碰撞
- 受击部位区分、物理骨骼动画（每个骨骼绑定一个胶囊或者其他形状的碰撞箱）
- CPU 侧光照系统
- 物品掉落与拾取
- 生态群系，不同的群系有不同的地形生成
- bvh树的完整实现（用于优化碰撞检测）
- 粒子特效

## 技术栈

| 领域 | 选型 |
|------|------|
| 语言 | [Zig](https://ziglang.org/) 0.16.0 |
| 图形 API | [WGPU](https://github.com/gfx-rs/wgpu-native) (WebGPU 实现，Vulkan 后端) |
| 窗口 | [GLFW](https://github.com/glfw/glfw) 3.4 |
| 3D 模型 | [zgltf](https://github.com/kooparse/zgltf) |
| 图片 | [zigimg](https://github.com/zigimg/zigimg) + [stb](https://github.com/nothings/stb) |
| 数据库 | [fridge](https://github.com/cztomsik/fridge) (SQLite ORM) |
| ECS | [zig-ecs](https://github.com/prime31/zig-ecs) |

---

## 许可

本项目以 MIT 协议开源

第三方库的许可见各自源码目录。