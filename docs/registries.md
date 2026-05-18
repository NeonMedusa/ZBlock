# 注册表设计

## 为什么需要 registries.zig

三个注册表各自独立，不相互引用（避免循环依赖）。但运行时需要一种方式在编译期将掉落物字符串名解析为整数 ID 供 `game.zig` 消费——`registries.zig` 负责这个聚合。

## 文件职责

### block\_registry.zig

- 定义 `BlockProtoType`、`BlockId`、`BlockState`、`ItemDropVal`
- `ItemDropVal` 用 `item_name: [:0]const u8`（字符串）存掉落物名称，不引用任何外部 ID
- 方块原型定义处直接写 `drops = &.{.{ .item_name = "stone" }}`
- 提供 `BlockId.fromNameRuntime()` 供存档加载时做运行时名字查找

### item\_registry.zig

- 定义 `ItemProtoType`、`ItemId`、`ItemCategory`
- `item_infos` 包含 block items + 额外物品（如 apple）
- `ItemNames` comptime 枚举，用于编译期字符串→ID 查找
- `ItemId` 只是一个裸枚举——所有 ID 查询方法在 `registries.zig` 提供

### entity\_registry.zig

- 定义 `EntityTypeInfo`、`EntityTypeId`
- 掉落物同样用字符串，和 block 风格一致

### registries.zig

- 唯一一个同时 import 三个注册表的文件
- 编译期构建：
  - 扫描所有 block/entity 的原始 `ItemDropVal`（含字符串名）
  - 用 `ItemNames` 查询每个名字对应的整数 ID
  - 输出 `ResolvedDrop = { item_id, min_count, max_count, probability }`
  - 结果写入 flat 数组，运行时通过 `getBlockDrops(idx)` / `getEntityDrops(idx)` 访问
- 零运行时字符串开销

## 掉落物解析流程

```
定义时（entity_registry.zig）:
    drops = &.{.{ .item_name = "apple", .min_count = 1, .max_count = 2 }}

编译期（registries.zig）:
    block_drops_flat[i] = ResolvedDrop{
        .item_id = @intFromEnum(@field(ItemNames, "apple")),  // 编译期查找
        .min_count = 1,
        .max_count = 2,
        .probability = 1.0,
    }

运行时（game.zig handleLeftClick）:
    for (registries.getBlockDrops(block_idx)) |drop|
        tryItemToInventory(self, drop.item_id, ...);  // 直接整型，无字符串
```

## 为什么不用 JSON

当前 < 10 种方块/物品/实体，Zig 内联定义足够清晰。如果未来注册表数量增长到需要版本管理和自动迁移，可以：

1. 将三张表定义迁移到 `blocks.json` / `items.json` / `entities.json`
2. build.zig 在编译期读取 JSON，生成对应的 `.zig` 文件
3. 现行消费代码**不需要任何修改**（接口不变）

目前 JSON 迁移没有实施的必要。

---

## 运行时哈希表

为解决大规模存档加载时 `fromNameRuntime` 的线性扫描性能问题，`registries.zig` 在 `Game.init()` 时构建三张 `StringHashMapUnmanaged`：

```zig
// registries.zig（运行时）
pub var block_name_to_id: std.StringHashMapUnmanaged(u32) = .{};
pub var item_name_to_id: std.StringHashMapUnmanaged(u32) = .{};
pub var entity_name_to_id: std.StringHashMapUnmanaged(u32) = .{};

pub fn init(allocator: Allocator) void;
pub fn deinit(allocator: Allocator) void;
```

| 哈希表 | 用于 | 替代的对象 |
|--------|------|-----------|
| `block_name_to_id` | chunk palette 加载时 name→ID | `BlockId.fromNameRuntime` |
| `item_name_to_id` | 背包/热栏加载时 name→ID | `ItemId.fromNameRuntime` |
| `entity_name_to_id` | 实体加载时 type→ID | `EntityTypeId.fromNameRuntime` |

调用端将线性扫描的 `fromNameRuntime` 替换为 O(1) 哈希表查询：

```zig
// 旧（线性扫描）
const id = BlockId.fromNameRuntime(name) orelse 0;

// 新（O(1) 哈希表）
const id = registries.block_name_to_id.get(name) orelse 0;
```
