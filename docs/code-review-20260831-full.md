# 全面代码审查报告（2026-08-31）

> **审查范围**：`lib/` 全部 72 个 Dart 文件（约 21,000 行）、`test/` 24 个测试文件、`pubspec.yaml`、`analysis_options.yaml`、`main.dart` 启动链路、工程门禁。
> **审查方式**：逐文件通读核心模块（引擎/游戏/数据/服务/启动链路），全库交叉检索（异常吞没、硬编码、定时器、依赖引用、复杂度热点），并与前两轮评审（`code-review-20260829.md`、`code-review-20260830-save-resume.md`）逐条对账闭环情况。
> **严重度**：P0 = 发布阻塞或数据损坏；P1 = 明确 bug / 显著性能损耗；P2 = 架构与可维护性债务。
> **校验状态**：`flutter analyze` 与 `flutter test` 本机冷启动超过 50 分钟未完成（见 §8.3），本次未取得量化数字，结论均基于代码事实（行号可直接跳转核对）。

---

## 0. 一句话结论

架构分层（engine 纯领域逻辑 / game 渲染 / data 持久化 / pages UI）是本项目的核心资产，`PuzzleEngine` 的可测试性、`SnapshotStore` 的原子写 + `.bak` 回滚、`AppLogger` 的脱敏落盘都达到可圈可点的水平。

但项目正被两件事拖住：**（1）前两轮评审的 5 个 P0 一条都没修**；**（2）复杂度失控的算法热点 + 约 600 行复制粘贴代码**正在把「能跑」推向「难改」。建议本轮先只做 §3 的 5 项 P0 和 §4 的前 6 项 P1，其余排队。

---

## 1. 上轮评审闭环情况（对账表）

### 1.1 2026-08-29 评审的 5 个 P0 —— **0 修复**

| # | 问题 | 位置 | 状态 |
|---|---|---|---|
| P0-1 | `webview_flutter`、`desktop_webview_window` 全库 0 引用（实际用的是 `flutter_inappwebview`） | `pubspec.yaml:64-65` | ❌ 未修 |
| P0-2 | `flame_riverpod` + `flutter_riverpod` 声明后 **全库 0 引用**，与 setState+单例的实际架构脱节 | `pubspec.yaml:38,42` | ❌ 未修 |
| P0-3 | `flutter_launcher_icons` 是构建期工具却放在 `dependencies` | `pubspec.yaml:39` | ❌ 未修 |
| P0-4 | i18n 体系 0% 落地：`MaterialApp` 无 `localizationsDelegates`/`supportedLocales`，中文硬编码遍布全部 UI 文件 | `main.dart:101-147` | ❌ 未修 |
| P0-5 | 默认 bootstrap 硬编码内网 IP + 明文 HTTP | `app_content.dart:33` | ❌ 未修 |

### 1.2 2026-08-29 评审的 18 个 P1 —— **3 修复 / 15 未修**

| # | 问题 | 位置 | 状态 |
|---|---|---|---|
| 1 | `copyWith` 传 null 清不掉旧快照 | `level_item.dart:45,59` 等 3 处 | ✅ **已修**（新增 `clearSnapshot` 哨兵标志） |
| 2 | 重复通关时 `_keyTotalCompleted` 重复 +1 | `game_repository.dart:443,542,636,692` | ❌ 未修 |
| 3 | 每日挑战月份硬编码 2026/7、2026/8 | `bing_daily_data.dart:29-30` | ❌ 未修 |
| 4 | 下载 id 用毫秒时间戳，同毫秒冲突 | `download_manager.dart:174` | ❌ 未修（`local_` 分支已加序号，`dl_` 分支未加） |
| 5 | ZIP 解压按 basename 平铺，子目录同名图互相覆盖 | `pack_content_pipeline.dart:194` | ❌ 未修 |
| 6 | JSON 持久化非原子写 | `events_content_pipeline.dart:263`、`main_content_pipeline.dart:220`、`manifest_router.dart:75`、`pack_content_pipeline.dart:263` | ❌ 未修 |
| 7 | `AppContent.init` / `GameRepository.init` 无重入保护 | `app_content.dart:50-52`、`game_repository.dart:87` | ❌ 未修 |
| 8 | 活动 map 只 upsert，远端消失不清理 | `events_content_pipeline.dart:86` | ⚠️ 部分（新增 Auto-GC 清理 disabled 项，但 `_eventsMap` 条目本身仍不删） |
| 9 | 计时器每秒整页 `setState` | `game_page.dart:169-178` | ❌ 未修 |
| 10 | `_loadHeaderColor` 主 isolate 逐像素求均值 | `game_page.dart:120-166` | ✅ **已修**（`instantiateImageCodec(targetWidth:48)` 先降采样，遍历量降到 2304 像素） |
| 11 | `hintFor` 比较器内 `new EdgeLayout` | `puzzle_engine.dart:474-482` | ❌ 未修（本轮量化为多秒级卡顿，升级见 §4.1） |
| 12 | `ZipDecoder().decodeBytes` 主 isolate 执行 | `daily_content_pipeline.dart:51`、`events_content_pipeline.dart:152`、`pack_content_pipeline.dart:134` | ❌ 未修 |
| 13 | 下载全量字节读入内存 | `content_http_client.dart:80-94` | ❌ 未修 |
| 14 | `shouldUpscale` 用 OR，极端长宽比被放大到内存爆炸 | `image_upscaler.dart:18` | ❌ 未修 |
| 15 | `main()` 串行 await 6 个 init | `main.dart:54-72` | ❌ 未修 |
| 16 | 无 CI 门禁 | 仓库根目录 | ❌ 未修（无 `.github/`） |
| 17 | `analysis_options.yaml` linter 规则全注释 | `analysis_options.yaml:11-15` | ❌ 未修 |
| 18 | 测试内联复制对话框 UI 再断言复制品 | `test/widget_test.dart:57-128` | ❌ 未修 |

