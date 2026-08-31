# 全面代码审查核验报告（dsf 复核，2026-08-31）

> **核验基准**：对 `docs/code-review-20260831-full.md` 全部 P0/P1/P2 条目逐条对照当前代码库（`lib/`、`test/`、`pubspec.yaml`、`analysis_options.yaml`）进行静态核对。
> **核验方式**：逐文件读取关键行号 + 全库交叉检索（依赖 import 计数、bestTime 展示链路、`writeAsString`/`ZipDecoder`/`listSync`/`unawaited` 等模式）。非运行时 profiling，复杂度结论为静态推导。
> **重要环境更新**：本机实测 `flutter analyze` **17.6s 完成、0 issues**；`flutter test` **165/165 全部通过**（17s）。原报告 §8.3「analyze/test 超 50 分钟无结果」已不成立，说明工程健康度好于原报告暗示。

---

## 0. 一句话结论

原报告 44 条问题中，**约 30 条真实且值得修复，约 8 条部分属实（表述过重或影响被夸大），约 4 条属主观偏好或已不成立**。最该优先处理的是 4 件事：P1-1（`hintFor` 比较器内重建整盘拓扑）、P0-3（退出保存不落盘）、P0-4（每日挑战跨月失效）、P0-1（内网 IP 默认源）。P0-2 需降级并纠正表述——真实缺陷是「顶层 `bestTimeSeconds` 被裸写覆盖」，但**当前没有任何页面展示该字段**，并非"用户可见数据损坏"。

---

## 1. 先摆三个关键新事实（原报告没写到）

### 1.1 `flutter analyze` = 0 issues，`flutter test` = 165 通过
- 原报告 §8.3 断言「analyze 56 分钟 / test 43 分钟无输出、未取得量化数字」。本次实测：
  - `flutter analyze` → **No issues found! (17.6s)**
  - `flutter test` → **All tests passed! (165 tests, 17s)**
- 含义：① 代码当前**编译与静态检查完全干净**；② 原报告大量基于「analyze 没跑完所以无法确认」的保留结论，现在有确定答案。

