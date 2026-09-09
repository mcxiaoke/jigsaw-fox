# Flutter 代码库全面审查报告

- 审查日期：2026-09-09 12:16 (GMT+8)
- 审查范围：`lib/`（96 文件 / 42,111 行）、`test/`（46 文件 / 10,959 行）、`integration_test/`、`docs/`（91 篇）、`pubspec.yaml`
- 审查方式：`flutter analyze` + `flutter test` + 分模块逐文件人工核查
- 结论：**无 error、无 warning、299 测试全绿**，但静态检查的"干净"掩盖了若干结构性风险——主要是磁盘缓存无上限、死代码页面、依赖空挂、文档失真

> 说明：报告中每条问题均标注了可验证的文件与行号。凡经核查**不成立**的怀疑点，已在末尾单独列出，避免误导。

---

## 一、基线数据

| 指标 | 结果 |
|---|---|
| `flutter analyze` | **230 条，全部为 info 级；error 0 条，warning 0 条** |
| `flutter test` | **299 项全部通过**（耗时 20s） |
| 静态检查配置 | `very_good_analysis` + `strict-casts/raw-types/inference` 已开启 |
| 待升级依赖 | 24 项（含 2 项受 pubspec 约束无法升级） |

info 级告警的分布（Top 4）：

| 类型 | 数量 | 主要位置 |
|---|---|---|
| `discarded_futures` / `unawaited_futures` | 约 60 | `widgets/game_toast.dart`、`widgets/victory_dialog.dart`、`widgets/lazy_level_image.dart` |
| `avoid_slow_async_io` | 约 30 | `test/` 为主（测试可接受） |
| `prefer_const_*` | 约 40 | `test/` 为主 |
| `avoid_dynamic_calls` | 约 20 | `scripts/publish/app_reference/`（非主工程） |

**判断**：`lib/` 主工程的 info 告警集中在"异步调用未 await"这一类，属真实隐患但非崩溃级，不构成立即风险。

---

## 二、严重问题（P0）

### 1. L2 磁盘缓存无上限、无 LRU 淘汰 —— 磁盘无限增长

`lib/logic/cache/image_cache_manager.dart`

L1 内存缓存设计良好（150 张 / 30MB LRU），但 **L2 磁盘缓存只有"只增不减"的索引集合**：

```dart
// L51
final Set<String> _diskKeyIndex = <String>{};
// L131 / L262 / L490：只 add，全文件无任何容量判断与淘汰
_diskKeyIndex.add(fileName);
```

全文件 grep `evict|LRU|maxSize|trim|purge` 仅命中两处注释（L31、L44），**没有任何实际淘汰代码**。每次新图源生成 `thumb_<hash>_<dim>.jpg` 永久留存。

> **勘误（2026-09-09 实施时修正）**：初版报告把 `lib/logic/download_manager.dart` 的 `download_cache`（L220、L313）与 `thumbnail_cache` 相提并论、建议"同步处理上限"，这个建议是**错误的**。`download_cache` 存放的是用户主动下载的原图，属用户资产，做 LRU 自动淘汰会静默销毁用户已下载的内容；而 `thumbnail_cache` 是可重建的派生缓存，淘汰后能自动重新生成。二者性质完全不同：前者只能由用户显式管理容量，后者可以安全自动淘汰。实施时只对 `download_cache` 保留了临时文件（`.part`）泄漏的修复。

**影响**：重度用户长期使用后磁盘占用单调增长，且 `clearCache()`（L544）只能手动触发，用户不会主动清理。这是本次审查中**唯一会随使用时长持续恶化**的问题。

### 2. 两个页面是死代码，但仍有测试在"保护"它们

| 文件 | 行数 | 生产代码引用 | 测试引用 |
|---|---|---|---|
| `lib/pages/tabs/my_puzzles_tab_view.dart` | 882 | **0** | `test/new_features_test.dart:446` |
| `lib/pages/tabs/events_tab_view.dart` | — | **0** | `test/events_tab_view_test.dart:12,26,44` |

`MyPuzzlesTabView` 与 `EventsTabView` 在整个 `lib/` 中除自身定义外**无任何调用点**，仅被测试引用。意味着 882 行代码随包发布却永不执行，而测试还在为死代码提供"回归保护"，制造虚假的安全感。

