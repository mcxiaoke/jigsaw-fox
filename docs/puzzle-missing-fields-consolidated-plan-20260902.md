# 「我的」Tab 与全库数据模型缺失字段综合裁定与实施方案

> 制定日期：2026-09-02  
> 综合输入：  
> 1. `docs/puzzle-my-tab-and-daily-fold-plan-v2.md`（实施方案 v2.1）  
> 2. `docs/puzzle-missing-fields-audit.md`（外部审计 33 项清单）  
> 3. `docs/data-schema-comprehensive-fields-plan-20260902.md`（首轮全景调查）  
> 裁定准则：**实事求是。不盲目扩充，逐项核实数据来源与开销；刚需与不可逆字段坚决一次性加全，伪需求与脱离实际的字段坚决剔除。**

---

## 一、 核心准则与字段审查裁定原则

在决定一个字段“要不要加”时，必须严格通过以下三道审查：

1. **是否有不可逆的历史断代风险？**
   - 若发布后再加，老用户数据永远为 `null` 且不可推算（如 `firstCompletedAt`、`firstPlayedAt`、单难度时间戳），**坚决必须加**。
2. **是否有明确、顺畅的数据来源？**
   - 必须在当前业务链路（结算、存档、目录扫描）中能自然获得，**严禁为了造字段而侵入性修改无关流程**。
3. **加起来是否方便？会不会产生脏数据或双写不一致？**
   - 严格利用已有的 `extra` 通道与宽容解析机制，**零迁移、不破坏任何旧接口签名**；凡是可能引起状态不同步的冗余快照（如收藏快照进度）坚决不加。

---

## 二、 字段逐项核定与取舍裁定表

### 1. `LevelProgress`（整图进度模型，`lib/data/progress_store.dart`）

| 字段名 | 类型 | 通道 | 裁定结果 | 真实数据来源 | 理由与决策 |
| :--- | :--- | :--- | :--- | :--- | :--- |
| `firstPlayedAt` | `DateTime?` | `extra` | ✅ **必须加** | `updateProgress` 首次保存（`cur.lastSavedAt == null`）时赋 `now` | 不可逆时间戳。用于成就与“游玩历史”回溯。 |
| `lastCompletedAt` | `DateTime?` | `extra` | ✅ **必须加** | `recordDifficultyCompletion` 及 `updateProgress(isCompleted: true)` 时赋 `now` | **P1 核心**。「我的-已完成」子 Tab 倒序排序直接依赖。 |
| `firstCompletedAt` | `DateTime?` | `extra` | ✅ **必须加** | `recordDifficultyCompletion` 首次通关（`cur.isCompleted == false`）时赋 `now` | 不可逆时间戳。整图图鉴点亮、通关纪念日历关键凭证。 |
| `lastPlayedAt` | `DateTime?` | getter | ✅ **必须加** | 直接返回 `lastSavedAt` | 语义别名，零存储成本，对齐「我的-进行中」最近活跃排序。 |
| `totalPlayCount` | `int` | getter | ✅ **保留** | `records.values.fold(0, (s, r) => s + r.playCount)` | 纯内存聚合 getter，零存储，用于展示“累计挑战 N 次”。 |
| `completedDifficultyCount` | `int` | getter | ✅ **保留** | `records.values.where((r) => r.isCompleted).length` | 纯内存聚合 getter，用于展示“已打通 3/6 难度”。 |
| `bestDifficultyKey` | `String` | getter | ✅ **保留** | 遍历 `records` 取得最高星级对应的 key | 纯内存推导，点击卡片优先推荐最强战果。 |
| `lastSessionElapsedSeconds` | `int` | `extra` | ⚠️ **降级可选** | 结算传入的 `timeSeconds` | 弱需求（快照中已有 `elapsedSeconds`，通关已有 `bestTime`），可作为 extra 记录，但不上纲上线为必须。 |
| `snapshotUpdatedAt` | `DateTime?` | `extra` | ❌ **剔除** | N/A | **伪需求**。每次快照保存后均紧跟 `updateProgress`，`lastSavedAt` 天然同步刷新，两者 99.9% 重合，无需双重记录。 |

---

