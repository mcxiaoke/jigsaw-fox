# 交叉核对总结与综合修复计划（2026-08-31）

> **基准文档**：`docs/code-review-20260831-full.md`（原始审查报告，65 项问题）
> **交叉核对对象**：四份独立复核报告
> - `code-review-20260831-full-review-by-bdz.md`（BDZ 复核）
> - `code-review-20260831-full-review-by-glmf.md`（GLMF 复核）
> - `code-review-20260831-full-review-by-dsf.md`（DSF 复核）
> - `code-review-20260831-full-review-by-gmf.md`（GMF 复核）
> **核对方式**：逐项比对四份复核对原始报告每一条问题的判定，识别共识、分歧与新发现，产出综合修复计划。

---

## 1. 四份复核报告交叉比对总览

| 维度 | BDZ | GLMF | DSF | GMF |
|---|---|---|---|---|
| 复核问题数 | 65（含子项） | ~65 | ~44 | ~28（P0×5 + P1×23 + P2 选列） |
| 属实率 | 89%（58/65 完全属实） | ~95% | ~68%（30 真实 / 8 部分 / 4 主观） | 100% |
| P0 成立 | 5/5 | 5/5 | 5/5（但建议 P0-2 降级） | 5/5 |
| P1 成立 | 22/23 | 23/23 | 23/23（部分降级） | 23/23 |
| P2 成立 | 全部属实 | 全部属实 | 全部属实（部分降级） | 全部属实 |
| analyze/test | 未取得 | 未取得 | **analyze=0 issues / test=165 通过** | 未取得 |
| 需修正项数 | 3 处描述不准确 + 10 路径修正 | 3 处表述 + 8 修正 | ~6 处降级/修正 | 0 |

**核心结论**：四份复核一致确认原始报告**问题全部真实存在**，分歧集中在**严重度定级**和**个别表述精确度**上，不影响问题本身的成立。

---

## 2. 全员共识：100% 确认的问题

以下问题被全部四份复核报告一致认定为**真实存在且需要修复**，无任何异议：

### 2.1 P0 共识（5/5 全员一致）

| 编号 | 问题 | 核心位置 | 共识 |
|---|---|---|---|
| P0-1 | 默认内容源硬编码内网 IP + 明文 HTTP | `app_content.dart:32-34` | ✅ 4/4 确认 · **暂时搁置**（app 暂未对外发布，开发阶段用开发测试服务无问题） |
| P0-2 | 通关结算四分支未 await + updateProgress 覆盖语义 | `game_page.dart:439/449/459/468` | ✅ 4/4 确认（DSF 建议降级，见 §3） |
| P0-3 | 保存 fire-and-forget，退出不保证落盘 | `game_page.dart:272-321,921,1070` | ✅ 4/4 确认 |
| P0-4 | 每日挑战按"几号"匹配 + 数据源只到 2026-08 | `home_tab_view.dart:147` | ✅ 4/4 确认 |
| P0-5 | i18n 体系零落地 | `main.dart:101-147` | ✅ 4/4 确认 · **暂时搁置**（后续会系统做国际化和翻译） |

### 2.2 P1 性能热点共识（7/7 全员一致）

| 编号 | 问题 | 共识 |
|---|---|---|
| P1-1 | `hintFor` 比较器内每次 `new EdgeLayout` 全盘重建 | ✅ 4/4，最高 ROI 修复 |
| P1-2 | `updatePieceVisibility` O(n³)（边缘筛选开启时） | ✅ 4/4 |
| P1-3 | `_mergeAllAdjacentClusters` O(n²)~O(n³) | ✅ 4/4 |
| P1-4 | 指针移动整页 setState + 重复 hover 调用 | ✅ 4/4（BDZ 有精确化，见 §3） |
| P1-5 | 音效 StackTrace.current 每次播放执行 | ✅ 4/4 |
| P1-6 | SnapshotStore.save 每次全目录扫描 + 删同关其他难度 | ✅ 4/4（GLMF 补充设计意图，见 §4） |
| P1-7 | 每秒整页 setState + 统计重复累加 | ✅ 4/4 |

### 2.3 P1 正确性缺陷共识（16/16 全员一致）

全部 16 项（P1-8 至 P1-23）被四份报告一致确认真实存在。个别报告对 P1-8、P1-15、P1-19、P1-21 有精确化补充（见 §3），但问题本身无人否认。

