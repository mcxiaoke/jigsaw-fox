# 文档与代码不一致跟踪表 (DOC-CODE-DRIFT)

> **生成时间**: 2026-09-04 11:25 GMT+8
> **核对范围**: `docs/CHANGES-20260901.md` ~ `CHANGES-20260904.md` 记录的代码改动 ↔ `docs/` 中的原架构文档与细分领域文档
> **方法**: 7 个领域并行核对（文档 vs `lib/`/`scripts/` 实际代码），并对 3 个最高危结论独立复验
> **状态图例**: ✅ 一致无需改 / 🔴 High / 🟠 Medium / 🟢 Low / ⏳ 待更新

---

## 一、汇总

| 文档 | 领域 | 严重度 | 状态 |
|---|---|---|---|
| `data-architecture-current.md` | 数据架构(原架构) | 🔴 High | ⏳ 待归档/重命名 |
| `dart-manifest-pure-route-migration.md` | Manifest/路由 | 🔴 High | ⏳ 待标注未实施 |
| `unified-export-and-manifest-restructure-design.md` | 导出/Manifest | 🔴 High | ⏳ 待补兼容缺口 |
| `online-image-picker-and-source-tracking-design.md` | 在线搜图/WebView2 | 🔴 High | ⏳ 待重写选型 |
| `board-tray-touch-conflict-solution-20260903.md` | 棋盘/托盘 | 🔴 High | ⏳ 待标注未实现 |
| `jigsaw-honor-title-system-design.md` | 荣誉称号 | 🔴 High | ⏳ 待标注未实现 |
| `jigsaw-achievements-data.md` | 成就数据 | 🔴 High | ⏳ 待重排对齐 |
| `jigsaw-difficulty-scoring-achievements-design.md` | 成就/难度 | 🔴+🟠 | ⏳ 待更新 |
| `home-navigation-sorting-implementation-plan-20260902.md` | 首页/排序 | 🔴 High | ⏳ 待标注取代 |
| `image-loading-and-caching-audit-20260902.md` | 图片缓存审计 | 🔴/🟠 | ⏳ 待重写为修复后 |
| `network-level-lazy-download-plan-20260902.md` | 网络懒加载 | 🟠 Medium | ⏳ 待更新状态 |
| `puzzle-my-tab-and-daily-fold-plan-v2.md` | 我的Tab | 🟠 Medium | ⏳ 待更新类结构 |
| `viewport-containment-and-smooth-zoom-design-20260903.md` | 视口/缩放 | 🟠 Medium | ⏳ 待同步常量 |
| `tabletop-drag-containment-and-zoom-pan-fix-plan-20260903.md` | 拖拽/托盘 | 🟠 Medium | ⏳ 待同步 safeMinY |
| `puzzle-content-storage-and-expansion-design.md` | 内容存储 | 🟢 Low | ⏳ 待补字段 |
| `aspect-ratio-expansion-and-grid-design-20260903.md` | 画幅/网格 | 🟢 Low | ⏳ 待补片段 |

**附带实现风险（文档需同步澄清，非纯文档问题）**:
1. 🔴 **Manifest 纯路由只改了打包脚本，Dart 客户端未迁移** → 发布新 `manifest.json` 后每日模块静默失效。
2. 🔴 **棋盘/托盘触摸冲突修复方案从未落地** → `game_page.dart` 仍带原缺陷。

---

## 二、原架构文档

### `docs/data-architecture-current.md` — 🔴 严重过时，建议归档
描述为 Hive 迁移前的 SharedPreferences + JSON 架构，且引用已删除文件/类。

| 文档声称 | 代码现实（证据） | 建议更新 |
|---|---|---|
| 持久化层 = `SharedPreferences`，列业务 key `jigsaw_level_{N}` / `jigsaw_daily_{...}` / `jigsaw_custom_list` | 业务 key 全仓 0 命中；数据已迁 Hive（`game-progress-v1`/`game-collections-v1`/`app-state-v1`，`storage_manager.dart:14-16`，存 JSON String，无 TypeAdapter） | 重命名为 `data-architecture-legacy-pre-hive.md` 移入 `docs/archived/`，以 `hive-migration-design.md`(v4.7) 为权威源 |
| §2/§5 引用 `daily_challenge.dart`、`bing_daily_data.dart`、`DailyChallengeItem` | 三者 `lib/` 中已不存在（已切 `DailyContentPipeline`），grep 全零命中 | 删除旧引用 |
| 快照嵌在 `savedSnapshotJson` 字段 | 现为文件级 `SnapshotStore`（`game_repository.dart:421,622` 恒置 null，死字段） | 改为描述 `SnapshotStore` |
| `PuzzleBoardState.version` 固定为 2 | `puzzle_state.dart:141-142` 为 `currentVersion=3`；新增 `canonicalId/difficultyKey/aspectLabel/createdAt/updatedAt/extra` | 同步版本与字段 |

