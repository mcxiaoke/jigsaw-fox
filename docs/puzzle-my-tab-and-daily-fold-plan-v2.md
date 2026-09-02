# 每日月份折叠 +「我的」Tab 实施方案 v2.1（对 temp/implementation_plan.md 的审查修正版）

> 审查日期：2026-09-02（v2.1 修订同日）
> 审查对象：`temp/implementation_plan.md`（外部 AI 产出）
> 审查方式：逐条对照现有代码（file:line 均已实测核实）与 `temp/gui` 3 张参考截图
> v2.1 修订：① 记录两项已拍板决策（§二）；② 新增底层数据结构评估（§三，结论：不重构、加法扩展）；③ Tab 布局按方案 A' 更新文件计划（§六/§七）。v2 原稿备份于 `temp/backups/puzzle-my-tab-and-daily-fold-plan-v2.md.bak-20260902-1508`。

---

## 一、原计划审查结论

原计划的总体分层（FavoriteStore / 统一元数据解析 / 月份折叠状态 / 子 Tab 列表）方向正确，
FavoriteStore 确为空白（全库 grep「favorite|收藏」0 命中），CanonicalId 五前缀路由描述准确。
但存在 **1 个文件冲突级、2 个数据层不可实现级、若干设计偏差**，直接照做会返工。

| # | 严重度 | 问题 | 代码证据 | 修正（v2.1） |
| :-- | :--- | :--- | :--- | :--- |
| 1 | **P1 冲突** | 计划要求**新建** `my_profile_tab_view.dart`，但项目已有 `lib/pages/tabs/my_puzzles_tab_view.dart`，且它就是底部第 4 个 Tab（"自制"），AppBar 标题已经是"我的拼图" | `main_screen.dart:12,35,92` | 方案 A' 下：`my_puzzles_tab_view.dart`（自制 Tab）**原样不动**，新建独立文件 `my_center_tab_view.dart` 承载"我的"Tab，命名彻底解耦 |
| 2 | **P1 不可实现** | "已完成按完成时间倒序"——`LevelProgress` 根本没有完成时间戳：`records` 仅含 bestStars/bestTimeSeconds/playCount/minHintsUsed，`lastSavedAt` 是任意保存时间 | `progress_store.dart:10-25,472-486` | `recordDifficultyCompletion` / `updateProgress(isCompleted:true)` 写入 `lastCompletedAt`（走已有 `extra` 通道，零迁移），历史数据降级用 `lastSavedAt`；详见 §三 |
| 3 | **P1 规则缺口** | 进行中/已完成判定会重叠：`isCompleted` 是粘性的（通关后永久 true），通关后换难度续玩 → `hasSnapshot=true && isCompleted=true`，按原计划过滤条件同一张卡同时进两个列表，且未定义去重规则 | `game_repository.dart:396-401`（`isCompleted \|\| current.isCompleted \|\| …`） | 已拍板规则乙：已完成 = `isCompleted`；进行中 = `(hasSnapshot \|\| progressPercent>0)` 且允许与已完成重复出现，见 §五-2 |
| 4 | P2 与截图不符 | 参考截图 3 底部为 `图库\|每日拼图\|图集\|活动\|我的拼图`。原方案 A/B 均不贴合 | 截图 3 底栏 | 用户已拍板 **方案 A'**：保留现有 4 Tab（主页/每日/活动/自制），末尾追加"我的"，不抽离图集（§二） |
| 5 | P2 被低估 | pack/event 元数据解析并非"映射回 AppContent"一句话：需 `AppContent.instance.packs.getPackLevels(pack)` 反查 `PuzzleLevelItem`；daily 双格式互转（canonical `daily:20260902` 无横线 vs `DailyChallengeItem.date = 2026-09-02`） | `pack_levels_page.dart:45`、`game_repository.dart:126-127` | Resolver 内置两种格式互转 + pack 反查，见 §四-3 |
| 6 | P2 孤儿数据 | 自制关卡删除（`deleteCustomPuzzle`）后，收藏与进度残留 `ugc:*` 悬挂引用 | `game_repository.dart:318-354` | FavoriteStore 冗余 title/image（原计划已有，保留），Resolver 解析失败返回失效标记，卡片置灰 + 可一键清理 |
| 7 | P3 过度设计 | `DailyFoldController` 独立类没必要——`DailyTabView` 已是 StatefulWidget 且**已按月分组渲染**（monthGroups + 月份 header + 进度徽标全都在） | `daily_tab_view.dart:188-192,390-410,417-466` | 只需在 State 里加 `Set<String> _expandedMonthKeys`，改动量约 40 行 |
| 8 | P3 缺失 | 全程未提刷新链路：GamePage 返回后"我的"列表、收藏按钮变更如何同步（现有页面均为 pop 后 setState 模式） | `daily_tab_view.dart:67`、`my_puzzles_tab_view.dart:142` | 见 §五-4 刷新触发点清单 |
| 9 | P3 命名混乱 | 同一概念 3 个名字：MyPuzzlesCenterTabView / MyProfileTabView / MyTabView；UnifiedPuzzleResolver / PuzzleMetadataResolver | 计划 §二/§五/§六 | 统一：`MyCenterTabView`（新建）+ `UnifiedPuzzleResolver`；`MyPuzzlesTabView` 保持专指自制 Tab |