（澄清：`OnlineImagePickerPage` 曾被初筛误报为死代码，实际在 `lib/pages/tabs/my_center_tab_view.dart:577` 被引用，**不是**死代码。）

### 3. 两个 riverpod 依赖完全未被使用

`pubspec.yaml` 声明了 `flutter_riverpod: ^3.4.2` 与 `flame_riverpod: ^5.5.5`，但全仓 `lib/` grep `ProviderScope|ConsumerWidget|WidgetRef|ref.watch|flame_riverpod` **零命中**。

**影响**：白白增加包体积、依赖面与升级维护成本。要么删除，要么明确它是否为未来架构预留——若属预留，应在文档中写明，否则后来者会误判为"项目使用了 riverpod"。

---

## 三、中等问题（P1）

### 4. `SoundService.dispose()` 定义了却从未被调用

`lib/services/sound_service.dart:444`

```dart
Future<void> dispose() async {
  final futures = _pool.map((s) => s.player.dispose()).toList();
```

`dispose()` 方法存在且实现完整（dispose 播放器池 + 取消 Timer/Subscription），但全仓调用点只有 `lib/main.dart:150` 的 `init()`，**没有任何地方调用 `dispose()`**。单例生命周期内原生播放器池与 `FlameAudio.audioCache` 静态单例始终不释放。

> **重要修正**：此前认为音频层"混用 FlameAudio / audioplayers / SoundPool 三套引擎"的判断**已不成立**。经源码核实，全仓 grep `soundpool|SoundPool|MAX_STREAMS` **零命中**；实际只有两套——`audioplayers` 的 `AudioPlayer`（L228、L588）与 `flame_audio` 的 `FlameAudio.audioCache`（L232、L254）。结论从"三套引擎混乱"修正为"两套引擎 + dispose 未接线"。

### 5. `import_pack_page` 在 await 之后 setState 缺少 mounted 守卫

`lib/pages/import_pack_page.dart:46-56`

```dart
final result = await FilePicker.platform.pickFiles(...);
if (result != null && result.files.single.path != null) {
  setState(() {            // ← L52，无 if (mounted) 检查
    _localPathController.text = result.files.single.path!;
```

用户在选择器打开期间退出页面，原生回调返回时触发 `setState() called after dispose()` 崩溃。同文件 `_startImport`（L96/110/118）已正确加了守卫，属遗漏而非普遍问题。

### 6. 下载失败路径残留 `.part` 临时文件

`lib/logic/download_manager.dart` 的 `saveOrDownloadImage`：非 403/401 错误走 `rethrow`（L293），此时 `.part` 文件已存在却未清理；403/401 重试失败后 `return null`（L436）同样未删除重试用 `.part`。
`lib/logic/cache/image_cache_manager.dart` 的 `getNetworkThumbnailBytes` 同类缺陷：L430-436 的 `return null` 绕过了外层 catch（L507 才有清理），残留 `tmp_net_*.part`。失败重试越多，垃圾越多。

### 7. 并发竞态三处

| 位置 | 问题 |
|---|---|
| `image_cache_manager.dart:73-96` | `_isInitialized` 在 `await getApplicationSupportDirectory()` 之后（L89）才置 true，并发调用会重复建索引。对比 `DownloadManager.init()`（L44-46）同步置位，反而是安全的 |
| `game_repository.dart:868-871` | `recordSnapStats` 读-改-写非原子：`await stateBox.put(key, totalPiecesSnapped + pieceCount)`，高频吸附并发时计数丢失 |
| `progress_store.dart:270/344/435` | `save` / `recordDifficultyCompletion` / `updateProgress` 均为"load → 改 → 整条覆盖"，自动存档与通关结算并发时最后写者胜 |

（公平地说：`storage_manager` 与 `progress_store` 在写入失败时会回滚内存并记录 warning（L283-291、L416-418），错误处理并不草率；schema 前向兼容也做得好——`fromJson` 用 `known` 集合过滤未知键并保留 `extra`。这是本项目的明显优点。）

### 8. 下载能力偏弱：无断点续传、无法取消、无并发上限

`saveOrDownloadImage`（L241-318）每次都 `await partFile.delete()`（L242）从头下载，无 Range/seek；`_dio.download` 未传 `CancelToken`，用户无法取消；`DownloadManager` 自身无并发限流。大图下载体验与流量消耗均有优化空间。

### 9. 超长 build 方法