---

## 三、细分领域文档

### 存储 / Hive / 数据
- `hive-migration-design.md` 及两份审计文档 — ✅ 抽检与代码一致，无需改（INFO/LOW 项属实但非阻塞）。
- `data-architecture-current.md` — 见上。

### Manifest / 内容 / 导出 / 路由
| 文档 | 严重度 | 不一致点 | 证据 | 建议更新 |
|---|---|---|---|---|
| `dart-manifest-pure-route-migration.md` | 🔴 | 标题与 CHANGES 易读成「已完成」，实际 Dart 侧 6 文件迁移全「待改」 | `root_manifest.dart:84-99` 仍 `currentMonth/zipUrlPattern/listUrlPattern`；`content_manager.dart:108-114,168-171` 仍读旧字段；`daily_tab_view.dart:121` 仍读 `dailyModule.currentMonth` | 明确标注「未实施 + 发布新 manifest 将令每日模块失效」 |
| `unified-export-and-manifest-restructure-design.md` | 🔴 | §2.4 Dart 侧延后、§8 承诺过渡双写新旧 daily 字段，但脚本只写 `url/version`，旧客户端无兼容过渡；`schemaVersion` 该文档写 1、`puzzle-content-storage` 写 3 | `server.py:1159-1185` 仅写 `url/version`；`server.py:955-962` 已产出纯路由 | 补「旧客户端兼容缺口」说明 + 统一 `schemaVersion` 目标 |
| `puzzle-content-storage-and-expansion-design.md` | 🟢 | §9 模型缺 `addedAt/unlockCoins/unlockCode` 与 `isUpcoming/isZipType/isArrayType` getter | `puzzle_level_item.dart:60-64,155-174` 已有这些字段 | 轻量补字段 |

### 图片加载 / 缓存 / 缩略图
| 文档 | 严重度 | 不一致点 | 证据 | 建议更新 |
|---|---|---|---|---|
| `image-loading-and-caching-audit-20260902.md` | 🔴/🟠 | 正文停在修复前：顶部标 ✅ 已修复，但 §7.4/§7.6/§7.7/§7.8/§5.2 仍以未修复口吻详述并引旧行号，与代码相反 | `events_tab_view.dart:138` 已用 `AppCachedImage` 走磁盘缓存；`image_cache_manager.dart:325-339` 已遍历全档位删除；`:161` 掩码已改 `0x7FFFFFFFFFFFFFFF`；`settings_page.dart:58,68` 已调用 | 重写为「修复后」版本，更新所有行号与结论 |
| `network-level-lazy-download-plan-20260902.md` | 🟠 | 状态标「Draft→待实施 / `LevelImageResolver`/`LazyLevelImage` 未实施」，实际已实现并接线 | `level_image_resolver.dart`/`lazy_level_image.dart` 已存在并接线 | 更新状态为「已实施」 |

### 首页 / 每日 / 我的 Tab
| 文档 | 严重度 | 不一致点 | 证据 | 建议更新 |
|---|---|---|---|---|
| `home-navigation-sorting-implementation-plan-20260902.md` | 🔴 | 方案未落地，且与代码遵循的 `hometab-reference-implementation-20260902.md` 矛盾：`LevelFilter`/`LevelStatusFilter`/`LevelSortOrder` 枚举、Smart Hero Zone、三维排序、`lastPlayedAt` 均不存在 | grep `LevelFilter\|LevelStatusFilter\|LevelSortOrder\|updateLastPlayedAt` 全零命中；首页仅单 Tag 过滤（`home_tab_view.dart:80-87`） | 标注「未实施 / 被 hometab-reference 取代」 |
| `puzzle-my-tab-and-daily-fold-plan-v2.md` | 🟠 | §五 设计 `MyPuzzlesController`/`MyPuzzlesLists` 类未采用（列表内联于 `_MyCenterTabViewState`） | `my_center_tab_view.dart:40-42,755` | 补类或更新类结构描述 |