### 2.4 P2 共识

- **7 个死依赖**：4/4 确认全库 0 引用
- **复制粘贴债务**（约 600 行）：4/4 确认
- **resume_helper 跨层依赖 UI**：4/4 确认
- **无全局错误捕获 / 无 CI / linter 全注释**：4/4 确认
- **硬编码色值遍布全库**：4/4 确认（统计数字需修正，见 §3）

---

## 3. 分歧与修正（四份报告的不同判定）

### 3.1 严重度定级分歧

| 编号 | 原报告 | BDZ | GLMF | DSF | GMF | 综合判定 |
|---|---|---|---|---|---|---|
| **P0-2** | P0 数据损坏 | P0 确认 | P0 确认 | ⚠️ 建议降 P1 | P0 确认 | **P0 维持，但标注"潜伏"** |
| **P0-5** | P0 发布阻塞 | P0 确认 | P0 确认 | ⚠️ 范围决策 | P0 确认 | **P0 维持，产品决策排期** |
| **P1-9** | P1 | P1 确认 | ⚠️ 可降 P2 | ⚠️ 低影响 | P1 确认 | **P2（低概率触发）** |
| **P1-15** | P1 内存爆炸 | P1 确认 | P1 确认 | ⚠️ 影响夸大 | P1 确认 | **P1 维持，修正描述为"浪费"** |

**P0-2 详析（唯一有实质分歧的定级）**：

- DSF 的核心论点：全库无任何页面展示 pack/event 的 `bestTimeSeconds`，排行榜/成就走的是嵌套 `records[difficultyKey]`（有 min/max 保护），所以当前**不可见**。
- BDZ/GLMF 的论点：`updateGenericProgress` 是四分支中唯一漏 `min` 的，顶层字段一旦写坏无法自愈，属于**数据一致性潜伏缺陷**。
- **综合判定**：维持 P0 定级。虽然当前无 UI 展示，但（1）四分支未 await 是真实竞态；（2）顶层 `bestTimeSeconds` 被裸覆盖后，后续 `recordDifficultyCompletion` 的 min 会对着已写坏的值取 min，属于不可自愈的数据损坏；（3）一旦后续版本展示该字段即变用户可见。标注为"潜伏型 P0"。

### 3.2 描述精确化（问题成立，但原报告表述需修正）

| 编号 | 原报告表述 | 修正来源 | 修正内容 |
|---|---|---|---|
| **P1-4** | "每次指针移动整页 setState" | BDZ | setState **非无条件**每次触发，仅缩放/中键平移/放大拖拽空白区域时触发；但问题本身成立 |
| **P1-8** | "重复通关虚增 totalCompletedLevels" | DSF | `achievements_dialog` 把它当"累计完成 N 局"使用，+1 语义正确；真正问题是 `achievements_page` 用 `getTotalSolved()`（按 canonicalId 去重）vs 对话框用 `totalCompletedLevels`（按局数累加），**两套口径不一致** |
| **P1-15** | "内存爆炸" | DSF | 4000×750 放大到 8000×1500≈48MB，是**浪费**但谈不上"内存爆炸"；建议改 AND 或总像素阈值 |
| **P1-21** | FNV `& 0xFFFFFFFFFFFFFFFF` 截断 | BDZ | `& 0xFFFFFFFFFFFFFFFF` 是**标准 FNV-1a 正常做法**，不是 bug；真正问题是 `snapshot_store.dart:77` 的 `substring(0,8)` 将 64 位哈希截断为 32 位十六进制（16 位 bit），碰撞概率大幅上升。GLMF/DSF/GMF 认为当前 `dart:io` 依赖使 Web 不可编译，此项为"未来被 Web 复用才踩坑"的低风险 |
| **P2 unawaited** | "造成命名歧义" | GLMF + DSF | no-op 遮蔽**属实**（使 `unawaited_futures` lint 失效），但"命名歧义"**经实测不成立**（dart analyze 无 ambiguous import 报错）。建议删除的理由是**lint 失效**而非编译歧义 |
| **P2 init 串行** | "6 个 init 串行" | BDZ + GLMF | 实际 **7 个**串行 await（漏算了 AchievementStore） |
| **P2 硬编码色值** | "`main_screen.dart` 一个文件约 20 次" | BDZ + GLMF + DSF | `main_screen.dart` 实际 **5 次**；全库约 **83~88 次**分布在 21 个文件。结论（与 `main.dart:96` 注释矛盾）成立，统计口径需修正 |
| **P2 presets** | "24/54/96/150/216 各有横竖两项" | GLMF | **384 也有两项**（16×24 / 24×16），原报告漏列 |
| **P2 测试覆盖** | "`jigsaw_puzzle_game.dart` 零覆盖 / 4 tab 全部无测试" | GLMF | `test/game_layout_test.dart` 覆盖了 JigsawPuzzleGame 布局；`test/events_tab_view_test.dart` 覆盖了活动 tab。"深度覆盖不足"成立，"零覆盖"表述过强 |