- `lib/widgets/choose_difficulty_sheet.dart`：build 从 L348 到 L966，**约 617 行**单方法 widget 树
- `lib/pages/game_page.dart`：build 从 L1108 到文件末尾 L1343，约 235 行

两者任何状态变更都重走整棵子树，且可维护性差。

---

## 四、轻微问题（P2）

10. **`app_logger.dart:550` 自定义空 `unawaited()` 遮蔽了 `dart:async` 的同名函数**，使 L83/267/279 等处的 unawaited 实际是空操作。功能无害但误导性极强，应删除该冗余定义。
11. **注释与代码不符**：`puzzle_engine.dart:19` `defaultSnapRatio = 0.40` 但注释写"48%"；`jigsaw_puzzle_game.dart:1391` 注释称"硬上限 44px"而 L1395 实际 `maxScreenPx = 48`。手感调参时极易被误导。
12. **重复代码**：`game_repository.dart` 的 `updateLevelProgress`(L440-516)、`updateCustomProgress`(L642-722)、`updateGenericProgress`(L761-840) 三处近 80 行快照同步逻辑几乎逐字复制，改一处易漏另两处。
13. **Phase0 死分支**：`unlock_service.dart:64-70` 的 `checkDifficultyUnlock` 恒返回 `isUnlocked: true`；`game_repository.dart:527-534` 解锁分支因恒 true 永不触发。
14. **fire-and-forget Future 未捕获**：`download_manager.dart:177/324/372`、`image_cache_manager.dart:324` 的 `prewarmThumbnail` 未 await 也未 try，异常会成为未处理异步错误。
15. **依赖升级**：24 项可升级（`win32` 5.15→6.4、`package_config` 2.2→3.0 跨度较大，需回归验证）。

---

## 五、文档过时情况（重点）

`docs/` 共 91 篇，其中带日期的"设计/计划/实施报告"类占比很高，是过时重灾区。

### 已确认过时的文档

| 文档 | 过时类型 | 证据 | 建议 |
|---|---|---|---|
| **`docs/jigsaw-puzzle-game-architecture.md`**（09-07 修改） | 架构描述不符 + 功能已下线 | ① §2 写 4-Tab 为「主页/每日/**活动(Events)**/自制」，实际 `lib/pages/main_screen.dart:17` 与 IndexedStack 子项为 Home/Daily/**Collections**/My；② §4.2 称"管理 100 关官方关卡"，实际 `lib/data/game_repository.dart:121` 已注释 `// _initLevels();`，L117-120 明确"首页切网络 main 内容，不再生成内置 100 关"；③ §1 持久化只列 SharedPreferences，实际 `GameRepository` 同时使用 Hive（L307/L895/L897） | **最高优先级，立即更新** |
| `docs/i18n-bilingual-support-plan-20260906.md` | 现状断言失效（方案已落地） | 文档称「`lib/l10n` 目录不存在」「main.dart 未配置 delegates」；实际 `lib/l10n/{en,zh}.i18n.json` 已存在、`pubspec.yaml:57` 含 slang、`main.dart:112/169/238` 已接线 | 归档或标注"已落地" |
| `docs/rendering-performance-optimization-plan-20260906.md` | 方案前提失效 | §4.1 称 `linen_texture_manager.dart` 当前为 `BlendMode.softLight` 且是瓶颈；实际 L72 已是 `BlendMode.srcOver`，方案二已无意义 | 更新/归档 |

### 经核查依然准确、可保留的文档

- `docs/ui-ux-architecture-and-tabs-refactor-20260905.md` — Tab 命名与代码一致，引用的 `adaptive_hero_banner.dart` 确实存在
- `docs/game-page-performance-review-20260906.md` — 关于 `hideBorders`、`_secondsNotifier` 死代码的结论与代码完全吻合
- `docs/UI-OPTIMIZATION-IMPLEMENTATION-REPORT-20260906.md` — 声称的 slang 落地与修改文件清单均属实

### 文档体系的结构性问题

91 篇文档中约 70 篇属"易过时类"（设计/计划/实施报告）。当前缺少**归档机制**：已实施的计划与现行设计混放同目录，后来者无法区分"这是现状"还是"这是历史"。建议建立 `docs/archive/` 并配合文档头部的状态标记（现行 / 已实施 / 已废弃）。

