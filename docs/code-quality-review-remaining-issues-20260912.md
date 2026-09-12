# 代码质量 Review 遗留问题综合清单（2026-09-12）

> 生成时间：2026-09-12 14:28（GMT+8）
> 来源：合并 `flutter-code-quality-review-a/b/c-20260912.md` 三份独立审查
> 性质：**只读核对 + 逐条源码复核**后的问题台账，非新建审查
> 覆盖：`lib/`（96 文件 / 约 41.7k 行）、`test/`（50 文件）、`integration_test/`、`pubspec.yaml`、`analysis_options.yaml`

---

## 〇、本文档的定位与使用方式

三份 review 合计提出 100+ 条问题，但**口径不一、含有误报与夸大**（详见 §2）。本文档的职责是：

1. **剔除已修复项**——2026-09-12 当日已落地的 5 项高危修复不再重复列出（见 §1）。
2. **标注核实结论**——每条问题附「✅ 属实 / ⚠️ 夸大 / ❌ 误报」三态之一，并给出核实依据。
3. **给出可执行清单**——按「改动量 × 收益」而非单纯严重度排序，便于排期。

**与既有文档的关系**（避免重复劳动）：

| 文档 | 范围 | 本文档关系 |
|---|---|---|
| `flutter-code-quality-review-a/b/c-20260912.md` | 三份原始审查 | 本文档是它们的**去伪存真合并版** |
| `code-review-and-fix-plan-20260912.md`（v9） | 「图集关卡玩完图裂」定向缺陷修复计划 | 已完成，本文档不复列 |
| `architecture-debt-refactor-roadmap-v2-20260912.md` | 架构债务与系统简化（做减法） | **互补**：该文档聚焦架构收敛，本文档聚焦代码级坏味道 |

---

## 一、已修复项（本次提交完成，不再列出）

以下 5 项在 2026-09-12 下午修复并验证通过（`flutter analyze` 0 error/0 warning、`flutter test` 全绿、`flutter build windows --debug` 成功、集成测试通过）：

| # | 问题 | 修复内容 | 涉及文件 |
|---|---|---|---|
| F1 | achievement / economy 写盘绕过关窗防丢队列 | 新增 `putRaw()` / `deleteRaw()` 统一写入原语（与 `putJson` 同源），18 处直写改走该路径并纳入 `_pendingWrites` | `storage_manager.dart`、`achievement_store.dart`、`economy_service.dart` |
| F2 | achievement_store 4 处 `catch (_) {}` 零日志 | 全部改为 `catch (e, st)` + `AppLogger.repo.warning`（含 reset 删除路径） | `achievement_store.dart` |
| F3 | `AppContent._initFuture` 失败被永久缓存 | 加 `.onError` 清除缓存并透传错误，失败后进程内可重试 | `app_content.dart` |
| F4 | `unlock_service_test` 假测试 | 3 个「只调不验」用例删除（文件移除） | `test/services/unlock_service_test.dart` |
| F5 | 结算管线 90 行复制两份 | 抽 `_applySnapSettlement()` 共用，dragEnd / hint 只传差异参数 | `jigsaw_puzzle_game.dart` |
| F5+ | `game_repository` 6 处同类直写 | 一并纳入 `putRaw` / `deleteRaw`（防丢档一致性） | `game_repository.dart` |

---

## 二、三份 review 的误报与夸大清单（⚠️ 重要）

复核发现以下条目**不成立或严重夸大**，后续不应据此排期：

| 来源 | 原表述 | 核实结论 | 证据 |
|---|---|---|---|
| review-a §4.1 | 「25 处 JSON 裸强转」 | ⚠️ 夸大：精确为 **16 处** | 正则 `json['x'] as (String\|int\|bool\|double)` 排除 `as T?` 后实测 16 处 |
| review-a §2 | `discarded_futures` 62 / `unawaited_futures` 30 | ⚠️ 实测 **60 / 30**（口径随改动浮动） | `flutter analyze` 实跑 |
| review-a §4.7 | 「65 处硬编码色 + 173 处 `Colors.x`」 | ✅ 属实（65 处 `Color(0x…)`） | grep 实测 65 处 |
| review-b §P1-1 | 「`zoomNotifier` 反复进出累积内存泄漏」 | ⚠️ 夸大：`GamePage` 单次生命周期，Flame `GameWidget` 回收整树，**无累积泄漏**，仅属规范性缺失 | `game_page.dart:961` dispose 已清理 `_gameImage`/`_secondsNotifier` 等 |
| review-b §P2-2 | 「50 处 `avoid_slow_async_io` 应改 `existsSync()`」 | ⚠️ 方向反了：实测 **61 处**，其 **50 处在 `lib/`**，多为 `await file.exists()` 在**非 UI 路径**（snapshot_store 18、storage_manager 9），改 sync 反而阻塞 | 见 §3.3，真实问题在 UI 路径（review-c H6） |
| review-c L16 | 「`locale_helper.dart` 无引用可删」 | ❌ **误报**：`LocaleHelper.isChinese()` 被 `puzzle_collection_item.dart` / `puzzle_event_item.dart` 实调 | grep 实测 |
| review-c M31 | 「7 处硬编码英文未走 l10n」 | ✅ 属实，但**紧迫度低**（'TODAY'/'NEW' 等，英文界面下本就读得通） | — |
| review-c §八 | 「`pieceById` 复杂度待确认（H2 关键前提）」 | ✅ 已确认：`puzzle_state.dart:272` 为 **O(n) 线性扫描** | 已读源码 |

