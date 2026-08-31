# 代码审查报告核对（2026-08-31）

> **核对对象**：`docs/code-review-20260831-full.md` 中列出的全部问题
> **核对方式**：6 个并行子代理逐条读取项目源代码，与原始审查报告描述对比验证
> **项目根目录**：`C:\Home\Projects\jigsawpuzzle`
> **判定标记**：✅ 真实存在需修复 | ⚠️ 部分存在（描述需修正） | ❌ 不存在或已修复

---

## 0. 核对结果总览

| 类别 | 总数 | ✅ 真实需修 | ⚠️ 部分存在 | 子项描述不准确 |
|------|------|-------------|-------------|-----------|
| P0 — 发布阻塞 | 5 | 5 | 0 | 0 |
| P1 — 性能热点 | 7 | 6 | 1（P1-4） | 1（P1-4 描述过宽） |
| P1 — 正确性缺陷 | 16 | 14 | 2（P1-19、P1-21） | 1（P1-21 的 FNV 截断描述） |
| P2 — 依赖死重 | 7 | 6 | 1（flutter_launcher_icons） | 0 |
| P2 — 复制粘贴 | 7 | 7 | 0 | 0 |
| P2 — 结构与分层 | 9 | 8 | 1（P2-5.3.6 色值计数） | 0 |
| P2 — 工程与健壮性 | 14 | 12 | 2（P2-5.4.8、P2-5.4.10） | 1（P2-5.4.3 init 数量） |
| **合计** | **65** | **58** | **7** | **3** |

> 注："子项描述不准确"指问题整体成立但原报告某子项描述有误（详见 §8）。按问题整体判定，0 项完全不存在。

**核心结论**：原始审查报告中 **58/65（89%）** 的问题经源代码核对完全属实，7 项部分属实（需修正描述），另有 3 个子项描述不准确（不影响问题整体成立）。报告整体质量高，问题真实性强，建议优先修复 P0 全部 5 项和 P1 性能热点的前 3 项。

---

## 1. P0 — 发布阻塞（全部 ✅ 真实存在）

### P0-1 默认内容源是内网测试机 IP ✅

| 子项 | 判定 | 核对依据 |
|------|------|----------|
| `app_content.dart` 硬编码内网 IP | ✅ | 第 32-34 行 `defaultBootstrapUrls` 唯一条目为 `http://192.168.1.118/data/www/game/test/manifest.json`，注释直言"优先指向测试服务器" |
| `import_pack_page.dart` 样本 URL 硬编码 | ✅ | 第 28-29 行两个 `_sampleTestUrl` / `_samplePureUrl` 均指向同一内网 IP，绑定到 ActionChip 按钮上 |
| `content_http_client.dart` 无重试无 CancelToken | ⚠️ | 无重试 ✅ 确认、无 CancelToken ✅ 确认（全库搜索零结果）。**路径修正**：实际路径为 `lib/logic/content/network/content_http_client.dart`（非 `lib/logic/content/`） |

### P0-2 通关结算写同一份 ProgressStore 记录却不 await ✅

| 子项 | 判定 | 核对依据 |
|------|------|----------|
| `recordDifficultyCompletion` 已 await（报告正确描述） | ✅ | `game_page.dart:428` 实际为 `final updateResult = await ProgressStore.instance.recordDifficultyCompletion(...)`，报告正确指出此行已 await，作为与下方四条未 await 分支的对比 |
| 四个 `_repo.updateXxxProgress` 未 await | ✅ | `game_page.dart:438-476` 四个分支全部 fire-and-forget，方法签名返回 `Future<void>` 但调用处无 `await` |
| `updateProgress` 顶层 stars/bestTimeSeconds 裸覆盖 | ✅ | `progress_store.dart:325-330`：`stars: stars ?? cur.stars`（无 max）、`bestTimeSeconds: bestTimeSeconds ?? cur.bestTimeSeconds`（无 min）。对比 `recordDifficultyCompletion` 第 269-270 行正确使用 `math.max`/`math.min` |
| `updateGenericProgress` 传 timeSeconds 无 min | ✅ | `game_repository.dart:690-691`：`bestTimeSeconds: timeSeconds` 原样直传。而 `updateLevelProgress:336-340`、`updateDailyProgress:479-483`、`updateCustomProgress:572-576` 三条分支均做了 min保护 |

