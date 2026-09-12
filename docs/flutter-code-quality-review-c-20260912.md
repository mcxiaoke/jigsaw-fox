# jigsawpuzzle Flutter 代码质量全面审查报告（第三轮独立复查）

> 审查日期：2026-09-12 13:25–15:00（GMT+8）
> 审查性质：只读审查，未修改任何项目代码
> 审查范围：`lib/` 全量（96 个 Dart 文件，约 41,733 行，含生成代码 4,465 行）、`test/`（51 个文件，12,568 行）、`integration_test/app_test.dart`、`pubspec.yaml`、`analysis_options.yaml`
> 审查方法：三路并行深度人工审查（核心逻辑层 / UI 与外围层 / 测试与数据服务层）+ `flutter analyze` 静态实证 + 关键问题原文抽查复核（6 处高等级主张全部验证属实）
> 最佳实践基准：Effective Dart、very_good_analysis 10.3.0、Flutter 官方性能指南与架构建议、flutter_test 行为断言实践、Dart pub 规范

## 文档关系说明（重要）

`docs/` 下已存在 2026-09-12 当日的相关文档：

| 文档 | 定位 | 与本报告关系 |
|---|---|---|
| `code-review-and-fix-plan-20260912.md`（v9） | 针对「图集关卡玩完后进行中记录图裂、点击无反应」根因链的定向缺陷修复计划，v8 已实施、v9 已复审收口 | 本报告不重复其已修复的定向缺陷（如 .bak 清理、冗余 HttpClient、删图路径、索引代次等），仅核对残留 |
| `flutter-code-quality-review-a-20260912.md` | 静态分析 + 指标量化导向的广度审查（B+ 评级） | 与本报告互为印证：其"25 处裸强转 / 92 处未等待 Future / 5 个巨型文件"与本轮实测（25 处 cast 脆弱点、79 处未处理 Future、5 个 >1000 行文件）方向一致 |
| `flutter-code-quality-review-b-20260912.md` | 架构债务与坏味道审查 | 同上 |

本报告为**第三轮独立复查**，焦点是：① 上午两轮审查之后仍然存在、或未被覆盖的坏味道；② 本轮新增发现的缺陷（含 2 条高等级测试假绿与写路径静默丢失）；③ 给出一份可直接落地、按收益排序的改进清单。若后续要合并修复，建议以 `code-review-and-fix-plan-20260912.md` 的 P0–P3 编号体系与本报告交叉引用。

---

## 一、总体评价与统计

**总体评价：B+（基础扎实，局部高危，可维护性债务显著）。**

- 优点：静态分析 **0 error / 0 warning**（201 条均为 info 级）；测试 51 文件全绿且断言与实现一致性普遍良好；类型纪律严格（strict-casts/raw-types/inference 全开）；数据层防御性设计（备份轮转、损坏自愈、迁移测试）属行业上游水平。
- 核心风险：**异常静默吞掉**（约 50 处空 catch 无日志）、**巨型文件/巨型 build**（5 个 >1000 行、3 个 build 超过 600 行）、**热路径算法复杂度**（吸附结算 O(n²)–O(n³)）、**写路径失败无感知**（收藏/成就数据可无感丢失）、**2 处测试名实不符**（篡改即全绿）。

### 问题统计

| 域 | 高 | 中 | 低 | 小计 |
|---|---|---|---|---|
| 核心逻辑与数据层（lib/game + lib/logic + lib/data） | 4 | 22 | 17 | 43 |
| UI 与外围层（lib/pages + lib/widgets + lib/theme 等） | 3 | 8 | 6 | 17 |
| 测试与依赖配置（test/ + integration_test + pubspec + analysis_options） | 2 | 9 | 11 | 22 |
| **合计** | **9** | **39** | **34** | **82** |

> 注：22 条中含 5 条正面确认（不列为问题，见第七章），实际问题 77 条；另有 1 条合并项（favorite_store 写失败在数据层与测试层各记一次，表中计 2、正文合并呈现）。

### 类别 Top 5

1. 异常处理与可观测性（约 50 处静默 catch + 7 处写路径静默失败）
2. 性能（热路径全表扫描 / 同步 IO / 每帧重建，与 analyze 的 50 处 `avoid_slow_async_io` 互相印证）
3. 架构与重复代码（god class、巨型 build、3+ 处 90 行级重复块、6 个同构 pipeline）
4. 异步纪律（79 处未处理 Future：`discarded_futures` 53 + `unawaited_futures` 26，集中在页面层）
5. 测试质量（假测试 2 处、隔离缺口、覆盖盲区 5 处）

---

## 二、静态分析实证（flutter analyze，2026-09-12 实测）

`flutter analyze` 输出 201 条 issue，**全部为 info 级（0 error / 0 warning）**，集中于 8 条规则：

| 规则 | 数量 | 解读 |
|---|---|---|
| discarded_futures | 53 | 丢弃的 Future，可能静默吞异步错误；页面层重灾区（game_page 9、my_center 6、online_image_picker 6） |
| avoid_slow_async_io | 50 | 使用同步 dart:io 方法（33 条在 lib/，17 条在 test/），UI 线程同步 IO 风险 |
| unawaited_futures | 26 | 未等待的 Future（`Future.delayed`/callback 内） |
| avoid_equals_and_hash_code_on_mutable_classes | 10 | 可变类覆写 `==`/`hashCode` 而未标 `@immutable`（edge_curve、edge_layout、puzzle_state、puzzle_model、crop_puzzle_page） |
| always_put_required_named_parameters_first | 3 | 命名参数排序规范 |
| unnecessary_underscores / unnecessary_import / comment_references | 5 | 杂项 |