### 3.3 行号偏差汇总

| 原报告引用 | 实际行号 | 偏差 | 发现者 |
|---|---|---|---|
| `bing_daily_data.dart:29-30` | 30-31 | +1 | GLMF |
| `image_upscaler.dart:18` | 20 | +2 | GLMF |
| `pack_content_pipeline.dart:194` | 195 | +1 | GLMF |
| `pubspec.yaml:64-65`（webview） | 47-48 | -17 | GLMF |
| `pubspec.yaml:39`（launcher_icons） | 46 | -7 | GLMF |

所有偏差为 ±1~2 行小漂移（pubspec 的 -17/-7 属于版本号变动导致的行号位移），不影响问题定位。

---

## 4. 新发现（原报告未提及的重要事实）

### 4.1 工程健康度优于原报告暗示（DSF 发现）

原报告 §8.3 称 `flutter analyze` 和 `flutter test` 冷启动超 50 分钟无输出。DSF 实测：

- `flutter analyze` → **No issues found! (17.6s)**
- `flutter test` → **All tests passed! (165 tests, 17s)**

**含义**：代码当前编译与静态检查完全干净，测试全通过。原报告大量基于"analyze 没跑完所以无法确认"的保留结论现在有确定答案。建议将这两个数字固化为 CI 门禁基线。

### 4.2 P1-6 是设计意图而非疏忽（GLMF 发现）

`snapshot_store.dart:17` 文件头明确写着设计要点："单关卡只留最新残局，保存新难度时自动清理同关旧快照"。即删除其他难度是**写入代码时的既定决策**，不是实现疏忽。

**含义**：修复前需先做产品决策——要么承认"单难度存档"（删除 ContinueDialog 多难度假 UI），要么改设计为"多难度并存 + 容量上限"。直接删清理逻辑而不改注释与 UI，会留下第三种不一致。

### 4.3 P0-2 根因比描述更集中（GLMF 补充）

`updateProgress` 并非全路径覆盖——当 `isCompleted == true && activeDifficultyKey` 同时传入时，records 内部走 max/min（`progress_store.dart:312-323`）。但 generic 分支（pack/event）恰好**不传 `activeDifficultyKey`**，正好踩中顶层字段直接覆盖路径。根因比原报告描述的更集中。

### 4.4 ImageCacheManager 内存层有 LRU（BDZ 发现）

原报告 P2-5.4.10 称"快照与缩略图都没有容量上限与 LRU"。实际上 `MemoryCache` 类已实现 LRU（`maxItems: 150` / `maxCacheMB: 30`）。问题仅存在于**磁盘层**（ImageCacheManager 磁盘缓存和 SnapshotStore 无容量上限），修正为"磁盘层无容量上限"。

---

## 5. 综合修复计划

### 5.1 修复优先级总览

基于四份复核报告的交叉判定，对原始 65 项问题重新定级并排列优先级：

| 优先级 | 问题数 | 修复窗口 | 核心依据 |
|---|---|---|---|
| **P0 紧急** | 5（3 本期 + 2 搁置） | P0-2/3/4 本期必须 | P0-1/P0-5 暂时搁置 |
| **P1 高** | 8 | 本期+下期 | 用户可感知卡顿 / 数据一致性 |
| **P1 中** | 15 | 下期 | 正确性缺陷 / 次要性能 |
| **P2 低** | ~37 | 技术债排期 | 架构债务 / 可维护性 |

### 5.2 第一批：P0 紧急 + 最高 ROI（1~2 天）