**核对确认**：报告对 P0-2 的描述准确——`recordDifficultyCompletion` 已 await（报告正确指出），核心问题在于四个 `updateXxxProgress` 未 await + `updateProgress` 裸覆盖 + `updateGenericProgress` 无 min 保护。竞态和数据损坏风险**真实存在**。

### P0-3 保存仍是 fire-and-forget ✅

| 子项 | 判定 | 核对依据 |
|------|------|----------|
| `_flushSave` → `_doSave()` 返回 void | ✅ | `game_page.dart:272-274` `_flushSave()` 调 `_doSave()`，`_doSave()` 第 314 行返回 `void`；内部 `fut.whenComplete` 无人持有 |
| AppBar 返回只调 `_flushSave()` | ✅ | `game_page.dart:919-922`：`_flushSave()` 后立即 `Navigator.pop()` |
| PopScope 只调 `_flushSave()` | ✅ | `game_page.dart:1067-1071`：`_flushSave()` 后立即 `pop(result)` |
| `_isSaving` 时 Timer 重试 | ✅ | `game_page.dart:316-320`：新建 `Timer(300ms, _doSave)` 重试，仍 fire-and-forget |
| `_flushSync` 开头 `if (_isSaving) return` | ✅ | `game_page.dart:278-281`：异步保存进行中时同步兜底直接放弃 |
| `_flushSync` 内部 fire-and-forget | ✅ | `game_page.dart:294-301`：`// ignore: discarded_futures` + `_repo.updateGenericProgress(...)` |

### P0-4 "今日挑战"按"日"匹配，数据源只到 2026-08 ✅

| 子项 | 判定 | 核对依据 |
|------|------|----------|
| 只比较几号忽略年月 | ✅ | `home_tab_view.dart:147`：`firstWhere((d) => d.dayNumber == now.day, ...)` |
| 硬编码 2026/7、2026/8 | ✅ | `bing_daily_data.dart:30-31`：`kBingDaily30Days = _generateMonthDaily(2026, 8)`、`kBingDailyJuly = _generateMonthDaily(2026, 7)` |
| imageUrl 全同 | ✅ | `bing_daily_data.dart:79`：全部 61 条记录共用同一个 Unsplash 链接 |

### P0-5 i18n 体系零落地 ✅

| 子项 | 判定 | 核对依据 |
|------|------|----------|
| MaterialApp 未配置本地化 | ✅ | `main.dart:101-147`：无 `localizationsDelegates`、`supportedLocales`，全库搜索零结果 |
| 无 l10n 基础设施 | ✅ | 无 `l10n.yaml`、无 `lib/l10n/` 目录、无 `*.arb` 文件 |
| 中文硬编码遍布 | ✅ | `main_screen.dart:29-37`（'主页'/'每日'/'活动'/'自制'）、`settings_page.dart:38`、`import_pack_page.dart` 多处、`main.dart:102` |

---

## 2. P1 — 性能热点（6 ✅ + 1 ⚠️）

### P1-1 hintFor 排序比较器内 new EdgeLayout ✅

| 子项 | 判定 | 核对依据 |
|------|------|----------|
| comparator 每次比较构造 2 个 EdgeLayout | ✅ | `puzzle_engine.dart:474-482`：`EdgeLayout(rows: state.rows, cols: state.cols, seed: state.seed).edgesFor(...)` 每次 2 次 |
| EdgeLayout 构造函数重建整盘拓扑 | ✅ | `edge_layout.dart:83-89`：构造函数调用 `_generate(seed)`，生成 `(rows-1)*cols + rows*(cols-1)` 个描述符。**路径修正**：实际为 `lib/logic/geometry/edge_layout.dart` |
| 已有 edgeLayout 字段可复用 | ✅ | `jigsaw_puzzle_game.dart:193`：`late EdgeLayout edgeLayout` |

### P1-2 updatePieceVisibility O(n³) ✅