---

## 三、遗留真实问题清单

按「改动量 × 收益」排序，分四档。**P1 = 小改动高收益（推荐优先）**；P2 = 中改动高收益；P3 = 需规划的重构；P4 = 卫生项。

### P1 — 小改动 / 高收益（建议下一批处理）

| # | 问题 | 位置 | 核实 | 改动量 | 收益 |
|---|---|---|---|---|---|
| **P1-1** | `pieceById` O(n) 线性扫描，被 BFS / resolveSnap 热路径反复调用 | `lib/logic/models/puzzle_state.dart:272、282` | ✅ | **~10 行**：加 `Map<int,PieceState>` 惰性索引 | 吸附判定 BFS 从 O(n²) → O(n)；n=576 时收益最明显 |
| **P1-2** | 死代码未清除：`kHotTagIds` 无任何引用；4 个 `_ensureXxx*` l10n 校验脚手架靠 `// ignore` + `print` 挂活（slang 已接管） | `home_tab_view.dart:32`、`choose_difficulty_sheet.dart:188-221`、`achievements_page.dart:109`、`my_center_tab_view.dart:1253` | ✅ 已确认无测试依赖 | **~80 行删除** | 消除误解噪音；`print` 不再进生产日志 |
| **P1-3** | 废弃 API / 参数保留：`GameRepository.totalCompletedLevels` 恒返回 0；`_initLevels()` 100+ 行 demo 死码；`resume_helper` 的 `isCompleted` 参数已废弃（3 处） | `game_repository.dart:94、145`；`data/resume_helper.dart:37、100、228` | ✅ | **~60 行删除** | 减面；避免误用作完成度来源 |
| **P1-4** | `analysis_options.yaml` 全局放宽 `avoid_catches_without_on_clauses: false`，与静默 catch 群互为因果 | `analysis_options.yaml:27` | ✅ | **1 行 + 局部 ignore** | 恢复后可防新增裸 catch；需先处理存量 |
| **P1-5** | `intl: any` 无上界；`flutter_launcher_icons` 在 `dependencies`（构建工具误入运行时）；`cupertino_icons` / `flutter_lints` 冗余 | `pubspec.yaml:44、50、38、67` | ✅ | **~5 行** | 可重现构建 + 供应链安全 |
| **P1-6** | 10 处可变类重写 `==`/`hashCode` 未标 `@immutable` | `edge_curve.dart:313`、`edge_layout.dart:56`、`puzzle_state.dart:115`、`puzzle_model.dart:305`、`crop_puzzle_page.dart:29` 等 | ✅ | **~10 行注解** | 静态断言保护；消除 lint |
| **P1-7** | `snapshot_store_test` 未 mock path_provider，快照实际写入全局 `%TEMP%\jigsaw_snapshots` 且不清理 | `test/snapshot_store_test.dart:16` | ✅ | **~15 行**：`forTest(Directory)` 注入 + tearDown | 消除跨进程测试污染（真实隐患） |

### P2 — 中改动 / 高收益