### 1.3 2026-08-30 存档/续玩评审 —— 3 个 P0 全部未修，P1 部分修复

| # | 问题 | 位置 | 状态 |
|---|---|---|---|
| P0-1 | 快照难度与请求难度不匹配时 `_applyBoardState` 静默丢弃 | `jigsaw_puzzle_game.dart:1761-1768` | ⚠️ 缓解（`game_page.dart:186-209` 改为优先采纳快照 rows/cols），但引擎侧仍无任何日志外的反馈通道 |
| P0-2 | 用 `pieceCount` 反查难度有横竖歧义 | `game_repository.dart:389,514,608` | ⚠️ 缓解（新增 `difficultyKey` 优先分支），但**兜底路径仍在**，`presets` 中 24/54/96/150/216 各有横竖两项，歧义源未消除 |
| P0-3 | 保存是 fire-and-forget，退出不保证落盘 | `game_page.dart:272-304,314-379,921,1070` | ❌ 未修（本轮升级为 P0-3，见 §3.3） |
| P1-4 | 多难度并存只做一半，索引里永远 1 个难度 | `progress_store.dart:332`、`resume_helper.dart:96` | ❌ 未修，且本轮发现存储层已**主动删除**其他难度（§3.2） |
| P1-5 | 自由摆放的存档永远不会被"继续" | `resume_helper.dart:68-72` | ✅ **已修**（0% 非平凡残局可续玩） |
| P1-6 | prefs 与文件双写未收敛 | `game_repository.dart:354,495,588` | ✅ **已修**（`savedSnapshotJson: null` + `clearSnapshot: true`，大 JSON 不再落 prefs） |
| P1-7 | 无迁移，老用户升级即丢档 | `migration_service.dart` | ✅ **已修**（`MigrationService` 完整实现，老 prefs 快照迁移 + 废弃档位清理） |

> **值得肯定的闭环**：P1-5 / P1-6 / P1-7 三项（续玩判定、双写收敛、数据迁移）是真做完了，不是打补丁。存档链路的正确性相比 8-30 有实质提升。

---

## 2. 总体评价

**做得好的**

- `PuzzleEngine` 是纯静态纯函数领域层，与 Flame 渲染完全解耦，配合 `snap_algorithm_test` / `edge_layout_test` / `undo_manager_test` 有真实行为断言 —— 这是全项目最有价值的资产，不要让它腐化。
- `SnapshotStore` 的 `tmp → bak → rename` 原子写 + 失败回滚 + 损坏自愈，是本项目持久化代码里质量最高的一块。
- `PuzzleBoardState` 的 `version` + `extra` 未知键透传做到了真正的双向兼容（旧读新不丢、新读旧兼容）。
- `AppLogger` 分级分类 + 路径/URL 脱敏 + 按天滚动 + 总量回收，工程完成度高。
- `PuzzlePieceComponent` 的静态画笔常量、`MemoryCache` 的 LRU、`EngineTaskQueue` 的 Single-Flight，都是正确的实现。
- `mounted` / `context.mounted` 检查覆盖到位，`use_build_context_synchronously` 类问题基本不存在。

**主要短板**

- **算法复杂度失控**：至少 5 处 O(n²)~O(n³) 热点落在拖拽/提示/整理的高频路径上，20×20（400 片）规格下有可感知卡顿（§4.1）。
- **复制粘贴规模大**：四个 `updateXxxProgress`（约 380 行）、Migration 三段（约 85 行）、`isTrivial` 判定三份、FNV 哈希两份、`_computeLayout` 栅格遍历三份、`PuzzleDifficulty` 三个等价 switch。
- **P0 长期滞留**：5 个 P0 挂了 2 天一条未动，说明缺少「问题→责任人→门禁」的收敛机制。
- **无全局错误捕获、无 CI、linter 规则空**：质量靠人眼。

---

## 3. P0 — 发布阻塞

### P0-1 默认内容源是内网测试机 IP，正式包必然失效

- `lib/logic/content/app_content.dart:33`：`'http://192.168.1.118/data/www/game/test/manifest.json'` 作为 `defaultBootstrapUrls` 的唯一条目。
- `lib/pages/import_pack_page.dart:28-29`：两个同样的内网 IP 样本 URL 硬编码进页面。
- 另有 `content_http_client.dart` 全程无重试、无 `CancelToken`。

**后果**：所有非内网环境每次启动都要等 `connectTimeout: 8s` 超时，在线内容 100% 不可用；`import_pack_page` 的"试试样本"按钮在生产包里点下去必然失败。明文 HTTP 也构成传输风险。

**修法**：bootstrap URL 改为构建期注入（`--dart-define=CONTENT_BASE_URL=...`）并强制 HTTPS；`import_pack_page` 的样本 URL 用 `--dart-define` 或仅在 `kDebugMode` 下注入；给 `ContentHttpClient` 补 1~2 次指数退避重试。