| 子项 | 判定 | 核对依据 |
|------|------|----------|
| 边缘筛选开启时 O(n³) | ✅ | `jigsaw_puzzle_game.dart:1579-1601`：外层 O(n) × `pieceById` O(n) × `where().any()` 内含 O(n) pieceById |
| pieceById 是 O(n) 线性扫描 | ✅ | `puzzle_state.dart:192-197`：for 循环遍历查找。**路径修正**：实际为 `lib/logic/models/puzzle_state.dart` |
| 多处高频调用 | ✅ | 第 1551（handlePieceDragEnd）、1460（cancelPieceDrag）、1663/1704（organizeTray）行 |

### P1-3 _mergeAllAdjacentClusters O(n²)~O(n³) ✅

| 子项 | 判定 | 核对依据 |
|------|------|----------|
| while + 双重 for + 合并时 3 次 O(n) | ✅ | `puzzle_engine.dart:362-414`：`while(changed)` 最多 O(n) 轮 × 双重 for O(n²) + 每次合并 3 次 O(n)（两个 `.where().length` + 一个 `.map().toList()`），最坏 O(n³) |

### P1-4 每次指针移动整页 setState ⚠️ 部分存在

| 子项 | 判定 | 核对依据 |
|------|------|----------|
| 每次指针移动整页 setState | ⚠️ **描述需修正** | `game_page.dart:783-820`：`setState` **并非无条件每次触发**，仅在多指缩放（806 行）、中键平移（810 行）、放大后拖拽空白（819 行）时触发。非"每次指针移动" |
| `_onPointerHover` 与 `onMouseMove` 重复调用 | ✅ | `game_page.dart:823-830` 和 `jigsaw_puzzle_game.dart:908-914` 都调用 `updateHoldingPiecePosition`，Listener 包裹 FlameGame 导致同一 hover 事件双重触发 |

### P1-5 sound_service 每次播放抓 StackTrace ✅

| 子项 | 判定 | 核对依据 |
|------|------|----------|
| `_logCaller = true` 未关闭 | ✅ | `sound_service.dart:112`：`static const bool _logCaller = true`，注释写"测试完可关" |
| `_caller()` 用 StackTrace.current | ✅ | `sound_service.dart:175-189`：`StackTrace.current.toString().split('\n')` |
| snap 80ms 节流后仍约 12 次/秒堆栈捕获 | ✅ | `sound_service.dart:106,154-158`：80ms 节流，但未节流的每次仍执行堆栈捕获 + INFO 级落盘 |

### P1-6 SnapshotStore 每次保存删同关其他难度 ✅

| 子项 | 判定 | 核对依据 |
|------|------|----------|
| save() 成功后目录扫描 + 删其他难度 | ✅ | `snapshot_store.dart:153-159`：`listDifficultyKeys(cid)` 全目录 `await for` 遍历 + `delete` 其他难度 |
| 800ms 防抖但每次仍冗余 I/O | ✅ | `game_page.dart:82-83,261-270`：防抖在调用方，但每次防抖后 save() 仍执行目录扫描 |
| ContinueDialog SegmentedButton 死代码 | ✅ | `resume_helper.dart:92-99`：`difficulties: [info.dkey]` 只传 1 项；`continue_dialog.dart:118`：`if (widget.difficulties.length > 1)` 永远为 false |

### P1-7 每秒整页 setState / 统计重复累加 ✅

| 子项 | 判定 | 核对依据 |
|------|------|----------|
| 计时器每秒整页 setState | ✅ | `game_page.dart:168-178`：`Timer.periodic(1s, ...)` → `setState(() => _seconds++)` |
| totalCompletedLevels + 1 无条件累加 | ✅（见 P1-8） | 四处均未检查"是否首次完成"，重玩已通关关卡仍 +1 |

---

## 3. P1 — 正确性缺陷（14 ✅ + 2 ⚠️）

### P1-8 totalCompletedLevels + 1 无条件累加 ✅

四处全部确认：`game_repository.dart` 第 443（updateLevelProgress）、542（updateDailyProgress）、636（updateCustomProgress）、692（updateGenericProgress）行。`isCompleted` 只判断"本次通关"，不检查是否首次完成。

### P1-9 snapshot_store saveSync 永久改写 _snapshotsDir ✅

`snapshot_store.dart:172-181`：`if (!_initialized || _snapshotsDir == null)` 时将 `_snapshotsDir` 永久赋值为 `Directory.systemTemp` 下的临时目录。后续所有调用（含异步 `save()` 中的 `_fileFor()`）都使用此临时目录。

