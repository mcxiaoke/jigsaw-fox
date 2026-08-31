# 审查复核报告：code-review-20260831-full.md 逐条核对（2026-08-31）

> **复核对象**：`docs/code-review-20260831-full.md`（下称"原报告"）
> **复核方式**：对原报告引用的全部 file:line 逐条打开源码核对，含全库 grep 交叉验证（依赖引用计数、`hideBorders` 启用路径、硬编码色值统计、`.github` 存在性）；对原报告标注"未验证"的 `unawaited` 命名歧义问题用最小复现工程实测（dart analyze，SDK 3.x，结果：**无歧义报错**）。
> **判定口径**：✅ 属实（file:line 与问题描述均成立）｜⚠️ 基本属实（问题成立，细节/行号/量化有偏差）｜❌ 不属实或表述过强。

---

## 0. 一句话结论

**原报告质量很高，可信。** 共核对 P0×5、P1×23、P2×31、闭环表×16，约 **95% 条目属实或基本属实**，行号引用准确率极高（仅 4 处 ±2 行漂移）。发现 **3 处需要修正的表述**（§6 测试零覆盖表过强、§5.3-6 色值统计错误、§5.4-1 unawaited"命名歧义"经实测不成立）与 **2 处重要补充**（SnapshotStore 删其他难度是设计意图而非疏忽；updateProgress 的 max/min 分支细节）。修复建议的优先级排序（P0-1~4 + P1-1 先行）成立。

---

## 1. P0 核对结果（5/5 成立）

| # | 原报告问题 | 核对结论 | 关键证据（实测行号） |
|---|---|---|---|
| P0-1 | 默认内容源内网 IP + 明文 HTTP | ✅ 属实 | `app_content.dart:33` 原文即 `http://192.168.1.118/...`；`import_pack_page.dart:28-29` 两个内网样本 URL 属实；`content_http_client.dart:14` `connectTimeout: 8s`、全文件无 retry/无 CancelToken 属实 |
| P0-2 | 通关结算四分支未 await + `updateProgress` 覆盖语义丢最佳成绩 | ✅ 属实（补充细节见 §4.1） | `game_page.dart:428` await；`:439/:449/:459/:468` 四处裸调未 await；`progress_store.dart:329-330` `stars ?? cur.stars` / `bestTimeSeconds ?? cur.bestTimeSeconds` 直接覆盖；`game_repository.dart:691` generic 分支 `bestTimeSeconds: timeSeconds` 未经 min，而 level/daily/custom 三分支（:336-340/:479-483/:572-576）均做了 min |
| P0-3 | 保存 fire-and-forget，"退出必存"不成立 | ✅ 属实 | `_doSave()` 返回 `void`（:314）；AppBar 返回 `:921`、PopScope `:1070` 均只调 `_flushSave()` 后立即 pop；`_flushSync` 开头 `if (_isSaving) return;`（:281）；`_flushSync` 内 `updateGenericProgress` 带 `// ignore: discarded_futures`（:295-301）。dispose 的兜底（:888）遇到在途异步保存会静默放弃，孤儿快照无 GC 通道 |
| P0-4 | 每日挑战只按"几号"匹配 + 数据源硬编码 7/8 月 | ✅ 属实 | `home_tab_view.dart:147` `d.dayNumber == now.day` 原文属实；`bing_daily_data.dart:30-31`（原报告写 29-30，偏 1 行）硬编码 2026/7、2026/8；`:79` 全部同一 Unsplash 占位图属实 |
| P0-5 | i18n 零落地 | ✅ 属实 | `main.dart:101-147` MaterialApp 无 `localizationsDelegates`/`supportedLocales`；全库 UI 中文硬编码（home_tab_view/main_screen/game_page 通读确认） |

**补充（P0-2 精确化）**：`updateProgress` 并非全路径覆盖——当 `isCompleted == true && activeDifficultyKey` 同时传入时，records 内部走 max/min（`progress_store.dart:312-323`）；**但 generic 分支（pack/event）恰好不传 `activeDifficultyKey`，正好踩中顶层字段直接覆盖路径**，且 `updateGenericProgress` 是四分支中唯一漏 min 的。原报告结论成立，根因比描述的更集中。

---

## 2. P1 核对结果（23 项：22 成立，1 部分成立）

### 2.1 性能热点