### 成就 / 荣誉称号 / 难度评分
| 文档 | 严重度 | 不一致点 | 证据 | 建议更新 |
|---|---|---|---|---|
| `jigsaw-honor-title-system-design.md` | 🔴 | §8.4 要求 `lib/logic/honor_title.dart`、`lib/services/honor_title_service.dart`、`lib/pages/honor_titles_page.dart` 及 `HonorTitleService` 类全部不存在 | grep `HonorTitle` 在 `lib/` 零命中 | 标注「整系统未实现」 |
| `jigsaw-achievements-data.md` + `jigsaw-difficulty-scoring-achievements-design.md` §8.2 | 🔴 | 25 项成就 ID/阈值/奖励与代码 SSOT 不符（如 `complete_*`→`win_*`；`three_star_*`/`stars_100`→`star_*`；`snap_200/1000`→`snap_100/500/2000`；`master_all` 奖励 500 vs 1000；`time_2h` 100 vs 120） | `lib/services/achievement_service.dart:50-293` | 执行文档 §六「重排」使与代码对齐 |
| `jigsaw-difficulty-scoring-achievements-design.md` 正文 §2.1/§3 | 🟠 | 写「比例收敛为 1:1+2:3、删除 3:4/4:3、仅 L1~L6」，代码含 5 种比例 + 新增 L7 | `puzzle_model.dart:44-51`(5 比例)、`:142-143`(L7) | 同步正文 §2.1/§3 与页眉 v3.4 扩展 |

### 棋盘几何 / 托盘 / 视口 / 裁切 / 读档
| 文档 | 严重度 | 不一致点 | 证据 | 建议更新 |
|---|---|---|---|---|
| `board-tray-touch-conflict-solution-20260903.md` | 🔴 | 三道防线（`isScrollingTray`/`_trayGestureBuffer`/`_SingleTouchIntent`）完全未实现，代码仍带原缺陷 | `game_page.dart` 无上述符号；`_onPointerDown:721`/`_onPointerMove:747` 仍是逐帧 `dy < trayPosition.y` 判定 | 标注「方案未落地，缺陷仍在」 |
| `viewport-containment-and-smooth-zoom-design-20260903.md` | 🟠 | §3.2/§5.1 仍硬编码 `normMinX = isTabletop ? -0.35 : 0.0`，代码已动态反推 | `jigsaw_puzzle_game.dart:1248-1259` | 更新代码片段为动态推导版 |
| `tabletop-drag-containment-and-zoom-pan-fix-plan-20260903.md` | 🟠 | §3.1A/§4.1 写 `safeMinY=44.0`，代码已改 8.0；且同文件 `_syncResizeTransform` 的 `safeMinY` 仍为 44.0（resize 路径内部不一致） | `jigsaw_puzzle_game.dart:1050,1672`(`_topToolbarHeight=8.0`)、`:448`(仍 44.0) | 同步 `safeMinY=8.0` 并注明 resize 路径未改 |
| `aspect-ratio-expansion-and-grid-design-20260903.md` | 🟢 | §3.1 构造函数片段缺 `required this.multipliers`（已内化为实例字段） | `jigsaw_puzzle_game.dart:53-59` | 补全构造函数片段（网格阶数表与代码一致，无需改逻辑） |

### 在线搜图 / WebView2 / 来源追踪
| 文档 | 严重度 | 不一致点 | 证据 | 建议更新 |
|---|---|---|---|---|
| `online-image-picker-and-source-tracking-design.md` | 🔴 | §1.2/§3.1/§6 写 `webview_flutter ^4.10` + `desktop_webview_window ^0.2.3`；文档称桌面「独立大窗口」；完全缺失 `WebViewService`/WebView2 探测/GameToast 拦截；来源平台写 Unsplash/Pixabay/Pexels；下载拦截 API 用 webview_flutter | `pubspec.yaml:54` 仅 `flutter_inappwebview ^6.1.5`（前两者已删）；`online_image_picker_page.dart:7` 改 inappwebview、`:567` 单 `InAppWebView`、`webview_service.dart:21,55-57` 设 `WebViewEnvironment`；`my_puzzles_tab_view.dart:323-330`/`online_image_picker_page.dart:42-49` GameToast 拦截；来源统一 `'网络'`(`online_image_picker_page.dart:377`) | 改写 §1.2/§3.1/§6 为 `flutter_inappwebview ^6.1.5` + 单 `InAppWebView`；新增「WebView2 运行防护」小节；§4 来源改「相册/网络」中性命名 |

---

## 四、优先处理顺序
1. **立即（防误发布）**: `data-architecture-current.md` 归档；`dart-manifest-pure-route-migration.md` + `unified-export-and-manifest-restructure-design.md` 标注「Dart 客户端未迁移 + 发布兼容缺口」。
2. **高**: `board-tray-touch-conflict-solution`、`online-image-picker-and-source-tracking-design`、`jigsaw-honor-title-system-design` 标「未实现/需补章节」。
3. **中**: `home-navigation-sorting-implementation-plan` 标「被 reference 取代」；`image-loading-and-caching-audit` 重写为修复后版；`viewport`/`tabletop` 两篇同步代码常量。
4. **低**: `puzzle-content-storage`、成就数据表重排、`aspect-ratio` 构造函数片段补丁。
