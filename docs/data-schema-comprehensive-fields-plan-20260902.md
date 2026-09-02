# 数据架构全景字段审查与一次性补齐方案

> 编写日期：2026-09-02  
> 适用范围：`ProgressStore`、`DifficultyRecord`、`LevelProgress`、`FavoriteStore`、`UnifiedPuzzleCardData`、`SnapshotStore` 及既有关卡模型  
> 目标原则：**开发阶段前瞻性一次性补齐所有可能缺少的字段；利用宽容解析与零迁移红利，杜绝发布后因数据断代引发的不可逆痛点。**

---

## 一、 为什么必须在开发阶段“一次性加足字段”？

在基于本地持久化（`SharedPreferences` / 本地 JSON / 文件级快照）的应用中，存在以下铁律：

1. **不可逆的历史行为断代**：
   - 诸如**首次通关时间（`firstCompletedAt`）**、**单难度通关时间（`completedAt`）**、**首次开玩时间（`firstPlayedAt`）**、**累计实际耗时（`totalPlayTimeSeconds`）** 等行为事件，如果发生时不予记录，事后哪怕编写再复杂的 `MigrationService`，也永远无法从历史存档中凭空推算还原。
2. **孤儿卡片渲染灾难**：
   - 当用户删除本地自制拼图、限时活动下架或卸载扩展包后，收藏夹或历史记录仅存快照引用。若未在收藏或记录中冗余保存**宽高比（`aspectRatioLabel`）**、**来源前缀（`sourceModule`）** 或 **作者（`author`）**，孤儿卡片排版将发生拉伸变形、丢失版权出处或引发空指针崩溃。
3. **低成本红利期**：
   - 当前项目正处于快速开发迭代期，全部模型支持可选命名参数与默认值，加字段无需编写数据迁移脚本；一旦正式发布上线积累了真实用户，修改数据结构不仅需要繁琐的双向兼容迁移，还存在损坏用户进度的风险。

---

## 二、 核心进度层：`LevelProgress` 与 `DifficultyRecord`

文件路径：`lib/data/progress_store.dart`

### 1. `DifficultyRecord`（单难度档位成绩）

#### 现有字段
- `bestStars`: int（最佳星级 0~3）
- `bestTimeSeconds`: int（最佳通关耗时）
- `isCompleted`: bool（是否通关）
- `playCount`: int（游玩次数）
- `minHintsUsed`: int（历史最少提示次数，初始 -1）
- `extra`: Map<String, dynamic>（透传容器）

#### 缺失痛点
目前 `DifficultyRecord` 完全没有任何时间戳字段。玩家在不同日期打通了不同难度（例如新手 25 块与大师 225 块），难度完成时间全部丢失，无法做难度维度的通关成就与勋章时间线。

#### 建议一次性补齐字段
| 字段名 | 类型 | 默认值 | 业务价值与使用场景 |
| :--- | :--- | :--- | :--- |
| `lastCompletedAt` | `DateTime?` | `null` | 该难度**最近一次通关**时间（ISO8601） |
| `firstCompletedAt` | `DateTime?` | `null` | 该难度**首次通关**时间（不可逆！首通成就、勋章达成时间） |
| `firstPlayedAt` | `DateTime?` | `null` | 该难度**首次开始游玩**时间 |
| `lastPlayedAt` | `DateTime?` | `null` | 该难度**最近一次游玩**时间 |
| `totalPlayTimeSeconds` | `int` | `0` | 该难度累计游玩总时长（秒，非单局最佳，代表真实心血投入） |
| `minMoves` | `int` | `-1` | 历史最少有效移动/吸附步数（预留：极简步数挑战、步数大师成就） |
| `isPerfect` | `bool` (getter) | - | 快捷推导属性：`bestStars == 3 && minHintsUsed == 0`（3星且0提示纯粹通关） |

---

### 2. `LevelProgress`（单关卡全局通用进度 SSOT）