**结论**：这些规则在 very_good_analysis 中默认是 info 而非 warning/error，累积 201 条反映"功能正确但纪律松弛"。优先级最高的两类：**79 处未处理 Future**（与异常静默互为因果）与 **50 处同步 IO**（与 UI 线程阻塞风险直接相关）。建议设立"新增代码不允许引入以上规则的 info"的 CI 门槛（`flutter analyze --fatal-infos` 或逐步清零清单）。

---

## 三、高优先级问题（9 条，建议优先处理）

### H1. [异常/可观测性] content 层约 22 处 `catch (_) {}` 静默吞异常，故障完全不可诊断

- **位置**（已逐一核实）：
  - `lib/logic/content/content_manager.dart:271、299`
  - `lib/logic/content/pipelines/main_content_pipeline.dart:329、626、631`
  - `lib/logic/content/pipelines/daily_content_pipeline.dart:152、158、291`
  - `lib/logic/content/pipelines/pack_content_pipeline.dart:136、149、177`
  - `lib/logic/content/pipelines/event_content_pipeline.dart:327、333、370、376`
  - `lib/logic/content/pipelines/collections_content_pipeline.dart:364、370、425、431`
  - `lib/logic/content/pipelines/atomic_replace.dart:103、109、140、146、155`（写盘/替换路径）
  - `lib/logic/content/models/root_manifest.dart:23`、`puzzle_event_item.dart:33`、`puzzle_collection_item.dart:44`
  - `lib/logic/content/network/content_http_client.dart:105、128、150、166`
- **问题**：下载、JSON 解析、索引构建、磁盘替换、缓存写盘等全部故障路径均无日志、无错误上报、无重试；`atomic_replace` 的 5 处位于**写盘替换**路径，替换失败后新旧数据可能处于中间态且无感知。线上内容缺失只能靠"用户看不到内容"间接推断。
- **最佳实践对照**：Effective Dart 与 Dart 惯例——空 catch 必须注释原因并至少 `log`（`catch (e, st) { log.severe(..., e, st); }`）；网络/解析失败应区分异常类型（`SocketException` vs `FormatException`），给调用方以可恢复的失败信号；Dart 语言规范警示空 catch 会掩盖 `Error`。
- **改进建议**：① 全部补 `AppLogger.content` 日志 + 异常对象；② 下载/替换路径可恢复错误（网络超时类）由 pipeline 做 1 次指数退避重试；③ 写盘替换失败必须回滚或标记"新旧共存待清理"；④ 结合 `analysis_options.yaml:27` 的放宽（见 M-低 30），恢复 `avoid_catches_without_on_clauses` 后对确实需要宽 catch 的文件局部 `// ignore` + 理由。

### H2. [性能] puzzle_engine 吸附结算热路径：单次拖放 7–9 次全表遍历/重建，最坏 O(n³) 且注释误导

- **位置**：`lib/logic/engine/puzzle_engine.dart:196`（`List.from`）、`:226/230`（全表 map）、`:254`（全表 map+copyWith）、`:306-335`（过滤+合并 remap）、`:355/363`、`_mergeAllAdjacentClusters :414-461`（`:446-450` 全表 k 循环 remap+copyWith）、`canSnapCluster :135-153`（内部 `computePlantedPieceIds :99-128` + `:147-149` 内嵌全表 for）
- **问题**：一次拖放（dragEnd → resolveSnap）链路至少 7–9 次 O(n) 全表操作，每元素新建 `PieceState`；n=225 时单次释放约 2000 个对象。`_mergeAllAdjacentClusters` 的 `while (changed)` 每轮 O(n²) 全对扫描，每次合并触发全表 remap+copyWith，最坏 O(n³)。`:445` 注释 `// In-place cluster ID remap (no new list allocation)` 字面成立但实际全表扫描并产生 n 个新对象，造成"零开销"误读（已原文抽查验证）。
- **最佳实践对照**：不可变模型（copyWith）本身是 Effective Dart 推崇的方向，但热路径应"增量更新"——只对受影响集群局部变换（常见方案：状态快照分片 + dirty-set 追踪）。
- **改进建议**：① `pieceById` 若为 O(n) 扫描，先改为 `Map<int, PieceState>` 索引（一行改动让 BFS 从 O(n²) 降为 O(n)）；② `computePlantedPieceIds` 结果在同一 resolveSnap 调用内缓存复用；③ 合并算法改候选队列（仅检查边界变更的集群）替代 while 全对扫描；④ 修正 `:445` 注释说明真实成本。

### H3. [架构/重复代码] jigsaw_puzzle_game.dart：2521 行 god class，核心结算与限位逻辑三份重复

- **位置**：`lib/game/jigsaw_puzzle_game.dart`（全长 1-2521）；吸附结算流程重复 `handlePieceDragEnd :1808-1979` vs `hint() :2373-2466`（约 90 行逐行重复）；拖拽 clamp 重复 `updateHoldingPiecePosition :1189-1228` vs `handlePieceDragEnd :1835-1875`；`_computeLayout :592-831`（约 240 行，内含 `estimateSlots`/`hasBalancedDistribution :639-729` 约 30 行重复）；`_applyBoardState :2206-2370`（约 165 行）
- **问题**：单类承载布局计算、散落、拖拽、吸附、存档/恢复、提示、边缘筛选、托盘整理等 50+ 方法。同一条"结算管线"在 dragEnd 与 hint 两处复制——修改一边漏掉另一边即产生行为分叉（吸附判定与动画不一致）。这是全项目维护风险最高的文件（用户最常改的交互核心）。
- **最佳实践对照**：Flutter 官方架构建议与 Flame 组件化实践——游戏逻辑应拆分为可独立测试的 system/component；单一类 >800 行属公认 god object 反模式。
- **改进建议**：① 抽 `SnapSettler`：把"resolveSnap → 结算 → 后置回调 → 完成判定"封装为一次 `settle()`，dragEnd 与 hint 共用；② 抽 `BoardBounds` 纯函数（输入 position + 边缘布局 → clamp 结果）供三处共用；③ 布局算法拆独立策略类（散落/表排/托盘各一）；④ 短期兜底：先把 `:639-729` 重复段合并为一个私有方法。

