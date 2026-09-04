# Flutter 代码审查报告（精简版 · 已修复/搁置分流）

> **评审日期**：2026-09-04 · **复核**：2026-09-04 全量逐行 (`flutter analyze` 0 issues)  
> **版本**：v1.0.0+1 · **范围**：`lib/` 全量  
> **修订**：2026-09-04 16:35 三阶段修复完成（`26b6539`/`bab9552`/`cbb80b6`/`355d8fe`）  
> 本文档为原 786 行详细报告的精简落地版：已修复项仅保留一句话描述并标注状态，搁置项单列并说明理由，不再重复矩阵与长篇剖析。原始逐行证据见 `IMPLEMENTATION-REPORT-20260904.md`。

---

## 一、总览

- **原 13 项 + 增量 5 项 + 综合去重 8 项 = 26 独立问题**，`flutter analyze` 静默。
- **已修复 19 项**（含核心部分修复 4 项），**搁置 7 项**（影响面大/需真机压测/设计评审）。
- 三阶段落地：P0 阻断 → P1 稳定性 → P2 体验/规范；`analyze 0`/`test 247`/`build windows --debug` 均通过。

| 状态 | 数量 | 占比 |
|---|---|---|
| ✅ 已修复（含核心修复） | 19 | 73% |
| ⏸️ 搁置（择期单独立项） | 7 | 27% |

---

## 二、已修复（19 项）——简述 + 状态

> 仅一句话归因，详细 `grep` 证据与 `compute`/`dio.download` 方案见实施报告。

| 编号 | 严重级 | 一句话描述 | 状态 | 关键改动 |
|---|---|---|---|---|
| **P01** | P0 | `GamePage._loadImage` 无 `mounted` 守卫，快速退场 `ui.Image` 泄漏 | ✅ 已修复 2026-09-04 | `try/catch` + `if(!mounted) img.dispose()` |
| **P02** | P0 | `Crop` 链式 `toImage` 未捕获 `Picture`，`croppedImage` 未 `dispose` | ✅ 已修复 | 拆变量+`try/finally dispose`+`offset` |
| **P03** | P0 | `ShareCard` `boundary.toImage` 与 `Linen` `picture.toImage` 未释放 | ✅ 已修复 | `try/finally image/picture.dispose()` |
| **P04** | P2 | 13 处 `buffer.asUint8List()` 无参（实际 `offset==0` 安全，规范缺口） | ✅ 已修复 | 全量补 `offsetInBytes/lengthInBytes`（`home/daily/my_puzzles/event/game` 9处 + 已修4处） |
| **P05** | P0 | `_flushSync` fire-and-forget，关窗 `closeAll` 竞态丢档 | ✅ 核心已修复 | `putJson` 入 `_pendingWrites` 队列，`main onExit waitPending+flush` 再 `close` |
| **P06** | P1 | `ContentHttpClient.downloadFile` `Dio.get` 全量进 RAM | ✅ 已修复 | `Dio.download` 流式 + 200MB 上限 + `DioException` |
| **P07** | P1 | `ZipDecoder.decodeBytes` 主线程同步 ANR | ✅ 已修复 | `compute(_decodeZipIsolate)` + 2000文件上限 |
| **P08** | P2 | 8 处 `cast<String>()` 脏数据 `TypeError` | ✅ 已修复 | `whereType<String>()` |
| **P09** | P1 | `getJson` `as String?` 在 `try` 外击穿 | ✅ 已修复 | `is! String` 守卫 |
| **P11** | P2 | 难度弹窗每帧重建 16~100 贝塞尔（原称400高估） | ✅ 已修复 | 合并 `Path` 缓存 `_ensureCache(Size)` |
| **P12** | P2 | `Online` JS `replaceAll("'")` 未转义 | ✅ 已修复 | `jsonEncode(targetUrl)` |
| **P13** | P2 | `TargetImageSize` `round()` 可得 0 崩溃 | ✅ 已修复 | `math.max(1, round())` 双端 |
| **P14** | P1 | `DownloadManager` 同 P06，`Uint8List.fromList` 2×拷贝 | ✅ 已修复 | `Dio.download` `.part`+50MB限+403重试 |
| **P15** | P1 | `ImageCacheManager` 网络缩略图全量缓冲+无上限 | ✅ 已修复 | `Dio.download` 临时文件 + 文件版 `ThumbnailGenerator` +20MB限 |
| **P16** | P0 | `MyCenter._resolveImageBytes` `HttpClient` 泄漏+无界缓冲 | ✅ 已修复 | 超时/`contentLength`+`chunked`双熔断/`close(force)` |
| **P18** | P1 | 扩展包 `download 1× + readAsBytes 1× + decode 1×` 3×峰值 | ✅ 核心已修复 | `downloadFile` 流式 + `_processZipFile` `compute` 读盘 + Isolate 解压（完全文件流式待 `archive_io`） |
| **P19** | P0 | 活动 `GamePage(levelIndex:index)` 丢 `canonicalId` 覆盖主线 | ✅ 已修复 | 传 `canonicalId: level.id` |
| **P20** | P1 | `syncAll` 无锁并发写 + `resolveManifest` 弱网4~16s阻塞秒开 + Events 覆盖 | ✅ 核心已修复 | `_isSyncing/_syncFuture` 互斥 + `resolveManifestCacheFirst` 先盘 + 保留 `prevDownloaded` |
| **P21** | P1 | `Progress/Snapshot` 内存先改吞错、`load` 一律删盘、`.tmp/.bak` 双删、`backup` 未flush | ✅ 核心已修复 | 失败回滚/单条try/`Format`vs`IO`分流/`tmp→snapshot`恢复/`_doBackup`前flush |
| **P22** | P1 | `Crop` Build内写`controller` 红屏、`Game/Event` 永久加载/转圈、`Victory` `forward` 竞态 | ✅ 已修复 | `postFrameCallback`/`try/finally`/`mounted`守卫 |