### P1-10 image_cache_manager getCacheKey 不含 quality ✅

`image_cache_manager.dart:90-101`：`getCacheKey` 签名仅含 `sourcePath` 和 `targetDimension`，不含 `quality`。**路径修正**：实际为 `lib/logic/cache/image_cache_manager.dart`。

### P1-11 getThumbnailFile 生成失败返回原图路径 ✅

`image_cache_manager.dart:216`：`return File(sourcePath)` 返回原图路径，调用方拿到全分辨率大图。**路径修正**：同上。

### P1-12 deleteCustomPuzzle 无引用计数直接删图片 ✅

`game_repository.dart:287-302`：第 295-296 行直接 `await file.delete()`，无引用计数检查。

### P1-13 ZIP 解压按 basename 平铺 ✅

`pack_content_pipeline.dart:170,195`：`p.basename(filename)` 丢弃目录结构，第 195 行平铺写入同一目录。**路径修正**：实际为 `lib/logic/content/pipelines/pack_content_pipeline.dart`。原报告行号 194 略有偏差，实际 `p.basename` 在 170 行、写入在 195 行。

### P1-14 content_http_client 全量缓冲无流式 ✅

`content_http_client.dart:80-94`：`ResponseType.bytes` 全量缓冲，无流式、无大小上限、无 CancelToken。**路径修正**：实际为 `lib/logic/content/network/content_http_client.dart`。

### P1-15 image_upscaler shouldUpscale 用 OR ✅

`image_upscaler.dart:20`：`return shortSide <= minShortSide || longSide <= minLongSide` 用 OR，应改为 AND。**路径修正**：实际为 `lib/logic/image_upscaler.dart`。

### P1-16 download_manager id 用毫秒时间戳 ✅

`download_manager.dart:174`：`'dl_${DateTime.now().millisecondsSinceEpoch}'` 无序号后缀；对比第 108 行 `local_` 分支已用 `_$i` 修复。

### P1-17 多处非原子写 ✅（4 处全部确认）

全部为 `writeAsString(jsonEncode(...), flush: true)` 直接覆盖目标文件：

| 位置 | 判定 |
|------|------|
| `events_content_pipeline.dart:263` | ✅ |
| `main_content_pipeline.dart:220` | ✅ |
| `manifest_router.dart:75` | ✅ |
| `pack_content_pipeline.dart:263` | ✅ |

### P1-18 ZipDecoder 主 isolate 同步执行 ✅（3 处全部确认）

| 位置 | 判定 |
|------|------|
| `daily_content_pipeline.dart:51` | ✅ |
| `events_content_pipeline.dart:152` | ✅ |
| `pack_content_pipeline.dart:134` | ✅ |

### P1-19 _applyBoardState 尺寸不匹配静默 return ⚠️ 部分存在

`jigsaw_puzzle_game.dart:1761-1768`：尺寸不匹配时 `return` 且无回调，方法本身确实静默。**但**调用方 `undo()`（1745-1746 行）和 `redo()`（1756-1757 行）在 `_applyBoardState` 之后**无条件**调用 `onStateUpdated?.call()`，即使状态未实际应用也会触发 UI 刷新，可能给用户造成"撤销/重做成功"的假象。问题部分存在——方法内部无失败信号，调用方也未检查返回结果。

### P1-20 标签筛选用 l.index % 5 伪分类 ✅

`home_tab_view.dart:70-76`：标签分类基于 `index % 5`。`bird`（`%5==2`）是 `landscape`（`%5==2 || %5==0`）的严格子集；`architecture`（`%5==0`）也是 `landscape` 的严格子集。5 个标签中 2 个是另一个标签的子集。

### P1-21 FNV 哈希截断问题 ⚠️ 部分存在

| 位置 | 判定 | 核对依据 |
|------|------|----------|
| `& 0xFFFFFFFFFFFFFFFF` 截断 | ❌ **报告此描述不准确** | 这是 FNV-1a 64-bit 标准实现，在 Dart native 上是正确且必要的，不是 bug |
| `snapshot_store.dart:77` 额外截断至 32 位 | ⚠️ | `.toRadixString(16).padLeft(8, '0').substring(0, 8)` 将 64 位哈希截断为 32 位（8 个 hex 字符），确实增加碰撞概率 |
| `image_cache_manager.dart:99` 保留 64 位 | ❌ 无此问题 | `.toRadixString(16).padLeft(16, '0')` 保留完整 16 位 hex，无额外截断 |