另：计划 Phase 1-3 说"扩展 ProgressStore 提供拉取所有 ID 列表"——`listAllCanonicalIds()` 已存在（`progress_store.dart:173`），只需补批量加载。

---

## 二、已拍板的决策（原 Phase 0）

### 决策 1：底部导航布局 —— **方案 A'**

5 Tab：**主页 / 每日 / 活动 / 自制 / 我的**（"我的"固定最后一位）。
- 现有 4 个 Tab 及对应视图文件**全部不动**（含 `my_puzzles_tab_view.dart` 自制 Tab，其内容已足够多，不与"我的"合并）；
- "我的"为全新 Tab：子 Tab `进行中(N) | 收藏(N) | 已完成(N)`，仅做进度/资产聚合展示。

### 决策 2：进行中 / 已完成去重 —— **规则乙（允许重复）**

- **已完成** = `LevelProgress.isCompleted == true`；
- **进行中** = `hasSnapshot == true || progressPercent > 0`（不再排除 isCompleted）。含义：有活跃存档/进度的图都算"进行中"，因此通关后换更高难度续玩的图会**同时**出现在"进行中"与"已完成"两个子 Tab——这正是业务本意（有活档 = 玩家大概率回来续玩）。
- 实现上谓词收敛在 `MyPuzzlesController` 一处，后续若要切规则甲只改一个函数。

---

## 三、底层数据结构评估：要不要改？（结论：不重构，做一次加法式扩展）

### 1. 现状盘点（实测）

```
写入路径（每次游玩/结算多处联动，属刻意的 v3 双写设计）：
GamePage (debounce 自动存档 game_page.dart:344-426 / 结算 :495-535)
  ├─ GameRepository.update{Level|Daily|Custom|Generic}Progress
  │    ├─ 模块镜像 JSON（levels/daily/custom prefs，供解锁链与旧 UI）
  │    └─ ProgressStore.updateProgress / recordDifficultyCompletion   ← canonical SSOT
  └─ SnapshotStore（重快照文件，仅棋盘布局）
```

| 疑似缺陷 | 实测结论 |
| :--- | :--- |
| 缺 `lastPlayedAt` | **不缺**。`lastSavedAt` 在每次中途存档（debounce autosave，`game_page.dart:344-426`）与结算（`game_page.dart:495-535` → `progress_store.dart:292,369`）都刷新为 now，语义上就是 lastPlayedAt。补一个别名 getter 即可，无需迁移 |
| 缺 `lastCompletedAt` | **确实缺**。`DifficultyRecord`/`LevelProgress` 均无完成时间戳（`progress_store.dart:10-25`）。这是唯一必须新增的字段 |
| 缺收藏数据 | 全新需求，由新建 `FavoriteStore` 承载，不动现有结构 |
| 三份进度镜像交叉 | **存在但是历史设计**：模块镜像（levels/daily/custom JSON）仍被解锁链（`game_repository.dart:504-513` 的 `isUnlocked`）与旧 UI 消费；而所有游戏写入路径都会同步写 ProgressStore（`game_repository.dart:416-485,601-668,757-824,867+`），**canonical 维度 SSOT 已成立**。"我的"页只读 ProgressStore 即可，不受镜像影响 |
| JSON 版本兼容 | `LevelProgress.fromJson` 是宽容解析（known/extra 机制 + 全字段默认值，`progress_store.dart:554-609`），**加字段零迁移**；`extra` 通道自动保留未知键 |