> 注：P05/P18/P20/P21 标注“核心已修复”表示关键链路闭环，残余小分支（`stateBox` 零散 `put`、完全流式 `archive_io`）已纳入搁置。

---

## 三、搁置（7 项）——理由与后续

| 编号 | 严重级 | 标题 | 搁置理由 | 建议后续 |
|---|---|---|---|---|
| **P10** | P2 | Flame 持续 60/120 FPS 满帧耗电 | 已有视锥剔除剔除85%~90%，`pauseEngine` 需插手势/空闲状态机（1s无交互暂停、手势唤醒）+ 已锁定集群合批底图，改动涉游戏循环，收益边际，风险中等 | 单独分支 + 功耗对比测试 |
| **P17** | P0 | 全分辨率三重常驻（70MB峰值）难度感知解码 | 需 `instantiateImageCodec(targetWidth)` 按 `rows*cols*48~64px` `clamp(1080,3072)` 分难度封顶，且拆“游戏纹理”与“导出超分”双管线，改动手感与清晰度敏感，需真机 3GB/4GB 对比 400块放大细节 | 独立设计评审 + 3C 低端机压测 |
| **P23** | P2 | `daily_tab_view` Build内 `listSync`+365次 `getLevelProgress` | `listSync` 每帧扫盘但文件少，365次为内存O(1)热点，修复需 `initState` 异步缓存+`contentUpdateNotifier` 失效，易引异步竞态，掉帧感知弱 | 异步缓存分支 + 滚动帧率对比 |
| **P24** | P2 | 散落重叠/epsilon固定0.035 | 24×24 0.1宽挤压12块、`isSolved`误判，已有 0.48*min(1/cols) 自适应雏形，需按 `1/cols` 动态化 | 引擎参数调优分支 |
| **P25** | P2 | 引擎 O(N²)/O(N³)+渲染全量 `where` | `pieceById` 20万次/`_merge` 9000万次仅450块极端，`organizeTray`/`pointerMove` 40k~48k/秒，需 Map索引+邻接表重构，改动面大 | 算法重构长期项 |
| **P26** | P2 | 缓存非原子/无重试/Auto-GC误删/`minAppVersion`未用等 | 涉及 `mainContentPipeline` `.tmp+rename`、重试退避、`https`白名单、Auto-GC使用中保护等，多点分散，需逐项单测 | 技术债队列 |
| **P05/P21/P18 残余** | P1 | `stateBox` 零散 `put`、完全流式解压 | 主链路已闭环，残余仅影响金币/计数或需 `archive_io`，收益低、测试成本高 | 随 P26 一并消化 |

---

## 四、验证与提交

- **静态**：`flutter analyze` **No issues found**（`curly_braces` 已补）
- **单测**：`flutter test` **247 passed**
- **编译**：`flutter build windows --debug` **Built JigsawFox.exe 17.2s**
- **关键回归**：`buffer.asUint8List()` 无参 0处、`cast<String>` 0处、`HttpClient` 已 `close`、`jsonEncode` 已替换、`TargetImageSize` 已 `max`、`_pendingWrites` 已 `wait`
- **提交**：`26b6539`(P0) `bab9552`(P1) `cbb80b6`(P2) `355d8fe`(终验)，均未 `push`

> 详细分阶段 diff 与逐行 `Read/grep` 证据见 `docs/IMPLEMENTATION-REPORT-20260904.md`；变更摘要同步 `docs/CHANGES-20260904.md`。