| # | 核对结论 | 证据 |
|---|---|---|
| P1-1 hintFor | ✅ 属实，**影响量化甚至偏保守** | `puzzle_engine.dart:474-482` comparator 每次 2 个 `EdgeLayout` 构造属实；`edge_layout.dart:83-89` 构造函数**立即**执行 `_generate`，:132-141 生成 `(rows-1)×cols + rows×(cols-1)` 个描述符、每个 4 次 RNG 调用属实。20×20：≈3,450 次比较 × 2 构造 × 1,560 描述符 × 4 RNG ≈ **4,300 万次 RNG**（原报告估 2,000 万，量级一致）。修复方案（复用 `jigsaw_puzzle_game.dart:193` 已有 `edgeLayout` 字段）可行，改动约 5 行 |
| P1-2 updatePieceVisibility | ✅ 属实 | `jigsaw_puzzle_game.dart:1579-1613`：外层 n 循环内 `_boardState.pieceById` 为线性扫描（`puzzle_state.dart:192-197` 原文核实），边缘筛选开启时内层再嵌 where+any+pieceById，O(n³) 成立；调用点 1460/1476/1551/1571/1663/1704/1789/1873 全部核实 |
| P1-3 _mergeAllAdjacentClusters | ✅ 属实 | `puzzle_engine.dart:363-414`：双循环内还有 `result.where` 两次 O(n) + 命中后 `result.map` 全量拷贝 + break 重扫，最坏 O(n³) 成立 |
| P1-4 指针移动整页 setState | ✅ 属实 | `game_page.dart:806/810/819` setState 属实；`_onPointerHover`（:823-830）与 Flame `onMouseMove`（`jigsaw_puzzle_game.dart:908-914`）**确实重复调用** `updateHoldingPiecePosition`（其内部 `_pieces.values.where` O(n) :976-977）属实 |
| P1-5 sound_service StackTrace | ✅ 属实 | `:112` `_logCaller = true`、`:168` INFO 级落盘、`:177` `StackTrace.current` 每次播放执行，注释自述"测试完可关"，全部属实 |
| P1-6 SnapshotStore.save 删其他难度 | ✅ 属实，**但需补充设计背景**（见 §4.2） | `snapshot_store.dart:153-159` 保存后全目录扫描并删除同关其他难度属实；与 `resume_helper.dart:96` 只传 1 项难度、ContinueDialog 多难度 UI 成死代码的判断属实 |
| P1-7 每秒整页 setState + 统计重复累加 | ✅ 属实 | `game_page.dart:169-178` Timer.periodic setState；`game_repository.dart:443/542/636/692` 见 P1-8 |

### 2.2 正确性缺陷

| # | 核对结论 | 证据 |
|---|---|---|
| P1-8 重复通关虚增 totalCompleted | ✅ 属实 | :443/:542/:636/:692 `totalCompletedLevels + 1` 无条件累加 |
| P1-9 saveSync 永久改写目录 | ✅ 属实 | `snapshot_store.dart:173-181` 未初始化时把 `_snapshotsDir` 写为 `%TEMP%/jigsaw_snapshots` 且不还原；后续异步 save 走 `_fileFor` 沿用被改写目录。**补充**：正常时序（main 串行 init 先于 runApp）很难触发，属异常时序缺陷，风险评级可从 P1 降到 P2 |
| P1-10 getCacheKey 不含 quality | ✅ 属实 | `image_cache_manager.dart:90-101`，key 只含 path+targetDimension |
| P1-11 getThumbnailFile 失败回退原图 | ✅ 属实 | `:216` `return File(sourcePath)` |
| P1-12 deleteCustomPuzzle 无引用计数 | ✅ 属实 | `game_repository.dart:287-314` 直接删本地文件 |
| P1-13 ZIP 按 basename 平铺覆盖 | ✅ 属实 | `pack_content_pipeline.dart:195`（原报告 194，偏 1 行）`p.join(targetDir.path, baseName)` |
| P1-14 下载全量缓冲 | ✅ 属实 | `content_http_client.dart:80-94` `ResponseType.bytes` 全量缓冲，无流式/上限/CancelToken |
| P1-15 shouldUpscale 用 OR | ✅ 属实 | `image_upscaler.dart:20`（原报告写 18，偏 2 行）`shortSide <= 750 \|\| longSide <= 1000`，4000×750 案例推导正确 |
| P1-16 dl_ 时间戳 id 无序号 | ✅ 属实 | `download_manager.dart:174`；`local_` 分支确有 `_$i` 后缀（grep 核实），不对称属实 |
| P1-17 四处非原子写 | ✅ 属实 | `events:263` / `main:220` / `manifest_router:75` / `pack:263` 四处 `writeAsString` 逐一核实 |
| P1-18 ZipDecoder 主 isolate | ✅ 属实 | `daily:51` / `events:152` / `pack:134` 三处核实 |
| P1-19 _applyBoardState 尺寸不匹配静默 return | ✅ 属实 | `jigsaw_puzzle_game.dart:1761-1768`，仅 AppLogger.warning，无 UI 反馈通道 |
| P1-20 标签筛选伪分类 | ✅ 属实 | `home_tab_view.dart:71-76` `l.index % 5`，bird(:73) 是 landscape(:72) 子集的逻辑矛盾成立 |
| P1-21 FNV `& 0xFFFFFFFFFFFFFFFF` | ✅ 属实 | `snapshot_store.dart:75` / `image_cache_manager.dart:97`；JS 平台退化风险描述合理（当前 dart:io 依赖下不可达 Web） |
| P1-22 listSync 主线程列目录 | ✅ 属实 | `app_logger.dart:276 / 342 / 386` 三处 `listSync()` 核实；`_rotateIfNeeded` 在每次 flush（800ms 定时）都可能触发属实 |
| P1-23 `_sink?.close()` 未 await | ✅ 属实 | `:292`（未 await）vs `:316`（await），不对称属实 |