### H4. [异步/可恢复性] AppContent._initFuture 失败后永久缓存，进程内初始化不可重试

- **位置**：`lib/logic/content/app_content.dart:87`（`Future<void>? _initFuture`）、`:110-116`（initFromDiskCache 无条件缓存 future）
- **问题**：`initFromDiskCache` 将 future 无条件赋给 `_initFuture`。若 `_manager!.initialize`（磁盘 manifest 损坏/版本不兼容）抛错，该 failed future 被永久缓存——此后 BootGate 或任何重试入口再调用都命中同一 failed future，**进程生命周期内永远失败，只能重启 App**（已原文抽查验证）。
- **最佳实践对照**：lazy-init future 缓存惯例必须与"失败可重试"配合：失败时清除缓存并暴露错误，由上层决定重试。
- **改进建议**：
  ```dart
  Future<void> initFromDiskCache({List<String>? bootstrapUrls}) {
    final existing = _initFuture;
    if (existing != null) return existing;
    final future = _initFromDiskCache(bootstrapUrls).onError((Object e, StackTrace st) {
      _initFuture = null; // 失败清除缓存，允许重试
      return Future<void>.error(e, st);
    });
    _initFuture = future;
    return future;
  }
  ```
  同时把错误转发至 `contentUpdateNotifier` 或增设 `initError` 状态，供启动页展示"重试"。

### H5. [Widget 组织] 三个巨型 build()：my_center / daily / choose_difficulty

- **位置**：
  - `lib/pages/tabs/my_center_tab_view.dart:539-1307` —— build() 约 770 行延伸至文件尾；文件 1340 行仅 2 个顶层类
  - `lib/pages/tabs/daily_tab_view.dart:461-1074` —— build() 约 614 行直达文件尾；文件 1075 行仅 1 个顶层类
  - `lib/widgets/choose_difficulty_sheet.dart:357-971` —— build() 约 615 行，另有 `_buildPieceOption(972-)` 约 130 行；文件 1106 行
- **问题**：三个 screen 的主 build 均超 600 行，大量内联 `Container`/`Text`/`Row` 与条件分支平铺；`my_center` 的 tab 切换 case 分支也在 build 内联展开，轻微改动即触发整个页面重建。setState 波及面被放大，widget test 几乎不可能针对局部编写。
- **最佳实践对照**：Flutter 官方推荐 widget 树按功能拆分为私有 `Widget` 工厂方法或独立 StatelessWidget；build 超过百行即有拆分信号。
- **改进建议**：① 机械拆分——每个 `Column`/`Sliver` 分支提为 `Widget _buildXxx(...)` 私有方法；② 语义拆分——`daily` 的月份分组头部、`choose_difficulty` 的难度卡片提为独立 `StatelessWidget`（可复用 `const` 与局部重建）；③ 拆分后每个方法只接收 `(palette/style)` 与数据，便于后续 widget test。

### H6. [性能] UI 图片路径上的同步磁盘 IO（existsSync 在 build 路径）

- **位置**：`lib/widgets/app_cached_image.dart:85、:121、:242`（`File(localPath).existsSync()`）、`lib/widgets/lazy_level_image.dart:63`
- **问题**：全部执行在 UI 线程的 build / didUpdateWidget / image resolver 路径。网格页（home/daily/collections）一次刷新同时重建十几到几十张卡片，每张卡 1–2 次同步 stat（磁盘 IO），弱设备或换图刷新瞬间可感知掉帧。
- **最佳实践对照**：UI 线程禁止同步文件系统调用；"是否本地已下载"应来自内存状态而非每帧 stat。
- **改进建议**：① 由 `DownloadManager`/`LevelImageResolver` 维护内存中的已下载集合（下载/删除事件驱动更新），widget 只查集合；② 短期过渡：结果缓存进 State 字段，仅当 path 变化或下载事件触发时重算。

### H7. [架构] online_image_picker_page 单类巨型状态机（919 行），WebView 策略与 UI 耦合

- **位置**：`lib/pages/online_image_picker_page.dart` 全文件 919 行；build() 自 439 行起约 480 行
- **问题**：WebView 生命周期、导航栈、301/403 反爬处理、注入 JS/CSS 字符串、下载条、快捷栏 TabBar 全部塞在一个 State 与一个巨型 build 中；注入脚本字符串无法单测。
- **最佳实践对照**：UI 与"外部系统策略"应分层——WebView 行为封装为独立组件，注入脚本抽为 service 常量。
- **改进建议**：抽取 `_OnlineWebView` StatefulWidget（接收 `site`/`onDownload` 回调）；JS/CSS 注入字符串移到 `lib/data/constants/` 或 `webview_service.dart` 集中管理；下载流程接入现有 `DownloadManager`，页面只做编排。

### H8. [测试] unlock_service_test 存在"只调不验"假测试，核心解锁逻辑零行为验证

- **位置**：`test/services/unlock_service_test.dart:38-42` 与 `:44-48`（两个用例仅断言 `targetRequired` 为 1/5 常量）、`:24-36`（难度解锁仅断言恒 true）
- **问题**：`lib/services/unlock_service.dart:74-90`（checkDailyChallengeUnlock）与 `:93-112`（checkEventUnlock）存在完整的"已通关/未通关"两分支行为，测试却从不构造两种场景断言 `isUnlocked` 的真假切换。更严重的是 `unlock_service.dart:48-61` `_completedMainLevelCount()` 中 `catch (_) { return 0; }` 的静默降级路径无人测试——若 `ProgressStore.loadAllProgress()` 出错，每日/活动将**永久锁定**，而当前测试依然全绿。测试名「requires main level completion」声称检验行为，实际只验常量。
- **最佳实践对照**：flutter_test 最佳实践要求断言"真实行为（states & transitions）"而非实现常量；三 A 结构中的 Act 必须能产生两种可观察结果。
- **改进建议**：① 空库场景断言 `isUnlocked:false`、`currentProgress:0`；② 先完成 1 关/5 关后再断言 `isUnlocked:true` 与 `currentProgress` 递增；③ 为 `_completedMainLevelCount` 的异常降级加故障注入测试，防"永久锁定"回归。