另外，未发现任何文档存在"类名/方法名彻底失效"型铁证——文档中提到的 `ContentManager`、`ManifestRouter`、`MainContentPipeline`、`CanonicalId`、`EdgeLayout`、`ThumbnailDimension`、`minZoom=2.0` 等**全部真实存在**。文档失真的形式主要是**架构描述滞后于重构**，而非凭空捏造。这一点比预想的好。

---

## 六、测试质量

299 项全绿，但绿得有些虚。

| 问题 | 证据 |
|---|---|
| **假测试** | `test/generate_cuts_demo_test.dart` 全文件 **0 个 expect**，只读取资源、绘制、写 PNG 到 `temp/`，是 demo 伪装成测试 |
| **点击无断言** | `test/daily_tab_fold_test.dart:38` 唯一 expect 只校验月份标题存在；L41/L45 点击折叠/展开后**不断言状态变化** |
| **依赖私有 LAN** | `test/logic/content_manager_test.dart:10/239/326-366` 硬编码 `http://192.168.1.118`，**仅作者本机可通**，换机/CI 必挂 |
| **依赖真实外网** | `test/logic/jigsawdata_remote_verify_test.dart:16/44-53` 直连 `raw.githubusercontent.com` 并重试 5 次；且 L80-84 用 `if (manifestUrl.isEmpty) return;` 静默"通过式跳过"，污染绿条 |
| **硬等待** | `crop_puzzle_test.dart:61`、`widget_test.dart:109`、`storage_manager_test.dart:544/593` 等用 `Future.delayed` 做假同步 |
| **集成测试过浅** | `integration_test/app_test.dart` 仅遍历 4 个 tab + 断言 `MainScreen` 存在且无 `ErrorWidget`（L23-96），**未触碰任何核心玩法**（拖拽、吸附、胜利流程） |

### 覆盖率缺口（真正的风险）

| 源文件 | 行数 | 覆盖情况 |
|---|---|---|
| `jigsaw_puzzle_game.dart` | 2521 | 仅 `new_features_test.dart:68-133` 测 ghostOpacity/undo 两个方法，**渲染/移动/吸附物理 2500+ 行未覆盖** |
| `game_repository.dart` | 948 | 仅作 fixture 调用 `init()`，无专用测试 |
| `download_manager.dart` | 489 | 零覆盖 |
| `game_page.dart` | 1343 | 仅校验 6 个 AppBar 图标 + 进度条，无交互断言 |
| `daily_tab_view.dart` | 1024 | 仅 1 个 expect |
| `my_center_tab_view.dart` | 1227 | 仅空态 + 切 tab（8 expect） |

**判断**：测试偏重 UI 文案快照，引擎层与数据层几乎裸奔。299 个绿灯主要证明"页面能渲染出来"，不能证明"拼图逻辑是对的"。

---

## 七、经核查「不成立」的怀疑点

为避免误导后续决策，以下常见怀疑经查证**不成立**（部分是项目做得好的地方）：

- ❌ 每帧 `update()` 重计算 / GC 压力：**不成立**。`JigsawPuzzleGame` 无自定义 `update()` 覆写，重活（`computePlantedPieceIds`、`resolveSnap`）仅在落子/可见性变更时触发；`PuzzlePieceComponent.render` 有视锥剔除（L189-204），Paint 全为 `static final`。这块写得相当克制。
- ❌ UI 硬编码中文绕过 l10n：**不成立**。grep 整个 `pages/`、`widgets/`，中文仅出现在注释里，所有用户可见字符串均走 `t.*`。
- ❌ 图片未降采样导致内存暴涨：**不成立**。`app_cached_image.dart:62` 已统一用 `ResizeImage` 降采样。
- ❌ Widget 生命周期普遍泄漏：**不成立**。`game_page`(L903-921)、`import_pack`(L38-42)、`log_viewer`(L158-162)、`achievements`(L52-55)、`victory_dialog`(L204-212)、`home_tab_view`(L302-309) 的 dispose 均正确释放，监听器 add/remove 成对齐全。仅 `import_pack_page:52` 一处 mounted 遗漏（见 P1-5）。
- ❌ 写入失败静默吞异常导致状态不一致：**不成立**。`StorageManager`/`ProgressStore` 均有回滚 + warning 记录。
- ❌ schema 迁移不兼容旧数据：**不成立**。`fromJson` 用 `known` 集合过滤未知键并保留 `extra`，前向兼容良好。
- ❌ `lib/game/` 与 `lib/logic/` 遗留 TODO/FIXME：**不成立**，grep 零命中。
- ❌ 混用三套音频引擎：**部分不成立**，实际为两套（详见 P1-4）。