---

## 3. P2 核对结果

### 3.1 依赖死重（7/7 属实）

全库 grep（lib/ + test/）`package:<name>/` 引用：`flame_riverpod`、`flutter_riverpod`、`webview_flutter`、`desktop_webview_window`、`cupertino_icons`、`vector_math`、`flutter_launcher_icons` 均 **0 引用**，与原报告一致。实际 WebView 用的是 `flutter_inappwebview`（`main.dart`、`online_image_picker_page.dart`）。⚠️ 行号修正：原报告写 `pubspec.yaml:38,42`（正确）、`:64-65`（实际 webview 两个在 **47-48**，launcher_icons 在 **46**）。

### 3.2 复制粘贴债务（7/7 属实）

| # | 核对结论 | 实测规模 |
|---|---|---|
| 1 四个 updateXxxProgress | ✅ | game_repository.dart :316-446/:462-544/:555-638/:650-697，结构逐段比对几乎相同；差异确实已产生真实 bug（P0-2 generic 分支漏 min） |
| 2 Migration 三段 | ✅ | migration_service.dart :57-84/:87-113/:116-142，逐行等价（仅 canonicalId 构造与日志 tag 不同），~85 行 |
| 3 isTrivial 三份 | ✅ | game_page.dart :287/:331 + resume_helper.dart :68-71，三份语义完全相同 |
| 4 栅格遍历三份 | ✅ | jigsaw_puzzle_game.dart :575-611(estimateSlots) / :613-661(hasBalancedDistribution) / :778-878(_getTabletopScatterSlots)，前者两份近乎逐行相同（~130 行量级成立） |
| 5 FNV 两份 | ✅ | snapshot_store.dart:71-78 vs image_cache_manager.dart:92-98 |
| 6 三个等价 switch | ✅ | puzzle_model.dart :228-259/:262-293/:296-321 |
| 7 isPinching 复位两份 | ✅ | game_page.dart :832-843/:845-856 |

### 3.3 结构与分层（9 项：8 属实，1 部分属实）

| # | 核对结论 | 说明 |
|---|---|---|
| 1 resume_helper 数据层依赖 UI | ✅ | `resume_helper.dart:3`(material) `:7`(continue_dialog) 属实 |
| 2/3 拆文件建议 | ✅ | 1925/1281 行实测属实（build ~215 行未逐行数，量级合理） |
| 4/5 main_screen setState hack + IndexedStack | ✅ | `:64/:93` setState(() {})、`:202-215` IndexedStack 属实 |
| 6 硬编码色值 | ⚠️ 细节有误 | `0xFF2E7D32` 在 **main_screen.dart 实际 5 次，不是"约 20 次"**（全库 21 个文件合计约 88 次，game_page 12 次最多）。问题本身成立（与 `main.dart:96` 注释"不写死任何具体色值"矛盾属实），统计口径需修正 |
| 7 路由分散 | ✅ | home_tab_view.dart 3 处 push 属实 |
| 8 presets 横竖歧义 | ✅ | `puzzle_model.dart:342-362`：24/54/96/150/216 各两项属实（**384 也有两项**：16×24/24×16，原报告漏列）；pieceCount 反查兜底仍在（game_repository.dart:389/514/608，difficultyKey 优先分支并存）属实 |
| 9 snapRatio 注释与值不符 | ✅ | `puzzle_engine.dart:16-20`：注释写"48% 黄金手感比例"，`:20` 实值 `defaultSnapRatio = 0.40`；`jigsaw_puzzle_game.dart:1127` 注释 `// 0.48` 属实 |