### H9. [数据一致性] 收藏/成就写路径失败被静默吞掉，用户数据可无感丢失

- **位置**：
  - `lib/data/favorite_store.dart:199-205`（_saveEntry）、`:208-214`（_deleteEntry）——catch 后仅 `AppLogger.repo.warning`（已原文抽查验证）
  - `lib/services/achievement_store.dart:151-173`（4 个 `_put*` 为 `catch (_) {}` 全静默，连日志都没有）
- **问题**：收藏/成就解锁是用户显式操作：内存先改 + 异步落盘失败仅打日志 → 用户以为成功，重启后丢失，无重试、无降级。此外 `achievement_store` 的写走 Hive 原生 `_box.put`，**不在** `StorageManager._pendingWrites` 关窗防丢档队列（storage_manager.dart:83-88）——强杀/关窗瞬间成就数据直接丢失，而进度/收藏都有 P05 防护。
- **最佳实践对照**：写路径失败必须"可观测"（fail loud）：返回 `bool`/`Future<bool>` 供 UI 提示，或 rethrow 由上层统一处理；同构数据（同写 hive_ce box）应共享同一套挂起写入跟踪。
- **改进建议**：① `_saveEntry`/`_deleteEntry` 改返回 `Future<bool>`，失败时 UI 层 SnackBar 提示"保存失败请重试"；② `achievement_store` 至少补 `AppLogger.repo.warning`，并将成就写纳入 `flushPendingWrites` 可感知路径；③ 配合故障注入测试（见 T6）。

---

## 四、中优先级问题（39 条）

### 4.1 异常与可观测性（7 条）

| # | 位置 | 问题与建议 |
|---|---|---|
| M1 | `lib/data/progress_store.dart:254、267、277、279、286、288、298、314、340` | `_index!` 九处强解包依赖 init() 先行；无前置校验与错误信息。建议 `_index ?? (throw StateError('ProgressStore not initialized'))` |
| M2 | `lib/data/snapshot_store.dart:270、315` | 删除路径空 catch 无日志（另有 14 处多为可接受的容错，见 L1）。建议删除路径补 warning 日志 |
| M3 | `lib/logic/cache/local_image_locator.dart:73、111、150、164、171、210、212、228、240、243` | 12 处定位失败静默返回 null 走 fallback，图片缺失不可排查。建议至少 debug 日志 |
| M4 | `lib/logic/cache/level_image_resolver.dart:142` | 空 catch + `''` 哨兵双重静默（哨兵问题见 M12）。建议统一 nullable 结果 |
| M5 | `lib/data/game_repository.dart:385` | 快照清理错误被 `catch (_) {}` 吞掉 → 删除拼图后残留垃圾文件。建议改 warning 日志 |
| M6 | `lib/logic/content/pipelines/manifest_router.dart:41-47、:90、:103、:116-122、:136、:170` | 三级回退后返回 offline fallback，用户看到空目录而非"网络不可用"，无指标记录回退层级。建议回退时 notify，UI 显示离线模式，记录回退原因 |
| M7 | `lib/logic/download_manager.dart:316-321` | delete+rename 非原子：rename 失败残留脏文件 + 索引不一致。建议先写 `.tmp` 同目录原子 rename，失败回滚 |

### 4.2 性能（9 条）

| # | 位置 | 问题与建议 |
|---|---|---|
| M8 | `lib/data/progress_store.dart:624-659` | reconcileSnapshots 每 cid 一次同步 IO round-trip + unawaited 通知；快照变更频繁时写放大。建议批量 reconcile 或 500ms 防抖合并写 |
| M9 | `lib/game/jigsaw_puzzle_game.dart:1154-1234、:1564-1573、:1694-1731` | 拖拽热路径（鼠标移动）每帧 3-4 次 O(n) 全表过滤/迭代。建议维护 clusterId→pieces 索引，一次遍历完成包围盒+位移+优先级 |
| M10 | `lib/game/jigsaw_puzzle_game.dart:2058-2078` | organizeTray 双层嵌套 O(n²)（每碎片对全表 where 数 clusterSize），两轮共 2×O(n²)。建议先一次遍历建 `Map<String,int>` clusterSize |
| M11 | `lib/game/jigsaw_puzzle_game.dart:976-968` | _tabletopScatterSlots 64 轮随机试探，最坏 O(64×n²)。建议预排布 + 冲突消解 |
| M12 | `lib/logic/cache/level_image_resolver.dart:187`、`local_image_locator.dart:218、230` | 主关卡线性查找 + `dir.listSync()` 无索引全量扫描。建议建 key→entry 索引、listSync 改 async |
| M13 | `lib/logic/content/pipelines/main_content_pipeline.dart:84-110` | `get levels` 每次访问全量 map/filter 重建（调用频率待确认）。建议结果缓存 + 变更失效 |
| M14 | `lib/logic/content/content_manager.dart:140-165、:220-232` | fetchDailyIndexMetadata 每次冷启动无条件全量刷新。建议加 TTL（如 6h）+ forceRefresh 语义 |
| M15 | `lib/logic/engine/puzzle_engine.dart:531-544` | hintFor 每次新建 EdgeLayout，sort 比较器内重复 `edgesFor(a)`/`edgesFor(b)`（O(n log n)×2）。建议预建 edgeCounts map |
| M16 | `lib/game/jigsaw_puzzle_game.dart:231-244` | solvedCount/remainingTrayPieces/isDraggingAnyPiece getter 每处调用 O(n) 全表 where（频率待确认）。建议维护增量计数 |