**修正说明**：报告将 `& 0xFFFFFFFFFFFFFFFF` 描述为截断问题不准确，这是标准 FNV-1a 实现。真正的问题仅在于 `snapshot_store.dart` 的 `substring(0, 8)` 额外截断。关于 JS/Web 平台 int32 截断的担忧在当前 `dart:io` 依赖下不构成实际风险。

### P1-22 app_logger listSync ✅（3 处全部确认）

`app_logger.dart` 第 276 行（`_rotateIfNeeded`）、342-343 行（`_cleanupOldLogs`）、385-386 行（`listLogFiles`）均使用 `listSync()`。三处方法声明为 `async`，完全有条件改用 `await list()`。

### P1-23 app_logger close 未 await ✅

`app_logger.dart:292`：`_sink?.close()` 未 await（紧接 `_sink = null; return;`）。对比第 316 行同类调用 `await _sink?.close()` 已正确 await。

---

## 4. P2 — 依赖死重（6 ✅ + 1 ⚠️）

### P2-5.1 依赖死重

| 依赖 | lib/ 引用 | test/ 引用 | 判定 | 说明 |
|------|----------|-----------|------|------|
| `flame_riverpod` | 0 | 0 | ✅ 死重 | 无任何 Riverpod 用法 |
| `flutter_riverpod` | 0 | 0 | ✅ 死重 | 无 ConsumerWidget/ProviderContainer |
| `webview_flutter` | 0 | 0 | ✅ 死重 | 实际用 `flutter_inappwebview` |
| `desktop_webview_window` | 0 | 0 | ✅ 死重 | 无引用 |
| `flutter_launcher_icons` | 0 | 0 | ⚠️ **分类错误** | 不是死重（有 `flutter_launcher_icons.yaml` 配置文件，是 CLI 工具），但应从 `dependencies` 移到 `dev_dependencies` |
| `cupertino_icons` | 0 | 0 | ✅ 死重 | 无 import |
| `vector_math` | 0 | 0 | ✅ 死重 | 经 flame 间接使用，可删或加注释 |

---

## 5. P2 — 复制粘贴债务（全部 ✅）

### P2-5.2 复制粘贴清单

| # | 位置 | 内容 | 判定 | 核对依据 |
|---|------|------|------|----------|
| 1 | `game_repository.dart:316-446 / 462-544 / 555-638 / 650-697` | 四个 `updateXxxProgress` 结构几乎完全相同 | ✅ | SnapshotStore/ProgressStore 同步逻辑的 if/else 链逐行对应，`totalCompletedLevels + 1` 也在四处完全重复 |
| 2 | `migration_service.dart:57-84 / 87-113 / 116-142` | 主线/每日/自制三段迁移代码逐行等价 | ✅ | 三段结构完全相同，仅循环变量名和 canonicalId 方法不同 |
| 3 | `game_page.dart:287,331` + `resume_helper.dart:68-71` | `isTrivial` 判定三份完全相同 | ✅ | L287 和 L331 逐字符完全相同；resume_helper 逻辑等价仅变量名不同 |
| 4 | `jigsaw_puzzle_game.dart:575-611 / 613-661 / 778-827` | 三份栅格遍历 | ✅ | 三段共享相同常量（`pad=4.0`、`stepX=max(32.0, *1.18)`、`16.0`、`60.0`、`48.0`、`8.0`、`44.0`）和碰撞检测逻辑 |
| 5 | `snapshot_store.dart:71-78` vs `image_cache_manager.dart:92-98` | FNV-1a 哈希两份实现 | ✅ | 相同种子 `0xcbf29ce484222325` 和质数 `0x100000001b3`，仅遍历方式（codeUnit vs utf8 bytes）和输出长度不同 |
| 6 | `puzzle_model.dart:228-259 / 262-293 / 296-321` | `secPerPiece` / `tierIndex` / `tierLevel` 三个等价 switch | ✅ | case 分组完全平行，仅返回值不同。**路径修正**：实际为 `lib/logic/puzzle_model.dart` |
| 7 | `game_page.dart:836-840 / 849-853` | `_onPointerUp` / `_onPointerCancel` isPinching 复位逻辑 | ✅ | 2 处重复（规模小） |