### P0-2 通关结算写同一份 ProgressStore 记录却不 await，最佳成绩会被覆盖

- `lib/pages/game_page.dart:428`：`recordDifficultyCompletion` 是 `await` 的，内部 load→mutate→save。
- `lib/pages/game_page.dart:439 / 449 / 459 / 468`：四个 `_repo.updateXxxProgress(...)` **全部没有 await**，且这四条分支内部同样对 `ProgressStore` 做 load→mutate→save。
- `lib/data/progress_store.dart:329-330`：`updateProgress` 里 `stars: stars ?? cur.stars`、`bestTimeSeconds: bestTimeSeconds ?? cur.bestTimeSeconds` 是**直接覆盖**，不做 max/min。
- `lib/data/game_repository.dart:691`：`updateGenericProgress` 传 `bestTimeSeconds: timeSeconds`（本次耗时，未经 `min` 比较）；而主线/每日/自制三条分支（`game_repository.dart:336-340 / 479-483 / 572-576`）都做了 `min` 保护。

**后果**（两个叠加）：
1. **竞态丢更新**：step1 与 step2 并发读写同一条记录，慢的那次后写覆盖快的，`deltaStars`、`minHintsUsed`、`playCount` 可能丢失或错算。
2. **pack/event 最佳用时被改写**：`updateGenericProgress` 用本次耗时直接覆盖历史最佳，重玩一次慢的，最佳成绩就变差了。这是**用户可见的数据损坏**。

**修法**：① 四个分支统一 `await`；② 合并为一次 `ProgressStore` 写入（step1 已经写了，`updateLevelProgress` 等只需负责 prefs 侧的关卡元数据，不要再碰 ProgressStore）；③ `updateProgress` 的 `stars`/`bestTimeSeconds` 改为 `max`/`min` 语义而非覆盖。

### P0-3 保存仍是 fire-and-forget，"退出必存"不成立

- `lib/pages/game_page.dart:272-275`（`_flushSave`）、`921`（AppBar 返回）、`1070`（`PopScope`）：都只调 `_doSave()`，`_doSave()` 返回 `void`，返回的 `Future` 无人 `await`（376 行的 `fut.whenComplete` 也无人持有）。
- `lib/pages/game_page.dart:314-321`：`_isSaving == true` 时新建 `Timer(300ms, _doSave)` 重试。
- `lib/pages/game_page.dart:278-281`：`_flushSync()` 开头 `if (_isSaving) return;` —— **异步保存进行中时，同步兜底直接放弃**。
- `lib/pages/game_page.dart:294-301`：`_flushSync` 内部又 fire-and-forget 调 `_repo.updateGenericProgress(...)`（带 `// ignore: discarded_futures`）。

**后果**：AppBar 返回 / 系统返回 / 切后台三条路径都只是"发起"保存。`Navigator.pop()` 立即执行 → `dispose()` → 进程可能在 `updateGenericProgress` 落盘前结束。结果是**快照文件写进去了，但索引 `hasSnapshot=false`**，用户下次点开关卡看不到"继续"，而磁盘上躺着一个永远不会被 GC 的孤儿快照。`_flushSync` 遇到并发保存则直接静默放弃，连文件都不写。

**修法**：① `_doSave()` 改为返回 `Future<void>` 并在三条退出路径上 `await`（返回按钮可先 pop 再 await，或改用 `WillPopScope` 的异步分支）；② 删除 `_flushSync` 的 `if (_isSaving) return;`，改为先 `await` 在途保存失败的收尾；③ `_flushSync` 里的索引写入也要走同步路径（`SharedPreferences` 实例已缓存，可直接 `setString` 后不 await 落盘，至少保证进程内一致）。

### P0-4 "今日挑战"按"日"匹配，且数据源只到 2026-08

- `lib/pages/tabs/home_tab_view.dart:147`：`_repo.dailyChallenges.firstWhere((d) => d.dayNumber == now.day, ...)` —— **只比较"几号"，完全忽略年月**。
- `lib/data/bing_daily_data.dart:29-30`：`kBingDaily30Days = _generateMonthDaily(2026, 8)`、`kBingDailyJuly = _generateMonthDaily(2026, 7)`，数据源硬编码两个月。
- `lib/data/bing_daily_data.dart:79`：`imageUrl` 全部是同一个 Unsplash 占位链接。

**后果**：进入 9 月后，`now.day` 仍能在 7/8 月数据里找到匹配，首页 banner 会显示"9月3日 · 今日挑战"却指向 8 月 3 日的图；10 月后同理。整个"每日"tab 的数据在 2026-08-31 之后就是错的。

**修法**：按 `yyyyMMdd` 完整日期匹配；数据源改由当前日期动态生成（或由内容管线下发），至少保证滚动窗口不中断；`imageUrl` 字段要么接真实源，要么删掉避免误导。

### P0-5 i18n 体系零落地（与"zh-CN / en-US 双语"需求差距 100%）

- `lib/main.dart:101-147`：`MaterialApp` 未配置 `localizationsDelegates` / `supportedLocales`。
- 全库 UI 字符串硬编码中文，包括会进入存档与日志的文案（如 `game_page.dart:197` 的 `'$r x $c (${r * c}块)'`）。