---

## 八、建议行动项（请逐项拍板）

| # | 事项 | 优先级 | 工作量 | 备注 |
|---|---|---|---|---|
| 1 | 更新 `jigsaw-puzzle-game-architecture.md`（Events→Collections、删 100 关断言、补 Hive） | 高 | 小 | 该文档是架构真源，描述的是 09-07 前的旧状态，误导性最强 |
| 2 | 为 L2 磁盘缓存增加容量上限 + LRU 淘汰 | 高 | 中 | 唯一随时间持续恶化的问题；`download_cache` 同步处理 |
| 3 | 建立 `docs/archive/` 归档机制 + 文档状态标记 | 高 | 小 | 治本，否则过时文档会持续累积 |
| 4 | 删除 `my_puzzles_tab_view.dart`(882行) 与 `events_tab_view.dart` 及其测试 | 中 | 中 | 需先确认是否为未来功能预留 |
| 5 | 删除 `flutter_riverpod` / `flame_riverpod` 依赖（或书面说明预留用途） | 中 | 小 | 零使用，纯负担 |
| 6 | 给 `SoundService.dispose()` 接线，或删除该方法 | 中 | 小 | 先确认期望的释放时机 |
| 7 | 修 `import_pack_page.dart:52` mounted 守卫 | 中 | 极小 | 一行改动 |
| 8 | `.part` 临时文件统一用 try/finally 清理 | 中 | 小 | 涉及 2 个文件 3 处 |
| 9 | 修 `ImageCacheManager.init()` 竞态（用 Completer 缓存进行中的 Future） | 中 | 极小 | |
| 10 | 删除 `test/generate_cuts_demo_test.dart` 假测试，或移出 test 目录 | 中 | 极小 | |
| 11 | 修 `content_manager_test.dart` 私有 LAN 硬编码（改本地 mock server） | 中 | 中 | 否则 CI 无法启用 |
| 12 | 补 `jigsaw_puzzle_game.dart` 吸附/完成判定的单元测试 | 中 | 大 | 2521 行核心引擎几乎裸奔 |
| 13 | 拆分 `choose_difficulty_sheet.dart` 的 617 行 build | 低 | 中 | |
| 14 | 修正 `puzzle_engine.dart` / `jigsaw_puzzle_game.dart` 的注释数值（0.40 vs 48%、44px vs 48） | 低 | 极小 | |
| 15 | 清理 `app_logger.dart:550` 遮蔽的 `unawaited` 定义 | 低 | 极小 | |
| 16 | 依赖升级（24 项） | 低 | 中 | `win32`/`package_config` 大版本跨度需回归 |

---

## 九、总体评价

代码库的整体质量**高于预期**，体现在：零 error/warning、启用 strict-casts/raw-types/inference、测试全绿、Widget 生命周期管理普遍规范、l10n 落地彻底、前向兼容的 schema 设计、渲染层有视锥剔除且不在每帧做重活。这些都说明项目不是野蛮生长的。

真正的问题不在"代码写得差"，而在**三个结构性欠账**：

1. **缓存只设计了写入，没设计淘汰** —— L1 内存有 LRU，L2 磁盘完全没有，是个明显的半截工程；
2. **文档没有生命周期管理** —— 91 篇文档、70 篇易过时，已实施的计划与现行设计混放，架构主文档描述的是两天前的状态；
3. **测试数量可观但覆盖错位** —— 299 项集中在 UI 渲染快照，2521 行的核心引擎和 948 行的数据仓库几乎没测，绿条给了不该有的信心。

建议优先处理行动项 1、2、3——成本低，且能立刻止住"文档持续失真"与"磁盘持续膨胀"两个趋势性问题。

---

## 十、实施进展（2026-09-09 当日更新）

用户已拍板实施，除行动项 12 / 13 / 16 搁置外，其余均已落地。逐项状态：