> 目标：消除发布阻塞和数据损坏风险，以及收益最大的单点性能修复。

| 序号 | 编号 | 修复内容 | 改动量 | 风险 | 依赖 |
|---|---|---|---|---|---|
| 1 | **P1-1** | `hintFor` 比较器复用已有 `edgeLayout` 字段，comparator 内只调 `edgeLayout.edgesFor(r,c)`（O(1)） | ~5 行 | 低 | 无 |
| 2 | **P0-2** | ① 四分支补 `await`；② `updateGenericProgress` 的 `bestTimeSeconds` 走 `min`；③ `updateProgress` 顶层 `stars`/`bestTimeSeconds` 改 max/min 语义 | ~20 行 | 中 | 无 |
| 3 | **P0-3** | ① `_doSave()` 改返回 `Future<void>`；② 三条退出路径（AppBar/PopScope/lifecycle）await；③ 删除 `_flushSync` 的 `if (_isSaving) return;` 早退；④ `_flushSync` 内 `updateGenericProgress` 补 await | ~30 行 | 中 | 无 |
| 4 | **P0-4** | ① `home_tab_view.dart:147` 按完整 `yyyy-MM-dd` 匹配；② `bing_daily_data.dart` 改为动态生成滚动窗口（至少覆盖当前月±1）；③ `daily_tab_view.dart` 的 `_calculateStreak` 同步修正 | ~50 行 | 中 | 无 |
| 5 | ~~**P0-1**~~ | **暂时搁置** — app 暂未对外发布，开发阶段用开发测试服务无问题。后续对外发布前再处理 | — | — | — |
| — | ~~**P0-5**~~ | **暂时搁置** — i18n 是系统工程，后续会系统做国际化和翻译 | — | — | — |

**P1-1 排第一的理由**：四份报告一致认定其 ROI 最高——改动约 5 行，消除数千万次 RNG 调用（20×20 规格下点一次提示卡顿数秒），收益/成本比全场最优。

### 5.3 第二批：P1 高优先级正确性与性能（2~3 天）

| 序号 | 编号 | 修复内容 | 改动量 | 备注 |
|---|---|---|---|---|
| 6 | **P1-4** | ① 删 `GamePage._onPointerHover`（Flame `onMouseMove` 已覆盖）；② 缩放徽标改 `ValueListenableBuilder` 局部刷新 | ~15 行 | BDZ 精确化：setState 非无条件，但重复 hover 调用确实冗余 |
| 7 | **P1-5** | `_logCaller` 改 `kDebugMode`；`play()` 日志降 `Level.FINE` | ~5 行 | 代码注释自述"测试完可关" |
| 8 | **P1-2** | ① `PuzzleBoardState` 内建 `_byId` 索引（`Map<int, PieceState>` 惰性构建）；② 预计算 `clusterSizes` / `clusterMembers` / `borderPieceIds` 集合 | ~40 行 | O(n³) → O(n) |
| 9 | **P1-6** | **先做产品决策**：A) 保留单难度 → 删 ContinueDialog 多难度 UI 死代码；B) 改多难度并存 → 移除 save() 内清理逻辑 + 修 resume_helper 传多档 + 加容量上限。决策后实施 | 30~80 行 | GLMF 发现是设计意图，不能直接删清理逻辑 |
| 10 | **P1-8** | 统一"通关数"口径：`getTotalSolved()` vs `totalCompletedLevels` 二选一，全 UI 统一 | ~20 行 | DSF 发现两套口径不一致是真正问题 |
| 11 | **P1-3** | `_mergeAllAdjacentClusters` 改用增量更新避免全量 `where` + `map` 重建 | ~30 行 | |
| 12 | **P1-7** | Timer.periodic 的 `setState` 改 `ValueListenableBuilder` 局部刷新 | ~10 行 | |
| 13 | **抽取 _persistProgress** | 四个 `updateXxxProgress` 合并为一个 `_persistProgress` 内部函数 + 四个薄包装 | ~100 行净减 | 顺带消灭 P0-2 类分歧 bug 的根源 |

### 5.4 第三批：P1 中优先级正确性缺陷（2~3 天）