### 2. `DifficultyRecord`（单难度记录模型，`lib/data/progress_store.dart`）

> **关键漏洞纠偏**：原计划完全忽视了此层，而审计文档明确指出这是最大历史缺口。

| 字段名 | 类型 | 通道 | 裁定结果 | 真实数据来源 | 理由与决策 |
| :--- | :--- | :--- | :--- | :--- | :--- |
| `firstCompletedAt` | `DateTime?` | `extra` | ✅ **必须加** | `recordDifficultyCompletion`（`oldRecord.firstCompletedAt ?? now`） | **不可逆！** 单难度首通时间，各档位突破成就的直接证据。 |
| `lastCompletedAt` | `DateTime?` | `extra` | ✅ **必须加** | `recordDifficultyCompletion` 每次通关赋 `now` | 该档位最近完成时间，展示“大师难度通关于 3 天前”。 |
| `lastPlayedAt` | `DateTime?` | `extra` | ⚠️ **调整策略** | 通关时同 `now`；中途不强写 records | 若中途 autosave 强写未通关的 record 会导致空对象污染 records 集合。 |
| `minMoves` | `int` | `extra` | ✅ **建议加** | 初始 `-1`，结算时若有传入步数则更新 | 前瞻预留步数挑战与极简成就，极低成本。 |
| `isPerfect` | `bool` | getter | ✅ **保留** | `bestStars == 3 && minHintsUsed == 0` | 纯内存推导，完美通关角标直接读取。 |

---

### 3. `FavoriteEntry`（新增收藏存储，`lib/data/favorite_store.dart`）

| 字段名 | 类型 | 裁定结果 | 真实数据来源 | 理由与决策 |
| :--- | :--- | :--- | :--- | :--- |
| `canonicalId` | `String` | ✅ **必须加** | 入参 | 全局主键。 |
| `favoritedAt` | `DateTime` | ✅ **必须加** | `DateTime.now()` | 收藏子 Tab 默认倒序排序主键。 |
| `titleSnapshot` | `String?` | ✅ **必须加** | 收藏入口当前页面的标题 | 孤儿卡兜底标题。 |
| `imageSnapshot` | `String?` | ✅ **必须加** | 收藏入口当前页面的图片路径/URL | 孤儿卡兜底缩略图。 |
| `sourceLabelSnapshot` | `String?` | ✅ **必须加** | 入口页 `CatalogEntry.sourceLabel` | 孤儿卡来源标识（“主线”/“每日”/“自制”）。 |
| `isLocalFileSnapshot` | `bool` | ✅ **必须加** | 入口页 `CatalogEntry.isLocalFile` | **防崩溃**：决定离线孤儿卡走 FileImage 还是 AssetImage。 |
| `aspectRatioLabel` | `String` | ✅ **必须加** | 入口页图片宽高比标签（如 `square1x1`） | **防排版崩坏**：源被删后网格仍需长宽比以自适应布局。 |
| `author` | `String?` | ✅ **建议加** | 关卡作者/出处署名 | 摄影师/画师合规与版权署名。 |
| `tags` | `List<String>` | ✅ **建议加** | 关卡既有标签 | 预留收藏夹内多标签筛选。 |
| `preferredDifficultyKey` | `String?` | ⚠️ **降级可选**| 收藏时正在查看的难度 | 再次打开时默认选中该难度，体验优化项。 |
| `progressPercentSnapshot`| `int?` | ❌ **坚决剔除** | N/A | **严重反模式**。收藏夹应显示实时动态进度；源删除后孤儿卡展示“收藏当时的静态进度”无意义且会造成数据割裂。 |

---

### 4. `CatalogEntry`（统一目录索引，`lib/logic/catalog_index.dart`）