| # | 事项 | 状态 | 落地说明 |
|---|---|---|---|
| 1 | 更新架构主文档 | ✅ 已完成 | Tab 改 Collections、删 100 关断言、补 Hive、新增缓存章节 |
| 2 | 磁盘缓存上限 + LRU | ✅ 已完成 | 500MB 上限、90% 水位、最旧优先淘汰，附专项测试 |
| 3 | 归档机制 + 状态标记 | ✅ 已完成 | 新建 `docs/archive/` 与 README，已归档 2 篇 |
| 4 | 删除死代码页面 | ✅ 已完成 | 删除 882 行 + events 页及其测试，已备份 |
| 5 | 删除 riverpod 依赖 | ✅ 已完成 | 连带移除 16 个传递依赖 |
| 6 | SoundService.dispose 接线 | ✅ 已完成 | 修复 `_initialized` 重置缺陷，接线到 `onExitRequested` |
| 7 | mounted 守卫 | ✅ 已完成 | 另修 `files.single` 空列表抛异常 |
| 8 | `.part` 临时文件清理 | ✅ 已完成 | 两处改 `try/finally` 兜底 |
| 9 | `init()` 竞态 | ✅ 已完成 | 改用 `Completer` 共享进行中的 Future |
| 10 | 删除假测试 | ✅ 已完成 | 移出 test 目录至 `tool/`，保留能力 |
| 11 | 私有 LAN 硬编码 | ✅ 已完成 | 环境变量驱动 + 默认 skip，纯 URL 用例保持全环境可跑 |
| 12 | 补核心引擎测试 | ⏸ 搁置 | 后续单独立项 |
| 13 | 拆分 617 行 build | ⏸ 搁置 | 后续单独立项 |
| 14 | 修正注释数值 | ✅ 已完成 | 0.40 / 48px 已修正 |
| 15 | 清理遮蔽的 unawaited | ✅ 已完成 | 已删除，改用 `dart:async` 版本 |
| 16 | 依赖升级 | ⏸ 搁置 | 后续单独立项 |

### 实施后的验证结果

| 检查项 | 结果 |
|---|---|
| `flutter analyze` | **0 error、0 warning**（242 info，较基线 230 略增，主要来自新增代码的 `avoid_slow_async_io`，与项目既有的异步 I/O 设计取舍一致） |
| `flutter test` | **311 通过 / 8 跳过**（8 项为依赖真实内容服务器的用例，默认跳过，可用 `--dart-define=JIGSAW_TEST_SERVER=<base>` 启用） |
| `flutter build windows --debug` | ✅ 构建成功（`JigsawFox.exe`） |

### 实施中发现的两个新问题（原报告未覆盖）

1. **`SoundService.dispose()` 存在重置缺陷**：它不清除 `_initialized`，一旦调用就再也无法重新初始化，音效将永久失效。这个缺陷此前从未暴露，恰恰因为 dispose 从未被调用——属于"死代码掩盖了 bug"的典型案例。已一并修复。
2. **测试套件存在并发脆弱性**：全量 `flutter test` 首次运行出现 10 个 `loading` 失败，单独重跑这些文件则全部通过，再次全量运行亦通过。判定为测试间共享资源（临时目录 / 单例状态）在并发执行下的竞争，非本次改动引入。建议后续为测试分配独立临时目录，避免间歇性假失败。

### 需要留意的情况

实施期间检测到另一条并行工作流正在改动 `recommend_service.dart`（新增文件）与 `collection_levels_page` / `event_levels_page` / `pack_levels_page` / `my_center_tab_view` / `choose_difficulty_sheet` 等页面，并新增了 23 个推荐难度相关测试（测试数由 295 增至 311）。上述文件本次未触碰，但两者共享 `CHANGES-20260909.md` 与部分页面，后续合并时需留意冲突。

---

## 十一、存储分区评估与设置页行为核查（2026-09-09）

### A. 缓存存储分区评估 —— 决定维持现状（用户拍板）

背景：`thumbnail_cache` / `network_levels` / 日志均存放在 `getApplicationSupportDirectory()`。经查证 path_provider 三平台映射：

| 平台 | support（当前存放） | 应用缓存目录（未使用） |
|---|---|---|
| Android | `files/`（"清除数据"删，"清除缓存"不删） | `getCacheDir()`（两按钮都删，低存储自动清） |
| Windows | RoamingAppData（`AppData\Roaming`，域环境随登录/注销漫游） | LocalAppData |
| iOS | NSApplicationSupport（会进 iCloud/iTunes 备份） | NSCachesDirectory |