**后果**：en-US 无法交付；且字符串散落在 60+ 文件里，越晚做迁移成本越高。

**修法**：先建基础设施（`l10n.yaml` + `lib/l10n/app_zh.arb` / `app_en.arb` + `gen_l10n`），不要求一次性迁完；新代码一律走 `AppLocalizations.of(context)`，存量按页面分批迁移。

---

## 4. P1 — 正确性与性能

### 4.1 性能热点（按影响排序）

| # | 位置 | 复杂度 | 实测级影响 |
|---|---|---|---|
| P1-1 | `puzzle_engine.dart:474-482` `hintFor` 排序比较器 | **O(n log n) 次全盘重建** | **最严重** |
| P1-2 | `jigsaw_puzzle_game.dart:1579-1601` `updatePieceVisibility` | **O(n³)**（边缘筛选开启时） | 高 |
| P1-3 | `puzzle_engine.dart:363-414` `_mergeAllAdjacentClusters` | 典型 O(n²)，级联合并退化 **O(n³)** | 高 |
| P1-4 | `game_page.dart:806/810/819` + `823-830` | 每次指针移动整页 `setState` + 双份 O(n) 更新 | 高 |
| P1-5 | `sound_service.dart:112/168/175-189` | 每次播放抓一次 `StackTrace.current` | 中高 |
| P1-6 | `snapshot_store.dart:153-159` | 每次自动保存全目录扫描 + 删同关其他难度 | 中高 |
| P1-7 | `game_page.dart:169-178` `game_repository.dart:443` 等 | 每秒整页重建 / 统计重复累加 | 中 |

**P1-1（重点）**：`hintFor` 的 comparator 里 `EdgeLayout(rows:, cols:, seed:)` 被构造了 2 次/比较。而 `EdgeLayout` 构造函数（`edge_layout.dart:104-142`）会**重新生成整盘拓扑**：`(rows-1)×cols + rows×(cols-1)` 个描述符，每个 4 次 RNG 调用 + 1 次对象分配。

按 20×20 = 400 片、全部未归位估算：排序比较次数 ≈ n·log₂n ≈ 3,440 次 → **6,880 次全盘重建** → 约 2,000 万次 RNG 调用 + 约 500 万次对象分配。这已经不是"卡顿"，是**点一次提示卡住数秒**。

> 修法极简：`JigsawPuzzleGame` 已有 `edgeLayout` 字段（`jigsaw_puzzle_game.dart:193`），把 `EdgeLayout` 作为参数传入 `hintFor`，comparator 内只调 `edgeLayout.edgesFor(r, c)`（O(1)）。或干脆改为"先预计算每块的 `isCorner`/`isBorder` 布尔值，再按元组排序"，不再碰 `EdgeLayout`。

**P1-2**：`updatePieceVisibility` 的结构是

```
for (p in _pieces.values)                       // × n
  _boardState.pieceById(p.id)                   // O(n) 线性扫描，见 puzzle_state.dart:192-197
  if (_borderFilterActive)
    clusterPieces = _pieces.values.where(...)    // O(n)
    clusterPieces.any((o) => ... || _boardState.pieceById(o.id).isSolved(...))  // O(n) 内再 O(n)
```

而 `updatePieceVisibility` 在每次 `handlePieceDragEnd`（1551）、`cancelPieceDrag`（1460）、`organizeTray`（1663/1704）后都会调用。400 片开启边缘筛选时，单次调用是千万级步进。

> 修法：① `PuzzleBoardState` 内建 `_byId` 索引（`Map<int, PieceState>` 惰性构建），把 `pieceById` 从 O(n) 降为 O(1)；② 预计算 `Map<int,int> clusterSizes` 与 `Map<int,List<int>> clusterMembers`，避免每次 `where`；③ 用 `Set<int> borderPieceIds` 缓存边缘块集合。

**P1-4**：`_onPointerMove` 在缩放/平移/中键拖动时每个事件都 `setState(() {})`，重建整个 `Scaffold`（AppBar + 背景 `Image.asset` + `GameWidget` 子树）；同时 `_onPointerHover`（`game_page.dart:823-830`）与 `JigsawPuzzleGame.onMouseMove`（`jigsaw_puzzle_game.dart:908-914`）**都在调 `updateHoldingPiecePosition`**，而该函数内部 `_pieces.values.where(...)` 又是一次 O(n)。

> 修法：缩放徽标改用 `ValueListenableBuilder` 局部刷新；删掉 `GamePage._onPointerHover`（Flame 侧的 `onMouseMove` 已经覆盖，两者做了同一件事）。

**P1-5**：`sound_service.dart:112` 的 `static const bool _logCaller = true;` 让每次 `play()` 都执行 `StackTrace.current.toString().split('\n')`。`StackTrace.current` 是重量级操作，而 `Sfx.snap` 在密集拼合时按 80ms 节流持续触发，且第 168 行还以 INFO 级落盘整行日志。代码注释自己写着"测试完可关"。

> 修法：`_logCaller` 改为 `kDebugMode`，或直接删除 `_caller()`；`play()` 的日志降到 `Level.FINE`。

**P1-6（同时是功能缺陷）**：`SnapshotStore.save()` 在每次成功保存后执行

```
final oldKeys = await listDifficultyKeys(cid);   // 全目录 list()
for (final k in oldKeys) { if (k != dkey) await delete(cid, k); }
```