### 4.3 架构与重复代码（9 条）

| # | 位置 | 问题与建议 |
|---|---|---|
| M17 | `lib/data/game_repository.dart:460-546、665-746、785-865` | 三份约 90 行"更新进度→快照收尾→通知"模板逐行重复。建议抽 `_commitProgress(...)` 私有方法共用 |
| M18 | `lib/pages/tabs/home_tab_view.dart:468-587` vs `lib/pages/tabs/collections_tab_view.dart:60-175` | `_startDownloadEvent` 约 95% 相同（差异仅下架守卫与日志前缀）。建议抽公共 `ensureEventDownloadedWithToast(context, item, {logTag})` |
| M19 | `lib/logic/content/pipelines/`（6 个文件） | main/daily/pack/event/collections/atomic_replace 各自实现缓存读/下载/解压/索引流程，同构复制 6 份。建议抽 `BaseContentPipeline<T>` 模板方法 |
| M20 | `lib/game/jigsaw_puzzle_game.dart:592-831` | `_computeLayout` 约 240 行，内含 `estimateSlots`/`hasBalancedDistribution` 约 30 行重复。短期合并私有方法，长期拆布局策略类 |
| M21 | `lib/logic/puzzle_model.dart` | DifficultyTier 的 label 映射 switch 重复两份。建议抽 `Map<DifficultyTier, String>` |
| M22 | `lib/logic/catalog_index.dart:139、176、242、277、312` 等 | 13 处硬编码字符串（'square1x1'/'6x6'/标签）与枚举重复定义。建议建常量表或直接用枚举 `name` |
| M23 | `lib/pages/tabs/my_center_tab_view.dart:493` vs `lib/logic/image_source.dart:40` | 取图管线重复实例化 ImagePicker（imageQuality: 90 双份）。建议复用 `ImageSource.pickMulti(...)` |
| M24 | `lib/services/achievement_store.dart:21-62` | key 前缀设计与防御注释优秀（正面），但注意与 M25 配合纳入写队列——此处仅列架构上下文 |
| M25 | `lib/logic/download_manager.dart:382、:207` | `_itemsNotifier` 全量 spread 重建 + where 线性查重。建议批量操作后只通知一次、建立 id 索引 |

### 4.4 可测性与依赖注入（5 条）

| # | 位置 | 问题与建议 |
|---|---|---|
| M26 | `lib/data/models/level_item.dart:46-49、:134`、`custom_puzzle_item.dart:24-26、:68`、`downloaded_image_item.dart:41-42、:50`、`progress_store.dart:724` | fromJson 裸 `as String`/`as int` 遇脏数据直接 TypeError；rows/cols 默认值两处重复；downloaded id 用 `DateTime.now()` 生成（同 JSON 两次解析得不同 id）；isNew 依赖真实时钟。建议 `(json['x'] as num?)?.toInt() ?? default`、默认值提常量、id 用内容哈希、时钟注入 |
| M27 | `lib/logic/unified_puzzle_resolver.dart:104` | 纯解析逻辑直接依赖 `FavoriteStore.instance` 全局单例。建议构造器注入 `bool Function(String) isFavorite` |
| M28 | `lib/pages/*`（23+ 处 `ProgressStore.instance`、8 处 `RecommendService.instance` 等） | 页面直连全局单例无注入；`my_center_tab_view.dart:60-68` initState 一次性注册 6 个全局 notifier，手工 removeListener 配对。建议统一 `_teardown()`；长期用 InheritedWidget/service locator 收敛 |
| M29 | `lib/logic/content/app_content.dart:87-116` 同 H4 之外 | 时钟 `DateTime.now()` 在 catalog_index:164 等 4+ 处直接调用。建议统一时钟注入（与 M26 同源修复） |
| M30 | `lib/services/sound_service.dart:268-274`、`lib/services/app_logger.dart:247-253` | 用 `WidgetsBinding.instance.runtimeType.toString().contains('Test')` 嗅探测试环境，脆弱约定。建议显式 `@visibleForTesting forceTestMode` 开关 |

### 4.5 国际化与主题一致性（3 条）

| # | 位置 | 问题与建议 |
|---|---|---|
| M31 | `lib/pages/tabs/daily_tab_view.dart:556('TODAY')、:1060`、`home_tab_view.dart:917`、`event_levels_page.dart:360`、`collection_levels_page.dart:492`、`collections_tab_view.dart:193('NEW')、:512`、`my_center_tab_view.dart:1039('By \$author')` | 7 处硬编码英文展示文案未走 l10n；'New'/'NEW' 大小写不一致重复 5 文件。建议统一 slang key（`t.badges.new` 等，大小写由样式控制），品牌名 Pixabay/Unsplash/Pexels 豁免 |
| M32 | `lib/pages/game_page.dart:79、1026、1064、1077、1146、1162、1267、1110、1187、1197、1256`；`achievements_page.dart:279`；`event_levels_page.dart:353`；`collection_levels_page.dart:485`；`collections_tab_view.dart:195、505、534`；`daily_tab_view.dart:1056`；`home_tab_view.dart:558、794、843、910`；`my_center_tab_view.dart:707、727`；`choose_difficulty_sheet.dart:37、43` | 25 处硬编码色值绕过 AppPalette；橙色 0xFFC97A2E 跨 5 文件重复，game_page 绿色系 6 处（0xFF2E7D32）深色模式将失去适配。建议新增 `palette.success/warning/newBadge/skeleton` 语义入口并收敛 |
| M33 | `lib/data/constants/puzzle_tags.dart:224-242` | kHomeTags 中文 label 硬编码，en-US 直接透传（展示路径待确认）。建议改机器 key + UI 层 l10n 映射 |

### 4.6 异步与并发（3 条）