### 1.2 `app_logger.dart` 自定义 `unawaited` 遮蔽**没有**造成编译/analyze 错误
- [app_logger.dart](file:///c:/Home/Projects/jigsawpuzzle/lib/services/app_logger.dart#L453-L454) 确实定义了顶层 `void unawaited(Future<void> f) {}`（no-op）。
- 但既然 analyze = 0 issues，说明它**未触发 ambiguous import**，也没有任何调用点解析到错误的版本（使用 `unawaited` 的 [image_cache_manager.dart](file:///c:/Home/Projects/jigsawpuzzle/lib/logic/cache/image_cache_manager.dart#L238) 同时 import `dart:async` 与 `app_logger.dart`，均无报错）。
- 结论：这是**代码气味**（no-op 会让 `unawaited_futures` 类 lint 对 app_logger 自身失效，且未来若启用该 lint 会有风险），但**不是功能 bug、不阻塞构建**。原报告 §8.2「需等 analyze 确认」已解决：无错误。仍建议删除，改用官方 `unawaited`。

### 1.3 P0-2 的「最佳成绩被覆盖」是潜伏缺陷，不是用户可见损坏
- 全库检索 `lib/pages/` 中**没有任何地方展示 pack/event 的 `bestTimeSeconds`**（无「最佳/最快」字样，`maxStars`/`bestStars` 仅存在于数据层）。排行榜/成就走的是 `ProgressStore` 的嵌套 `records[difficultyKey]`（该字段在 [recordDifficultyCompletion](file:///c:/Home/Projects/jigsawpuzzle/lib/data/progress_store.dart#L240-L256) 与 [updateProgress](file:///c:/Home/Projects/jigsawpuzzle/lib/data/progress_store.dart#L314-L317) 中均有 min/max 保护），**不受覆盖影响**。
- 所以「重玩一次慢的，最佳成绩就变差」当前**不可见**，但顶层字段一旦被写坏也无法自愈（下次 `recordDifficultyCompletion` 的 `min` 对着已写坏的值取 min）。属于数据一致性潜伏缺陷，**不是发布阻塞**。

---

## 2. P0 逐条核验

| # | 原结论 | 复核结论 | 证据与说明 |
|---|---|---|---|
| P0-1 内网 IP | ❌ 未修 | ✅ **真实，需修** | [app_content.dart](file:///c:/Home/Projects/jigsawpuzzle/lib/logic/content/app_content.dart#L32-L34) `defaultBootstrapUrls` 唯一条目为 `http://192.168.1.118/...`；[import_pack_page.dart](file:///c:/Home/Projects/jigsawpuzzle/lib/pages/import_pack_page.dart#L28-L29) 两个样本 URL 同 IP；[content_http_client.dart](file:///c:/Home/Projects/jigsawpuzzle/lib/logic/content/network/content_http_client.dart#L56-L113) 无重试/无 `CancelToken`。外网启动必等 8s 超时。建议 `--dart-define` 注入 + HTTPS，样本 URL 仅 `kDebugMode`。 |
| P0-2 结算竞态 | ❌ 未修 | ⚠️ **部分属实，建议降 P1** | ① `game_page.dart` 四个 `_repo.updateXxxProgress`（[439](file:///c:/Home/Projects/jigsawpuzzle/lib/pages/game_page.dart#L438-L476)/449/459/468）确实**未 await**——真实。② [game_repository.dart](file:///c:/Home/Projects/jigsawpuzzle/lib/data/game_repository.dart#L690-L692) `updateGenericProgress` 传裸 `timeSeconds` 覆盖顶层 `bestTimeSeconds`——真实。③ 但「step1 与 step2 并发」**不准确**：step1（[game_page.dart:428](file:///c:/Home/Projects/jigsawpuzzle/lib/pages/game_page.dart#L428)）是 `await` 完才进 step2，二者顺序执行。④ 「用户可见数据损坏」**夸大**：见 §1.3。建议：四个分支补 `await`、`updateGenericProgress` 的 bestTime 走 min、`updateProgress` 顶层字段改 max/min 语义。 |
| P0-3 退出保存 fire-and-forget | ❌ 未修 | ✅ **真实，需修（重点）** | [game_page.dart](file:///c:/Home/Projects/jigsawpuzzle/lib/pages/game_page.dart#L272-L275) `_flushSave()` 只调 `void _doSave()`；AppBar 返回 [921](file:///c:/Home/Projects/jigsawpuzzle/lib/pages/game_page.dart#L919-L923) 与 `PopScope` [1070](file:///c:/Home/Projects/jigsawpuzzle/lib/pages/game_page.dart#L1065-L1072) 均 pop 不等待；[dispose:888](file:///c:/Home/Projects/jigsawpuzzle/lib/pages/game_page.dart#L880-L890) `_flushSync()` 里 `if (_isSaving) return;`（[281](file:///c:/Home/Projects/jigsawpuzzle/lib/pages/game_page.dart#L278-L281)）在异步保存进行中**直接放弃**；`_flushSync` 内 `updateGenericProgress`（[296](file:///c:/Home/Projects/jigsawpuzzle/lib/pages/game_page.dart#L294-L302)）未 await。`saveSync` 同步写文件但 **ProgressStore 索引写入不保证完成** →「文件在、`hasSnapshot=false`」的孤儿快照确实可能发生。`didChangeAppLifecycleState`（[97-107](file:///c:/Home/Projects/jigsawpuzzle/lib/pages/game_page.dart#L96-L107)）切后台同样走 `_flushSync`，受影响。 |
| P0-4 每日挑战 | ❌ 未修 | ✅ **真实，需修** | [home_tab_view.dart:147](file:///c:/Home/Projects/jigsawpuzzle/lib/pages/tabs/home_tab_view.dart#L146-L147) `firstWhere((d) => d.dayNumber == now.day)` 只比「几号」；[bing_daily_data.dart:30-31](file:///c:/Home/Projects/jigsawpuzzle/lib/data/bing_daily_data.dart#L30-L37) 仅 2026-07/08；[daily_tab_view.dart:91](file:///c:/Home/Projects/jigsawpuzzle/lib/pages/tabs/daily_tab_view.dart#L87-L98) `_calculateStreak` 同样按月内 dayNumber 匹配。daily 主展示（[121](file:///c:/Home/Projects/jigsawpuzzle/lib/pages/tabs/daily_tab_view.dart#L117-L121)）按完整日期匹配但 9 月后只能回退到「最近一条 8-31」。9 月起整块每日数据错位，属真实发布阻塞（时效性功能）。 |
| P0-5 i18n 零落地 | ❌ 未修 | ✅ **真实，但属范围决策** | [main.dart:101-147](file:///c:/Home/Projects/jigsawpuzzle/lib/main.dart#L101-L147) `MaterialApp` 无 `localizationsDelegates`/`supportedLocales`，全库中文硬编码（含日志/存档文案）。**技术上属实**；是否「发布阻塞」取决于 en-US 是否本期必须交付。项目规则要求 zh-CN+en-US，建议至少先落地基础设施（`l10n.yaml`+ARB），存量分批迁移。 |

**P0 小结**：原报告把 P0-2 与 P0-5 定为「发布阻塞」偏重；真正需要本期修的 P0 是 **P0-3（保存）、P0-4（每日）**，P0-1 视发布环境而定（内网测试包可暂缓），P0-2 降为 P1，P0-5 作为产品决策单独排期。

---

## 3. P1 性能热点核验（7 项全属实，但严重度需区分）

| # | 原结论 | 复核结论 | 证据与量化 |
|---|---|---|---|
| P1-1 `hintFor` | 最严重 | ✅ **真实，最高 ROI** | [puzzle_engine.dart:474-476](file:///c:/Home/Projects/jigsawpuzzle/lib/logic/engine/puzzle_engine.dart#L464-L479) 比较器内 `new EdgeLayout(...)` 每次比较 2 个；[edge_layout.dart:104-142](file:///c:/Home/Projects/jigsawpuzzle/lib/logic/geometry/edge_layout.dart#L103-L142) 构造时生成 `(rows-1)×cols + rows×(cols-1)` 描述符、每个 4 次 RNG。400 片 ≈ 3,440 次比较 × 2 × 3,040 RNG ≈ **2000 万次 RNG**。修复 5 行：`JigsawPuzzleGame.edgeLayout` 已存在（[jigsaw_puzzle_game.dart:193](file:///c:/Home/Projects/jigsawpuzzle/lib/game/jigsaw_puzzle_game.dart#L193)、`hint()` 调用于 [1807](file:///c:/Home/Projects/jigsawpuzzle/lib/game/jigsaw_puzzle_game.dart#L1803-L1807)），传入即可。 |
| P1-2 `updatePieceVisibility` | O(n³) | ✅ **真实** | [jigsaw_puzzle_game.dart:1579-1601](file:///c:/Home/Projects/jigsawpuzzle/lib/game/jigsaw_puzzle_game.dart#L1578-L1613)：外层 O(n) × `pieceById` O(n)（[puzzle_state.dart:192-197](file:///c:/Home/Projects/jigsawpuzzle/lib/logic/models/puzzle_state.dart#L191-L197) 线性扫）+ 筛选时 `where().any()` 内再 `pieceById` O(n)。边缘筛选开启时单次千万级步进。调用点集中在 `organizeTray`([1663](file:///c:/Home/Projects/jigsawpuzzle/lib/game/jigsaw_puzzle_game.dart#L1634))/`cancelPieceDrag`([1460](file:///c:/Home/Projects/jigsawpuzzle/lib/game/jigsaw_puzzle_game.dart#L1425))/`handlePieceDragEnd`([1551](file:///c:/Home/Projects/jigsawpuzzle/lib/game/jigsaw_puzzle_game.dart#L1551))。修复：`_byId` 索引 + 预计算 cluster 集合。 |
| P1-3 `_mergeAllAdjacentClusters` | O(n²)~O(n³) | ✅ **真实** | [puzzle_engine.dart:363-414](file:///c:/Home/Projects/jigsawpuzzle/lib/logic/engine/puzzle_engine.dart#L362-L414)：`while(changed)` + 双 for，合并时 `where`×2 + `map` 全列表重建（[400-404](file:///c:/Home/Projects/jigsawpuzzle/lib/logic/engine/puzzle_engine.dart#L400-L404)）。级联合并退化 O(n³)。仅在大盘高密度合并且 `onBoardPieceIds` 放行时触发。 |
| P1-4 指针事件 | 高 | ✅ **真实** | [game_page.dart:806/810/819](file:///c:/Home/Projects/jigsawpuzzle/lib/pages/game_page.dart#L805-L820) 平移/缩放每事件 `setState` 整页；且 [game_page.dart:823-830](file:///c:/Home/Projects/jigsawpuzzle/lib/pages/game_page.dart#L823-L830) `_onPointerHover` 与 Flame [onMouseMove:908-914](file:///c:/Home/Projects/jigsawpuzzle/lib/game/jigsaw_puzzle_game.dart#L907-L914) **双份调用** `updateHoldingPiecePosition`（其内部 [975-976](file:///c:/Home/Projects/jigsawpuzzle/lib/game/jigsaw_puzzle_game.dart#L974-L978) 又是 O(n) `where`）。删一个 hover 即可，低成本。 |
| P1-5 音效 StackTrace | 中高 | ✅ **真实（低优先）** | [sound_service.dart:112](file:///c:/Home/Projects/jigsawpuzzle/lib/services/sound_service.dart#L111-L112) `_logCaller = true` + [168](file:///c:/Home/Projects/jigsawpuzzle/lib/services/sound_service.dart#L166-L168) INFO 级落盘 + [175-189](file:///c:/Home/Projects/jigsawpuzzle/lib/services/sound_service.dart#L174-L189) `StackTrace.current.toString().split('\n')`。注释自述「测试完可关」。snap 类 80ms 节流，属持续小开销。 |
| P1-6 `SnapshotStore.save` | 中高 | ✅ **真实（功能+性能双问题）** | [snapshot_store.dart:153-159](file:///c:/Home/Projects/jigsawpuzzle/lib/data/snapshot_store.dart#L152-L159) 每次保存后 `listDifficultyKeys` 全目录扫 + **删除同关其他难度快照**；[listDifficultyKeys:300-317](file:///c:/Home/Projects/jigsawpuzzle/lib/data/snapshot_store.dart#L299-L317) 全目录 `await for`。与「同关多难度并存」设计直接冲突（`resume_helper` 也只传 1 项 `[info.dkey]`）。要么明确砍掉多难度并存，要么把清理移出 `save()` 热路径。 |
| P1-7 每秒 timer | 中 | ✅ **真实（低优先）** | [game_page.dart:168-179](file:///c:/Home/Projects/jigsawpuzzle/lib/pages/game_page.dart#L168-L179) `Timer.periodic(1s)` 内整页 `setState`。建议改 `ValueListenableBuilder`。 |

---

## 4. P1 正确性缺陷核验（16 项）

| # | 复核结论 | 证据与说明 |
|---|---|---|
| P1-8 `totalCompletedLevels +1` | ⚠️ **部分属实** | 四处无条件 +1（[game_repository.dart:442-443](file:///c:/Home/Projects/jigsawpuzzle/lib/data/game_repository.dart#L442-L445)/541/635/691）真实。但 [achievements_dialog.dart:29](file:///c:/Home/Projects/jigsawpuzzle/lib/widgets/achievements_dialog.dart#L28-L32) 把它当「累计完成 N 局」——按该语义 +1 是**正确**的。真正的问题是**两套成就 UI 口径不一致**：[achievements_page.dart:70](file:///c:/Home/Projects/jigsawpuzzle/lib/pages/achievements_page.dart#L69-L70) 用 `getTotalSolved()`（按 canonicalId 去重），对话框用 `totalCompletedLevels`（按局数累加）。需明确口径并统一，而非简单判定为 bug。 |
| P1-9 `saveSync` 改写单例目录 | ✅ 真实（低影响） | [snapshot_store.dart:172-181](file:///c:/Home/Projects/jigsawpuzzle/lib/data/snapshot_store.dart#L172-L181) 未初始化时把 `_snapshotsDir` 永久指向 `%TEMP%`。正常启动链路 `GameRepository.init` 先 `SnapshotStore.init`，实际触发概率低；但若触发会把后续所有快照写进临时目录。改为局部变量即可。 |
| P1-10 缓存 Key 缺 quality | ✅ 真实（低） | [image_cache_manager.dart:90-101](file:///c:/Home/Projects/jigsawpuzzle/lib/logic/cache/image_cache_manager.dart#L89-L101) `getCacheKey` 只含 path+dimension，`quality` 不参与。当前调用方统一默认 80，实际未暴露。 |
| P1-11 失败返回原图 | ✅ 真实 | [image_cache_manager.dart:216](file:///c:/Home/Projects/jigsawpuzzle/lib/logic/cache/image_cache_manager.dart#L194-L217) 缩略图生成失败 `return File(sourcePath)` 原图。网格直接解码大图确有 OOM 风险（失败路径下）。建议返回 null/占位。 |
| P1-12 删共享图片文件 | ✅ 真实 | [game_repository.dart:287-302](file:///c:/Home/Projects/jigsawpuzzle/lib/data/game_repository.dart#L287-L302) `deleteCustomPuzzle` 直接物理删本地文件，无引用计数。同源自制多引用时删一损多。 |
| P1-13 ZIP 按 basename 平铺 | ✅ 真实 | [pack_content_pipeline.dart:195](file:///c:/Home/Projects/jigsawpuzzle/lib/logic/content/pipelines/pack_content_pipeline.dart#L182-L198) `File(p.join(targetDir.path, baseName))`，`a/1.jpg` 与 `b/1.jpg` 静默互覆。 |
| P1-14 下载全量缓冲 | ✅ 真实 | [content_http_client.dart:80-94](file:///c:/Home/Projects/jigsawpuzzle/lib/logic/content/network/content_http_client.dart#L79-L94) `ResponseType.bytes` 全量进内存再写盘，无流式、无大小上限、无 `CancelToken`。 |
| P1-15 `shouldUpscale` OR | ✅ 逻辑缺陷（影响夸大） | [image_upscaler.dart:20](file:///c:/Home/Projects/jigsawpuzzle/lib/logic/image_upscaler.dart#L11-L21) `shortSide<=750 \|\| longSide<=1000`。4000×750 会被判低清并 2× 放大到 8000×1500≈12MP≈48MB——**浪费但谈不上内存爆炸**。建议改 AND 或总像素阈值。 |
| P1-16 `dl_` id 无序号 | ✅ 真实（低概率） | [download_manager.dart:174](file:///c:/Home/Projects/jigsawpuzzle/lib/logic/download_manager.dart#L174-L176) `'dl_${millisecondsSinceEpoch}'` 同毫秒冲突。相邻 `local_` 分支已带序号，此处遗漏。 |
| P1-17 非原子 JSON 写 | ✅ 真实（低） | [events_content_pipeline.dart:263](file:///c:/Home/Projects/jigsawpuzzle/lib/logic/content/pipelines/events_content_pipeline.dart#L256-L263)、[main_content_pipeline.dart:220](file:///c:/Home/Projects/jigsawpuzzle/lib/logic/content/pipelines/main_content_pipeline.dart#L210-L220)、[manifest_router.dart:75](file:///c:/Home/Projects/jigsawpuzzle/lib/logic/content/pipelines/manifest_router.dart#L75)、[pack_content_pipeline.dart:263](file:///c:/Home/Projects/jigsawpuzzle/lib/logic/content/pipelines/pack_content_pipeline.dart#L263) 均直接 `writeAsString` 覆盖。这些是**缓存文件**（可重同步），风险低于报告暗示；但既然 `SnapshotStore` 已示范原子写，应复用。 |
| P1-18 `ZipDecoder` 主线程 | ✅ 真实 | [daily_content_pipeline.dart:50](file:///c:/Home/Projects/jigsawpuzzle/lib/logic/content/pipelines/daily_content_pipeline.dart#L49-L51)、[events_content_pipeline.dart:152](file:///c:/Home/Projects/jigsawpuzzle/lib/logic/content/pipelines/events_content_pipeline.dart#L151-L152)、[pack_content_pipeline.dart:134](file:///c:/Home/Projects/jigsawpuzzle/lib/logic/content/pipelines/pack_content_pipeline.dart#L133-L134) 同步 `decodeBytes`。大包解压卡 UI。 |
| P1-19 `_applyBoardState` 静默丢弃 | ✅ 真实（已缓解） | [jigsaw_puzzle_game.dart:1761-1768](file:///c:/Home/Projects/jigsawpuzzle/lib/game/jigsaw_puzzle_game.dart#L1761-L1768) 尺寸不匹配仅 warning+return，无 UI 反馈。上游 [game_page.dart:186-209](file:///c:/Home/Projects/jigsawpuzzle/lib/pages/game_page.dart#L185-L209) 已用快照 rows/cols 优先构造 effectiveDiff 缓解，但引擎侧仍无回调通道。 |
| P1-20 `%5` 伪分类 | ✅ 真实（低） | [home_tab_view.dart:71-76](file:///c:/Home/Projects/jigsawpuzzle/lib/pages/tabs/home_tab_view.dart#L69-L77) `bird`（`%5==2`）严格是 `landscape`（`%5==2 \|\| %5==0`）子集，分类自相矛盾。装饰性逻辑，替换为真实 tag 或删。 |
| P1-21 FNV `&0xFFFFFFFFFFFFFFFF` | ✅ 模式真实（Web 不可编译，低） | [snapshot_store.dart:75](file:///c:/Home/Projects/jigsawpuzzle/lib/data/snapshot_store.dart#L71-L78)、[image_cache_manager.dart:97](file:///c:/Home/Projects/jigsawpuzzle/lib/logic/cache/image_cache_manager.dart#L96-L100)。当前工程大量 `dart:io` 依赖，Web 根本无法编译（见 §6），此项纯属「未来被 Web 复用才踩坑」。可加注释或保留。 |
| P1-22 日志 `listSync` | ✅ 真实（低） | [app_logger.dart:276](file:///c:/Home/Projects/jigsawpuzzle/lib/services/app_logger.dart#L265-L283)/342-346/385-389 三处同步列目录；`_rotateIfNeeded` 每次 flush 都可能触发。 |
| P1-23 `_sink.close()` 未 await | ✅ 真实（微） | [app_logger.dart:292](file:///c:/Home/Projects/jigsawpuzzle/lib/services/app_logger.dart#L287-L294) 未 await，而 [316](file:///c:/Home/Projects/jigsawpuzzle/lib/services/app_logger.dart#L316) 是 await 的。旋转时可能丢缓冲。 |

---

## 5. P2 核验（大部分属实，两处量化需修正）

### 5.1 依赖死重 —— ✅ 全部属实（0 引用确认）
全库 import 检索（`lib/`+`test/`）：
- `flame_riverpod` / `flutter_riverpod` / `webview_flutter` / `desktop_webview_window` / `cupertino_icons` / `vector_math` / `flutter_launcher_icons` → **均 0 处 `package:` import**（[pubspec.yaml](file:///c:/Home/Projects/jigsawpuzzle/pubspec.yaml#L30-L55)）。
- 需先决策 Riverpod 用/删，其余直接删或挪 `dev_dependencies`。

### 5.2 复制粘贴债务 —— ✅ 属实
- 四份 `updateXxxProgress`（[game_repository.dart](file:///c:/Home/Projects/jigsawpuzzle/lib/data/game_repository.dart#L317-L446) 起）结构高度重复（~380 行），且已产生真实分歧（`updateGenericProgress` 漏 `min`，即 P0-2）。抽 `_persistProgress` 值得做。
- Migration 三段循环（[migration_service.dart:57-142](file:///c:/Home/Projects/jigsawpuzzle/lib/data/migration_service.dart#L47-L142)）逐行等价；`isTrivial` 三份；`secPerPiece/tierIndex/tierLevel` 三个同构 switch（[puzzle_model.dart:228-321](file:///c:/Home/Projects/jigsawpuzzle/lib/logic/puzzle_model.dart#L227-L321)）；FNV 两份。

### 5.3 分层与结构 —— 基本属实
- `resume_helper.dart` data 层 import material + `continue_dialog.dart` 并持有 `BuildContext` 弹窗：**属实**（[resume_helper.dart:1-9](file:///c:/Home/Projects/jigsawpuzzle/lib/data/resume_helper.dart#L1-L9)）。
- `main_screen.dart` 返回后 `setState` 整屏刷新（[63/92](file:///c:/Home/Projects/jigsawpuzzle/lib/pages/main_screen.dart#L61-L64)）：属实；`IndexedStack` 4 tab 启动全建（[202-215](file:///c:/Home/Projects/jigsawpuzzle/lib/pages/main_screen.dart#L202-L215)）：属实。
- `presets` 横竖歧义：**属实**（[puzzle_model.dart:342-361](file:///c:/Home/Projects/jigsawpuzzle/lib/logic/puzzle_model.dart#L342-L361) 中 24/54/96/150/216 各含 portrait+landscape 两项；`game_repository` 兜底 `firstWhere(pieceCount)` 歧义仍存）。
- **量化修正**：原报告称「`0xFF2E7D32` 在 `main_screen.dart` 一个文件约 20 次」——实测 **main_screen 仅 5 次**（[main_screen.dart](file:///c:/Home/Projects/jigsawpuzzle/lib/pages/main_screen.dart#L111) 等），但**全 lib 共 83 次/21 文件**。结论「硬编码色值遍布、与 main.dart:96 注释矛盾」成立，具体数字需修正。
- 注释/值不一致（0.48 vs 0.40）：**属实**（[puzzle_engine.dart:16-20](file:///c:/Home/Projects/jigsawpuzzle/lib/logic/engine/puzzle_engine.dart#L16-L20) 注释 48% 但 `defaultSnapRatio=0.40`；[jigsaw_puzzle_game.dart:1127](file:///c:/Home/Projects/jigsawpuzzle/lib/game/jigsaw_puzzle_game.dart#L1127) `// 0.48`）。

### 5.4 工程健壮性 —— 部分属实
- 无 `FlutterError.onError`/`PlatformDispatcher.onError`/`runZonedGuarded`：**属实**（[main.dart:22-76](file:///c:/Home/Projects/jigsawpuzzle/lib/main.dart#L22-L76)）。
- 6 个 init 串行 await（[main.dart:53-73](file:///c:/Home/Projects/jigsawpuzzle/lib/main.dart#L53-L73)）：属实，可 `Future.wait` 并行。
- `main.dart:67` 同一 `sw` 同时打印 done/total：**属实**（`total=` 值实为 SoundService 单段耗时，误导）。
- linter 规则全注释：**属实**（[analysis_options.yaml:11-15](file:///c:/Home/Projects/jigsawpuzzle/analysis_options.yaml#L11-L15)）。
- 无 CI：**属实**（无 `.github/`）。
- `web/` 目录与 `dart:io` 并存：**属实**（[web/](file:///c:/Home/Projects/jigsawpuzzle/web) 存在，[main.dart:1](file:///c:/Home/Projects/jigsawpuzzle/lib/main.dart#L1) import dart:io）。属误导性脚手架，建议删除或显式声明不支持 Web。
- `unawaited` 遮蔽：代码气味属实，**但非编译错误**（见 §1.2），原报告影响表述过重。
- 测试假件：[widget_test.dart:57-128](file:///c:/Home/Projects/jigsawpuzzle/test/widget_test.dart#L57-L128) 手写内联 `AlertDialog` 复刻通关弹窗并断言复制品（真实实现是 [game_page.dart:_showVictoryDialog:604](file:///c:/Home/Projects/jigsawpuzzle/lib/pages/game_page.dart#L604)），**无回归价值**——属实。
- 渲染层：`BoardGhostComponent` 每帧 `new Paint()`（[jigsaw_puzzle_game.dart:44-47](file:///c:/Home/Projects/jigsawpuzzle/lib/game/jigsaw_puzzle_game.dart#L42-L47)）：属实（仅 ghost 开启时）；`puzzle_piece_component` 每片每帧 clipPath+drawImageRect+4×drawPath：属实，且 `hideBorders` 字段从未置 true（[jigsaw_puzzle_game.dart:1325](file:///c:/Home/Projects/jigsawpuzzle/lib/game/jigsaw_puzzle_game.dart#L1325) 只复位），「合并底板整图」路径从未启用。

---

## 6. 测试评估核验

- 24 个测试文件集中于 `logic/` 与 `data/`，`PuzzleEngine`/`SnapshotStore`/`MigrationService` 有真实行为断言：**属实**。
- 实测 **165/165 通过**（原报告成文时未拿到数字；上一轮基线 113/113，本轮已增长）。
- 零覆盖区域（`game/`、`pages/` 全部、`widgets/`、`sound_service`、`app_logger`、`game_repository` 四分支、`download_manager` 等）：**属实**。
- 原报告「最该补的 3 个测试」建议成立：① `updateXxxProgress` 等价性（防 P0-2 类分歧）② `SnapshotStore.save` 多难度保留 ③ `hintFor` 复杂度回归。

---

## 7. 修复优先级建议（基于本次核验）

**第一批（正确性/体验，本期做）**
1. **P1-1** `hintFor` 复用 `edgeLayout`（~5 行，消除数秒卡顿，收益最大）。
2. **P0-3** 保存链路：`_doSave` 返 `Future`、三条退出路径 await、删 `_flushSync` 的 `_isSaving` 早退、索引写保证完成。
3. **P0-4** 每日挑战按 `yyyyMMdd` 匹配 + 数据源滚动窗口（至少修 `home_tab_view:147` 与 `_calculateStreak`）。
4. **P0-2(降级)** 四分支补 `await` + `updateGenericProgress` bestTime 走 min + `updateProgress` 顶层 max/min 语义。
5. **P1-4** 删重复 `_onPointerHover`；**P1-5** `_logCaller` 改 `kDebugMode`。

**第二批（性能/数据完整性）**
6. **P1-2** `pieceById` 加索引 + 预计算 cluster 集合。
7. **P1-6** 决策多难度并存：若保留则移出 `save()` 热路径 + 修 `resume_helper` 传多档；否则删 UI 死代码。
8. **P1-13/P1-18/P1-14/P1-16/P1-17** 内容链路修复（zip 保留相对路径、`compute` 解压、流式下载、id 序号、原子写）。
9. **P1-11/P1-12/P1-9** 缓存与删除安全。

**第三批（决策/技术债）**
10. **P0-1** bootstrap URL 注入（视发布环境）；**P0-5** i18n 基础设施（产品决策）。
11. **P1-8** 统一「通关数」口径（`getTotalSolved` vs `totalCompletedLevels` 二选一）。
12. 清理 7 个死依赖 → CI + 启用 linter → 全局错误捕获 → 抽取 `_persistProgress` → 拆大文件。

---

## 8. 遗留事项

- 未对 `online_image_picker_page` / `crop_puzzle_page` / `choose_difficulty_sheet` / `achievements_page` / `settings_page` / `import_pack_page` 逐行通读（与原报告一致）。
- 未做运行时 profiling；P1-1~P1-4 复杂度为静态推导，建议 DevTools 在 20×20 下实测卡顿与帧率。
- `flutter analyze` 0 issues / `flutter test` 165 通过 为本机基线；建议固化为 CI 门禁（先启用 `unawaited_futures` 等 lint 后基线会变化）。

*报告生成时间：2026-08-31（GMT+8）*