两个问题：
1. **性能**：`listDifficultyKeys` 对整个 snapshots 目录做全量 `await for` 遍历，而 `save()` 在 800ms 防抖的自动保存里被高频调用，目录越大越慢。
2. **功能**：它把"同关多难度并存"从存储层彻底否掉了 —— 无论 `ProgressStore.snapshotKeys` 记了几个，磁盘上永远只剩最后保存的那一档。这与 8-30 评审 P1-4、以及 `ContinueDialog` 的 `SegmentedButton` 多难度 UI（`resume_helper.dart:96` 只传 1 项，已成为死代码）直接冲突。

> 修法：把清理策略改为"按 LRU / 按容量上限淘汰"，而不是"只要保存就删光其他难度"。至少应把删除动作移出 `save()` 热路径。

### 4.2 正确性缺陷

| # | 位置 | 问题 | 后果 |
|---|---|---|---|
| P1-8 | `game_repository.dart:443 / 542 / 636 / 692` | `totalCompletedLevels + 1` 无条件累加 | 重复通关同一关，累计通关数虚高，直接影响成就判定 |
| P1-9 | `snapshot_store.dart:172-181` | `saveSync` 在未初始化时把 `_snapshotsDir` **永久改写**为系统临时目录 | 一旦 `saveSync` 早于 `init()` 触发（如用户秒进秒退），后续所有快照都写进 `%TEMP%`，随系统清理丢失，且与已落盘的快照分裂 |
| P1-10 | `image_cache_manager.dart:90-101` | `getCacheKey` 不含 `quality` 参数 | 同一路径同一尺寸、不同 `quality` 的两次请求命中同一缓存键，`quality` 实际被忽略 |
| P1-11 | `image_cache_manager.dart:216` | `getThumbnailFile` 生成失败时 `return File(sourcePath)` | 调用方拿到**原图路径**塞进网格，直接解码全分辨率大图 → OOM 风险 |
| P1-12 | `game_repository.dart:292-302` | `deleteCustomPuzzle` 无引用计数直接删本地图片文件 | 同一张下载图被多个自制拼图引用时，删一个拼图会连带删掉共享文件 |
| P1-13 | `pack_content_pipeline.dart:194` | 解压按 `p.basename` 平铺写入 | `a/x.jpg` 与 `b/x.jpg` 静默互相覆盖，图包丢图 |
| P1-14 | `content_http_client.dart:80-94` | `ResponseType.bytes` 全量缓冲再落盘，无流式、无大小上限、无 `CancelToken` | 大资源包内存峰值不可控；用户离开页面无法取消下载 |
| P1-15 | `image_upscaler.dart:18` | `shortSide <= 750 \|\| longSide <= 1000` 用 OR | 4000×750 这类极端长宽比被判为"低分辨率"并放大到 8000×1500 |
| P1-16 | `download_manager.dart:174` | id = `'dl_${DateTime.now().millisecondsSinceEpoch}'` 无序号后缀 | 同毫秒两次下载 id 与文件名冲突、互相覆盖（相邻的 `local_` 分支已用 `_$i` 修过，`dl_` 漏了） |
| P1-17 | `events_content_pipeline.dart:263`、`main_content_pipeline.dart:220`、`manifest_router.dart:75`、`pack_content_pipeline.dart:263` | 直接 `writeAsString` 覆盖目标文件，非原子写 | 写入中途崩溃/断电 → 缓存 JSON 半截损坏，且 `SnapshotStore` 已经示范了正确的原子写写法，这里没复用 |
| P1-18 | `daily_content_pipeline.dart:51`、`events_content_pipeline.dart:152`、`pack_content_pipeline.dart:134` | `ZipDecoder().decodeBytes` 主 isolate 同步执行 | 大包解压期间 UI 完全卡死（`thumbnail_generator.dart` 已经用了 `compute`，这里没跟上） |
| P1-19 | `jigsaw_puzzle_game.dart:1761-1768` | `_applyBoardState` 尺寸不匹配时 `return` 且无回调 | 8-30 评审 P0-1 的另一半：引擎侧至今没有把"存档与当前难度不匹配"这件事告知 UI，用户只能看到一堆全新散落的碎片 |
| P1-20 | `home_tab_view.dart:71-76` | 标签筛选用 `l.index % 5` 伪分类 | "萌宠/风光/飞鸟/艺术/建筑"是装饰性的；且 `bird`（`%5==2`）是 `landscape`（`%5==2 \|\| %5==0`）的严格子集，分类逻辑自相矛盾 |
| P1-21 | `snapshot_store.dart:75` / `image_cache_manager.dart:97` | FNV 哈希用 `& 0xFFFFFFFFFFFFFFFF` 截断 | 在 JS/Web 平台 `&` 会退化为 **int32** 截断且乘法丢精度，碰撞概率大幅上升（原生平台是 64 位回绕，行为不同）。虽然当前 `dart:io` 依赖使 Web 不可编译，但这份代码一旦被 Web 复用就是坑 |
| P1-22 | `app_logger.dart:276 / 342 / 386` | `_rotateIfNeeded` / `_cleanupOldLogs` / `listLogFiles` 用 `listSync()` | 主线程同步列目录；`_rotateIfNeeded` 在每次 flush 时都可能触发 |
| P1-23 | `app_logger.dart:292` | `_sink?.close()` 未 `await`（第 316 行的同类调用是 await 的） | 旋转日志文件时可能丢失 sink 缓冲中的日志 |

