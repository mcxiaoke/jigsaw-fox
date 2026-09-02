# 「我的」Tab、每日月份折叠与数据模型全景字段补齐实施计划

本项目正处于开发期，本次实施将：
1. 建立「我的」Tab（5 Tab 布局，作为最后一项），自制 Tab 保持独立不动；
2. 每日挑战 Tab 支持月份折叠（默认展开当前月，支持偏好持久化）；
3. 全面补齐 `LevelProgress`、`DifficultyRecord`、`FavoriteStore`、`UnifiedCatalogIndex`、`UnifiedPuzzleResolver` 的各项核心字段与性能缓存，杜绝发布后历史数据断代；
4. 严格限制修改范围，不破坏原有正常功能。

## Proposed Changes

### 数据层 (Data Layer)

#### [MODIFY] [lib/data/progress_store.dart](file:///C:/Home/Projects/jigsawpuzzle/lib/data/progress_store.dart)
- `DifficultyRecord`:
  - 增加字段：`firstCompletedAt`, `lastCompletedAt`, `lastPlayedAt`, `minMoves`；
  - 增加 getter：`isPerfect` (`bestStars >= 3 && minHintsUsed == 0`)；
  - 更新 `toJson`、`fromJson`、`copyWith`。
- `LevelProgress`:
  - 增加字段：`firstCompletedAt`, `lastCompletedAt`, `firstPlayedAt`；
  - 增加 getter：`lastPlayedAt` (返回 `lastSavedAt`)、`totalPlayCount`、`completedDifficultyCount`、`bestDifficultyKey`、`allDifficultyStars`；
  - 更新 `toJson`、`fromJson`、`copyWith`。
- `ProgressStore`:
  - 扩展 `recordDifficultyCompletion`: 写入单难度与整图的 `firstCompletedAt`、`lastCompletedAt`、`firstPlayedAt`、`lastPlayedAt`；
  - 扩展 `updateProgress`: 写入整图首玩时间 `firstPlayedAt` 与通关时间 `lastCompletedAt`；
  - 新增 `loadAllProgress()`: 单次遍历 prefs keys + jsonDecode，批量加载全部进度；
  - 扩展 `refreshAggregatesCache()`: 顺手计算并缓存 `cachedTotalSolved` 与 `cachedTotalStars`，消除 N+1 读 prefs 瓶颈。

#### [NEW] [lib/data/favorite_store.dart](file:///C:/Home/Projects/jigsawpuzzle/lib/data/favorite_store.dart)
- 定义 `FavoriteEntry`: canonicalId, favoritedAt, titleSnapshot, imageSnapshot, sourceLabelSnapshot, isLocalFileSnapshot, aspectRatioLabel, author, tags, preferredDifficultyKey, extra；
- 定义 `FavoriteStore`: 单例模式，SharedPreferences 持久化（key: `jigsaw_favorites_v1`）；
- 提供 `favoriteIds` (Set<String>) 同步缓存、`idsNotifier` (ValueNotifier) 响应式通知、`toggleFavorite`、`isFavorite`、`favoritesSortedByTime`、`pruneOrphans`。

#### [MODIFY] [lib/main.dart](file:///C:/Home/Projects/jigsawpuzzle/lib/main.dart)
- 启动时初始化 `FavoriteStore.instance.init()`。

---

### 逻辑与解析层 (Logic & Resolver Layer)

#### [NEW] [lib/logic/catalog_index.dart](file:///C:/Home/Projects/jigsawpuzzle/lib/logic/catalog_index.dart)
- 定义 `CatalogEntry`: canonicalId, title, imagePathOrUrl, isLocalFile, sourceLabel, sourceModule, aspectRatio, author, tags, addedAt, recommendedDifficulty, contextId；
- 定义 `UnifiedCatalogIndex`: 静态 `build()` 扫描 main/daily/ugc/packs/events 统一构建只读索引 Map；支持 `invalidate()` 惰性重建。