| # | 位置 | 问题与建议 |
|---|---|---|
| M34 | `lib/data/game_repository.dart:886-912` | recordSnapStats read-modify-write 竞态：并发事件读旧值后写回覆盖增量。建议复用 `SingleFlight` 或同一 async 段内不可中断地完成读改写 |
| M35 | `lib/game/puzzle_piece_component.dart:451-455` | triggerSnapGlow 的 `Future.delayed` 380ms 回调访问 `game.edgeLayout`/`isBorderFilterActive`，关卡切换期间可能用旧 r/c 写错高亮。建议捕获关卡版本号比对或 dispose 时取消 |
| M36 | `lib/game/jigsaw_puzzle_game.dart:1622` | resetCurrentGame 用无种子 `Random()`，破坏同 seed 散落确定性（对照 :312 用 `Random(seed)`）。建议复用传入 seed，并考虑构造参数默认 `DateTime.now()`（:110）改为显式 |

### 4.7 测试与配置（3 条）

| # | 位置 | 问题与建议 |
|---|---|---|
| M37 | `integration_test/app_test.dart`（全 113 行） | 无环境变量门控；固定 pump（`pumpAndSettle(500ms)` + 每步 2×500ms）存在"空帧即绿"与动画卡死假红的非对称误报。**注**：本项目 AGENTS.md 将集成测试列为常规验证，门控属可选改进而非违约；建议至少把每步断言升级为"条件轮询等待目标 Widget 出现 + ErrorWidget 不存在"双校验，并限定 `HttpException` 过滤为类型匹配（:15-24） |
| M38 | `test/snapshot_store_test.dart:16-25` | 测试未 mock path_provider，快照实际写入全局 `%TEMP%\jigsaw_snapshots` 且 tearDown 不清理，跨进程/跨运行污染。建议 `SnapshotStore.forTest(Directory)` 注入 + tearDown 清理 |
| M39 | `pubspec.yaml:44`（flutter_launcher_icons 在 dependencies）、`:50`（`intl: any`）、`:38`（cupertino_icons 无使用）、`:67`（flutter_lints 与 very_good_analysis 并存但未被 include） | 构建期工具误放运行时依赖且无配置节；`intl: any` 无上界破坏可复现构建；cupertino_icons 冗余；flutter_lints 冗余。建议：launcher_icons 移 dev（或移除）；`intl` 按 lock 收窄（如 `^0.20.x`）；删除 cupertino_icons/flutter_lints；精简模板注释（:3-29、:75-121） |

---

## 五、低优先级问题（34 条）