---

## 5. P2 — 架构与可维护性

### 5.1 依赖死重（7 个声明依赖 0 引用）

交叉验证方式：遍历 `lib/` 与 `test/` 的 import 语句，统计 `package:<name>/` 命中文件数。

| 依赖 | 引用文件数 | 处理建议 |
|---|---|---|
| `flame_riverpod` | 0 | 删除（或真正落地 Riverpod） |
| `flutter_riverpod` | 0 | 删除（或真正落地 Riverpod） |
| `webview_flutter` | 0 | 删除（实际用 `flutter_inappwebview`） |
| `desktop_webview_window` | 0 | 删除 |
| `flutter_launcher_icons` | 0 | 移到 `dev_dependencies` |
| `cupertino_icons` | 0 | 删除 |
| `vector_math` | 0（经 `flame` 间接使用） | 可删，或加注释说明是间接依赖 |

> `flutter_riverpod` / `flame_riverpod` 尤其需要决策：要么删（承认架构就是 setState + 单例），要么用起来（游戏内状态、成就、经济系统都是 Riverpod 的合适场景）。当前"声明了却完全不用"是最差状态 —— 包体、分析、新人理解成本都在付，收益为零。

### 5.2 复制粘贴债务（合计约 600 行）

| # | 位置 | 重复内容 | 规模 |
|---|---|---|---|
| 1 | `game_repository.dart:316-446 / 462-544 / 555-638 / 650-697` | `updateLevelProgress` / `updateDailyProgress` / `updateCustomProgress` / `updateGenericProgress` 四个方法结构几乎完全相同（`shouldClear` 判定 + 四分支清理 + `updateProgress` 同步），差异只在 prefs key 与是否有 `stars` | **~380 行** |
| 2 | `migration_service.dart:57-84 / 87-113 / 116-142` | 主线/每日/自制三段迁移代码逐行等价 | ~85 行 |
| 3 | `game_page.dart:287 / 331` + `resume_helper.dart:68-71` | `isTrivial`（点进去即退判定）三份完全相同 | 3 处 |
| 4 | `jigsaw_puzzle_game.dart:575-611 / 613-661 / 804-827` | `estimateSlots`、`hasBalancedDistribution`、`_getTabletopScatterSlots` 三份近似栅格遍历 | ~130 行 |
| 5 | `snapshot_store.dart:71-78` vs `image_cache_manager.dart:92-98` | FNV-1a 哈希两份实现 | ~16 行 |
| 6 | `puzzle_model.dart:228-259 / 262-293 / 296-321` | `secPerPiece` / `tierIndex` / `tierLevel` 三个等价 switch | ~85 行 |
| 7 | `game_page.dart:836-840 / 849-853` | `_onPointerUp` / `_onPointerCancel` 的 isPinching 复位逻辑 | 2 处 |

> 第 1 项是最该优先处理的：四个方法的差异已经产生了真实 bug（`updateGenericProgress` 漏做 `bestTime` 的 `min` 保护，见 P0-2）。抽出一个 `_persistProgress(canonicalId, ...)` 内部函数 + 四个薄包装，能同时消灭 380 行和一类不一致 bug。

### 5.3 结构与分层

| # | 位置 | 问题 | 建议 |
|---|---|---|---|
| 1 | `resume_helper.dart:3,7` | **`lib/data/` 层 import `package:flutter/material.dart` 和 `../widgets/continue_dialog.dart`**，持有 `BuildContext` 并弹对话框 —— 数据层直接依赖 UI 层 | 把 `maybeShowResumeDialog` / `handleResumeResult` / `tryHandleResumeFlow` 挪到 `lib/widgets/` 或新建 `lib/pages/helpers/`；`data/` 只保留 `fetchResume` / `clearResume` 这些纯数据操作 |
| 2 | `jigsaw_puzzle_game.dart`（1925 行） | 单文件混合：布局计算、二分搜索散落算法、输入状态机、快照序列化、undo/redo、防丢自愈 | 拆为 layout / scatter / input / snapshot 四个协作 mixin 或类 |
| 3 | `game_page.dart`（1281 行，`build` 约 215 行） | 同上 | 拆 `_AppBar` / `_ZoomBadge` / `_OriginalImageOverlay` / `_VictoryBanner` 子组件 |
| 4 | `main_screen.dart:64,93` | 从子页面返回后 `setState(() {})` 整屏重建，是刷新 hack | 改用回调 / `ValueNotifier` 精准刷新 |
| 5 | `main_screen.dart:202-215` | `IndexedStack` 让 4 个 tab 全部在启动时构建（`HomeTabView` 首帧就要建 100 张关卡卡片） | 改用懒加载，或给 `HomeTabView` 的网格加分页/懒构建 |
| 6 | 全库 UI 文件 | 硬编码色值（`0xFF2E7D32` 在 `main_screen.dart` 一个文件出现约 20 次），与 `main.dart:96` 注释宣称的"主题内不写死任何具体色值"直接矛盾 | 提取到 `ThemeExtension` 或常量表 |
| 7 | 路由 | `Navigator.push(MaterialPageRoute(...))` 分散硬编码（`home_tab_view.dart` 一个文件就有 3 处） | 集中路由表 |
| 8 | `puzzle_model.dart:342-362` | `presets` 中 24/54/96/150/216 各有横竖两项（`6×4` 与 `4×6` 等），`pieceCount` 无法唯一确定难度 | 8-30 评审 P0-2 已要求废弃 pieceCount 反查，兜底路径（`game_repository.dart:389,514,608`）仍在 |
| 9 | `puzzle_engine.dart:16-20` vs `jigsaw_puzzle_game.dart:1127` | 注释说 "48% 是黄金手感比例"，实际 `defaultSnapRatio = 0.40`；游戏侧注释也写 `// 0.48` | 修注释或修值，二者必居其一 |