### 2. 方案对比

| 方案 | 内容 | 收益 | 代价 | 结论 |
| :--- | :--- | :--- | :--- | :--- |
| **甲：加法扩展（采纳）** | `LevelProgress` 新增 `lastCompletedAt`（extra 通道写入 + 一等 getter + `lastPlayedAt` 别名）；`loadAllProgress()` 批量加载；新建 FavoriteStore | 补齐全部缺口；旧数据零迁移；改动约 30 行 | 几乎无 | ✅ 本方案采用 |
| 乙：底层重构（统一 DB） | 迁移全部 prefs JSON + 快照文件到 sqflite/Isar 单表，拆除双写镜像 | 单一 SSOT、可查询 | 迁移脚本 + 解锁链重写 + 全量回归，约 3-5 天，高风险；当前规模（100 主线 + ~365 每日 + 自制/包）下 prefs 读取毫秒级，无性能瓶颈 | ❌ 收益不量化支撑复杂度，驳回 |
| 丙：镜像冻结（后置可选） | 进度/星级/时间以 ProgressStore 为唯一 SSOT，模块镜像仅保留解锁链所需字段，逐步废弃镜像中的进度副本 | 降低双写发散面 | 独立小重构，与本需求无耦合 | ⏸ 不阻塞本需求，记为后续技术债 |

### 3. 具体改动（ProgressStore，`lib/data/progress_store.dart`）

1. `LevelProgress` 增加：
   ```dart
   DateTime? get lastCompletedAt => DateTime.tryParse(extra['lastCompletedAt'] as String? ?? '');
   DateTime? get lastPlayedAt => lastSavedAt; // 语义别名，供"我的"页使用
   ```
2. `recordDifficultyCompletion`（:238）：`copyWith` 时传 `extra: {...cur.extra, 'lastCompletedAt': DateTime.now().toIso8601String()}`；
3. `updateProgress`（:312）：当 `isCompleted == true` 且此前未完成时同样写入；
4. 新增 `Future<Map<String, LevelProgress>> loadAllProgress()`：单次遍历 prefs keys + jsonDecode，替代 N+1（现有 `getTotalStars` :208 为逐条模式，勿复制）；
5. `extra` 是既有序列化通道（`toJson` :548-550 自动落盘、`fromJson` :567-571 自动回收），**无需动 key 前缀、无需迁移脚本**。

### 4. 规模模型与性能估算（实测基准，2026-09-02）

先纠正一个关键认知：**目录总量与进度数据量是两个数量级**。

| 维度 | 量级（按增速推算） | 存储/数据形态 | 影响对象 |
| :--- | :--- | :--- | :--- |
| **目录（Catalog，只读内容）** | 主线 100/月 → 年 1200+；每日 365/年；活动 2 周/100 → 年 1000+；加自制/包/历史累积 ≈ **3000~6000+** | 内容管线内存对象（levels/daily/packs/events），**不是** per-level prefs | Resolver 需要索引，见 §四-0 |
| **进度（Progress，用户行为）** | 只跟"**用户玩过的去重关卡数**"有关，与目录总量无关。重度玩家 2 年 ≈ 1000~2000 条 | per-canonicalId prefs JSON（`ProgressStore`），一条 ~400B | loadAll 的循环体 |

实测基准（Python 同算法复杂度；Dart jsonDecode 同量级，低端安卓保守 ×3~5）：