#### 现有字段
- `canonicalId`: String（全局主键）
- `progressPercent`: int（0~100）
- `isCompleted`: bool（是否曾通关）
- `completedPieceCounts`: List<int>（已打通的块数列表）
- `bestTimeSeconds`: int（全局最佳用时）
- `stars`: int（全局最高星级）
- `hasSnapshot`: bool（是否有在途残局存档）
- `activeDifficultyKey`: String（当前活跃难度）
- `snapshotKeys`: List<String>（存档列表）
- `records`: Map<String, DifficultyRecord>（难度记录字典）
- `lastSavedAt`: DateTime?（最后保存时间）
- `extra`: Map<String, dynamic>（透传容器）

#### 缺失痛点
缺少整图维度的首通时间、累计总投入时间、总局数以及最近一次通关时间（原方案 v2 中明确指出的 P1 缺陷）。

#### 建议一次性补齐字段
| 字段名 | 类型 | 默认值 | 业务价值与使用场景 |
| :--- | :--- | :--- | :--- |
| `lastCompletedAt` | `DateTime?` | `null` | 整图**最近一次通关**时间（用于「我的」- 已完成子 Tab 倒序排序） |
| `firstCompletedAt` | `DateTime?` | `null` | 整图**首次通关**时间（图鉴收集日历、里程碑回顾不可逆凭证） |
| `firstPlayedAt` | `DateTime?` | `null` | 整图首次开局时间 |
| `lastPlayedAt` | `DateTime?` | `lastSavedAt` | 最后活跃时间（一等字段/别名，用于「我的」- 进行中按活跃度排序） |
| `totalPlayTimeSeconds` | `int` | `0` | 该图跨所有难度累计游戏总秒数（年度报告：在这张图上沉浸了多久） |
| `totalCompletedCount` | `int` | `0` | 该图累计总通关局数（重复挑战次数统计） |
| `highestDifficultyKey` | `String?` | `null` | 已通关的最高难度 key（如 `16x24`，供卡片角标与段位直接读取展示） |

---

## 三、 收藏数据层：`FavoriteStore` 与 `FavoriteEntry`

新建文件路径：`lib/data/favorite_store.dart`

#### 缺失痛点
原计划仅设计了 `canonicalId`, `favoritedAt`, `titleSnapshot`, `imageSnapshot` 4 个字段。当源关卡失效被删时（例如 UGC 自制拼图被删、活动到期下架），若缺失**宽高比**，网格流排版将无法决定卡片比例，造成界面拉伸错位；且缺失来源类型与作者，无法在收藏夹内按来源筛选。

#### 建议一次性完整定义
```dart
class FavoriteEntry {
  const FavoriteEntry({
    required this.canonicalId,
    required this.favoritedAt,
    this.titleSnapshot,
    this.imageSnapshot,
    this.sourceModule = 'main',
    this.aspectRatioLabel = 'square1x1',
    this.author,
    this.tags = const [],
    this.defaultPieceCount,
    this.sortOrder = 0,
    this.extra = const {},
  });

  /// 全局规范 ID (如 "main:001", "daily:20260902", "ugc:1787548651000")
  final String canonicalId;

  /// 收藏时间戳（收藏子 Tab 默认倒序排序主键）
  final DateTime favoritedAt;

  /// 标题快照（源被删除/离线时兜底展示）
  final String? titleSnapshot;

  /// 缩略图路径/URL 快照
  final String? imageSnapshot;

  /// 来源模块 ('main' | 'daily' | 'event' | 'pack' | 'ugc'，供分类展示与角标着色)
  final String sourceModule;

  /// 宽高比标识 ('square1x1' | 'portrait2x3' | 'landscape3x2'，保证源失效后排版比例不崩)
  final String aspectRatioLabel;

  /// 创作者/出处署名（合规与防侵权展示）
  final String? author;

  /// 分类标签（风景/动物/二次元等，预留收藏夹内多维筛选）
  final List<String> tags;

  /// 默认/推荐块数（如 100 块）
  final int? defaultPieceCount;

  /// 用户自定义排序权重（预留收藏夹置顶或手动拖拽排序）
  final int sortOrder;

  /// 必须包含的透传字典，未来无需迁移即可扩展
  final Map<String, dynamic> extra;
}
```