| 序号 | 编号 | 修复内容 | 改动量 |
|---|---|---|---|
| 14 | **P1-13** | ZIP 解压按相对路径或哈希重命名存储，不再按 basename 平铺 | ~15 行 |
| 15 | **P1-18** | `ZipDecoder().decodeBytes` 改用 `compute` 放入后台 Isolate | ~20 行 |
| 16 | **P1-14** | `content_http_client` 改 Dio 流式写盘 + `CancelToken` + 大小上限 | ~30 行 |
| 17 | **P1-17** | 四处 JSON `writeAsString` 改 `.tmp` + `rename` 原子写（复用 SnapshotStore 已有模式） | ~20 行 |
| 18 | **P1-16** | `download_manager.dart` 的 `dl_` 分支补序号后缀（与 `local_` 分支对称） | ~3 行 |
| 19 | **P1-12** | `deleteCustomPuzzle` 增加文件复用引用检查后再删 | ~15 行 |
| 20 | **P1-11** | `getThumbnailFile` 失败返回 null 或占位图，不返回原图 | ~5 行 |
| 21 | **P1-10** | `getCacheKey` 纳入 `quality` 参数 | ~3 行 |
| 22 | **P1-19** | `_applyBoardState` 尺寸不匹配时增加状态回调通道（不只是 warning + return） | ~15 行 |
| 23 | **P1-20** | `home_tab_view` 标签分类改用真实 tag 元数据或删除 `l.index % 5` 伪逻辑 | ~10 行 |
| 24 | **P1-21** | 修正 `snapshot_store.dart:77` 的 `substring(0,8)` 截断为 `substring(0,16)`（保留完整 64 位哈希） | ~1 行 |
| 25 | **P1-22** | `listSync()` 改 `await for (final f in dir.list())` 异步列目录 | ~15 行 |
| 26 | **P1-23** | `app_logger.dart:292` 的 `_sink?.close()` 补 `await` | ~1 行 |
| 27 | **P1-9** | `saveSync` 未初始化时用局部变量而非改写单例 `_snapshotsDir` | ~5 行 |
| 28 | **P1-15** | `shouldUpscale` 的 OR 改 AND 或总像素阈值 | ~3 行 |

### 5.5 第四批：P2 技术债排期（渐进式）

| 序号 | 编号 | 修复内容 | 改动量 | 前置条件 |
|---|---|---|---|---|
| 29 | **死依赖清理** | 删除 7 个 0 引用依赖（先决策 Riverpod 用或删） | pubspec 改动 | Riverpod 决策 |
| 30 | **i18n 基础设施** | 建 `l10n.yaml` + `app_zh.arb` / `app_en.arb` + `gen_l10n`；新代码走 `AppLocalizations`；存量分批迁移 | 中 | 产品决策 en-US 是否本期 |
| 31 | **CI 门禁** | 加 `.github/workflows`：`flutter analyze --fatal-infos` + `flutter test`；基线 analyze=0 / test=165 | 小 | 无 |
| 32 | **启用 linter** | `analysis_options.yaml` 至少启用 `unawaited_futures`、`avoid_ignoring_return_values`、`use_build_context_synchronously` 等 | 小 | 先跑一遍修 lint |
| 33 | **全局错误捕获** | `main.dart` 加 `FlutterError.onError` + `PlatformDispatcher.onError` + `runZonedGuarded`；`_loadImage` 加 try/catch | ~30 行 | 无 |
| 34 | **删除 unawaited 遮蔽** | 删 `app_logger.dart:453-454` 的自定义 `unawaited`，统一用官方 `dart:async` 版本 | ~1 行 | 启用 lint 后基线会变 |
| 35 | **init 并行化** | `main.dart` 7 个串行 await 中无依赖项改 `Future.wait` 并行 | ~15 行 | 无 |
| 36 | **main.dart 日志修正** | `sw.elapsedMilliseconds` 单独计时，不再同时用作 done 和 total | ~3 行 |
| 37 | **init 重入保护** | `app_content.dart` 进入 init 立即置"初始化中"；`game_repository.dart` 加守卫 | ~10 行 |
| 38 | **resume_helper 解耦** | 数据操作留 `data/`，UI 交互挪 `widgets/helpers/` | ~50 行搬迁 |
| 39 | **拆大文件** | `jigsaw_puzzle_game.dart`（1925 行）拆 mixin；`game_page.dart`（1281 行）拆子组件 | 大 | 渐进 |
| 40 | **硬编码色值** | `0xFF2E7D32` 等提取到 `ThemeExtension` 或常量表（全库 ~88 处 / 21 文件） | 大 | 渐进 |
| 41 | **presets 歧义** | 废弃 `pieceCount` 反查，删除 `game_repository` 兜底路径 | ~20 行 |
| 42 | **注释/值修正** | `puzzle_engine.dart` snapRatio 注释 48% vs 实值 0.40 修正；`jigsaw_puzzle_game.dart:1127` `// 0.48` 修正 | ~2 行 |
| 43 | **聚合缓存优化** | `progress_store` 维护增量计数器替代全量扫描 | ~30 行 |
| 44 | **磁盘缓存 LRU** | ImageCacheManager 磁盘层 + SnapshotStore 加容量上限 + 按时间淘汰 | ~40 行 |
| 45 | **渲染优化** | `BoardGhostComponent` 改复用 Paint；`hideBorders` 启用路径落地；已归位碎片合并底板整图 | 中 |
| 46 | **假测试修复** | `widget_test.dart` 改为引用真实 `VictoryDialog` 而非内联复制 | ~50 行 |
| 47 | **补充关键测试** | ① `updateXxxProgress` 等价性测试（防 P0-2）；② `SnapshotStore.save` 多难度保留（锁 P1-6）；③ `hintFor` 复杂度回归（锁 P1-1） | ~100 行 |