```
2000 条进度 jsonDecode（loadAll 核心） : 15.1 ms   ≈ 7.5 µs/条
2000 条进度 JSON 总计                   : 780 KB
6000 条目录索引构建（Map）              : 5.6 ms
2000 次 resolver O(1) 命中              : 0.3 ms
```

**结论与约束**（写入实现规范）：
1. 「我的」列表装配复杂度 = O(玩过数 + 收藏数)，**与 3000~6000 目录总量解耦**——目录只在初始化/内容更新时构建一次内存索引（§四-0），禁止任何 per-card `firstWhere`；
2. 2000 条进度全量重建 ≈ 15~50ms（设备端），可接受，但**必须缓存**，仅在触发点（§五-4）重建，禁止每次 Tab 切换重算；
3. 进度存量护栏：prefs 进度条目积累到 **>2000 条或序列化总量 >1.5MB** 前不需要换存储；若越线，把 ProgressStore 后端换成 path_provider 每级一个 JSON 文件（与 SnapshotStore 同模式）即可，接口已隔离只换后端——本轮不实施，阈值写进代码注释。

---

## 四、数据层（Data Layer）

### 0. 目录索引 `UnifiedCatalogIndex`（规模护栏，先于 Resolver）

```dart
class CatalogEntry {          // 五来源统一后的只读视图
  final String canonicalId;   // 按 CanonicalId 规则合成，格式统一
  final String title;
  final String imagePathOrUrl;
  final bool isLocalFile;     // asset / 本地文件 / 网络 URL 的取图路由
  final String sourceLabel;   // 主线/每日/活动/扩展包/自制
}

class UnifiedCatalogIndex {
  final Map<String, CatalogEntry> byId;
  static Future<UnifiedCatalogIndex> build(); // 全量重建（6000 条 ≈ 6ms）
  void invalidate();                           // 内容变更后标记，惰性重建
}
```

- 数据来源：`GameRepository.levels`（合成 `main:NNN`）+ `dailyChallenges`（`daily:yyyyMMdd`）+ `customPuzzles`（`ugc:id`）+ `AppContent` packs/events 管线产物（枚举 levels 合成，同 §四-3 路由表）；
- **重建时机**：首次进入"我的"页时构建一次；此后监听 `AppContent.instance.contentUpdateNotifier`（`app_content.dart:33`，manifest 更新/包增删都会触发）与 `GameRepository.customPuzzlesNotifier` 失效重建。主线"每月 100 动态更新"即 manifest 版本更新 → 天然走该 notifier，索引自动跟随；
- **懒构建 + 缓存**：构建约 6ms，仅在失效后首次访问时重建，进入列表装配循环前保证已就绪。

### 1. 新增 `lib/data/favorite_store.dart`（收藏持久化）

存储介质对齐 ProgressStore：SharedPreferences，Key `jigsaw_favorites_v1`，值为 JSON 数组。

```dart
class FavoriteEntry {
  final String canonicalId;
  final DateTime favoritedAt;
  final String? titleSnapshot;   // 冗余快照：源被删后仍可显示
  final String? imageSnapshot;   // 缩略图路径/URL
}

class FavoriteStore {
  FavoriteStore._();
  static final FavoriteStore instance = FavoriteStore._();

  Future<void> init();                       // main() 启动时调用
  Set<String> get favoriteIds;               // 内存缓存，同步读
  ValueNotifier<Set<String>> get idsNotifier;// 全局响应式（收藏心形按钮用）
  Future<bool> toggleFavorite(String canonicalId, {String? title, String? image});
  bool isFavorite(String canonicalId);       // 同步版（build 内可用）
  Future<List<FavoriteEntry>> favoritesSortedByTime(); // favoritedAt 倒序
  Future<void> pruneOrphans(Set<String> validIds);     // 孤儿清理（可选）
}
```

要点：
- `idsNotifier` 用 `Set<String>` 即可满足心形按钮高亮，无需每次反序列化全量 entries；
- toggle 成功后同时更新内存缓存与 notifier，写入失败回滚内存态并打日志（对齐 `ProgressStore.save` 的 try/catch 风格，`progress_store.dart:159-170`）。

