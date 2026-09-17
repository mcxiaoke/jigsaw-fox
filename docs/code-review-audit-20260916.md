# 代码审查报告：数据逻辑与 UI/UX 问题清单

- 审查日期：2026-09-16
- 审查范围：`lib/` 全量核心代码（存储层、游戏引擎、经济/成就服务、全部页面与通用组件）
- 审查方式：人工逐文件走读 + 两个独立子代理交叉审查 + 关键问题人工复核（代码、资源、调用点实证）
- 静态检查：`flutter analyze` 结果为 **No issues found! (ran in 9.9s)**——本报告所列均为静态分析无法覆盖的逻辑、数据一致性、竞态与体验问题
- 问题统计：高优先级 8 项（数据 4 + UI 4），中优先级 17 项，低优先级 14 项

## 总体评价

工程基础质量在同类 Flutter 项目中属上乘：

- 持久层有完整的损坏检测（`isCorruption` 类型分流）、隔离留证、备份恢复（每 box 独立计数）、内存 box 终极兜底，绝不静默删盘；
- 所有写入经 `putJson`/`putRaw` 统一纳入挂起写入队列，关窗 `onExitRequested` 前 `waitPendingWrites + flushPendingWrites`，针对 hive_ce `close()` 不 flush 的坑做了正确处理；
- 快照文件级存储采用 `tmp → bak 保护 → rename` 原子写，启动时还有 tmp 恢复逻辑；
- 针对 Windows 桌面生命周期（inactive/hidden 而非 paused）、文件锁 sharing violation 都有专门适配；
- 游戏引擎的吸附两阶段判定（棋盘槽位 + 自由邻居合并）、边缘连通种植规则、放大后吸附半径归一化修正、越界收拢等算法成熟且注释充分。

主要问题集中在：**少量资源/链路的功能缺口、跨异步状态竞态（玩家资产相关）、迁移到网络内容后遗留的死路径，以及若干小屏/i18n/可访问性细节**。

---

# 一、数据与逻辑问题

## 🔴 高优先级

### D-1 默认自制拼图引用了不存在的图片资源（首启必现故障）