#### [NEW] [lib/logic/unified_puzzle_resolver.dart](file:///C:/Home/Projects/jigsawpuzzle/lib/logic/unified_puzzle_resolver.dart)
- 定义 `UnifiedPuzzleCardData`: 卡片视图模型，涵盖 20+ 精准核定字段；
- 定义 `UnifiedPuzzleResolver`: 输入 canonicalId + LevelProgress + CatalogIndex，同步装配卡片数据；支持孤儿卡兜底。

---

### 每日拼图月份折叠 (Daily Tab)

#### [MODIFY] [lib/pages/tabs/daily_tab_view.dart](file:///C:/Home/Projects/jigsawpuzzle/lib/pages/tabs/daily_tab_view.dart)
- `_DailyTabViewState` 增加 `_expandedMonthKeys` (Set<String>)；
- 首次进入默认展开当前月（`DateTime.now()` 对应的 `yyyy-MM`），其余收起；
- 持久化折叠偏好至 SharedPreferences（`jigsaw_daily_fold_v1`）；
- 月份 Header 点击展开/折叠，添加箭头旋转动画；
- 折叠时跳过 SliverGrid 渲染。

---

### UI 表现层 (Presentation Layer)

#### [MODIFY] [lib/main_screen.dart](file:///C:/Home/Projects/jigsawpuzzle/lib/main_screen.dart)
- 底部导航项由 4 项追加第 5 项：`_NavItemData(icon: PhosphorIconsFill.user, label: '我的')`；
- `_appBarTitle` switch 增加 `case 4: return '我的拼图'`；
- 设置齿轮入口跟随移至 index 4；
- `IndexedStack` 追加 `const MyCenterTabView()`。

#### [NEW] [lib/pages/tabs/my_center_tab_view.dart](file:///C:/Home/Projects/jigsawpuzzle/lib/pages/tabs/my_center_tab_view.dart)
- 独立新建“我的”Tab，包含 3 个子 Tab：`进行中(N) | 收藏(N) | 已完成(N)`；
- 装配逻辑与规则乙：
  - 进行中：`hasSnapshot == true || progressPercent > 0`，按 `lastPlayedAt` 倒序；
  - 已完成：`isCompleted == true`，按 `lastCompletedAt` 倒序；
  - 收藏：`FavoriteStore.favoritesSortedByTime()` 倒序；
- 网格卡片渲染：来源彩色徽标、角标（进行中显示进度条/再次挑战，已完成显示星级与用时，收藏显示红心）、孤儿卡置灰“已失效”并支持清理；
- 点击交互：进行中调 `ResumeHelper.tryHandleResumeFlow` 续玩；已完成/收藏调 `ChooseDifficultySheet.show`。

#### [MODIFY] [lib/widgets/choose_difficulty_sheet.dart](file:///C:/Home/Projects/jigsawpuzzle/lib/widgets/choose_difficulty_sheet.dart)
- 增加 `canonicalId` 参数；右上角增加心形收藏按钮，联动 `FavoriteStore`。

#### [MODIFY] [lib/pages/game_page.dart](file:///C:/Home/Projects/jigsawpuzzle/lib/pages/game_page.dart)
- AppBar 右侧增加心形收藏按钮，联动 `FavoriteStore`。

---

## Verification Plan

### Automated Tests
- 运行 `flutter test` 执行相关测试用例；
- 针对新增字段、序列化、缓存与解析器编写单元测试：
  - `test/data/progress_store_extension_test.dart`
  - `test/data/favorite_store_test.dart`
  - `test/logic/unified_puzzle_resolver_test.dart`

### Code Quality & Compilation
- 运行 `dart format` 对有改动的文件进行格式化；
- 运行 `flutter analyze` 确保 0 error, 0 warning；
- 运行 `flutter build windows --debug` 验证完整工程编译无误。