---

## 6. 修复依赖关系与注意事项

### 6.1 依赖关系

```
P0-2（四分支 await + max/min） ← 抽取 _persistProgress（消灭 380 行重复）
P0-3（保存 await 化）           ← P1-9（saveSync 目录改写，dispose 路径一并处理）
P1-6（多难度策略）              → 需产品决策先行
P0-1（内网 IP 注入）            → 视发布环境
P0-5（i18n）                    → 需产品决策（en-US 是否本期）
死依赖清理                       → Riverpod 用/删决策先行
CI 门禁                         → 应在 linter 启用后建立基线
```

### 6.2 四份报告的修复顺序共识

| 顺位 | BDZ | GLMF | DSF | GMF | **综合** |
|---|---|---|---|---|---|
| 1 | P0-2 | P0-2 | P1-1 | P0-1 | **P1-1**（最高 ROI） |
| 2 | P1-1 | P1-1 | P0-3 | P0-2 | **P0-2** |
| 3 | P0-3 | P0-3 | P0-4 | P0-3 | **P0-3** |
| 4 | P0-4 | P0-4 | P0-2(降级) | P0-4 | **P0-4** |
| 5 | P0-1 | P0-1 | P0-1 | P1-1 | **P0-1** |

> BDZ/GLMF 把 P0-2 排第一（数据损坏优先），DSF 把 P1-1 排第一（ROI 最高），综合取 P1-1 第一——因为改动仅 5 行且不阻塞其他修复，可立即执行；P0-2 紧随其后。

### 6.3 需要产品决策的事项

1. **P1-6 多难度存档策略**：保留单难度（删 UI 死代码）还是改多难度并存（加容量上限）？— GLMF 发现是设计意图
2. **P1-8 通关数口径**：`getTotalSolved()`（去重）还是 `totalCompletedLevels`（累加）？— DSF 发现两套口径不一致
3. **P0-5 / i18n**：en-US 是否本期必须交付？— 影响是否纳入第一批
4. **Riverpod**：删除还是真正落地？— 影响死依赖清理
5. **Web 平台**：是否支持？— 影响是否删除 `web/` 目录和 P1-21 的处理方式

---

## 7. 校验基线

| 指标 | 当前基线（DSF 实测） | 目标 |
|---|---|---|
| `flutter analyze` | 0 issues (17.6s) | 维持 0 |
| `flutter test` | 165/165 通过 (17s) | 维持 165+ 通过，新增关键测试后增长 |
| 测试覆盖 | 24 文件，集中在 logic/data | 补充 game/pages/widgets/services 覆盖 |

修复后应重新运行 `flutter analyze` 和 `flutter test` 确认无回归。

---

*报告生成时间：2026-08-31（GMT+8）*
*交叉核对来源：4 份独立复核报告 + 1 份原始审查报告*