### 3.4 工程与健壮性（14 项：13 属实，1 部分属实）

| # | 核对结论 | 说明 |
|---|---|---|
| 1 unawaited 遮蔽 | ⚠️ 半对半错（已实测闭环） | `app_logger.dart:453-454` no-op 遮蔽**属实**，使 unawaited_futures 类检查失效**属实**。但"造成命名歧义"**实测不成立**：最小复现（本地库声明 unawaited + 同时 import dart:async，dart analyze）→ **No issues found**（本地/包声明优先于 dart: 平台库导出，不产生 ambiguous import 错误）。原报告 §8.2 已自标"未验证"，现闭环：**删除 no-op 声明的建议维持，但理由是 lint 失效而非编译歧义** |
| 2 无全局错误捕获 | ✅ | main.dart 全文核实，无 FlutterError.onError / PlatformDispatcher.onError / runZonedGuarded；`_loadImage` 无 try/catch（game_page.dart:181-251，解码失败停 loading 属实） |
| 3 init 串行 | ✅ | main.dart :54-73 实为 **7 个串行 await**（原报告写 6 个，少算 AchievementStore） |
| 4 total 日志错 | ✅ | `main.dart:67` 同一 `sw.elapsedMilliseconds` 既作 done 又作 total |
| 5 dart:io vs web/ | ✅ | `main.dart:1` import dart:io，`web/` 目录存在 |
| 6 无 CI | ✅ | `.github/**` 不存在（glob 核实） |
| 7 linter 全注释 | ✅ | `analysis_options.yaml:11-15` |
| 8 init 无重入保护 | ✅（表述需精化） | `app_content.dart:37` **有** `if (_isInitialized) return;`，但 `_isInitialized = true` 在多个 await 之后（:52）→ await 窗口内可重入；`game_repository.dart:87-110` 则**完全无守卫**。原报告对 app_content 的"无重入保护"应精化为"守卫置位过晚" |
| 9 refreshAggregatesCache 全量扫描 | ✅ | progress_store.dart :113-129，且 `recordDifficultyCompletion` 每次通关后调用（:277）；getDistinctImagesWith3Star/getTotalStars/getTotalSolved 各自全量扫描（:181-221）属实 |
| 10 无容量上限/LRU | ✅ | snapshot_store / image_cache_manager 均只有 clearAll |
| 11 updateProgress 无串行化 | ✅ | load→mutate→save 无锁属实 |
| 12 每片每帧多层绘制 | ✅ | puzzle_piece_component.dart :187-237 clipPath + drawImageRect + drawPath×2~4；`hideBorders` 字段存在但**全库 grep 确认从未置 true**（仅 resetCurrentGame 置 false），"未见启用路径"属实 |
| 13 triggerSnapGlow Future.delayed | ✅ | :441-448，有 isRemoved 守卫，原报告"可接受"的评级合理 |
| 14 BoardGhostComponent 每帧 new Paint | ✅ | :44 vs TrayBackgroundComponent :68-75 static final，风格不一致属实 |

---

## 4. 需要修正 / 补充的结论

### 4.1 测试零覆盖表表述过强（❌ 部分不属实，原报告 §6）

实测 test/ 目录存在：

- **`test/game_layout_test.dart`**：直接构造 `JigsawPuzzleGame`，断言托盘布局/碎片数量——原报告"`lib/game/` jigsaw_puzzle_game.dart 零覆盖"**不成立**（覆盖的是布局，不含交互/快照深度，"深度覆盖不足"仍成立）。
- **`test/events_tab_view_test.dart`**：覆盖活动 tab——"4 个 tab 全部无测试"**不成立**。

其余零覆盖结论（pages 其余 9 页、game_repository、main.dart 启动链路等）经文件名比对**成立**。"最该补的 3 个测试"建议维持。