---

## 6. P2 — 结构与分层（8 ✅ + 1 ⚠️）

### P2-5.3 结构与分层清单

| # | 位置 | 问题 | 判定 | 核对依据 |
|---|------|------|------|----------|
| 1 | `resume_helper.dart:3,7` | 数据层 import Flutter Material 和 UI Widget | ✅ | `import 'package:flutter/material.dart'` + `import '../widgets/continue_dialog.dart'`；`maybeShowResumeDialog`/`handleResumeResult`/`tryHandleResumeFlow` 均持有 `BuildContext` 并弹对话框 |
| 2 | `jigsaw_puzzle_game.dart` | 1925 行单文件 | ✅ | `wc -l` 确认 1925 行 |
| 3 | `game_page.dart` | 1281 行单文件 | ✅ | `wc -l` 确认 1281 行 |
| 4 | `main_screen.dart:64,93` | `setState(() {})` 整屏重建 | ✅ | 第 64 行（成就页返回）和第 93 行（设置页返回）均传入空函数体 |
| 5 | `main_screen.dart:202-215` | IndexedStack 全部构建 | ✅ | 4 个 Tab 直接列入 `children`，启动时全部实例化 |
| 6 | 硬编码色值 `0xFF2E7D32` | 与 main.dart 注释矛盾 | ⚠️ **计数需修正** | 原报告称"main_screen.dart 一个文件出现约 20 次"，实际 `main_screen.dart` 出现 **5 次**（111/234/239/244/249 行）、`home_tab_view.dart` 出现 **6 次**（180/211/235/236/300/327 行），合计 11 次。核心矛盾（main.dart:96 注释宣称"不写死色值"但实际硬编码）成立 |
| 7 | `home_tab_view.dart` | Navigator.push 硬编码 3 处 | ✅ | 第 98、128、136 行，3 处内联 `MaterialPageRoute` + `GamePage` |
| 8 | `puzzle_model.dart:342-362` | presets 横竖歧义 | ✅ | 24/54/96/150/216 各有横竖两项；`game_repository.dart:389,514,608` 兜底路径仍用 `firstWhere` 按 pieceCount 反查。**路径修正**：puzzle_model.dart 实际为 `lib/logic/puzzle_model.dart` |
| 9 | `puzzle_engine.dart:16-20` vs `jigsaw_puzzle_game.dart:1127` | 注释说 48% 实际 0.40 | ✅ | puzzle_engine.dart 第 16 行注释三处提及 "48%"，实际值 `defaultSnapRatio = 0.40`；jigsaw_puzzle_game.dart 第 1127 行注释写 `// 0.48` |

---

## 7. P2 — 工程与健壮性（12 ✅ + 2 ⚠️）

### P2-5.4 工程与健壮性清单