- 位置：[lib/logic/image_source.dart](../lib/logic/image_source.dart#L8-L19)、[lib/data/game_repository.dart](../lib/data/game_repository.dart#L250-L275)、[lib/widgets/app_cached_image.dart](../lib/widgets/app_cached_image.dart#L69-L72)
- 实证：`assetSamples` 声明了 `assets/images/sample_01.jpg ~ sample_10.jpg` 共 10 张图，但 `assets/images/` 目录实际只有 `icon.png`、`icon-round.png`、`icon_1024.png`、`icon-android-foreground.png`、`splash_12.png`、`splash_500.png`，**sample 图片一张都不存在**。
- 影响：
  1. `GameRepository._initCustomPuzzles()` 首启植入的 3 个样例拼图（sample_01/02/03）在"我的"页可见，点击后 `rootBundle.load` 必然抛异常 → GamePage 弹"图片解码失败"toast → 1.2 秒后自动退出页面，样例关卡完全不可玩；
  2. `AppCachedImage` 对空路径的兜底也是 `AssetImage('assets/images/sample_01.jpg')`，当 event/collection 封面传空字符串时，该 AssetImage 解析失败再走 errorBuilder 灰块，兜底形同虚设；
  3. `reloadBuiltinLevelsForTest()` 引用的内置 100 关同样全部使用这批路径（生产已不调用，但测试桩数据不可用）。
- 修复建议：补齐 10 张 sample 资源（推荐），或在网络内容就绪前不植入样例、把空路径兜底改为 `PuzzleCardPlaceholder` 占位组件而非 AssetImage。

### D-2 活动（Event）关卡完全没有续玩链路

- 位置：[lib/pages/event_levels_page.dart](../lib/pages/event_levels_page.dart#L143-L215)
- 对比：home（daily）、collection_levels_page、pack_levels_page 均通过 `ResumeHelper.tryHandleResumeFlow` + `SnapshotStore.loadJsonString` 读取残局，并向 `ChooseDifficultySheet` 传 `savedProgressPercent`、`completedPieceCounts`、快照 json。
- 现状：活动关卡 `_openLevel` 直接弹难度面板，`onStart` 构造的 `GamePage` 只传了 `imageBytes/difficulty/canonicalId/packTitle`，**没有 `initialSnapshotJson`**，面板也看不到历史进度与成绩。
- 影响：活动关卡玩到一半退出后残局无法恢复；虽然自动保存仍在写，但用户侧无任何续玩入口，存档成为只读死数据。
- 修复建议：照搬 collection_levels_page 的续玩链路（读快照、传进度、onStart 注入 `initialSnapshotJson`）。

### D-3 成就奖励可能"吞币"：日上限触顶仍标记已领取 + 双击重复发奖窗口

- 位置：[lib/services/achievement_service.dart](../lib/services/achievement_service.dart#L518-L543)、[lib/services/economy_service.dart](../lib/services/economy_service.dart#L121-L148)、[lib/pages/achievements_page.dart](../lib/pages/achievements_page.dart#L93-L106)
- 问题 A（吞币）：`claimReward` 的顺序是"检查未领取 → `markClaimed` → `addCoins`"。`addCoins` 受每日 200 币软上限限制，触顶时返回 `actualEarned = 0`，但成就已被永久标记 claimed，**金币未到账且无法补领**。
- 问题 B（重复发奖）：`isClaimed` 检查与 `markClaimed` 写入之间有 await 间隙，服务层非原子；UI 按钮没有 claiming 在途态，快速双击可产生两个并发调用同时通过检查，导致 `addCoins` 执行两次。
- 修复建议：
  1. 服务层加"单成就领取中"互斥锁（如 `Future` 链或内存 `Set<String> pendingIds`）；
  2. 触顶时给出明确提示（"今日奖励已达上限，明日可领"）并选择是否仍标记领取，或把成就奖励设为 `bypassCap: true`（成就奖励是否计入日帽需产品决策，但必须二选一，不能静默吞）；
  3. UI 增加 claiming 态禁用按钮；`claimReward` 返回 false 时给 toast 反馈。

### D-4 GameToast 连续弹出时新 toast 被旧 toast 的退场回调误删

- 位置：[lib/widgets/game_toast.dart](../lib/widgets/game_toast.dart#L21-L75)、[退场回调](../lib/widgets/game_toast.dart#L123-L129)
- 机理：`_currentEntry` 是静态单例。旧 toast 在 `duration - 300ms` 开始退场动画；退场期间调用 `show()` 会移除旧 entry 并把静态变量指向新 entry。旧 entry 移除后其 AnimationController 被 dispose，`reverse()` 的 Future 以 TickerCanceled 完成，而 `whenComplete(widget.onDismiss)` **在取消时仍会执行**；onDismiss 闭包无差别 `_currentEntry?.remove()`——此刻删的是新 toast。
- 复现场景：连续领取成就、连续吸附触发多个提示时，新提示"一闪即消失"。
- 附带问题：静态 Timer 在 `duration` 时刻强删 entry，而退场动画到 `duration + 20ms` 才结束，出场动画尾部恒定被截断；调用方传入 `duration < 300ms` 时延迟为负，toast 刚滑入即滑出。
- 修复建议：onDismiss 闭包捕获自己的 entry 并做身份校验（`if (identical(_currentEntry, myEntry)) ...`）；Timer 删除逻辑与动画结束逻辑合并；对负 duration 做 clamp。

## 🟡 中优先级

### D-5 游戏未加载完成时点提示照扣币

- 位置：[lib/pages/game_page.dart](../lib/pages/game_page.dart#L745-L772)
- `_onHintPressed` 未判 `_game == null`（图片解码期间 AppBar 已可交互）。流程为：扣费/扣券成功 → `_game?.hint()` 空操作 → 还设置了 1.5 秒暂停计时标记。
- 影响：玩家资产被扣除但没有任何提示效果。
- 修复建议：开头加 `if (_game == null || _isSolved || _isPaused) return;`，或在加载完成前禁用灯泡按钮。

### D-6 结算的 moves（步数）传成了"已拼碎片数"

- 位置：[lib/pages/game_page.dart](../lib/pages/game_page.dart#L601-L610)
- `recordDifficultyCompletion(..., moves: _solvedPieces)`，`_solvedPieces` 是已吸附碎片计数而非有效步数，导致 `DifficultyRecord.minMoves`（历史最少步数）统计口径错误，未来若做步数相关成就/展示会全部失真。
- 修复建议：引擎侧统计真实有效操作数（吸附/合并次数或拖拽次数），沿 `onProgressChanged`/独立回调上报。

### D-7 Windows 失焦（inactive）时游戏计时不暂停

- 位置：[lib/pages/game_page.dart](../lib/pages/game_page.dart#L115-L125)
- `didChangeAppLifecycleState` 只处理 `paused/hidden/detached`。Windows 桌面点击其他窗口首先进入 `inactive`（本项目 main.dart 注释中也明确指出桌面端 paused 永不触发），此时：
  - 计时器继续走，玩家成绩用时虚高，直接影响 `StarCalculator` 的时间星级；
  - 不会触发 flushSync 保存（main.dart 的全局后台同步有 5 分钟节流兜底保存，但页面计时问题仍在）。
- 修复建议：将 inactive 纳入暂停/保存条件（注意与切窗备份节流区分，计时暂停不需要节流），或在 inactive 持续超过短阈值（如 2 秒）后再暂停，避免 Alt-Tab 瞬切误伤。

### D-8 图包（Pack）关卡完成角标永远不显示

- 位置：[lib/pages/pack_levels_page.dart](../lib/pages/pack_levels_page.dart#L391-L454)
- 角标读 `level.isCompleted`，但 `PackContentPipeline.getPackLevels` 构造 `PuzzleLevelItem` 时从不回填进度（grep 确认 pack pipeline 中无 `isCompleted`/`getLevelProgress` 调用），该字段恒为 false；页面 `_levels` 也只在 initState 取一次，不监听进度通知。
- 影响：图包关卡通关后绿色对勾永远不出现；外部变更（素材删改）也不会同步。
- 修复建议：卡片渲染时实时读 `ProgressStore.instance.getLevelProgress(level.id)`（与其他列表页一致），或监听 `progressNotifier` 后重建。

### D-9 "下一关"按钮是迁移遗留死路径，网络主线无法连玩

- 位置：[lib/pages/game_page.dart](../lib/pages/game_page.dart#L803-L840)、[lib/pages/game_page.dart](../lib/pages/game_page.dart#L850-L851)
- 现状链路：`_playNextLevel` 依赖 `widget.levelIndex` 与 `_repo.levels`；grep 确认**生产环境没有任何入口传 `levelIndex`**（全部走 `canonicalId`），且 `GameRepository.init()` 已不再调用 `_initLevels()`（`_levels` 恒空，仅测试钩子可恢复）。
- 影响：`hasNext` 恒 false，胜利弹窗"下一关"按钮永不出现；网络 main 内容通关后只能退出重选，无法连玩。
- 修复建议：这是 2026-09-07 首页网络迁移的遗留，需要产品/架构决策——可改为通过 `AppContent`/resolver 按 order 查下一张网络关卡并预下载，或在弹窗直接隐藏该能力直到链路补齐。

### D-10 图片缓存 key 不含内容 hash；相对 URL 是功能死路

- 位置：[lib/logic/cache/level_image_resolver.dart](../lib/logic/cache/level_image_resolver.dart#L71-L92)（落盘 key）、[本地快路径](../lib/logic/cache/level_image_resolver.dart#L177-L189)、[协议分支](../lib/logic/cache/level_image_resolver.dart#L259)
- 问题 A：缓存文件名仅为 URL 的 FNV 哈希 + 后缀。`PuzzleLevelItem.hash` 字段注释明确写着"用于补丁换图与缓存失效检测"，但代码从未使用该字段。判定逻辑是 `existsSync && length > 0` 即永久命中——服务端在同 URL 换图（补丁修图）后，客户端永远显示旧图。
- 问题 B：resolver 只处理 `assets/` 与 `http(s)://`。模型注释明确允许相对地址（如 `main/images/0101.webp`），这类路径直接 `return level.displayPath`，被 `FileImage` 当本地文件处理，必然解码失败，点重试也无解。
- 修复建议：缓存文件名纳入 hash（与项目记忆中"客户端图片缓存必须以 hash 入文件名做版本控制"的既有约束一致）；相对 URL 在 resolver 拼接 manifest base URL 后再走下载。

### D-11 LazyLevelImage 列表复用竞态导致错图/闪烁；失败态无退避风暴重试

- 位置：[lib/widgets/lazy_level_image.dart](../lib/widgets/lazy_level_image.dart#L49-L111)
- 问题 A：ListView 复用同一 State，`didUpdateWidget` 切换到新 level 后没有代次（generation）校验，旧 level 的下载 Future 晚完成时仍执行 `setState(() => _resolvedPath = 旧路径)`，新卡片先闪旧图再被覆盖。同文件 `_NetworkImageLoader`（app_cached_image.dart）有 `widget.url != url` 守卫，可照此修正。
- 问题 B：重建条件含 `(_failed && _resolvedPath == null)`，home 页监听进度/内容通知重建频繁，断网时会随通知风暴反复发起网络请求，没有指数退避。
- 修复建议：引入自增 token/identity 校验，返回时比对当前 widget；失败重试加最短间隔与最大次数。

### D-12 图集下载失败后卡片永久显示"下载中"

- 位置：[lib/pages/tabs/collections_tab_view.dart](../lib/pages/tabs/collections_tab_view.dart#L411-L427)
- `isDownloading` 除状态枚举外还靠 `progressMap` 中残留的 `0 < progress < 1` 推断；`_startDownload` 失败分支未重置进度值。失败/暂停后卡片可能一直显示下载进度态并拦截进入，而实际已无下载任务。
- 修复建议：下载态只以 status 枚举为准，或在 catch/finally 中清零 progressMap；`onRefresh`/空态重试的 `syncAll()` 也应补 catch 与失败 toast（当前为未处理 Future）。

### D-13 collection_levels_page 在 build 中内联创建 Future，角标闪烁 + 重复 I/O

- 位置：[lib/pages/collection_levels_page.dart](../lib/pages/collection_levels_page.dart#L434-L436)
- `FutureBuilder(future: ResumeHelper.loadProgress(level.id))` 直接写在 build 里。父级每次 setState（从游戏页返回时多处触发）都会让每张可见卡重新发起一次异步读取，FutureBuilder 先回到无数据态再刷新，角标闪烁。
- 修复建议：在 initState/数据层固化 Future 结果并缓存，按 `progressNotifier` 失效。

### D-14 total_snaps 成就计数口径与文案不符

- 位置：[lib/services/achievement_service.dart](../lib/services/achievement_service.dart#L477-L479)
- "累计吸附 X 片碎片"成就只在**通关结算**时按整图片数累加（`incrementCounter('total_snaps', actualPieces)`）。玩家拼了但未通关的吸附数永远不计；中途放弃后这些吸附永久丢失。
- 修复建议：在 `onPieceSnapped`（GamePage 已有该回调）节流累计吸附数，或定期将引擎内吸附计数刷入 store。

### D-15 Hint 对"不连通边框的内部碎片"反馈不一致

- 位置：[lib/game/jigsaw_puzzle_game.dart](../lib/game/jigsaw_puzzle_game.dart#L2517-L2576)、[lib/logic/engine/puzzle_engine.dart](../lib/logic/engine/puzzle_engine.dart#L135-L153)
- 引擎规则：不与边缘种植体连通的内部集群禁止吸附到槽位（`canSnapCluster` 为 false 时 break）。但 hint 直接把目标片坐标设为精确槽位，该片虽不锁定，却因坐标准确被 `PieceState.isSolved`（epsilon 0.035）判定为 solved，进而：
  - 被计入 `solvedCount`/进度百分比；
  - 边缘筛选、missingPieceCheck 等按 isSolved 处理；
  - 玩家花了提示币，视觉上却没有"吸住锁定/绿框"的一致反馈。
- 修复建议：hint 对内部片应走"移动到槽位附近 + 保持游离"的统一语义，或允许 hint 强制打通连通规则并明确视觉反馈；进度计数建议只统计"已种植（locked/planted）"而非坐标 epsilon 命中。

### D-16 多处 async 后裸 setState（mounted 缺口）与无 catchError 的网络 Future

- home：[home_tab_view.dart](../lib/pages/tabs/home_tab_view.dart#L271-L291) 两处 `await Navigator.push` 后裸 setState（同文件其他回调有守卫，属遗漏）；
- daily：[daily_tab_view.dart](../lib/pages/tabs/daily_tab_view.dart#L179-L212) `_ensureMonthDownloaded` 的 add loading 无 mounted 守卫（可由 await prefs 后的折叠偏好恢复链路在 dispose 后触发，finally 有守卫而此处没有）；[54-61 行](../lib/pages/tabs/daily_tab_view.dart#L54-L61) `fetchDailyIndexMetadata().then(...)` 无 `catchError`，失败时为未处理异步异常且 UI 永久停留无元数据态；[418/438 行](../lib/pages/tabs/daily_tab_view.dart#L418-L438) 导航后裸 setState；
- my center：[my_center_tab_view.dart](../lib/pages/tabs/my_center_tab_view.dart#L451-L460) `onStart` 中 push 前缺 mounted 判断（同文件其他回调均有）；
- event：[event_levels_page.dart](../lib/pages/event_levels_page.dart#L202-L213) `onStart` 同理。
- 修复建议：统一补 `if (!mounted) return;`，网络 Future 补 catchError 与错误态。

### D-17 resetAllData 生产环境无入口（需确认是否有意下线）

- 位置：[lib/data/game_repository.dart](../lib/data/game_repository.dart#L850-L907)
- grep 全仓库，`resetAllData()` 仅两个测试文件调用，设置页没有"清除全部数据"按钮（settings_page 中无 reset 相关代码），但这套 60 行的多服务重置链路（box.clear、快照清理、经济/成就/收藏/下载重置、样例重植、索引对账）仍在维护。
- 影响：死代码维护成本；用户也无法在应用内恢复出厂。
- 修复建议：确认产品意图——要么在设置页补回带二次确认弹窗的入口，要么在后续架构债务清理中移除（注意该链路本身实现是正确的，含 presetsInitialized 等标志处理，勿误删）。

## 🟢 低优先级

| 编号 | 位置 | 问题 |
|---|---|---|
| D-18 | [main.dart](../lib/main.dart#L93-L94) | `WidgetsFlutterBinding.ensureInitialized()` 连续调用两次（功能无害，属冗余） |
| D-19 | [economy_service.dart](../lib/services/economy_service.dart#L101-L105) | 新手赠送三次 put 非原子，极端崩溃窗口下重发可能把金币覆盖回 100（现有 starterGranted 标志已大幅收窄窗口，可接受） |
| D-20 | [game_repository.dart](../lib/data/game_repository.dart#L113-L116) vs AchievementService | `stat:totalPlayTimeSeconds` 仅通关局累计（recordSnapStats durationSeconds 在结算时调用），成就的 `play_seconds` 含弃局时长，两套游玩时长口径不一致 |
| D-21 | [sound_service.dart](../lib/services/sound_service.dart) | 槽位抢占竞态：全槽繁忙时 resetSync 新音效，旧 play Future 完成后可能误停刚起播的新音效（吸附洪峰时偶发"新音被掐断"）；`loadAll` 失败也置 `_initialized=true`，音效永久静默且无重试；dispose 与懒建池并发可能泄漏 AudioPlayer（退出路径） |
| D-22 | [jigsaw_puzzle_game.dart](../lib/game/jigsaw_puzzle_game.dart#L1153-L1163) 与 [game_page.dart](../lib/pages/game_page.dart#L976-L995) | 托盘滚轮事件同时被 Flame `onScroll` 与外层 Listener `onPointerSignal` 处理，可能双倍速滚动托盘，建议实测确认后只保留一处 |
| D-23 | [unlock_service.dart](../lib/services/unlock_service.dart) | `tierIndex/levelIndex` 入参被完全忽略（恒返回已解锁），签名易误导未来调用方，建议显式弃用标注；daily/event 每次调用都全量 loadAllProgress 过滤，无缓存 |
| D-24 | [pack_levels_page.dart](../lib/pages/pack_levels_page.dart#L108-L119) | `existsSync()` 与 `readAsBytes()` 之间无 try/catch，文件恰被清理时异常直接从 onTap 抛出，用户只看到无响应 |
| D-25 | [level_image_resolver.dart](../lib/logic/cache/level_image_resolver.dart#L195-L200) | 每张网络卡都对 `mainPipeline.levels` 做一次 id 全表线性扫描，O(可见卡 × 总关卡数)，建议建 id→level 索引 |
| D-26 | [daily_tab_view.dart](../lib/pages/tabs/daily_tab_view.dart#L129-L130) | 折叠偏好 `setStringList` unawaited 且无 try/catch，持久化失败无感知 |
| D-27 | [game_page.dart](../lib/pages/game_page.dart#L803-L840) | `_playNextLevel` 用 `rootBundle.load(nextLevel.assetPath)` 读旧内置 asset 体系，即使将来恢复入口也与网络内容资源体系不兼容 |
| D-28 | [progress_store.dart](../lib/data/progress_store.dart#L543-L559) | `clearSnapshot` 先 setHasSnapshot 再 load 再 save，同一操作产生最多 3 次写入，可合并为单次 save |

---

# 二、UI / UX 问题

## 🔴 高优先级

### U-1 "保存壁纸"名不副实：写入临时目录却提示已保存

- 位置：[lib/widgets/victory_dialog.dart](../lib/widgets/victory_dialog.dart#L214-L237)
- 实现把图片写入 `getTemporaryDirectory()`（`puzzle_wallpaper_{ts}.png`），该目录系统可随时清理，相册/文件管理器均不可见，也没有设置为壁纸，却弹出"壁纸已保存"成功提示。
- 同类问题：[share_card_generator.dart](../lib/widgets/share_card_generator.dart#L93-L124) 名为"分享"，实际只把 PNG 写入临时目录，未调起任何系统分享面板（`Share.shareXFiles` 等）。
- 修复建议：保存类操作应写入相册/下载目录（Windows 端为 Pictures/Downloads，需对应权限与通道），分享类操作必须调起系统分享；在能力补齐前应改文案为"已导出到临时目录"或隐藏入口，避免误导。

### U-2 续玩弹窗进度文案重复显示，且固定宽度在小屏溢出

- 位置：[lib/widgets/continue_dialog.dart](../lib/widgets/continue_dialog.dart#L100-L156)
- 文案硬编码为 `'$progressPercent%  $progressPercent/100'`，渲染成 "45%  45/100"——同一数值重复（疑似调试残留），且未走 i18n。
- 内容区固定 `SizedBox(width: 360)`，AlertDialog 默认左右 inset 共 40px，320dp 宽小屏内容可用宽仅约 280px，约 80px 水平溢出。
- 修复建议：删除重复片段（保留一种进度表达）并加入 i18n 资源；宽度改为 `double.maxFinite` + Dialog 约束自适应。

### U-3 裁剪页图片解码失败后永久转圈，无持久错误出口

- 位置：[lib/pages/crop_puzzle_page.dart](../lib/pages/crop_puzzle_page.dart#L153-L197)
- 解码失败只置 `_decodeFailed=true` 并闪一条 2.5 秒 toast，而视口渲染判据是 `_decodedImage != null ? 画面 : CircularProgressIndicator`——失败时视口内永远转圈，保存按钮禁用，页面内没有错误说明或"重新选择图片"按钮，用户只能返回。
- 修复建议：失败态渲染持久错误面板（图标 + 原因 + "重新选择"/"返回"按钮），与 GamePage 的坏图容错保持一致。

### U-4 难度面板解码失败后按错误纵横比选档，坏图无错误态

- 位置：[lib/widgets/choose_difficulty_sheet.dart](../lib/widgets/choose_difficulty_sheet.dart#L239-L268)、[预览区](../lib/widgets/choose_difficulty_sheet.dart#L530-L536)
- 图片尺寸解码异常被空 `catch (_) {}` 吞掉，`_imageWidth/_imageHeight` 保持初始 1×1，`_aspectRatio` 与 `_playableTiers` 全部按正方形推导：网格预览的 rows/cols、可选档位与真实图片比例不符，用户仍可点"开始"以错误档位进入游戏；预览 `Image.memory` 也没有 `errorBuilder`，坏图时卡片空白。
- 修复建议：解码失败直接禁用开始按钮并显示错误态/重试；档位推导必须以真实尺寸为准。

## 🟡 中优先级

### U-5 通关彩带动画实际静止，且每帧新建 60 个 Paint

- 位置：[lib/widgets/victory_dialog.dart](../lib/widgets/victory_dialog.dart#L278-L280)、[Painter](../lib/widgets/victory_dialog.dart#L736-L780)
- `_ConfettiPainter.shouldRepaint => true`，但 CustomPaint 没有绑定任何 Listener/Ticker。实际只有星星依次点亮（3 次 setState）和数字滚动（约 800ms）期间彩带在动，之后永久静止，与"彩带持续下落"的设计不符；同时每次 paint 都 new 60 个 Paint 对象。
- 附带：`_starController` 创建后从未使用（星星靠 `Future.delayed` 手动点亮），属无用资源。
- 修复建议：用独立 `AnimationController`（如 3 秒线性循环）驱动 CustomPaint；Paint 列表缓存复用；删除未使用的 _starController。

### U-6 暗色主题名存实亡，且存在大量硬编码浅色

- 位置：[lib/main.dart](../lib/main.dart#L270) 固定 `ThemeMode.light`（darkTheme 白定义）
- 硬编码浅色点：首页"全部分类"弹窗 `_AllTagsSheet` 背景 `Color(0xFFF2F2F2)`、文字 `Colors.black87`、选中态 `Colors.white`（[home_tab_view.dart](../lib/pages/tabs/home_tab_view.dart#L786-L856)）；GameToast 固定深色底；ContinueDialog 固定宽等。
- 影响：将来开启暗色或跟随系统时会大面积不适配（弹一块亮底弹窗）。
- 修复建议：短期至少让弹层走 AppPalette/ColorScheme；若确认产品只做亮色，应移除 darkTheme 死代码并在文档固化。

### U-7 点击目标普遍小于 40dp 推荐最小尺寸

- 我的页收藏红心实际可点区域约 23×23（[my_center_tab_view.dart](../lib/pages/tabs/my_center_tab_view.dart#L1185-L1214)）；
- 成就领取按钮约 21–26px 高（[achievements_page.dart](../lib/pages/achievements_page.dart#L559-L588)）；
- 首页标签 chip 约 32px 高、分类 IconButton constraints 仅 36×36（[home_tab_view.dart](../lib/pages/tabs/home_tab_view.dart#L700-L774)）；
- 游戏 AppBar 6 个图标 38×40（勉强），但密集排列时相邻目标易误触。
- 修复建议：用 `GestureDetector(behavior: opaque)` 外包至少 40×48 的热区，或改用 IconButton 默认尺寸。

### U-8 内容不足一屏时无法下拉刷新

- home 的 `CustomScrollView`（[home_tab_view.dart](../lib/pages/tabs/home_tab_view.dart#L317-L335)）、daily 外层滚动视图（[daily_tab_view.dart](../lib/pages/tabs/daily_tab_view.dart#L506-L514)）、my center 空态/网格态（[my_center_tab_view.dart](../lib/pages/my_center_tab_view.dart#L846-L899)）均缺 `AlwaysScrollableScrollPhysics`。
- 当筛选结果为空、内容撑不满视口时，Android ClampingPhysics 下 RefreshIndicator 无法触发。collections 页已正确添加该 physics，可反证其他页是遗漏。

### U-9 每日页 build 中重计算 streak 与全月进度，频繁重建有持续主线程开销

- 位置：[lib/pages/tabs/daily_tab_view.dart](../lib/pages/tabs/daily_tab_view.dart#L443-L504)
- 每次 build 最多循环 365 天计算连续打卡（分配大量日期字符串、逐条查进度），还遍历全部月份取关卡、排序、逐条查完成度，并在 build 中打一条聚合日志。该页同时监听 content/progress/locale 多个通知。
- 修复建议：结果缓存为字段，按通知/月份切换显式失效；build 中禁止日志。

### U-10 分享卡在窄屏数字溢出；坏字节时卡面空白

- 位置：[lib/widgets/share_card_generator.dart](../lib/widgets/share_card_generator.dart#L325-L367)
- 三列统计用固定 20px 字号的 Column 放在 Row 中，无 Expanded/FittedBox；320dp 窄屏扣除页面/卡片 padding 后三列可用宽约 160px，步骤数 5–6 位时水平溢出。卡面 `Image.memory`（290-297 行）无 errorBuilder，字节损坏时导出图空白且导出不报错。
- 修复建议：FittedBox + Flexible，补 errorBuilder。

### U-11 我的页选图期间整个 Tab 全屏转圈

- 位置：[lib/pages/tabs/my_center_tab_view.dart](../lib/pages/tabs/my_center_tab_view.dart#L499-L545)
- `_createFromGallery` 一进来就置全局 `_isLoading = true`，系统选图器打开期间及多图导入期间，整个 Tab（含 4 个子页）都显示全屏 loading。
- 修复建议：改局部 busy 态（按钮自身转圈 + 禁用），不阻塞其他子页浏览。

### U-12 图集卡下载进度刷新粒度过大，全部卡片重建

- 位置：[lib/pages/tabs/collections_tab_view.dart](../lib/pages/tabs/collections_tab_view.dart#L411-L427)
- 每张卡外包 ValueListenableBuilder 监听同一进度源，下载 tick 时全部卡片重建；其中 `totalCount <= 0` 的已下载图集每帧还要再调一次 `getCollectionLevels(col)`。
- 修复建议：进度值按 collection id 精确订阅/选择性 rebuild，关卡数预计算缓存。

### U-13 设置页反馈缺口

- 位置：[lib/pages/settings_page.dart](../lib/pages/settings_page.dart#L50-L62)、[374-383 行](../lib/pages/settings_page.dart#L374-L383)
- `_loadStats` 无 try/catch：`getPackageInfo()`/Store 异常时为未处理异步错误，页面停留"1.0.0"/金币 0 的初始值，无错误/重试态；检查更新返回 error 等非 hasUpdate/noUpdate 状态时点击后完全无反馈。
- 附带：`_coins` 直接读 `EconomyService.instance.coins`，本页未先 `await init()`，隐式依赖启动初始化顺序。

## 🟢 低优先级 / 一致性

| 编号 | 位置 | 问题 |
|---|---|---|
| U-14 | [daily_tab_view.dart](../lib/pages/tabs/daily_tab_view.dart#L559) | 今日徽标硬编码英文 `'TODAY'`，zh-CN 用户也看英文，未走 i18n |
| U-15 | [achievements_page.dart](../lib/pages/achievements_page.dart#L100-L101) | "已领取: x"冒号分隔硬编码拼接，未做 i18n 参数化；claimReward 返回 false 时无任何反馈 |
| U-16 | 全部图片卡片 | AppCachedImage/LazyLevelImage 均无 `semanticLabel`/Semantics，可点拼图卡对讲读无有效标签，整体可访问性支持薄弱 |
| U-17 | [event_levels_page.dart](../lib/pages/event_levels_page.dart#L243-L244) | 加载指示用默认 `CircularProgressIndicator`，与其他页面品牌色（0xFF2E7D32）不一致 |
| U-18 | [collection_levels_page.dart](../lib/pages/collection_levels_page.dart#L211) | 进入游戏传 `packTitle: _currentCollection.title`（原始字段），而页面标题等用 `displayTitle`，游戏内标题可能丢失本地化 |
| U-19 | [victory_dialog.dart](../lib/widgets/victory_dialog.dart#L638-L664) | 分享按钮未像其他按钮先 pop dialog，若分享回调假设弹窗已关闭会产生层级叠压 |
| U-20 | [crop_puzzle_page.dart](../lib/pages/crop_puzzle_page.dart#L396-L405) | 文件名时间戳与 ugc id 分别取两次 `DateTime.now().millisecondsSinceEpoch`，可能跨毫秒不一致（有防重，风险低） |
| U-21 | [crop_puzzle_page.dart](../lib/pages/crop_puzzle_page.dart#L629-L636) | InteractiveViewer 的 key 含视口尺寸，窗口拖拽改尺寸会重建 viewer 但保留旧矩阵，可能平移越界/裁剪框错位 |
| U-22 | [choose_difficulty_sheet.dart](../lib/widgets/choose_difficulty_sheet.dart#L363-L431) | 标题区最多三行 Column 置于默认 56 高 toolbar，窄屏 + 收藏/删除双 action 时有垂直溢出风险 |
| U-23 | [choose_difficulty_sheet.dart](../lib/widgets/choose_difficulty_sheet.dart#L447-L491) | 收藏按钮 await toggleFavorite 无 try/catch 与失败反馈 |
| U-24 | [app_cached_image.dart](../lib/widgets/app_cached_image.dart#L85-L121) | build 中对每张图同步 `File.existsSync()`（磁盘 stat），每次 rebuild 重复执行，快速滚动有累积开销，建议 resolver 层缓存命中结果 |
| U-25 | [home_tab_view.dart](../lib/pages/tabs/home_tab_view.dart#L726) | 吸顶 Tag 栏 `shouldRebuild => true`，任何 setState 都重建横滑标签列表，可用字段比较收窄 |

---

# 三、建议修复顺序

| 批次 | 事项 | 对应编号 | 理由 |
|---|---|---|---|
| 1（立即） | 补齐/移除 sample 资源，空路径改占位组件 | D-1 | 首启即可见的必现故障 |
| 1（立即） | 活动关卡补续玩链路；图包角标改读 ProgressStore | D-2、D-8 | 核心功能缺口 |
| 2（资产安全） | 提示扣费前判 `_game != null`；成就领取加互斥/上限处理/claiming 态；Toast 身份校验 | D-3、D-4、D-5 | 直接涉及玩家金币/券，且修复改动小 |
| 3（强感知体验） | 保存壁纸/分享行为与文案对齐；裁剪坏图态；续玩弹窗文案与宽度；难度面板坏图态 | U-1~U-4 | 用户可直接感知的错误引导与卡死 |
| 4（数据正确性） | moves 口径、inactive 暂停计时、缓存 hash/相对 URL、LazyImage 代次校验、下载失败清进度 | D-6、D-7、D-10、D-11、D-12 | 防止错误数据随使用时长累积 |
| 5（性能与打磨） | daily build 缓存、FutureBuilder 固化、热区尺寸、AlwaysScrollable、i18n 补全、Semantics | D-13、U-7~U-15 | 流畅度与规范性 |
| 6（需产品决策） | "下一关"网络主线连玩；resetAllData 是否恢复入口；暗色主题是否保留；成就奖励是否计入日帽 | D-9、D-17、U-6、D-3 | 属架构迁移遗留与产品取舍，不宜静默处理 |

## 验证要求（修复时遵循项目 AGENTS.md）

- 改动代码后运行 `dart format`（仅对改动文件）、`flutter analyze`、`flutter test`；
- 编译验证：`flutter build windows --debug`；运行验证：`flutter test .\integration_test\app_test.dart -d windows`；
- 主项目变更摘要追加到 `docs/CHANGES-YYYYMMDD.md` 顶部；
- 未经明确允许不执行 git commit，任何情况下不 git push；
- i18n 只补 `zh-CN` 与 `en-US` 两份资源。