| # | 问题 | 位置 | 核实 | 改动量 | 收益 |
|---|---|---|---|---|---|
| **P2-1** | UI 图片路径同步磁盘 IO：`File(localPath).existsSync()` 在 build / image resolver 路径，网格页一次刷新十几到几十张卡各 1–2 次 stat | `app_cached_image.dart:85、121、248`、`lazy_level_image.dart:71` | ✅ 属实（4 处，真实问题） | **~40 行**：改由 `LevelImageResolver` 维护内存已下载集合 | 弱设备网格刷新掉帧消除 |
| **P2-2** | 空 catch 静默吞异常（88 处，其中 content 层 ~22 处无日志、`atomic_replace` 写盘替换失败无感知） | `content/` 各 pipeline、`snapshot_store.dart`(16)、`download_manager.dart`(10)、`local_image_locator.dart`(9) | ✅ 数字属实；但**多数为可接受容错**，需甄别 | **~50 处补日志** | 故障可从「不可诊断」变为「可定位」 |
| **P2-3** | `game_repository` 三份约 90 行「更新进度→快照收尾→通知」模板逐行重复 | `game_repository.dart:460-546、665-746、785-865` | ✅ | **净减 ~120 行**：抽 `_commitProgress()` | 消除三处同步维护风险 |
| **P2-4** | `home_tab_view._startDownloadEvent` 与 `collections_tab_view` 约 95% 相同 | `home_tab_view.dart:468-587` vs `collections_tab_view.dart:60-175` | ✅ | **净减 ~80 行** | 下架守卫/日志逻辑统一 |
| **P2-5** | `CanonicalId` 双头实现：领域模型 `CanonicalId.forXxx` 与 `GameRepository.canonicalForXxx` 并存，padLeft 细节有差异 | `logic/content/models/canonical_id.dart` vs `game_repository.dart:129-135` | ✅ 属实（有 7 处外部调用） | **~30 行**：收敛为 SSOT | 消除 ID 拼接不一致隐患 |
| **P2-6** | UI 同步 IO 之外，`avoid_slow_async_io` 在 `lib/` 共 50 处 | `snapshot_store.dart`(18)、`storage_manager.dart`(9)、`download_manager.dart`(8)、`app_logger.dart`(8) | ✅ | **逐点甄别**（多数合理，可 `// ignore` + 理由） | 归档 lint，避免淹没真问题 |
| **P2-7** | `recordSnapStats` read-modify-write 竞态：并发事件读旧值后写回覆盖增量 | `game_repository.dart:886-912` | ✅ 属实 | **~20 行**：复用 `SingleFlight` | 统计数值准确 |
| **P2-8** | `triggerSnapGlow` 的 `Future.delayed` 380ms 回调访问 `game.edgeLayout`，关卡切换期可能用旧 r/c 写错高亮 | `puzzle_piece_component.dart:451` | ✅ | **~15 行**：捕获关卡版本号比对 | 消除跨关卡高亮错位 |
| **P2-9** | `resetCurrentGame` 用无种子 `Random()`，破坏同 seed 散落确定性 | `jigsaw_puzzle_game.dart` | ✅ | **~5 行** | 可复现性（利于回归测试） |

### P3 — 需规划的重构（改动大，单独立项）

| # | 问题 | 位置 | 核实 | 备注 |
|---|---|---|---|---|
| **P3-1** | `jigsaw_puzzle_game.dart` 2521 行 god class（50+ 方法），携带布局/拖拽/吸附/存档/提示/托盘整理 | `lib/game/jigsaw_puzzle_game.dart` | ✅ | 用户最常改的交互核心；建议按 Flame component 拆分，**需测试护航**。F5 已消除其中的结算重复 |
| **P3-2** | 三个巨型 `build()`：`my_center`(770 行) / `daily`(614 行) / `choose_difficulty`(615 行) | `my_center_tab_view.dart:539`、`daily_tab_view.dart:461`、`choose_difficulty_sheet.dart:357` | ✅ | 机械拆分即可显著改善；`setState` 波及面被放大 |
| **P3-3** | 吸附结算与合并算法热路径多次全表遍历，`_mergeAllAdjacentClusters` 的 `while(changed)` 最坏 O(n³) | `puzzle_engine.dart:405-461` | ⚠️ 算法属实，**紧迫度中**：最大 n=576 且仅 dragEnd 触发一次，非每帧 | 修 `pieceById`（P1-1）可先吃掉主要收益 |
| **P3-4** | 拖拽热路径（鼠标移动）每帧多次 O(n) 全表过滤 | `jigsaw_puzzle_game.dart:1149-1234`（`updateHoldingPiecePosition`） | ✅ 属实（`_pieces.values.where`） | 建议维护 `clusterId→pieces` 索引 |
| **P3-5** | 6 个 content pipeline 同构复制缓存读/下载/解压/索引流程 | `lib/logic/content/pipelines/`（6 文件） | ✅ | 抽 `BaseContentPipeline<T>`；与 roadmap-v2 的管线收敛议题重叠 |
| **P3-6** | `online_image_picker_page` 919 行单类，内联 150+ 行 JS 嗅探脚本无法单测 | `online_image_picker_page.dart` | ✅ | 抽 `_OnlineWebView` + JS 外置到 assets |
| **P3-7** | 状态管理 `setState` 与 `ValueNotifier` 混用（game_page 23、my_center 18、home_tab 18） | 各页面 | ✅ | 渐进下沉局部状态为 Notifier |