### 2. 扩展 `lib/data/progress_store.dart`

见 §三-3（`lastCompletedAt` + `lastPlayedAt` 别名 + `loadAllProgress()`）。

### 3. 新增 `lib/logic/unified_puzzle_resolver.dart`（统一元数据解析）

> 前置依赖：§四-0 `UnifiedCatalogIndex`。Resolver 不直接持有各来源列表，全部经索引 O(1) 反查；索引未命中（来源被删/格式异常）→ `isOrphan`。

```dart
class UnifiedPuzzleCardData {
  final String canonicalId;
  final String title;
  final String imagePathOrUrl;
  final bool isLocalFile;
  final String sourceLabel;        // 主线/每日/活动/扩展包/自制
  final Color sourceColor;
  final int progressPercent;
  final bool isCompleted;
  final bool hasActiveSnapshot;    // 参与规则乙判定
  final int maxStars;              // LevelProgress.maxStars
  final int bestTimeSeconds;
  final DateTime? lastSavedAt;
  final DateTime? lastCompletedAt;
  final bool isOrphan;             // 源已删除/下架
}

class UnifiedPuzzleResolver {
  UnifiedPuzzleResolver(this._index);

  /// 输入 canonicalId + 已批量加载的 progress，同步装配卡片数据（图片解析除外）
  UnifiedPuzzleCardData? resolve(String canonicalId, LevelProgress progress);
}
```

索引合成规则（即 §四-0 的 `canonicalId` 生成公式，格式均已实测核实）：

| 前缀 | 合成公式（对应索引数据源） | 备注 |
| :--- | :--- | :--- |
| `main:NNN` | `levels[i]` → `canonicalForLevel(i)` 三位补零（`game_repository.dart:124`） | index 越界 → isOrphan |
| `daily:yyyyMMdd` | `dailyChallenges[i]` → `canonicalForDaily(date)` **去横线**（:126）；反查时 `yyyyMMdd ↔ yyyy-MM-dd` 互转 | 图片为内置 asset（`item.assetPath`） |
| `ugc:{id}` | `customPuzzles[i]` → `canonicalForCustom(id)`（:128） | 被删除 → isOrphan（favorite 留快照兜底显示） |
| `pack:{packId}:{file}` | packs 管线产物 → `getPackLevels(pack)` 枚举合成（`pack_levels_page.dart:45` 同款 API） | 包被删 → isOrphan |
| `event:{eventId}:{file}` | events 管线产物，同 pack 枚举合成（`events_content_pipeline.dart`） | 活动下架 → isOrphan |

注意：`main:` 与 `ugc:`、`pack:` 的 name 段规则不同（index vs filename），必须用 `CanonicalId.parse` 的 `context` 字段区分，不能字符串前缀猜测。

---

## 五、业务逻辑层（Business Logic）

### 1. 月份折叠（不建独立 Controller）

`_DailyTabViewState` 内直接加：

```dart
final Set<String> _expandedMonthKeys = {};   // monthKey 形如 '2026-09'
bool _foldInitialized = false;
```

- 首次 build 时初始化：当前月（`DateTime.now()` 的 `yyyy-MM`）加入展开集合，其余收起；
- `_buildMonthHeader` 整行包 `InkWell` → `toggle` monthKey，右侧箭头 `AnimatedRotation(turns: expanded ? 0 : 0.5, duration: 200ms)`；
- 折叠渲染：`expanded` 为 false 时**跳过该月的 SliverGrid**（slivers 列表按条件生成，现有 for-in 结构 :390-410 天然支持）；
- 可选：把展开集合持久化到 prefs（`jigsaw_daily_fold_v1`），回App恢复上次状态；不做也不影响功能。

> 原计划把它抽成 `DailyFoldController` 属过度设计——该状态只有这一个消费方。

### 2. 「我的」列表装配（`MyPuzzlesController`，普通类即可）