| # | 位置 | 类别 | 问题与建议 |
|---|---|---|---|
| L1 | `lib/data/snapshot_store.dart:49、83、88、95、100、174、181、188、205、242、249、255、315、355、447` 空 catch；`:32/38/51` `_initialized=true` 三次赋值 | 异常 | 多数为可接受的容错（删除/备份路径除外，见 M2）；`_initialized` 收敛为末尾一次赋值 |
| L2 | `lib/data/storage_manager.dart:332、484、528、531、546、548` | 异常 | 6 处空 catch，`:546/:548` 文件操作失败无日志；补 fine/warning 日志 |
| L3 | `lib/game/jigsaw_puzzle_game.dart:342、508、548、1640、1889、2119、2337、2507` | 命名/风格 | out-param `List<double>` 返回坐标（8 处），Dart 无 out 参惯例；改用 `Vector2` 或 record |
| L4 | `lib/game/jigsaw_puzzle_game.dart:1092` | 可空性 | `_scatterAssignmentCache![id]` 强解包依赖内部不变式；改 `?[id]` + 缺失抛带上下文 StateError |
| L5 | `lib/game/jigsaw_puzzle_game.dart:1987、1994` | 性能 | updatePieceVisibility 每块重复查询边缘两次（edgesFor + isBorderPiece 内再查）；建议缓存 4 位邻接掩码 |
| L6 | `lib/game/jigsaw_puzzle_game.dart:1491-1496` | 风格 | _setZoom 的 postFrameCallback 未取消（幂等无泄漏），记录即可 |
| L7 | `lib/game/jigsaw_puzzle_game.dart:1884-1898、1923` | 性能 | hintFor/undo 全表 map+copyWith 存档，频率低可接受；与 H2 增量方案统一考虑 |
| L8 | `lib/logic/source_tag.dart:46-47` | 健壮性 | 未知 tag 静默归一 'main'，数据错误无感；catch 处 warning 日志 |
| L9 | `lib/data/models/custom_puzzle_item.dart:109-115` | i18n/健壮性 | displaySource 未知 sourceType 归并 online，掩盖数据问题；改 unknown + 兜底文案 |
| L10 | `lib/logic/cache/level_image_resolver.dart:112-162` vs `thumbnail_generator.dart:56-63` | 语义一致性 | 失败信号 `''` 哨兵 vs null 不统一；建议统一 nullable/sealed result |
| L11 | `lib/logic/cache/thumbnail_generator.dart:92` | 健壮性 | 标准比例直接返回原始字节引用（未重编码），调用方若期待 JPEG 会拿到原格式；注释/类型注明"原格式字节" |
| L12 | `lib/game/resume_helper.dart:228` | 遗留 | isCompleted 废弃参数仍被传入/签名保留；删除参数并更新调用处 |
| L13 | `lib/data/game_repository.dart:91-94` | 遗留 | `totalCompletedLevels` deprecated 恒 0；清理或标注 |
| L14 | `lib/data/game_repository.dart:243、251、259` | i18n | 示例数据 `sourcePlatform: '网络'` 中文字面量入数据层，非 zh 消费者原样读取；改机器 key |
| L15 | `lib/pages/tabs/home_tab_view.dart:32-?` kHotTagIds；`choose_difficulty_sheet.dart:188、197-221`；`achievements_page.dart:109-135`；`my_center_tab_view.dart:1253-1302` | 死码 | kHotTagIds 无引用；4 个 `_ensureXxx*` 方法靠 `// ignore: unused_element` + `print` 挂活（l10n 校验脚手架，slang 接管后应删除） |
| L16 | `lib/utils/locale_helper.dart:14-23` | 遗留 | `@Deprecated` 门面保留为兼容，仓库无引用则删除 |
| L17 | `lib/widgets/share_card_generator.dart:92-98` | 生命周期 | setState 后同帧 `toImage` 可能捕获旧帧；先 `await WidgetsBinding.instance.endOfFrame` |
| L18 | `lib/pages/achievements_page.dart:210`、`how_to_play_page.dart:81`、`settings_page.dart:85`、`my_center_tab_view.dart:839` | 性能 | 4 处非 builder ListView（静态内容可接受，不构成问题），未来扩展时切 builder |
| L19 | `test/game_layout_test.dart:2088-2091、2153-2155` | 测试断言 | 散落断言阈值直接引用生产常量，常量改小则断言同步放宽；经验阈值应以字面量+推导注释写入 |
| L20 | `test/widget_test.dart:485-486` | 测试断言 | 背景资产仅断言首元素；改全量 `containsAll` 完整性断言 |
| L21 | `test/services/unlock_service_test.dart:24-36` | 测试契约 | 难度解锁测试与实现同构（零门槛设计），命名与预期应注明"契约测试"，未来引入门槛时重建 |
| L22 | `test/new_features_test.dart`（setUpAll） | 测试隔离 | 单例跨测试共享状态，需确认每测试是否自带 reset（待确认） |
| L23 | `lib/services/sound_service.dart:91` | 随机性 | `Random()` 无种子，随机变体不可复现（当前无相关断言，待确认）；需测试时改可注入种子 |
| L24 | `test/data/game_state_migration_test.dart:34/228/248/249` 等 17 处 | 配置/风格 | analyze `avoid_slow_async_io` 在测试中 17 处：迁移测试用同步 IO 合理，可 `// ignore` + 理由 |
| L25 | `lib/logic/models/puzzle_state.dart:115、128` 等 10 处 | 模型规范 | 可变类覆写 `==`/`hashCode`（edge_curve、edge_layout、puzzle_state、puzzle_model、crop_puzzle_page）；若为调试便利，标 `@immutable` 或移入 debug 工具 |
| L26 | 全 lib/（`discarded_futures` 53 处+`unawaited_futures` 26 处） | 异步纪律 | 未处理 Future 集中在页面层；`unawaited()` 显式包装或 await，配合 CI 门槛清零 |
| L27 | `test/services/achievement_service_test.dart` 等 UI 测试 4+ 文件 | 测试组织 | 初始化五连（initTestAppStorage + GameRepository.init + LocaleService.init + setLanguage）重复；抽 `initWidgetTestApp()` 一步式 helper |
| L28 | `analysis_options.yaml:27` | lint 配置 | `avoid_catches_without_on_clauses: false` 全局放宽与静默 catch 群互为因果；建议恢复 true + 局部 ignore 并强制 catch 带日志 |
| L29 | `lib/services/app_logger.dart`（549 行） | 覆盖盲区 | 日志滚动/清理/脱敏/回填全部零测试；新增快照与参数化测试 |
| L30 | `lib/logic/content/models/*`（fromJson 相关）与 `test/logic/` | 覆盖盲区 | catalog_index/level_image_resolver 等解析容错路径覆盖不足（详见 T6 盲区清单） |
| L31 | `lib/logic/content/models/root_manifest.dart:23` 等（与 H1 同清单） | 异常 | 并入 H1，不重复计数 |
| L32 | `integration_test/app_test.dart:73-98` | 集成测试 | BackButton 兜底 pop 在根路由会把 app 退出 Navigator；改为 `fail('预期可返回，缺 BackButton')` 暴露结构变化 |
| L33 | `test/widgets/*`（`settings_page_ui_test.dart:28/73`、`victory_dialog_ui_test.dart:28/94` 等） | 异步纪律 | `unawaited_futures` 26 处中测试侧约 4 处；`tester.pumpWidget` 后未 await 的 Future 补 await/unawaited |
| L34 | `pubspec.yaml:2-5、7-19、24-29、75-121` | 配置 | flutter create 模板注释块残留（publish_to 说明、版本号注释、pub upgrade 指南、fonts 示例）；精简为项目实际配置 |

---

## 六、改进路线图（按收益/成本比排序，可直接落地）

### P0 —— 立即可做（1–2 天，全部是低风险高收益的正确性修复）

| 动作 | 涉及文件 | 收益 |
|---|---|---|
| 1. 空 catch 全部补日志（约 50 处，含 H1、H9、M1-M7 清单） | content/、data/、cache/ | 故障从"不可诊断"变为"可定位"，修复成本零风险 |
| 2. `_initFuture` 失败清除缓存（H4） | app_content.dart | 消除进程内不可恢复的启动失败 |
| 3. unlock_service_test 补两方向行为断言 + 故障注入（H8） | unlock_service_test.dart | 消除"永久锁定"回归全绿风险 |
| 4. favorite/achievement 写路径可观测（H9） | favorite_store、achievement_store | 用户数据不再无感丢失 |
| 5. `pieceById` 改 Map 索引（H2 的第 ① 步） | puzzle_state.dart/engine | 一行改动，BFS O(n²)→O(n) |

### P1 —— 一个月内（重构性改良）