---

## 四、 表现与索引层：`UnifiedPuzzleCardData` 与 `CatalogEntry`

新建文件路径：`lib/logic/catalog_index.dart`、`lib/logic/unified_puzzle_resolver.dart`

#### 缺失痛点
用于渲染「我的」Tab 网格与统一元数据卡片。卡片不仅需要展示标题和进度，还需要响应收藏、展示通关微标、识别长宽比及作者。

#### 建议一次性完整定义
```dart
class CatalogEntry {
  final String canonicalId;
  final String title;
  final String imagePathOrUrl;
  final bool isLocalFile;
  final String sourceLabel;
  final String sourceModule;
  final PuzzleAspectRatio aspectRatio;
  final String? author;
  final List<String> tags;
  final int defaultPieceCount;
  final String? contextId; // packId / eventId / dateStr
}

class UnifiedPuzzleCardData {
  const UnifiedPuzzleCardData({
    required this.canonicalId,
    required this.title,
    required this.imagePathOrUrl,
    required this.isLocalFile,
    required this.sourceLabel,
    required this.sourceColor,
    required this.sourceModule,
    required this.aspectRatio,
    this.author,
    this.tags = const [],
    this.progressPercent = 0,
    this.isCompleted = false,
    this.hasActiveSnapshot = false,
    this.maxStars = 0,
    this.bestTimeSeconds = 0,
    this.completedPieceCounts = const [],
    this.highestDifficultyKey,
    this.lastSavedAt,
    this.lastCompletedAt,
    this.firstCompletedAt,
    this.favoritedAt,
    this.isFavorite = false,
    this.isOrphan = false,
    this.contextId,
  });

  final String canonicalId;
  final String title;
  final String imagePathOrUrl;
  final bool isLocalFile;
  final String sourceLabel;
  final Color sourceColor;
  final String sourceModule;
  final PuzzleAspectRatio aspectRatio;
  final String? author;
  final List<String> tags;

  // 进度与成绩
  final int progressPercent;
  final bool isCompleted;
  final bool hasActiveSnapshot;
  final int maxStars;
  final int bestTimeSeconds;
  final List<int> completedPieceCounts;
  final String? highestDifficultyKey;

  // 时间维度
  final DateTime? lastSavedAt;
  final DateTime? lastCompletedAt;
  final DateTime? firstCompletedAt;
  final DateTime? favoritedAt;

  // 状态与路由
  final bool isFavorite;
  final bool isOrphan;
  final String? contextId;
}
```

---

## 五、 棋盘快照层：`PuzzleBoardState`

文件路径：`lib/logic/models/puzzle_state.dart`

#### 现有字段
已具备 `version`, `canonicalId`, `difficultyKey`, `aspectLabel`, `createdAt`, `updatedAt`, `extra`，前瞻架构良好。

#### 建议补齐的高价值字段
| 字段名 | 类型 | 默认值 | 业务价值与使用场景 |
| :--- | :--- | :--- | :--- |
| `moveCount` | `int` | `0` | 已进行的有效拖拽/吸附步数（用于步数统计与成就判定） |
| `undoCount` | `int` | `0` | 已进行的撤销次数（用于精准复盘） |
| `zoomLevel` | `double?` | `1.0` | 退出游戏时的视口缩放比例（恢复游戏时精准还原视野） |
| `panOffsetX` | `double?` | `0.0` | 退出游戏时的视口平移 X 坐标（恢复游戏视角无缝衔接） |
| `panOffsetY` | `double?` | `0.0` | 退出游戏时的视口平移 Y 坐标 |