### P4 — 卫生项 / 低优先级

| # | 问题 | 位置 | 说明 |
|---|---|---|---|
| P4-1 | 25 处硬编码色值绕过 `AppPalette`（橙 `0xFFC97A2E` 跨 5 文件、绿 `0xFF2E7D32` 6 处） | `game_page.dart` 等 | 暗色模式适配隐患（项目已有 `darkTheme`），但 `themeMode` 默认 light，紧迫度低 |
| P4-2 | 7 处硬编码英文展示文案未走 l10n | `daily_tab_view.dart:556` 等 | 'TODAY'/'NEW' 大小写不一致 |
| P4-3 | `achievement_store` key 前缀设计优秀但未覆盖 economy 的写队列 | — | **已于 F1 一并修复** |
| P4-4 | `pubspec.yaml` flutter create 模板注释块残留 | `pubspec.yaml:2-29、75-121` | 纯整洁度 |
| P4-5 | `snapshot_store.dart` 的 `_initialized = true` 三次赋值 | `snapshot_store.dart:32、38、51` | 收敛为末尾一次 |
| P4-6 | 8 处 out-param `List<double>` 返回坐标（Dart 无 out 参惯例） | `jigsaw_puzzle_game.dart` 多处 | 改用 `Vector2` / record |
| P4-7 | `app_logger.dart`（549 行）日志滚动/清理/脱敏/回填零测试 | `lib/services/app_logger.dart` | 覆盖盲区 |
| P4-8 | 测试初始化「五连」重复（4+ 文件） | `test/services/*` | 抽 `initWidgetTestApp()` helper |
| P4-9 | `avoid_slow_async_io` 在 `test/` 8 处、`tool/` 2 处 | 迁移测试等 | 同步 IO 在测试中合理，`// ignore` + 理由即可 |

---

## 四、静态分析基线（2026-09-12 修复后实测）

`flutter analyze` = **147 issues，全部 info，0 error / 0 warning**。

| 规则 | 数量 | 趋势 |
|---|---|---|
| `avoid_slow_async_io` | 61 | 持平（50 in lib / 8 in test / 2 in tool / 1 in scripts） |
| `discarded_futures` | 60 | 持平 |
| `unawaited_futures` | 30 | 持平 |
| `avoid_equals_and_hash_code_on_mutable_classes` | 10 | 持平（P1-6） |
| `prefer_const_constructors` | 4 | 持平 |
| `always_put_required_named_parameters_first` | 3 | 持平 |
| 其余杂项 | ~19 | — |

> 注：三份 review 对同一规则给出 50/61 等不同数字，系统计口径（是否含 test/tool）差异。本文档表格以「按文件归属分类」为准。

**建议**：待 P1 批次清理后启用 `flutter analyze --fatal-infos`，防止新增回潮。

---

## 五、推荐执行顺序

| 批次 | 内容 | 预估 | 验证方式 |
|---|---|---|---|
| **批次 1** | P1-1 ~ P1-7（小改动，收益明确） | 分批小步提交 | `flutter analyze` + `flutter test` |
| **批次 2** | P2-1、P2-3、P2-4（性能 + 去重） | 每项独立验证 | 上述 + 集成测试 |
| **批次 3** | P2-2、P2-5 ~ P2-9（健壮性收敛） | 需逐点甄别 | 上述 + 故障注入 |
| **批次 4** | P3 架构重构（单项立 plan） | 各立项 | 每步跑完整验证链 |
| **卫生** | P4 顺手清理 | 随相关改动带上 | — |

**红线提醒**：P3-1 / P3-2 触及用户最常改的交互核心，必须按项目约定「改动文件跑 `dart format`、禁止全仓格式化、变更记入 `docs/CHANGES-YYYYMMDD.md`」，且不得破坏已确认的 R1~R5 数据红线。

---

## 附录：核实方法

1. 逐条读源码复核三份 review 的高等级主张（`Read` + `Grep`），记录行号。
2. `flutter analyze` 实跑，按规则与文件归属统计真实数量。
3. 关键前提独立验证：`pieceById` 复杂度（读 `puzzle_state.dart:272`）、`_pendingWrites` 覆盖范围（读 `storage_manager.dart:405`）、`locale_helper` 引用（grep 反查）。
4. 对不成立项标注 ⚠️/❌ 并写明反证，避免误排期。