| # | 位置 | 问题 | 判定 | 核对依据 |
|---|------|------|------|----------|
| 1 | `app_logger.dart:453-454` | `void unawaited(Future<void> f) {}` 遮蔽官方函数 | ✅ | 空实现使 `unawaited_futures` lint 失效；项目中 `image_cache_manager.dart:238` 等处调用的是此空实现 |
| 2 | `main.dart:22-76` | 无全局错误捕获 | ✅ | 全库搜索 `FlutterError.onError`/`PlatformDispatcher`/`runZonedGuarded` 零结果 |
| 3 | `main.dart:54-72` | 串行 await | ✅ **数量需修正** | 实际为 **7 个** init 串行 await（ImageCacheManager、GameRepository、DownloadManager、AppContent、SoundService、EconomyService、AchievementStore），原报告称"6 个" |
| 4 | `main.dart:67` | 同一 sw 同时用作 done 和 total | ✅ | `sw.reset()` 后 `done` 和 `total` 插值同一值 |
| 5 | `main.dart` + lib/ | import dart:io 但保留 web/ 目录 | ✅ | `web/` 目录存在（含 `index.html` 等），内容为默认模板 + 定制图标 |
| 6 | 仓库根目录 | 无 CI 门禁 | ✅ | 无 `.github` 目录，无 `.github/workflows` |
| 7 | `analysis_options.yaml:11-15` | linter 规则全注释 | ✅ | 仅继承 `flutter_lints` 默认集，自定义规则全部被 `#` 注释 |
| 8 | `app_content.dart:50-52`、`game_repository.dart:87` | 单例 init 无重入保护 | ⚠️ | `app_content.dart` 有 `if (_isInitialized) return` 守卫但 `_isInitialized` 在 await 之后才置位（async 窗口无效）；`game_repository.dart` **完全无任何守卫** |
| 9 | `progress_store.dart:113-129,277` | refreshAggregatesCache 全量扫描 | ✅ | 遍历全部 prefs key 逐个 jsonDecode；`getDistinctImagesWith3Star`/`getTotalStars`/`getTotalSolved` 各自再做全量扫描（每个 2N 次 jsonDecode） |
| 10 | snapshot_store / image_cache_manager | 无容量上限与 LRU | ⚠️ | SnapshotStore **完全无上限** ✅；ImageCacheManager 内存层有完整 LRU（150 条/30MB）❌ 但磁盘层无上限 ✅ |
| 11 | `progress_store.dart:302-337` | updateProgress 无加锁 | ✅ | 经典 load→mutate→save，无 mutex/串行队列 |
| 12 | `puzzle_piece_component.dart:187-237` | 每片每帧重绘 | ✅ | 每帧最少 `clipPath + drawImageRect + 3×drawPath`；400 片时约 2000~2800 次画布操作 |
| 13 | `puzzle_piece_component.dart:441-448` | triggerSnapGlow 用 Future.delayed | ✅ | 返回的 Future 未存储，不可取消；有 `isRemoved` 守卫但 `game` 引用可能已失效 |
| 14 | `jigsaw_puzzle_game.dart:42-47` | BoardGhostComponent 每帧 new Paint | ✅ | 每次 render 创建新 `Paint()`；对比同文件 `TrayBackgroundComponent` 已用 `static final Paint` |

---

## 8. 原报告不准确之处汇总

| # | 原报告描述 | 实际情况 | 影响等级 |
|---|-----------|----------|----------|
| 1 | P1-4："每次指针移动整页 setState" | setState **并非无条件每次触发**，仅在缩放/中键平移/放大拖拽空白时触发；但重复调用 `updateHoldingPiecePosition` 确实存在 | 中 — 问题描述需修正 |
| 2 | P1-21："FNV 哈希用 `& 0xFFFFFFFFFFFFFFFF` 截断" | 该操作是标准 FNV-1a 64-bit 实现，不是 bug；真正问题仅在 `snapshot_store.dart` 的 `substring(0, 8)` 额外截断至 32 位 | 中 — 问题描述需修正 |
| 3 | P2-5.4.3："6 个 init 串行 await" | 实际为 **7 个** init 串行（多了 `AchievementStore.instance.init()`），原报告少计 1 个 | 低 — 不影响"串行 await 应并行化"的核心建议 |

---

## 9. 文件路径修正汇总

原报告中以下文件路径与项目实际结构不符：

| 原报告路径 | 实际路径 |
|-----------|----------|
| `lib/logic/content/content_http_client.dart` | `lib/logic/content/network/content_http_client.dart` |
| `lib/logic/content/pack_content_pipeline.dart` | `lib/logic/content/pipelines/pack_content_pipeline.dart` |
| `lib/logic/content/events_content_pipeline.dart` | `lib/logic/content/pipelines/events_content_pipeline.dart` |
| `lib/logic/content/main_content_pipeline.dart` | `lib/logic/content/pipelines/main_content_pipeline.dart` |
| `lib/logic/content/daily_content_pipeline.dart` | `lib/logic/content/pipelines/daily_content_pipeline.dart` |
| `lib/data/image_cache_manager.dart` | `lib/logic/cache/image_cache_manager.dart` |
| `lib/logic/image/image_upscaler.dart` | `lib/logic/image_upscaler.dart` |
| `lib/logic/engine/edge_layout.dart` | `lib/logic/geometry/edge_layout.dart` |
| `lib/logic/engine/puzzle_state.dart` | `lib/logic/models/puzzle_state.dart` |
| `lib/logic/engine/puzzle_model.dart` | `lib/logic/puzzle_model.dart` |