---

## 六、 既有模型宽容加固（`LevelItem`、`DailyChallengeItem`、`CustomPuzzleItem`）

#### 现有隐患
经代码排查，`LevelItem`、`DailyChallengeItem`、`CustomPuzzleItem` **目前均未声明 `extra: Map<String, dynamic>` 机制**。
如果未来云端下发新字段，反序列化时未知键会被抛弃，下次落盘时直接抹除。

#### 建议加固动作
1. **全部增加 `extra: const {}`**：
   - 构造参数增加 `this.extra = const {}`；
   - `fromJson` 解析未知键填入 `extra`；
   - `toJson` 回写未知键。
2. **`DailyChallengeItem` 补齐时间戳**：
   - 增加 `completedAt: DateTime?`：记录每日挑战实际通关的具体时刻（区分“当天准时打卡”与“后续补打卡”，供连胜 Streak 精准校验）。

---

## 七、 全局统计与状态持久化（`GameRepository` / `Settings`）

文件路径：`lib/data/game_repository.dart`

在 SharedPreferences 中，除现有的 `totalCompletedLevels`、`totalPiecesSnapped`、`totalPlayTimeSeconds` 外，建议在开发阶段预留以下全局指标 Key：

| 键名常量 | 类型 | 作用与未来场景 |
| :--- | :--- | :--- |
| `_keyDailyFoldedMonths` | `Set<String>` | **月份折叠偏好记忆**：持久化玩家折叠的月份集合，冷启动保留状态 |
| `_keyTotalHintsUsed` | `int` | 全局累计使用提示总次数（统计面板、节约达人成就） |
| `_keyTotalUndosUsed` | `int` | 全局累计使用撤销总次数 |
| `_keyFirstLaunchAt` | `String` | 首次安装启动时间戳（ISO8601，计算“来到拼图世界第 N 天”） |
| `_keyLastActiveAt` | `String` | 最近一次活跃时间戳 |
| `_keyMaxDailyStreak` | `int` | 历史最高连续每日打卡天数（破纪录荣誉勋章） |
| `_keyCurrentDailyStreak`| `int` | 当前连续打卡天数缓存 |

---

## 八、 落地与结算联动规范

在 `ProgressStore.recordDifficultyCompletion` 结算时，字段的更新联动规则如下：

```dart
// 1. 难度档位更新联动
final now = DateTime.now();
final updatedRecord = oldRecord.copyWith(
  bestStars: newBestStars,
  bestTimeSeconds: newBestTime,
  isCompleted: true,
  playCount: oldRecord.playCount + 1,
  minHintsUsed: newMinHints,
  lastCompletedAt: now,
  firstCompletedAt: oldRecord.firstCompletedAt ?? now,
  lastPlayedAt: now,
  firstPlayedAt: oldRecord.firstPlayedAt ?? now,
  totalPlayTimeSeconds: oldRecord.totalPlayTimeSeconds + timeSeconds,
);

// 2. 整图通用进度更新联动
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
  lastCompletedAt: now,
  firstCompletedAt: cur.firstCompletedAt ?? now,
  firstPlayedAt: cur.firstPlayedAt ?? now,
  totalPlayTimeSeconds: cur.totalPlayTimeSeconds + timeSeconds,
  totalCompletedCount: cur.totalCompletedCount + 1,
  highestDifficultyKey: ...
);
```

---

## 九、 总结与执行建议

本方案所列字段均严格遵循：
1. **全可选参数 + 安全默认值**：不破坏任何已有调用方；
2. **零迁移代价**：老数据解析自动赋默认值，新数据平滑落盘；
3. **全面覆盖「我的」Tab 诉求**：彻底打通进行中、已完成、收藏的排序、筛选与孤儿卡容错链路。

建议在执行 Phase 1（数据层开发）时，直接对照本设计将字段一次性落地！