### 5.4 工程与健壮性

| # | 位置 | 问题 | 建议 |
|---|---|---|---|
| 1 | `app_logger.dart:453-454` | `void unawaited(Future<void> f) {}` 遮蔽 `dart:async` 的同名官方函数（注释写着"避免未使用 unawaited 警告"）。它在 `dart:async` 也被 import 的文件中造成命名歧义，且是 no-op —— 使 `unawaited_futures` lint 彻底失效 | 删除该声明，统一用官方 `unawaited`。**这是 8-29 评审 P2-7，仍未修** |
| 2 | `main.dart:22-76` | 无 `FlutterError.onError` / `PlatformDispatcher.instance.onError` / `runZonedGuarded`，异步异常（如 `_loadImage()` 中 `decodeFlameImage` 抛错）在 release 下静默 | 加全局错误捕获 + 上报；至少给 `_loadImage` 加 try/catch 与错误态 UI（当前解码失败会导致页面永久停在 loading） |
| 3 | `main.dart:54-72` | 6 个 init 串行 await，首帧等待时间 = 各阶段之和 | `ImageCacheManager` / `DownloadManager` / `EconomyService` / `AchievementStore` / `SoundService` 之间无依赖，用 `Future.wait` 并行；非关键项移到首帧后 |
| 4 | `main.dart:67` | 同一 `sw.elapsedMilliseconds` 同时用作 "done" 和 "total"，日志里的 total 是错的 | 单独计时 |
| 5 | `main.dart` + `lib/**` | `lib/main.dart:1` 与 `content_http_client.dart:2` 等 import `dart:io`，而仓库保留了 `web/` 目录 | 明确声明不支持 Web 并删除 `web/`，否则是误导 |
| 6 | 仓库根目录 | 无 `.github/workflows`，无 CI 门禁 | 加最简 CI：`flutter analyze --fatal-infos` + `flutter test` |
| 7 | `analysis_options.yaml:11-15` | linter 规则全部注释，只有默认 `flutter_lints` | 至少启用 `unawaited_futures`、`avoid_ignoring_return_values`、`prefer_const_constructors`、`use_build_context_synchronously`、`avoid_dynamic_calls` |
| 8 | `app_content.dart:50-52`、`game_repository.dart:87` | 单例 `init()` 无重入保护，`_isInitialized` 在 await 之后才置位 | 进入 init 立即置"初始化中"或用 `Completer` 缓存 |
| 9 | `progress_store.dart:113-129,277` | `refreshAggregatesCache()` 全量扫描 prefs 所有 key 并逐个 `jsonDecode`，且在每次 `recordDifficultyCompletion` 后调用；`getDistinctImagesWith3Star` / `getTotalStars` / `getTotalSolved` 各做一次全量扫描（N 次独立 `load()`） | 维护增量计数器，或把聚合结果缓存成单条 prefs 记录 |
| 10 | `snapshot_store.dart` / `image_cache_manager.dart` | 快照与缩略图都**没有容量上限与 LRU 淘汰**（只有 `clearAll()` 全清） | 加容量上限 + 按 `updatedAt` 淘汰；否则长期使用的磁盘占用无限增长 |
| 11 | `progress_store.dart:302-337` | `updateProgress` 是 load→mutate→save，无任何加锁或串行化；自动保存定时器与通关结算并发时会丢更新 | 加一个简单的 per-`canonicalId` 串行队列（或把 ProgressStore 的写操作串行化） |
| 12 | `puzzle_piece_component.dart:187-237` | 每片每帧执行 `clipPath` + `drawImageRect` + 4 次 `drawPath`；400 片时 GPU/CPU 压力显著 | 已归位锁定的碎片可合并进底板整图渲染（代码里已有 `hideBorders` 字段但未见启用路径）；或按可见性裁剪 |
| 13 | `puzzle_piece_component.dart:443` | `triggerSnapGlow` 用 `Future.delayed` 且不可取消（有 `isRemoved` 守卫，可接受） | 可接受，但集群合并时一次性创建 N 个 Timer，建议改用 Flame 的 `TimerComponent`/effect |
| 14 | `jigsaw_puzzle_game.dart:44-47` | `BoardGhostComponent.render` 每帧 `new Paint()`（同文件的 `TrayBackgroundComponent` 已用 static final，风格不一致） | 改为复用/缓存 |

---

## 6. 测试评估