```dart
class MyPuzzlesLists {
  final List<UnifiedPuzzleCardData> inProgress; // 规则乙
  final List<UnifiedPuzzleCardData> completed;
  final List<UnifiedPuzzleCardData> favorites;
}

class MyPuzzlesController {
  Future<MyPuzzlesLists> buildLists() async {
    // 1. progressMap = await ProgressStore.instance.loadAllProgress()  （一次遍历）
    // 2. 进行中谓词（规则乙）：p.hasSnapshot || p.progressPercent > 0
    //    已完成谓词：p.isCompleted（允许与进行中重复）
    // 3. favorites：FavoriteStore.favoritesSortedByTime() → 逐个 resolve（orphan 保留置灰）
    // 4. 排序：
    //    进行中：lastPlayedAt(lastSavedAt) 倒序（最近玩过在前）
    //    已完成：lastCompletedAt 倒序，null 降级 lastSavedAt（历史数据）
    //    收藏：favoritedAt 倒序
  }
}
```

- 性能（规模护栏，实测见 §三-4）：目录反查走 `UnifiedCatalogIndex` O(1)；进度加载走 `loadAllProgress()` 单次遍历（2000 条 ≈ 15~50ms）；装配循环 O(玩过数+收藏数)，与目录总量解耦；结果**缓存**在页面 State，仅触发点（§五-4）时重建；**禁止**在列表装配路径触碰 SnapshotStore 大文件。
- 孤儿卡：`isOrphan == true` 的卡片置灰显示"源已失效"，提供"清除记录"按钮（调 `ProgressStore` 删 key + SnapshotStore.deleteAllFor + FavoriteStore 移除）。

### 3. 收藏入口联动

- `ChooseDifficultySheet`：右上角加心形 `IconButton`，状态读 `FavoriteStore.isFavorite(canonicalId)`，点击 toggle 并让 sheet 内本地 setState + `idsNotifier` 驱动全局刷新；
- `GamePage` AppBar：同上（GamePage 需拿到 canonicalId——main/daily/ugc 路径已传 customId/dailyDateStr，pack/event 路径核对 GamePage 构造参数，缺则补传）；
- 收藏成功写 `titleSnapshot/imageSnapshot`（从当前页面已持有的标题与图源直接取，零额外 IO）。

### 4. 刷新触发点（原计划完全遗漏）

| 触发点 | 机制 |
| :--- | :--- |
| GamePage pop 返回 | "我的"页面 `await push` 之后 `setState`（照抄 `my_puzzles_tab_view.dart:142-145` 现有模式） |
| 收藏 toggle | `FavoriteStore.idsNotifier` → 页面顶层 `ValueListenableBuilder` |
| 扩展包增删 | `AppContent.instance.packs.packsNotifier`（已有） |
| 自制关卡增删 | `GameRepository.customPuzzlesNotifier`（已有） |
| Tab 切入"我的" | IndexedStack 常驻，在 `MainScreen.onTap` 切到我的 Tab 时触发一次轻量 rebuild |

---

## 六、UI 表现层（Presentation）

### 1. `main_screen.dart` 改造（方案 A'，改动最小）

- `_GameBottomNav.items`（:202-207）追加第 5 项：`_NavItemData(icon: PhosphorIconsFill.user, label: '我的')`，其余 4 项不动；
- `_appBarTitle` switch（:26-39）加 `case 4: return '我的拼图'`；
- 设置齿轮的 `if (_currentIndex == 3)`（:74）改为 `if (_currentIndex == 4)`（跟随"我的"Tab）；
- IndexedStack children（:81-94）追加 `const MyCenterTabView()`；
- 4 个既有 Tab 视图文件零改动。

### 2. 新建 `lib/pages/tabs/my_center_tab_view.dart`（"我的"Tab）

> 自制 Tab（`my_puzzles_tab_view.dart`）保持原样，本文件为全新独立页面。

- 顶层 `DefaultTabController` + `TabBar`（下划线式，对齐截图 3）：`进行中(N) | 收藏(N) | 已完成(N)`；
- 每个子 Tab = `CustomScrollView` + 空状态占位（沿用现有 🦊 空态风格，`my_puzzles_tab_view.dart:394-413`）：
  - 进行中空："暂无进行中的拼图，去挑一张开始吧！" + 按钮"去图库挑挑看"（切回 Tab 0）
  - 收藏空："还没有收藏，在难度选择面板或游戏中点击 ❤️ 收藏"
  - 已完成空："还没有通关记录，完成第一张拼图吧！"