| 字段名 | 类型 | 裁定结果 | 真实数据来源 | 理由与决策 |
| :--- | :--- | :--- | :--- | :--- |
| `canonicalId` | `String` | ✅ **必须** | 合成规范 ID | 统一索引主键。 |
| `title` | `String` | ✅ **必须** | 各模块现成 title | 展示标题。 |
| `imagePathOrUrl` | `String` | ✅ **必须** | 各模块现成图片路径 | 图片源。 |
| `isLocalFile` | `bool` | ✅ **必须** | 各模块现成标记 | 取图路由判定。 |
| `sourceLabel` | `String` | ✅ **必须** | 各模块映射中文标签 | “主线”/“每日”/“活动”/“扩展包”/“自制”。 |
| `sourceModule` | `String` | ✅ **必须** | 规范前缀（main/daily/ugc/pack/event） | 机器判定与代码分支用。 |
| `aspectRatio` | `PuzzleAspectRatio` | ✅ **必须** | 由图片宽高推导或已有配置 | 网格自适应布局根本依据。 |
| `addedAt` | `DateTime?` | ✅ **建议加** | 各模型 `addedAt`/`importedAt`/`createdAt` | 各数据源均已现成持有，用于“NEW”角标判定。 |
| `recommendedDifficulty` | `String?` | ✅ **建议加** | 各模型默认 `difficulty` 计算 | 打开难度面板时高亮推荐项。 |
| `tags` | `List<String>` | ✅ **建议加** | 各模块现成 tags | 搜索和主题筛选基础。 |
| `contextId` | `String?` | ✅ **建议加** | packId / eventId / dateStr | 避免下游为调 API 频繁正则解析 canonicalId。 |
| `displaySubtitle` | `String?` | ⚠️ **降级可选** | 各模块组合副标题 | 优化列表副标题展示，来源明确。 |
| `difficultyTierCount` | `int` | ❌ **坚决剔除** | N/A | **伪需求**。游戏各难度是按宽高比由算法动态生成的（6~7 档），根本无需 hardcode 档位数。 |

---

### 5. `UnifiedPuzzleCardData`（统一卡片视图模型，`lib/logic/unified_puzzle_resolver.dart`）

| 字段名 | 类型 | 裁定结果 | 真实数据来源 | 理由与决策 |
| :--- | :--- | :--- | :--- | :--- |
| `canonicalId` ~ `sourceColor` | 基础 6 项 | ✅ **必须** | CatalogEntry 透传 | 卡片基本外观。 |
| `aspectRatio` | `PuzzleAspectRatio` | ✅ **必须** | CatalogEntry 透传 | 卡片宽高比排版。 |
| `progressPercent` | `int` | ✅ **必须** | LevelProgress.progressPercent | 进行中进度条。 |
| `isCompleted` | `bool` | ✅ **必须** | LevelProgress.isCompleted | 已完成判定。 |
| `hasActiveSnapshot` | `bool` | ✅ **必须** | LevelProgress.hasSnapshot | 规则乙判定。 |
| `activeDifficultyKey` | `String` | ✅ **必须** | LevelProgress.activeDifficultyKey | **续玩必传**：定位快照文件核心入参。 |
| `completedPieceCounts` | `Set<int>` | ✅ **必须** | LevelProgress.completedPieceCounts | **难度面板必传**：`ChooseDifficultySheet` 标记已通关档位。 |
| `maxStars` & `bestTimeSeconds` | 成绩 2 项 | ✅ **必须** | LevelProgress 现成字段 | 已完成卡片角标与最佳战报。 |
| `allDifficultyStars` | `Map<String, int>` | ✅ **建议加** | records.map(bestStars) | 卡片横向小星星进度排版，极低成本。 |
| `completedDifficultyCount` | `int` | ✅ **建议加** | LevelProgress getter | 显示“已通关 2/6 难度”。 |
| `totalPlayCount` | `int` | ✅ **建议加** | LevelProgress getter | 显示“挑战 5 次”。 |
| `minHintsUsed` | `int` | ✅ **建议加** | records 最小 hint | 显示“0提示通关”高光徽标。 |
| `isFavorite` | `bool` | ✅ **必须** | FavoriteStore.isFavorite | 卡片心形高亮状态同步。 |
| `favoritedAt` | `DateTime?` | ✅ **必须** | FavoriteEntry.favoritedAt | 收藏子 Tab 倒序排序。 |
| `lastCompletedAt` | `DateTime?` | ✅ **必须** | LevelProgress.lastCompletedAt | 已完成子 Tab 倒序排序。 |
| `lastSavedAt` | `DateTime?` | ✅ **必须** | LevelProgress.lastSavedAt | 进行中子 Tab 倒序排序。 |
| `isOrphan` | `bool` | ✅ **必须** | 目录反查未命中标记 | 孤儿卡置灰与失效处理。 |
| `isNew` | `bool` | ✅ **建议加** | `addedAt` 7天内且未完成 | “NEW”鲜明角标。 |
| `contextId` | `String?` | ✅ **建议加** | CatalogEntry.contextId | 点击卡片直接进入对应包/活动。 |