### 4.2 SnapshotStore 删其他难度是设计意图（P1-6 补充）

`snapshot_store.dart:17` 文件头明确写着设计要点："单关卡只留最新残局，保存新难度时自动清理同关旧快照"。即这不是实现疏忽，而是**写入代码时的既定决策**（对应 8-30 评审 P1-4 的处理方式）。修复前需要先做产品决策：要么承认"单难度存档"（删除 ContinueDialog 多难度假 UI），要么改设计为"多难度并存 + 容量上限"。直接删掉清理逻辑而不改注释与 UI，会留下第三种不一致。

### 4.3 其余修正清单（行号/量化小偏差）

| 原报告 | 实测 | 性质 |
|---|---|---|
| pubspec.yaml:64-65（webview） | 47-48 | 行号漂移 |
| bing_daily_data.dart:29-30 | 30-31 | 行号漂移 |
| image_upscaler.dart:18 | 20 | 行号漂移 |
| pack_content_pipeline.dart:194 | 195 | 行号漂移 |
| main.dart 串行 6 个 init | 7 个（漏 AchievementStore） | 计数 |
| main_screen 0xFF2E7D32 约 20 次 | 5 次（全库约 88 次） | 统计错误 |
| unawaited 造成命名歧义 | 无歧义（实测） | 机制误判 |
| presets 横竖重复 5 组 | 6 组（漏 384） | 遗漏 |

### 4.4 闭环表（§1）复核

8-29 评审 P1-1（clearSnapshot 哨兵，`level_item.dart:45,59` ✅）、P1-10（targetWidth:48 降采样，`game_page.dart:125` ✅）、8-30 的 P1-5/P1-6/P1-7（resume_helper 0% 可续玩 ✅、prefs 双写收敛 ✅、MigrationService 完整实现 ✅）——原报告标记"已修"的 5 项全部核实为真；标记"未修/缓解"的条目抽查亦一致。对账表可信。

---

## 5. 确认后的修复优先级（维持原报告第一批，微调理由）

| 顺位 | 事项 | 复核后备注 |
|---|---|---|
| 1 | P0-2 四分支 await + updateProgress max/min | 数据损坏类，且根因集中在 generic 分支漏 min，改动小 |
| 2 | P1-1 hintFor 复用 edgeLayout | ~5 行改动，收益最大（数千万次 RNG → 0） |
| 3 | P0-3 保存链路 await 化 + 删 `_flushSync` 的 `_isSaving` 早退 | 孤儿快照 + 续玩丢失，用户可感知 |
| 4 | P0-4 每日挑战完整日期匹配 | 9 月 1 日起必然复现，**有时间窗口压力** |
| 5 | P0-1 内网 IP 改 dart-define + HTTPS | 发布阻塞，但当前非发布窗口 |
| 6 | P1-6 多难度策略 | 先做产品决策（保留单难度 or 多难度+容量上限），再动代码 |
| 7 | P1-9 saveSync 目录改写 | 可与 P0-3 一并处理（dispose 路径） |

P0-5（i18n）确认属实但属渐进迁移，同意原报告排入第三批。

---

## 6. 复核方法说明

- 逐文件通读：game_page.dart、game_repository.dart、progress_store.dart、snapshot_store.dart、home_tab_view.dart、main.dart、main_screen.dart、sound_service.dart、content_http_client.dart、image_cache_manager.dart、resume_helper.dart、migration_service.dart、app_logger.dart、bing_daily_data.dart、jigsaw_puzzle_game.dart（全文）、puzzle_engine.dart（关键段）、edge_layout.dart（关键段）、puzzle_state.dart（关键段）、puzzle_model.dart（关键段）、puzzle_piece_component.dart（关键段）、四条 content pipeline（关键段）、download_manager/image_upscaler（关键段）。
- 全库检索：7 个疑似死依赖引用计数、`local_`/`dl_` id 后缀、`hideBorders` 赋值路径、`0xFF2E7D32` 分布、`.github` 存在性。
- 实验验证：`unawaited` 歧义最小复现（temp/unawaited_probe，dart analyze → No issues found）。
- 未执行：`flutter analyze` / `flutter test` 全量（沿用原报告 §8.3 的说明，本机冷启动超时问题未解决）；运行时 profiling 未做（§4.1 复杂度结论为静态推导 + 复核确认）。

> 临时探针目录 `temp/unawaited_probe/` 可删除。