- **覆盖分布**：24 个测试文件集中在 `logic/`（engine / geometry / content pipeline / cache / upscaler）与 `data/`（progress_store / snapshot_store / migration_service）。`PuzzleEngine` 的行为有真实断言，质量不错。
- **零覆盖区域**（未发现任何对应测试）：

  | 目录 | 未覆盖文件 |
  |---|---|
  | `lib/game/` | `jigsaw_puzzle_game.dart`（1925 行，核心交互与快照）、`puzzle_piece_component.dart` |
  | `lib/pages/` | 全部 10 个页面 + 4 个 tab（`game_page.dart` 1281 行无任何测试） |
  | `lib/widgets/` | 全部 8 个组件 |
  | `lib/services/` | `sound_service.dart`、`app_logger.dart`、`economy_service.dart`（有 `economy_service_test`）、`unlock_service.dart`（有测试）、`achievement_store.dart` |
  | `lib/logic/` | `download_manager.dart`、`image_source.dart`、`image_crop.dart`（有测试）、`rendering/`、`cache/engine_task_queue.dart` |
  | `lib/data/` | `game_repository.dart`（734 行，四个 `updateXxxProgress` 的分歧正是 bug 源头） |
  | `lib/main.dart` | 启动链路 |

- **已知假测试**：`test/widget_test.dart:57-128` 把通关对话框 UI 整段复制进测试文件重建后再断言，验证的是复制品而非真实代码，**无回归价值**（8-29 评审 P1-18，未修）。
- **最该补的 3 个测试**（投入产出比最高）：
  1. `game_repository` 四个 `updateXxxProgress` 的等价性测试 —— 直接防住 P0-2 这类"四个分支各自演化"的 bug。
  2. `SnapshotStore.save()` 的多难度保留行为测试 —— 锁住 P1-6 的修复。
  3. `PuzzleEngine.hintFor` 的耗时/复杂度回归测试 —— 锁住 P1-1。

---

## 7. 建议的行动顺序

**第一批（本轮必须完成，约 1~2 天）**
1. P0-1 内网 IP 改 `--dart-define` + HTTPS
2. P0-2 `_handleSolved` 四个分支补 `await` + `updateProgress` 改 max/min 语义
3. P0-3 保存改 `await`，删除 `_flushSync` 的 `_isSaving` 早退
4. P0-4 每日挑战按完整日期匹配 + 数据源动态化
5. P1-1 `hintFor` 复用已有 `edgeLayout`（改动约 5 行，收益最大）

**第二批（下轮，约 2~3 天）**
6. P1-2 / P1-3 给 `pieceById` 加索引、预计算 cluster 信息
7. P1-4 删掉 `_onPointerHover` 重复调用，缩放徽标改局部刷新
8. P1-5 `_logCaller` 改 `kDebugMode`
9. P1-6 `SnapshotStore.save` 移除"删同关其他难度"
10. 抽取 `_persistProgress`，消灭 380 行重复（顺带修掉同类不一致）

**第三批（技术债）**
11. 清理 7 个死依赖（先决策 Riverpod 用或删）
12. i18n 基础设施落地
13. 建 CI + 启用严格 linter
14. 全局错误捕获
15. 拆 `jigsaw_puzzle_game.dart` / `game_page.dart`

---

## 8. 附：审查方法与遗留事项

### 8.1 已执行
- 逐文件通读：`jigsaw_puzzle_game.dart`、`puzzle_piece_component.dart`、`puzzle_engine.dart`、`puzzle_state.dart`、`puzzle_model.dart`、`edge_layout.dart`、`game_repository.dart`、`progress_store.dart`、`snapshot_store.dart`、`resume_helper.dart`、`migration_service.dart`、`game_page.dart`、`main.dart`、`main_screen.dart`、`home_tab_view.dart`、`app_content.dart`、`app_logger.dart`、`sound_service.dart`、`image_cache_manager.dart`、`memory_cache.dart`、`engine_task_queue.dart`、`content_http_client.dart`、`pack_content_pipeline.dart`（部分）、`events_content_pipeline.dart`（部分）、`image_upscaler.dart`（部分）。
- 全库检索：`print(`、TODO/FIXME、空 catch、硬编码 URL、定时器、依赖引用计数、`writeAsString`/`writeAsBytes` 原子性、`ZipDecoder`/`compute`、`unawaited` 使用点、`.github` 存在性。
- 与前两轮评审（8-29 / 8-30）逐条对账，产出 §1 的闭环表。

### 8.2 未执行（需要时补）
- `online_image_picker_page.dart`（789 行，WebView 抓取链路）、`crop_puzzle_page.dart`（664 行）、`choose_difficulty_sheet.dart`（903 行）、`achievements_page.dart`、`settings_page.dart`、`import_pack_page.dart` 仅做了针对性检索，未逐行通读。
- 未做运行时 profiling（帧率、内存、启动耗时），§4.1 的复杂度结论是静态推导，建议用 DevTools 在 20×20 规格下实测确认。
- 未验证 `unawaited` 命名遮蔽的具体解析结果（是否报 ambiguous import），需等 `flutter analyze` 输出确认。

### 8.3 校验状态说明
`flutter analyze` 与 `flutter test` 在本机（Windows，冷启动）分别运行 56 分钟与 43 分钟后仍无任何输出，判定为卡在编译/锁竞争，已终止并单独重跑测试；截至报告成文时仍未产出结果。因此本报告**未附带 analyze issue 数与测试通过数**。建议后续在 CI 中固化这两个数字作为门禁基线（上一轮记录的基线是 `flutter analyze` 9 issues / `flutter test` 113/113 通过）。