- `_MyPuzzleGridCard`（新私有组件）：视觉骨架复用 `_buildCustomGridCard` 的成熟样式（渐变遮罩/角标/进度条，:442-622），叠加：
  - 左上：来源徽标（主线/每日/活动/扩展包/自制，颜色区分，沿用 :474-507 样式）；
  - 右上：进行中→`xx%`；已完成→`★★★` + 最佳用时；收藏页→实心红心（点击取消收藏）；
  - 孤儿卡：整体 `Opacity 0.45` + "已失效"角标；
- 卡片点击行为：
  - 进行中：`ResumeHelper.tryHandleResumeFlow(...)`（现有 API，`resume_helper.dart:188`）；
  - 已完成/收藏：`ChooseDifficultySheet.show(...)`（照抄 `daily_tab_view.dart:78-131` 调用模式，按来源分支组装 imageBytes——daily 走 asset、ugc 走本地文件、pack 走包内路径）。

### 3. `daily_tab_view.dart` 月份折叠

见 §五-1，另加截图 1 的视觉细节（可选润色）：
- 月份 header 右侧箭头（`PhosphorIconsBold.caretUp/Down`）；
- 日期圆形角标（:502-522）可升级为"撕历便签"样式（顶部色条 + 方形白底 + 加粗日期），纯绘制改动，不动数据。

---

## 七、实施步骤

| Phase | 内容 | 涉及文件 | 验证 |
| :--- | :--- | :--- | :--- |
| 1 | 数据层：FavoriteStore + ProgressStore 扩展（lastCompletedAt / lastPlayedAt 别名 / loadAllProgress）+ UnifiedCatalogIndex + UnifiedPuzzleResolver | `lib/data/favorite_store.dart`*、`lib/data/progress_store.dart`、`lib/logic/catalog_index.dart`*、`lib/logic/unified_puzzle_resolver.dart`*、`lib/main.dart`(init) | 单元测试：索引五来源合成 + 五前缀路由 + 孤儿分支 + daily 双格式互转 + lastCompletedAt 写入/回读 |
| 2 | 每日月份折叠 | `lib/pages/tabs/daily_tab_view.dart` | flutter analyze + 手测折叠/默认展开 |
| 3 | MainScreen 5-Tab 追加"我的" + MyCenterTabView（子 Tab/空态/卡片/点击行为）+ 收藏触点（ChooseDifficultySheet / GamePage） | `main_screen.dart`、`lib/pages/tabs/my_center_tab_view.dart`*、`choose_difficulty_sheet.dart`、`game_page.dart` | flutter analyze + Widget 测试（空态/子 Tab 切换/规则乙谓词） |
| 4 | 测试与登记 | `test/`、`docs/CHANGES-YYYYMMDD.md`（真实时间戳） | `flutter analyze` 零告警 + `flutter test`（按范围过滤优先） |

`*` = 新建文件。每个 Phase 独立可编译、可提交（征得同意后）。改动后按 AGENTS.md 对改动文件运行 `dart format`（禁止全仓格式化）。

## 八、风险与回退

- **风险 1**：GamePage 的 pack/event 路径 canonicalId 透传缺失 → 收藏按钮拿不到 ID。缓解：Phase 3 首项先核对 `game_page.dart` 构造参数（:344-426 已确认有 generic 分支），缺则加可选参数。
- **风险 2**：历史进度无 lastCompletedAt → 已完成排序退化。缓解：降级 lastSavedAt，文案不改，用户无感；该字段走 extra 通道，旧版本 App 读新数据也不丢（fromJson extra 保留）。
- **风险 3**：规则乙下同一张卡出现在两个子 Tab，用户可能困惑"为什么已完成里还有进度条"。缓解：进行中子 Tab 的已完成卡不显示进度条、改显示"再次挑战"角标；或直接切规则甲（改一处谓词）。