---

### 6. 全局统计与性能缓存（`ProgressStore` / `GameRepository`）

| 字段 / 方法 | 类别 | 裁定结果 | 改进方案 | 收益与实效 |
| :--- | :--- | :--- | :--- | :--- |
| `cachedTotalSolved` | `int` 缓存 | ✅ **坚决采纳** | 在 `refreshAggregatesCache()` 单次循环中累加 | **彻底根治 N+1**。原方法查一次要 load 全部 keys，现降为 O(1)。 |
| `cachedTotalStars` | `int` 缓存 | ✅ **坚决采纳** | 同上，在同一循环中累加全部 stars | 同上，消除页面首帧卡顿。 |
| `getTotalPlayCount()`| 聚合方法 | ✅ **保留** | 遍历 records 求和 | 成就与个人中心统计面板展示。 |
| `_keyDailyFoldedMonths` | 持久化 Key | ✅ **必须加** | SharedPreferences 字符串集合 | **体验刚需**。记住玩家折叠的月份，重启 App 不会全展开。 |
| `_keyTotalHintsUsed` | 统计 Key | ✅ **建议加** | 游戏结算时累计 | 全局提示统计与节约达人成就。 |
| `_keyFirstLaunchAt` | 统计 Key | ✅ **建议加** | 首次启动写入 ISO8601 | 玩家画像：“与拼图相伴的第 N 天”。 |

---

## 三、 修正后的精益实现代码规范

### 1. `lib/data/progress_store.dart` 补丁

```dart
// 1. DifficultyRecord 增加一等 getter（底层读写 extra）
extension DifficultyRecordTimestampExt on DifficultyRecord {
  DateTime? get firstCompletedAt =>
      DateTime.tryParse(extra['firstCompletedAt'] as String? ?? '');
  DateTime? get lastCompletedAt =>
      DateTime.tryParse(extra['lastCompletedAt'] as String? ?? '');
  DateTime? get lastPlayedAt =>
      DateTime.tryParse(extra['lastPlayedAt'] as String? ?? '');
  int get minMoves => (extra['minMoves'] as int?) ?? -1;
  bool get isPerfect => bestStars >= 3 && minHintsUsed == 0;
}

// 2. LevelProgress 增加一等 getter
extension LevelProgressTimestampExt on LevelProgress {
  DateTime? get firstCompletedAt =>
      DateTime.tryParse(extra['firstCompletedAt'] as String? ?? '');
  DateTime? get lastCompletedAt =>
      DateTime.tryParse(extra['lastCompletedAt'] as String? ?? '');
  DateTime? get firstPlayedAt =>
      DateTime.tryParse(extra['firstPlayedAt'] as String? ?? '');
  DateTime? get lastPlayedAt => lastSavedAt; // 语义别名

  int get totalPlayCount =>
      records.values.fold(0, (sum, r) => sum + r.playCount);
  int get completedDifficultyCount =>
      records.values.where((r) => r.isCompleted).length;
  
  Map<String, int> get allDifficultyStars =>
      records.map((k, v) => MapEntry(k, v.bestStars));
}
```

### 2. 写入链路原子更新规范（`recordDifficultyCompletion`）