> 路径偏差不影响问题本身的成立——所引代码内容均真实存在，但行号定位需以实际路径为准。

---

## 10. 行号偏差汇总

| 原报告行号 | 实际行号 | 说明 |
|-----------|----------|------|
| P1-13 `pack_content_pipeline.dart:194` | `p.basename` 在 170 行，平铺写入在 195 行 | 偏差 1 行 |
| P1-15 `image_upscaler.dart:18` | 第 20 行 | 偏差 2 行 |
| P1-16 `download_manager.dart:174` | 第 174 行 ✅ | 精确匹配 |
| P0-2 `game_page.dart:439/449/459/468` | 第 438-476 行（四个分支） | 偏差 1 行，分支结构正确 |
| P2-5.3.6 `0xFF2E7D32` "约 20 次" | main_screen.dart 5 次 + home_tab_view.dart 6 次 = 11 次 | 计数偏高 |

---

## 11. 结论与建议

### 核对结论

原始审查报告整体质量高：**65 项问题中 58 项（89%）完全属实，7 项部分属实需修正描述，另有 3 个子项描述不准确（不影响问题整体成立，详见 §8）**。所有 P0 问题核心成立，建议优先修复。

### 建议优先修复顺序

**第一批（最高优先，P0 全部 + P1-1）**：
1. **P0-1** 内网 IP 改 `--dart-define` + HTTPS（路径已确认为 `app_content.dart:32-34`）
2. **P0-2** 四个 `updateXxxProgress` 补 `await` + `updateProgress` 改 max/min 语义（注意 `recordDifficultyCompletion` 已 await 无需改）
3. **P0-3** 保存改 `Future<void>` + await，删除 `_flushSync` 的 `_isSaving` 早退
4. **P0-4** 每日挑战按完整日期匹配 + 数据源动态化
5. **P1-1** `hintFor` 复用已有 `edgeLayout`（改动约 5 行，收益最大）

**第二批（P1 性能与正确性）**：
6. P1-2 / P1-3 给 `pieceById` 加索引、预计算 cluster 信息
7. P1-5 `_logCaller` 改 `kDebugMode`
8. P1-6 `SnapshotStore.save` 移除"删同关其他难度"
9. P1-8 `totalCompletedLevels` 加首次完成判断
10. P1-9 `saveSync` 不改写 `_snapshotsDir`、改为 return + 等待 init
11. P1-15 `shouldUpscale` OR 改 AND
12. P1-16 `download_manager` `dl_` 分支补序号后缀
13. P1-17 四处非原子写改用 `.tmp → rename` 模式
14. P1-18 三处 ZipDecoder 移到 `compute`/`Isolate.run`

**第三批（技术债）**：
15. 清理 6 个死依赖 + flutter_launcher_icons 移 dev_dependencies
16. i18n 基础设施落地
17. 建 CI + 启用严格 linter
18. 全局错误捕获
19. 拆 `jigsaw_puzzle_game.dart`（1925 行）/ `game_page.dart`（1281 行）
20. 修复注释/值不一致（P2-5.3.9）

### 特别说明

- **P1-4**：原报告"每次指针移动整页 setState"描述需修正为"特定手势条件下 setState"；但 `_onPointerHover` 与 `onMouseMove` 重复调用 `updateHoldingPiecePosition` 的问题真实存在
- **P1-19**：`_applyBoardState` 静默 return 问题部分存在，但调用方 `undo()`/`redo()` 会无条件调用 `onStateUpdated`，可能造成"操作成功"假象
- **P1-21**：`& 0xFFFFFFFFFFFFFFFF` 是标准 FNV-1a 实现不是 bug，真正需修的是 `snapshot_store.dart` 的 `substring(0, 8)` 额外截断
- **P2-5.4.3**：实际为 7 个 init 串行（原报告称 6 个）
- **P2-5.4.10**：ImageCacheManager 内存层有完整 LRU（150 条/30MB），仅磁盘层和 SnapshotStore 无上限