| 动作 | 涉及文件 | 收益 |
|---|---|---|
| 6. `SnapSettler` + `BoardBounds` 抽取（H3 ①②） | jigsaw_puzzle_game.dart | 消除 90 行×2 重复，行为分叉风险归零 |
| 7. 三个巨型 build 机械拆分（H5） | my_center/daily/choose_difficulty | 页面可维护性、局部重建、可测试性提升 |
| 8. UI 同步 IO 改内存标志（H6） | app_cached_image、lazy_level_image | 网格页刷新掉帧消除 |
| 9. 79 处未处理 Future 清零（L26） | 页面层 22 文件 | 配合 CI `--fatal-infos`，异步错误不再静默 |
| 10. 吸附结算热量算法优化（H2 其余步骤） | puzzle_engine.dart | 大尺寸拼图拖拽/提示手感提升 |
| 11. 快照测试隔离（M38）、集成测试条件轮询（M37） | snapshot_store_test、app_test | 测试稳定性与可信度 |

### P2 —— 季度内（一致性收敛）

| 动作 | 涉及文件 |
|---|---|
| 12. 25 处硬编码色值入 AppPalette（M32） | pages/、widgets/ |
| 13. 7 处硬编码英文入 l10n（M31） | tabs/、pages/ |
| 14. 重复代码收敛：`_commitProgress`（M17）、`_startDownloadEvent`（M18）、`BaseContentPipeline`（M19） | game_repository、home/collections、pipelines/ |
| 15. pubspec 依赖整理（M39）+ 模板注释精简 | pubspec.yaml |
| 16. fromJson 防御性解析（M26）+ 时钟注入（M29） | data/models、catalog_index |
| 17. 覆盖盲区补测（L29/L30，盲区清单见 §八） | 新增 test 文件 |
| 18. `avoid_slow_async_io` 50 处逐点收敛（L24 + M12） | lib/、test/ |
| 19. 可变类 `==`/`hashCode` 标注或移除（L25） | geometry/、models/ |

### 持续 —— 工程卫生

- 新增代码门槛：空 catch 必须有日志；`unawaited()` 显式标注丢弃意图；页面不得直接 `File.existsSync`。
- CI 增加 `flutter analyze --fatal-infos`（逐条清零后启用）。
- 对改动文件 `dart format`（遵循项目约定，不做全仓库格式化）；只维护 zh-CN/en-US。

---

## 七、亮点与良好实践（建议保持，不要因重构破坏）

- **数据层防御性设计**：`snapshot_store` 原子写 + `.bak` 备份 + 损坏自愈；`storage_manager` 压缩前备份 + 恢复轮转 + `restoreTriesPerBox` 独立计数；迁移有 3 个专门测试文件。
- **渲染层工程化**：`puzzle_piece_component` 视锥剔除、3D 纸板分层、静态画笔复用、无监听器泄漏；`image_upscaler`/`thumbnail_generator` isolate 管线与流式处理正确。
- **异步原语优秀**：`single_flight.dart`、`image_crop.dart` 等纯函数/单飞语义清晰；`SoundService.dispose` 世代号作废在途回调 + `Future.wait` 释放；`AppLogger._flushToFile` 失败回填队首不丢日志。
- **测试质量基线好**：51 文件全绿；mock 方式统一（manual fake + forTest 注入，无 mockito 混用）；`initTestAppStorage` 隔离基座可靠；用例命名普遍为行为描述式；成就/经济/获胜弹窗等断言与生产实现逐行一致（已核对）。
- **lint 配置合规**：strict-casts/raw-types/inference 全开；exclude 仅生成代码；7 条放宽除 :27（见 L28）外均合理且有理由注释。

## 八、存疑点与未覆盖范围（如实声明）

**待确认（未能在本轮闭环）：**
1. `lib/logic/models/puzzle_state.dart` 的 `pieceById` 实现复杂度（H2 关键前提，若 O(n) 则 BFS 为 O(n²)）——建议先读该文件确认。
2. `solvedCount`/`reconcileSnapshots`/`main_content_pipeline.get levels` 的实际 UI 调用频率（影响 M8/M13/M16 等级）。
3. `kHomeTags` 中文 label 是否 UI 直接透传（M33）——若 UI 已本地化映射则降级。
4. `new_features_test` 组内单例是否逐个 reset（L22）。
5. `flutter_launcher_icons` 是否有独立配置脚本/CI 用法（决定移除或移 dev）。
6. `vector_math` 是否经 flame re-export 使用（决定去留）。

**未覆盖：** 真机/桌面 profile（掉帧判断基于代码路径分析）；l10n 资源文件内部一致性；game_page 深层动画 ticker 全量审计（建议单独一次 focused review）；`lib/logic/geometry/` 其余文件与 `rendering/` 目录（本轮未审）。

## 附录 A：审查方法

1. 摸底：glob 统计 lib/（96 文件）、test/（51 文件）、integration_test/（1 文件）规模，读取 pubspec/analysis_options。
2. 三路并行子审查（各自实际 Read/Grep 全部范围内文件并核实行号）：核心逻辑层 30 文件 / UI 层 33 文件 / 测试与数据层 67 文件。
3. 实证：`flutter analyze`（201 issue 全 info）；6 处高等级主张原文抽查复核（content_manager 空 catch、app_content initFuture、favorite_store 写失败、daily build 日志、engine:445 注释、analyze 规则分布）——全部属实。
4. 与当日既有审查文档（a/b/fix-plan）交叉核对，排除已修复项。

## 附录 B：关键统计锚点

- lib/ 手写代码约 37.3k 行（41,733 − 生成 l10n 4,465）；test/ 12,568 行；integration 113 行。
- 巨型文件（>1000 行）：jigsaw_puzzle_game.dart 2521、game_page.dart 1402、my_center_tab_view.dart 1340、choose_difficulty_sheet.dart 1106、daily_tab_view.dart 1075。
- lib/ analyze 分布：discarded_futures 53 / avoid_slow_async_io 33（lib 内） / unawaited_futures 26 / avoid_equals_and_hash_code 10 / 其余 25。
- 空 catch 总数（人工+lint 交叉）：约 50 处（content 22 + snapshot 16 + locator 12 + storage 6，含重叠计数）。