```dart
// 结算时原子回写时间戳
final now = DateTime.now();
final updatedRecord = oldRecord.copyWith(
  bestStars: newBestStars,
  bestTimeSeconds: newBestTime,
  isCompleted: true,
  playCount: oldRecord.playCount + 1,
  minHintsUsed: newMinHints,
  extra: {
    ...oldRecord.extra,
    'lastCompletedAt': now.toIso8601String(),
    if (oldRecord.firstCompletedAt == null)
      'firstCompletedAt': now.toIso8601String(),
  },
);

final next = cur.copyWith(
  isCompleted: true,
  progressPercent: 100,
  completedPieceCounts: updatedCounts.toList(),
  records: existingMap,
  stars: math.max(cur.stars, newBestStars),
  bestTimeSeconds: cur.bestTimeSeconds == 0
      ? newBestTime
      : math.min(cur.bestTimeSeconds, newBestTime),
  hasSnapshot: false,
  lastSavedAt: now,
  extra: {
    ...cur.extra,
    'lastCompletedAt': now.toIso8601String(),
    if (cur.firstCompletedAt == null)
      'firstCompletedAt': now.toIso8601String(),
  },
);
```

---

## 四、 对实施方案 v2.1（`puzzle-my-tab-and-daily-fold-plan-v2.md`）的修正计划

经上述核定，实施计划在保持**总框架（4个 Phase）不动**的前提下，对数据层和表现层的内容做精益增补：

```
Phase 1: 数据层精细落地（扩展 ProgressStore + 建立 FavoriteStore + 目录索引 + 解析器）
├── 1.1 ProgressStore：
│   ├── LevelProgress 增加 firstPlayedAt / firstCompletedAt / lastCompletedAt / lastPlayedAt
│   ├── DifficultyRecord 增加 firstCompletedAt / lastCompletedAt / minMoves / isPerfect
│   ├── loadAllProgress() 单次遍历实现
│   └── refreshAggregatesCache() 扩展 cachedTotalSolved / cachedTotalStars 消除 N+1
├── 1.2 FavoriteStore（新建）：
│   ├── FavoriteEntry 完整字段：canonicalId, favoritedAt, titleSnapshot, imageSnapshot,
│   │   sourceLabelSnapshot, isLocalFileSnapshot, aspectRatioLabel, author, tags, extra
│   └── 内存 Set<String> 响应式 idsNotifier + 持久化
├── 1.3 UnifiedCatalogIndex（新建）：
│   └── 五来源统一聚合为 CatalogEntry（含 aspectRatio, author, tags, addedAt, contextId）
└── 1.4 UnifiedPuzzleResolver（新建）：
    └── 装配 UnifiedPuzzleCardData（含 activeDifficultyKey, completedPieceCounts, allStars 等 20 字段）

Phase 2: 每日月份折叠
├── 2.1 _expandedMonthKeys 折叠状态维护
├── 2.2 持久化记忆到 SharedPreferences（_keyDailyFoldedMonths）
└── 2.3 SliverGrid 条件渲染 + 旋转箭头动画

Phase 3: UI 表现层与触点联动
├── 3.1 main_screen.dart 扩展第 5 个 Tab（我的）
├── 3.2 my_center_tab_view.dart（新建）：
│   ├── 子 Tab：进行中(N) | 收藏(N) | 已完成(N)
│   ├── 规则乙装配逻辑与三种倒序排序（进行中按 lastPlayedAt / 已完成按 lastCompletedAt / 收藏按 favoritedAt）
│   └── _MyPuzzleGridCard 卡片渲染（孤儿卡置灰、微标、心形收藏按钮）
└── 3.3 触点联动：ChooseDifficultySheet 与 GamePage 挂接收藏与刷新通知

Phase 4: 全量回归与测试
├── 4.1 单元测试：扩展字段序列化/反序列化测试、聚合缓存测试、解析器测试
├── 4.2 运行 dart format（仅限修改文件）
└── 4.3 更新 docs/CHANGES-20260902.md
```

---

## 五、 结论与审查对照

1. **剔除虚浮字段**：成功识破并剔除了 `progressPercentSnapshot`（破坏数据一致性）、`difficultyTierCount`（与几何算法冲突脱节）和 `snapshotUpdatedAt`（与 `lastSavedAt` 重复）等伪需求；
2. **锁死不可逆字段**：将 `firstCompletedAt`、`firstPlayedAt`、`lastCompletedAt` 及其在难度级的镜像全面焊死在数据模型中，绝不留历史遗憾；
3. **保证视觉不翻车**：在收藏中锁定了 `aspectRatioLabel` 和 `isLocalFileSnapshot`，从根本上杜绝了源被删除后孤儿卡排版变形和图片加载崩溃的问题。