**评估结论（维持现状，不改）**：
- **Windows Roaming 不作为问题**：域环境漫游仅在企业 AD 场景成立；消费级发行下 Roaming 是事实标准（用户本机 Roaming 已有数十 G 应用数据），迁移到 LocalAppData 无实际收益。
- **Android cache 分区错配在可接受范围**："清除缓存"对 `thumbnail_cache` 无效是真实平台差异，但该 app 数据量小，且有 500MB LRU 上限兜底 + 设置页内置清理入口（`_clearThumbnailCache`），影响可控。
- 迁移成本（跨端路径变更、旧目录清理、首次重建）与收益不匹配，故整体维持现状。

**遗留的独立低风险项**：`getThumbnailFile()` 仅查内存索引即返回 `File(path)`、不验证文件存在（`image_cache_manager.dart`）。文件长期放在 support 目录不会被系统清除，触发概率极低；已知悉，未修。

### B. 设置页"清理"与"重置所有游戏数据"的准确行为

**1. "清理"（设置页 → 清理缩略图缓存，`_clearThumbnailCache`）**

实际行为 = 仅调 `ImageCacheManager.clearCache()`：
- ✅ 清空 L1 内存缓存、L2 `thumbnail_cache` 全部物理文件（顺带清 `.part` 临时文件）、任务队列
- ❌ **不清理**：`network_levels`（网络关卡已落盘原图）、`download_cache`（用户下载原图）、应用日志

结论：该入口清理范围比"清理缓存"的一般预期窄，只覆盖缩略图。对用户下载的图片与日志不做清理。

**2. "重置所有游戏数据"（`resetAllData()`）**

UI 承诺（`dataResetDesc`）："清除所有关卡记录、每日挑战与自制拼图"。

实际清除范围：
- ✅ 3 个 Hive box：`progress`（关卡进度/每日挑战）、`collections`（自制拼图元数据）、`state`
- ✅ 文件级残局快照（`SnapshotStore.clearAll`）
- ✅ 经济（金币/券重置为 starter 发放）
- ✅ 成就、收藏
- ✅ `download_cache` 物理文件（**用户下载的原图一并删除**）
- ⚠️ 有意保留：SharedPreferences 设置（音效、背景等，L939 注释明确"仅设置入口保留设置"）
- ⚠️ **不清除**：`thumbnail_cache` / `network_levels` / 日志（残留孤儿文件，受 LRU 上限约束，无害但不彻底）

两个需要知晓的点：

① **行为比文案承诺更广**：文案只提关卡记录/每日挑战/自制拼图，实际连金币、成就、收藏、用户下载的原图也一起清空。对用户而言"重置数据"清得更彻底未必是坏事，但下载的原图（用户资产）被静默删除值得在文案中明示。

② **重置后状态 ≠ 全新安装状态**：`resetAllData()` 末尾显式调用 `_initLevels()`（L937）重新植入 100 关内置 demo；而正常启动路径的 `_initLevels()` 已于 2026-09-07 注释（首页切换为网络 main 内容）。即重置后会出现正常启动所没有的 100 关内置关卡。该调用标注"恢复出厂语义"（L936 注释），疑似 09-07 网络化改造时的遗漏。

**后续处理（2026-09-09 用户拍板）**：
- **"重置所有游戏数据"入口已从设置页移除**——Android 应用信息"清除数据"（Windows 删 AppData 目录）已覆盖该场景且更彻底；自研重置逻辑是持续的 bug 源，价值为负。
- `resetAllData()` **方法保留**（测试与开发期使用），但其中的 `_initLevels()` 调用已注释，与启动路径对齐——重置后内置关卡列表为空（不再重植 100 关 demo），仅保留 `_initCustomPuzzles()` 重植的 3 个样例。
- 前提提醒：若未来规划 iOS（无系统级"清除数据"入口，只能卸载重装），需重新评估是否恢复该入口。

### C. 本次核查顺带修复

- **`clearCache()` 未重置磁盘字节计数 `_diskCacheBytes`**（上一轮新增计数器的遗漏）：物理文件已删但计数虚高，之后每次缓存写入都会触发一次删不到任何文件的全目录扫描，且 `_enforceDiskCacheLimit` 因目录为空提前 return、计数永远无法自愈。已修复（`clearCache` 同步 `_diskCacheBytes = 0`）并补测试断言。
