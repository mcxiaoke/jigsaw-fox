# Flutter 代码全面审查报告（2026-09-10）——修订版

> 审查范围：`lib/` 全部 93 个 Dart 文件（约 36,720 行，不含 l10n/gen 生成代码），按 data / logic（engine、geometry、content、cache）/ services / game / pages / widgets 分层通读。
> 审查方法：分层通读 + 疑似问题逐条回到关联调用方/被调方交叉验证；所有引用的行号与片段均与当前工作区实际文件核对一致。审查期间未修改任何业务代码。
> 说明：本次为多轮并行审查后由主审统一复核，复核阶段**剔除了一批子任务误报与不实引用**（详见 §6"已排除的疑点"），仅保留经二次核实的真实问题。

> **【2026-09-10 修订版说明】**
> 原报告发布后经两轮独立复核，本版本为合并修订：
> 1. 复核一（`flutter-code-review-20260910-revision.md`）：逐条回源码比对，并用 `hive_ce 2.19.3` 源码验证 Hive 内存写语义、实测 `flutter analyze`（241 条 info，`avoid_slow_async_io 84 / discarded_futures 72 / unawaited_futures 36` 分类计数吻合）。
> 2. 复核二（`flutter-code-review-20260910-revision-msf.md`，Muse Spark 复核）：全量复核 5 P0 + 19 P1 + 7 P2 + 7 排除项，新增 12 项遗漏；二次实测 analyze 为 **242** 条（1 条波动为依赖版本）。
> 3. 合并结论：**28 项主问题中 23 项确认真实、5 项描述不准确/夸大；§6 排除的 7 项全部成立**。定级修订：`P0-1` 降至 P2（记录为故意移除全局兜底）、`P0-5` 降至 P1（机理修正，单步原子 vs 多步 put 竞态拆分）、`P1-2/6/9/11/18` 降至 P2；`P1-15(3)` 删除（不存在 close() 方法）。新增遗漏 O-1~O-12（§7）。
> 4. 行号以 2026-09-10 工作区为准；所有修订处均以 **【修订】** 标注。
> **【2026-09-10 修复版说明】**
> 按修复方案实施后，P1 及遗漏项已修复（详见各条 **【已修复】** 标注）：P1-10 差集清理、P1-13 下载 id 冲突、P1-14 死代码删除（NetworkSource 全库无调用方，事实真实但机理不成立，按删除处理）、P1-15 日志丢批/init 时序、P1-17 样例回滚、P1-19 解码失败提示、O-3 坏图解码失败 toast + 自动退出拼图页；全部通过 analyze/test/build 验证（详见 §0 与 `docs/CHANGES-20260910.md`）。

---

## 0. 静态分析基线（flutter analyze）

- **0 error / 0 warning / 241~242 info**（两轮实测分别为 241 / 242，1 条波动为依赖版本差异）。
- **【修复版】** 实施修复后实测（`flutter analyze --no-pub`）：**0 error / 0 warning / 241 info**，与基线一致；`flutter test` 313 passed / 8 skipped；`flutter build windows --debug` 编译通过。
- info 集中在三类：`avoid_slow_async_io`（84 处，主线程同步 IO）、`discarded_futures`（72 处）、`unawaited_futures`（36 处）——与下文多个实际问题的成因高度吻合，说明这些 lint 不只是风格问题。
- **【修订】** §4 按类别拆分统计归属，其中 `avoid_slow_async_io` 84 条中**内容管线占约 30 条**（原报告仅点名 2 处，详见 §4）；同批 242 条中含 `test/`、`tool/` 目录的 `unawaited/discarded`，非全部来自 `lib/`。

---

## 1. 严重问题（P0，建议优先修复）

> **【修订】** 复核后 P0 收缩为 3 项（P0-2、P0-3、P0-4）；P0-1 降 P2、P0-5 降 P1。

### P0-1 main.dart 缺少全局错误兜底，未捕获异常不可观测 【修订：事实真实，定级 P0→P2】
- **位置**：`lib/main.dart` `main()`（L88–186）
- **证据**：全 `lib/` 检索 `FlutterError.onError` / `PlatformDispatcher.instance.onError` / `runZonedGuarded` 均无结果。且 L150–165 后台初始化组：
  ```dart
  final bgFutures = [ DownloadManager.instance.init().then(...), SoundService.I.init().then(...) ];
  Future.wait(bgFutures).then((_) { AppLogger.system.info('Background init group done'); });
  ```
  `Future.wait` 未接 `catchError`，任一后台 init 抛错即成 unhandled async error。
- **机理**：启动期或运行期任何未捕获异步异常（包括 P0-2 的初始化失败路径）不会留下任何日志；AppLogger 明明已初始化却没接到全局错误回调。桌面端表现为静默白屏/功能失效且无从排查。
- **【修订】** `docs/CHANGES-20260906.md:138` 明确记载：**"故意移除三件套，回归框架默认 `dumpErrorToConsole`，仅 release 接 Crashlytics 才覆盖"**。即未捕获异常仍会打印到控制台，实际丢失的仅是 **AppLogger 文件日志**，非"完全不可观测"。
- **建议**：`bgFutures` 补 `.catchError(e, st → AppLogger.system.severe)` + 可选 `PlatformDispatcher.onError` 转发；**不必恢复 `runZonedGuarded`**。

### P0-2 ImageCacheManager 初始化失败被静默吞掉，且允许"失败后重复全量初始化" 【修订：真实，保持 P0】
- **位置**：`lib/logic/cache/image_cache_manager.dart` L139–144、L227
  ```dart
  } catch (e, st) {
    AppLogger.imageCache.severe('Failed to initialize', e, st);
    completer.complete();          // ← 不是 completeError
  } finally {
    _initCompleter = null;
  }
  ```
- **机理**（三连问题）：
  1. `completer.complete()` 使所有 `await init()` 的调用方误认为初始化成功，随后在 `_cacheDir == null` 状态下继续走缓存链路；`getThumbnailFilePath` 返回 `'$baseDir/$cacheKey'` 而 `baseDir = _cacheDir?.path ?? ''`（L227），得到非法路径 `/thumb_xxx.jpg`。
  2. `_isInitialized` 保持 false、`_initCompleter` 已置 null，下次任何调用会**再次执行完整 init**（含 `_rebuildDiskKeyIndexAsync` 清空重建索引），与仍在飞行中的 L3 缓存任务产生 `_diskKeyIndex` / `_diskCacheBytes` 竞态。
  3. 失败原因（目录创建失败、磁盘故障）无降级标志，问题会反复重演。
- **【修订】** 影响面微调：Windows 下 `''/thumb_xxx.jpg` 实际解析为 `C:\thumb_xxx.jpg` 根目录，无权限写根会 `catch` **静默失败**（不会产生根目录垃圾文件）；Linux/Android 才可能真写根分区。另注意：修复若简单改为 `completeError()`，会使 `lib/main.dart:138` 组1 `Future.wait` 直接抛出导致启动白屏（见 §7 O-1）。
- **建议**：失败时置**降级标志**（如 `_initFailed=true` 后 `getThumbnail*` 直接回退原图/网络），既阻止重复 init 又避免组1 白屏；`getThumbnailFilePath` 对 `_cacheDir == null` 返回 null 而非空串拼接；`completeError` 与降级标志二选一配合。
- **【已修复 2026-09-10（上一批）】**：`getThumbnailFilePath` 返回类型 `String`→`String?`，`_cacheDir == null` 时返回 null，8 处调用点全部适配 null 契约（L2 命中/写盘/删除/回退路径 null 均安全）；按用户约束**未加**降级标志、未动 `complete()` 语义（组1 `Future.wait` 降级即 §7 O-1 仍未实施）。

### P0-3 缩略图写盘非原子，损坏缓存会永久污染两级缓存且无自愈 【修订：真实，确为 P0】
- **位置**：`lib/logic/cache/image_cache_manager.dart` L315（本地）、L528/L547（网络）
  ```dart
  await targetFile.writeAsBytes(generatedBytes, flush: true);
  ```
- **机理**：直接写最终路径 `thumb_<hash>_<dim>.jpg`，进程被杀/断电/磁盘满会留下**截断的损坏 JPEG**。下次启动 `_rebuildDiskKeyIndexAsync`（L156–188）按文件名模式收录该文件（只看名字不校验内容）；L2 命中时 `readAsBytes` 非空即返回并写入 L1（L264–277）——损坏字节被两级缓存固化，ImageProvider 解码失败后**没有任何剔除/重生成机制**，该图表现为永久裂图。对比：网络下载 tmp 文件本身有 `.part` + finally 清理（L568–571 已核实正确），但**最终写 L2 的这一步是裸写**。
- **【修订】** 复核属实；补充修复面：仅 `.part`/finally 覆盖网络临时态，**L2 最终写未用 tmp+rename**。
- **建议**：写 L2 改为 `写临时文件 + rename` 原子替换；L2 读取后可做**最小 JPEG 魔数（SOI/EOI）校验**，解码失败时摘索引并重生成一次。
- **【已修复 2026-09-10（上一批）】**：本地与网络两条 L2 写盘路径均改为"写 `$targetPath.tmp` → 删旧文件 → rename 原子替换"，失败时经 `_deleteTempFile` 清理残留；按用户约束**未加** JPEG 魔数校验（读取侧自愈仍未实施）。

### P0-4 EXIF 方向在整条缩略图/裁剪管线中被忽略 【修订：真实，保持 P0（修复排期可缓）】
- **位置**：`lib/logic/cache/thumbnail_generator.dart` L158、L267；全 `lib/` 检索 `bakeOrientation` / `exif` 无结果
  ```dart
  final original = img.decodeImage(rawBytes);
  ```
- **机理**：`package:image` 的 `decodeImage` **不应用 EXIF Orientation**。经相机拍摄/未经转码的本地照片（大量为 Orientation=6/8）走本地导入（`DownloadManager.importFromLocalFiles` L125 读原始文件）或网络下载后：
  - 缩略图保持传感器原始方向，而 Flutter `ui.instantiateImageCodec`（引擎层应用 EXIF）显示已旋转方向 → 列表缩略图与大图方向不一致；
  - `DownloadManager.saveOrDownloadImage` 用 `ui.instantiateImageCodec`（L334）解析出的 width/height 是 EXIF 修正后的值，与后续未修正管线产出的缩略图宽高比不符，依赖宽高比的 UI（卡片占位、裁剪建议比例 `PuzzleAspectRatio.fromSize`）会错乱；
  - 智能裁剪 `findSmartCropRect` 在未旋转坐标系上计算 → 竖拍图裁错主体位置。
- **【修订】** 影响面收窄：实际仅影响**本地相机原图**（Orientation 6/8），网络素材多已转码，实际触发面窄；P0/P1 均可，建议归"近期"而非"立即"。
- **建议**：decode 后统一 `img.bakeOrientation(original)`（thumbnail_generator 两个入口），或导入入口先做一次带 EXIF 烘焙的转码。

### P0-5 EconomyService 金币读改写无互斥，并发下扣费丢失/重复 【修订：机理修正，P0→P1】
- **位置**：`lib/services/economy_service.dart` L121–148（addCoins）、L205–233（consumeHint）
  ```dart
  final newTotal = coins + actualEarned;   // 读
  await _box.put(_keyCoins, newTotal);     // 写（绝对值）
  ```
- **机理**：`coins` getter 直读 box，两个操作都是"读旧值 → await put → 写回绝对值"。第一次 `await put` 挂起期间事件循环可执行第二个 `consumeHint`，它读到旧余额并通过余额检查，最终两次 put 各写 `旧值 - price` → **点两次提示只扣一次钱**；反过来结算发币并发也可能丢币。日上限计数（L127–139）同模式，并发可突破 `kDailyCoinCap`。
- **【修订：机理拆分，部分不成立】**
  - `hive_ce`（2.19.3）`KeyStore.beginTransaction`（L184–203）与 `insert`（L149–163）**同步更新内存 `_store`**，`get` 读内存最新值 → **单次 `consumeHint` 的"读→算→await put"之间无 await 让出，单 isolate 同步段原子**，"点两次提示只扣一次钱"**不成立**（此断言删除）。
  - 但 `addCoins` 含 `await put(_keyDailyDate)` → `await put(_keyDailyEarned)` → `await put(_keyCoins)` **多步 await 间存在让出点**，第二个并发 `addCoins` 可能读到 `dailyEarned` 旧值 → 日上限统计少计（非超额）、极端下 `coins` 丢币（少计而非重复发放）。此部分**成立**。
  - 结论：不构成"并发必超额/必扣费丢失"的 P0；修正为 P1。
- **建议**：为 EconomyService 引入进程内串行队列（Future 链或 mutex），覆盖 addCoins 多步 put 路径即可。

---

## 2. 中等问题（P1）

> **【修订】** 复核后 P1 收缩为 14 项（P1-2/6/9/11/18 降 P2，P1-15(3) 删除）；原 P1-2、P1-6、P1-9、P1-11、P1-18 修订后见 §3。

### P1-1 AchievementStore 解锁落盘 unawaited + 吞错，落盘失败后可重复领奖 【修订：真实，保留 P1】
- **位置**：`lib/services/achievement_store.dart` L103–113、L157–161
  ```dart
  _unlockedCache[achievementId] = iso;
  unawaited(_putUnlock(achievementId, iso));   // 内部 catch (_) {} 仅吞错
  ```
- **机理**：`_putUnlock`（L157–161）失败静默。内存已标记解锁、本次会话正常，但重启后成就回到未解锁态，用户可**再次解锁并重复领取金币奖励**。counters 的 increment（L81–87）同样吞错。
- **建议**：落盘失败时回滚 `_unlockedCache` 并告警，或至少重试一次。

### ~~P1-2 EngineTaskQueue single-flight 注销无 identical 保护（配合 clearQueue 产生竞态）；本地/网络任务 key 命名空间未隔离~~ 【修订：夸大，降 P2 见 §3】
- 结论：`clearQueue`（L121–131）**仅删除 `_queue` 中排队项的注册，不删运行中任务**；同 key 并发在 `schedule`（L59–62）直接复用 A.future，不会产生 B.future 被 A finally 误删的窗口 → "误删致 miss 单飞"**不成立**。跨泛型 `as Future<T>` 当前两侧均为 `Future<Uint8List?>` 不触发；哈希碰撞概率 2^-63。保留 `identical` 守卫 + `net_` 前缀为低危建议。

### P1-3 `_enforceDiskCacheLimit` 重入保护吞掉淘汰时机，磁盘占用可阶段性越限 【修订：真实，保留 P1】
- **位置**：`lib/logic/cache/image_cache_manager.dart` L591–595
  ```dart
  if (_diskCacheBytes <= _maxDiskCacheBytes) return;
  if (_isEvicting) return;      // 淘汰窗口内的新超限写入被直接跳过
  _isEvicting = true;
  ```
- **机理**：淘汰是长异步过程（多个 await）。窗口内其他写入把 `_diskCacheBytes` 推过上限后调用本方法会直接 return，且无 dirty 标记、无"淘汰结束后复查一次"的循环（`finally _isEvicting=false`（L648）无复查）——超限状态会持续到下一次随机写入。不会无限增长（后续写入还会触发），但上限约束是"尽力而为"。
- **建议**：淘汰结束的 finally 中复查一次 `_diskCacheBytes`，仍超限则递归触发或置脏位。

### P1-4 SnapshotStore.save 与 saveSync 无互斥，可出现旧数据覆盖新数据 【修订：真实，保留 P1】
- **位置**：`lib/data/snapshot_store.dart` L145–191（save）、L211–273（saveSync，`tmp.writeAsStringSync` 位于 L239）
- **机理**：两者共享同一组 `.tmp`/`.bak` 辅助文件名且无锁。游戏页 `_doSave`（异步 save，含多个 await）执行中途让出控制权时，lifecycle/dispose 触发的 `_flushSync → saveSync`（game_page L110–119）会同步执行完整 tmp→bak→rename 序列并覆盖同一个 `.tmp`；save 恢复后 rename 失败走恢复逻辑，最终落盘的是 saveSync 的版本——两次保存的先后顺序与落盘内容可能倒挂（例如刚拖完的新进度被切后台瞬间的旧状态覆盖）。经推演**不会**出现"两个存档全丢"（.tmp 始终被后写者完整覆盖），但存在内容倒挂。
- **建议**：按 `safeFileName` 维度加 Future 链互斥；`_doSave` 的重试 Timer（game_page L424–433，300ms）在 dispose 后创建的问题一并处理。

### P1-5 GameRepository.addCustomPuzzle 先改内存后落盘，落盘失败即内存/磁盘分裂 【修订：真实，保留 P1】
- **位置**：`lib/data/game_repository.dart` L327–334
  ```dart
  _customPuzzles.insert(0, item);
  customPuzzlesNotifier.value = List.unmodifiable(_customPuzzles);
  await _saveCustomPuzzle(item);
  ```
- **机理**：`_saveCustomPuzzle`（putJson）失败时内存列表已插入、UI 已显示，磁盘无此条，重启后拼图"凭空消失"；异常上抛到 crop_puzzle_page 的 catch 后不 pop，但列表中已残留假条目。对比同项目 `ProgressStore.save`（L270–291）有"失败回滚内存"的范本实现，此处未对齐。`deleteCustomPuzzle`（L337–368）是反方向的同类风险（先删内存/文件后删 key）。
- **建议**：对齐 ProgressStore 的回滚模式；或先落盘成功再更新内存。
- **【已修复 2026-09-10（上一批）】**：`addCustomPuzzle` 改为先 `await _saveCustomPuzzle(item)` 落盘成功后再插入内存列表并刷新 notifier；`putJson` 透传 Hive 写盘 Future，失败上抛后内存不变、crop 页 catch 会 toast 且不 pop。

### ~~P1-6 Engine 吸附/锁定/级联三套容差不一致，导致重复吸附与行为分裂~~ 【修订：事实真实但体感夸大，降 P2 见 §3】
- 结论：6×6 `snapDist≈0.067>0.05`、12×12 `snapDist≈0.033<0.035` 的推演正确；但"重复音效 + undo 栈填满"仅发生在 0.05~0.067 误差带内**偶发**，非高频路径。仍建议由 `snapDist` 派生统一。

### P1-7 内容管线（collections/events/daily）缺少单飞防护，同资源并发下载互删临时目录 【修订：真实，保留 P1】
- **位置**：`lib/logic/content/pipelines/collections_content_pipeline.dart` L246、L284（`temp_extract_{id}` 目录 deleteSync→createSync）；`events_content_pipeline.dart` L208–210、`daily_content_pipeline.dart` L61–62 同模式。`main_content_pipeline` 有 `_inFlightDownloads` 单飞（L73、L334–343，且 identical 复核写法正确），三条管线均无。
- **机理**：同一图集/活动/月包被两个入口并发触发（快速双击下载、两个页面同时进入），第二个调用会在第一个正在写文件的 `temp_extract_{id}` 上 `deleteSync(recursive: true)`，双方都失败；交错更糟时可能把半解压目录 rename 到正式目录。`ContentManager._isSyncing` 只保护 sync 链路，不覆盖 `ensureXxxDownloaded`。
- **建议**：复用 main 管线的 `_inFlightDownloads` 模式（含 identical 复核）。
- **【已修复 2026-09-10（上一批）】**：抽取泛型单飞助手 `lib/logic/single_flight.dart`（`runSingleFlight<T>`，含 identical 复核），四条管线（main/collections/events/daily）统一接入，各管线保留独立 `_inFlightDownloads` 命名空间隔离。

### P1-8 manifest/events/collections 磁盘缓存写入非原子（与 main 管线不一致） 【修订：真实，保留 P1】
- **位置**：`lib/logic/content/pipelines/manifest_router.dart` L128–132（`await file.writeAsString(jsonEncode(json), flush: true)` 直写目标文件）；events L340–347、collections L489–496 同模式。对比 `main_content_pipeline` L495–500 是 tmp+rename。
- **机理**：写一半进程被杀 → 缓存 JSON 截断。下次 `_loadFromDiskCache` 有 try-catch 不崩，但表现为"已下载内容列表元数据全丢、需重新同步"；manifest 缓存丢失还会使 `isFirstBootReady()`（L144）变 false，老用户冷启动被打回首启流程。
- **建议**：统一 tmp+rename（Windows 上 rename 不能覆盖，参考 main 管线的 delete+rename 时序）。

### ~~P1-9 内容 zip 下载声明了 zipSha256/hash 但从不校验~~ 【修订：事实真实但属预留，降 P2 见 §3】
- 结论：字段仅声明于 `puzzle_collection_item.dart:23,74,122` 与 `puzzle_event_item.dart:16,52`，`scripts/publish/app_reference/integrations.dart:98` 曾注释掉校验——属**跨镜像一致性预留，非功能错误**。zipSha256 非空时校验失败回退下一镜像即可。

### P1-10 events/collections 远端同步只增不删，下架内容永久残留 【修订：真实，保留 P1】**【已修复：差集清理】**
- **位置**：`lib/logic/content/pipelines/events_content_pipeline.dart` L125–152、`collections_content_pipeline.dart` L155–186：远端列表逐条 upsert 进 map，从不删除"远端列表中已消失的 id"；Auto-GC 只清理 `isDisabled` 条目（events L167–176），collections 连 disabled 目录清理都没有。
- **机理**：运营若直接从 index.json 移除条目（而非标记 disabled），其内存条目、解压目录、缓存 JSON 永久残留且继续出现在可见列表中，形成磁盘泄漏与下架语义漏洞。
- **建议**：同步时以远端列表为全集做差集清理（保留本地已下载标记的按产品语义决定）。
- **【已修复 2026-09-10】**：两条管线 `syncWithRemote` 均实现差集清理——先收集远端 id 全集（含解析失败的原始 id 防误删），同步后以 `map 内不在远端全集中的 key` 为下架集合，逐一从内存 map 移除、删除本地解压目录（deleteSync 清理），随后 `_persistToCache` 重写缓存；日志含 `removed=N` 计数。采用"直接清除本地文件"产品语义（下架即回收）。

### ~~P1-11 daily ensureMonthReady 解压 0 个文件仍返回成功，形成重复整包下载死循环~~ 【修订：事实真实，降 P2 见 §3】
- 结论：`extracted`（L90）未校验即 `rename + return true`（L108/L117）属实；events 的 ensureEventDownloaded 同缺。`extracted==0` 视为失败清理即可。

### P1-12 manifest 磁盘缓存不做 schemaVersion 兼容性校验 【修订：真实，保留 P1】
- **位置**：`lib/logic/content/pipelines/manifest_router.dart` L146–159（`_loadFromDiskCache` 直接 `RootManifest.fromJson`，无版本检查）；版本区间校验 `kMinSupportedSchemaVersion=3 / kMaxSupportedSchemaVersion=4` 只存在于首启网络路径（`app_content.dart` L203–211，常量定义 L29-31）。
- **机理**：与 `app_content.dart` 注释"老客户端读到未来破坏性 schema 时明确失败而非静默解析错乱"的设计意图相悖——降级读磁盘缓存时，未来 schema 的 manifest 会被静默解析，字段错位表现为"内容全空但无报错"。
- **建议**：`_loadFromDiskCache` 解析后做同一区间校验，越界返回 null。

### P1-13 DownloadManager 下载 id 仅用毫秒时间戳，并发下载互相覆盖 【修订：真实，保留 P1】**【已修复：id 单调序号化】**
- **位置**：`lib/logic/download_manager.dart` L219–221
  ```dart
  final id = 'dl_${DateTime.now().millisecondsSinceEpoch}';
  final filePath = '${cacheDir.path}/img_$id.jpg';
  ```
- **机理**：同毫秒两次下载（双击、批量）→ 相同 filePath 与相同 Hive key `material:dl_xxx`，两条流写同一目标文件相互覆盖，先完成记录的元数据（宽高/大小）与实际文件内容不符。本地导入路径（L141）有 `_i` 序号后缀，网络下载没有。同 URL 的去重检查基于 `itemsNotifier`（L200–206），而列表项在下载完成后才插入 → 并发同 URL 重复下载的窗口同样存在。
- **建议**：id 追加随机后缀（`_rnd.nextInt(0xFFFF)`）或内容哈希；`saveOrDownloadImage` 入口加单飞。
- **【已修复 2026-09-10】**：新增静态 `_nextTimestampedId(prefix)`（毫秒时间戳 + 单调递增序号 `_idSeq` 十六进制，65536 自循环），网络下载与本地导入两处 id 生成统一接入；id 格式变更无 `split('_')`/前缀格式依赖（全库已核实），Hive key 为字符串不敏感。并发同 ms 不再撞 id。单飞入口复用此前 P1-7 已实现的 `runSingleFlight` 体系，不重复实现。

### P1-14 NetworkSource 裸 Dio() 无超时，弱网下可无限挂起 【修订：真实但无调用方，死代码删除】**【已修复：删除 NetworkSource】**
- **位置**：`lib/logic/image_source.dart` L65–71
  ```dart
  response = await Dio().get<List<int>>(url, options: Options(responseType: ResponseType.bytes));
  ```
- **机理**：未配置 `connectTimeout/receiveTimeout`（对比 `ContentHttpClient` L14–15 明确配了 8s/15s），且全量 `response.data` 内存缓冲无大小防护。弱网/对端不响应时该 Future 可能挂起到 OS 层 TCP 超时；调用方在 UI 路径 await 它时表现为界面长时间无响应。
- **建议**：补超时与最大字节数防护，或复用 ContentHttpClient。
- **【修订：机理不成立】** 二次核验全库（`lib/` + `test/` + `studio/`）发现 `NetworkSource` 与 `PuzzleSource` 抽象**无任何实例化调用点**（import 该文件的 3 处仅使用 `assetSamples`/`AssetSource`）——属死代码/预留实现，"调用方在 UI 路径 await 它时界面无响应"场景当前不存在，P1 风险面不成立，按死代码处理。
- **【已修复 2026-09-10】**：删除 `NetworkSource` 类及其裸 `Dio()` 依赖（含 dio import）；保留 `PuzzleSource` 抽象与 `AssetSource`/`GallerySource` 实现。`dio` 依赖仍被 `download_manager`/`content_http_client` 使用，不受影响。

### P1-15 AppLogger 文件通道可靠性缺陷 【修订：2 真 1 假，删除第 3 点】**【已修复：丢批恢复 + init 时序】**
- **位置**：`lib/services/app_logger.dart`
  1. **flush 失败丢批**（L294–324）：`lines` 从 `_pendingLines` 取走并 clear 后（L302–303），若 `_rotateIfNeeded()` 或写盘抛错，catch 块只关闭 sink，这批日志**永久丢失**且无计数。**【修订：真实，保留】** **【已修复：catch 中 `_pendingLines.insertAll(0, lines)` 放回队首，下次 flush 重试，时序不被打乱】**
  2. **init 立即完成导致启动早期日志不落盘**（L79–92）：`_initialized = true; _initCompleter!.complete()`（L86–87）在 `unawaited(_initFileAppender())` 完成前执行，`_handleRecord` 里 `_fileEnabled`（L179）仍为 false → `main()` 启动后前 4~6 条关键日志（launch starting、ImageCache tuned 等）不会写文件。**【修订：真实，保留】** **【已修复：`init()` 改为 `await _initFileAppender()` 后再 complete，文件通道就绪才对外宣称已初始化，启动早期日志可落盘】**
  3. **close() 未保存 onRecord 订阅**（L79 与 L503–516）：close 后再次 init 会再挂一个 `Logger.root.onRecord.listen`，每条日志被处理两次。**【修订：不实，删除】** —— 全文件**不存在 `close()` 方法**（仅 `flush()` L503 / `clearAll()` L510 与内部 `_sink?.close()` L317/L354/L514），"close 后再 init 重复挂 listener"场景不存在。
- **建议**：flush 失败把 lines 放回队首；文件 appender 就绪后再 complete（或 init 返回等待其就绪的 Future）。

### P1-16 FavoriteStore.toggle 先改缓存后落盘，失败静默导致状态回跳 【修订：真实，保留 P1】
- **位置**：`lib/data/favorite_store.dart` L200–214（`_saveEntry`/`_deleteEntry` 内 catch 后仅打 warning，L203/L212）、L236–254（toggle 先改 `_entriesCache` 再落盘）
- **机理**：写失败时 UI 已显示新状态，重启后收藏状态回跳；与 `ProgressStore.save` 的回滚策略不一致。
- **建议**：失败回滚缓存或上抛。

### P1-17 首启样例植入存在"半套固化"窗口 【修订：真实，保留 P1】**【已修复：失败回滚】**
- **位置**：`lib/data/game_repository.dart` L264–285：三个样例逐条 `_saveCustomPuzzle`，任一失败 `allOk=false` 不置 `presetsInitialized` 标志；但已写入的 1–2 条留在 collections box 中，下次启动 `rawItems.isEmpty` 不成立 → 走 else 分支（L281–284）**直接把标志补置 true**，缺失样例永不补齐。
- **机理**：与 L264–265 注释"避免半套样例"的声明相矛盾——注释防住了"永久跳过"，没防住"半套固化"。首次启动用户可能只看到 1 个样例。
- **建议**：`!allOk` 时清理本轮已写入的样例 key，或改为按单样例 key 记录完成状态。
- **【已修复 2026-09-10】**：采用方案 A 回滚——记录本轮成功写入的 `plantedSampleIds`，任一失败时逐条 `_deleteCustomPuzzleKey` 清理并打 warning 日志，保持"全有或全无"，下次启动 `rawItems` 为空重新完整植入。

### ~~P1-18 在线取图页 dispose 后长链路副作用继续执行~~ 【修订：部分夸大，降 P2 见 §3】
- 结论：dispose（L88–92）仅取消 bannerTimer、`_webViewController` 未置 null 属实；但 `evaluateJavascript`（L173）有 try/catch、下载失败有 toast（L428–433）——"后台落盘"属**有意行为**（切走仍入素材库），仅缺 dispose 置 null + 入口短路。

### P1-19 裁剪页解码失败静默假死 【修订：真实，保留 P1】**【已修复：失败提示 + 按钮禁用】**
- **位置**：`lib/pages/crop_puzzle_page.dart` L148–182：`_decodeImage` 的 `catch (_) {}`（L176）完全吞掉解码失败。
- **机理**：解码失败时无任何提示或禁用，用户面对一个空的裁切框（`_saveAndCreate` L281 有 `_decodedImage == null` 兜底，不会崩，但等同页面假死）。
- **建议**：catch 中 toast 并提供返回引导（或禁用保存按钮）。
- **【已修复 2026-09-10】**：新增 `_decodeFailed` 状态——catch 中 `setState` 置位并 `GameToast.show` 错误提示（新增 i18n key `crop.decodeFailedToast`，zh/en 双语）；保存按钮 `onPressed` 在 `_isSaving || _decodeFailed` 时禁用；解码成功路径复位标志（防重入）。

---

## 3. 低风险提示（P2，记录备查）

> **【修订】** 原 7 项全部真实（保留）；新增 5 项由 P1/P0 降级而来（编号 8-12），并新增 §7 遗漏 O-5~O-12 中的相关低危项。

1. **SnapshotStore 32 位短哈希 + safeId 归一化**（`snapshot_store.dart` L103–118）：FNV-1a 只取低 32 位，canonicalId 非法字符统一归一为 `_`。当前各 canonicalId 生成源（main:NNN / daily:yyyyMMdd / ugc:dl_时间戳）实际碰撞概率极低，但 pack 类 id 含中文/点号文件名时归一化后区分度下降。建议 load 时校验文件内 canonicalId 与请求一致作为兜底。**【真实】**
2. **game_repository.updateLevelProgress 的 jsonDecode 无独立容错**（L441–443）：`snapshotJson` 脏数据会跳过同批次的进度索引更新（外层 catch 仅 warning）。正常数据源不会触发，但可考虑把 decode 单独 try 住。**【真实】**
3. **`deleteCustomPuzzle` 中快照清理空 catch**（game_repository L362–365）：失败会残留孤儿快照文件；由于 ugc id 是时间戳不会复用，仅产生磁盘垃圾。**【真实】**
4. **`JigsawPuzzleGame` 无 onRemove 清理、zoomNotifier 不释放**：`zoomNotifier`（jigsaw_puzzle_game L162）ValueNotifier 无 dispose/removeListener；ui.Image 由 GamePage 统一 dispose（game_page L917），实际泄漏为每局一个 ValueNotifier，影响极小。**【真实】**
5. **`TrayBackgroundComponent.onDragUpdate` 与碎片滚动路径的 `isDraggingAnyPiece` O(n) 全扫**（jigsaw_puzzle_game L243–244）：托盘滚动热路径每 tick 全量扫描碎片表，大拼图可感知但非功能性问题。**【真实】**
6. **`PuzzleBoardState.fromJson` 缺字段抛的是 `as` 强转的 TypeError 而非 FormatException**（`lib/logic/models/puzzle_state.dart` L23–29/L184–185）：`pieces/rows/cols/seed` 缺失抛 `_CastError`，仅 pieces 数量不符与版本过低抛 FormatException（L187/L195）；调用方若按 FormatException 判定损坏会漏判。当前调用方 `onLoad`（jigsaw_puzzle_game L250+，报告原引 L381–391 为 onLoad 内段）与 snapshot_store 用全量 catch，未实际出错，属契约隐患。**【真实】**
7. **`main_content_pipeline` tmp+rename 的 delete→rename 窗口**（L495–500）：Windows 上 rename 不能覆盖需先 delete，两步之间崩溃会使缓存文件消失（下次重新同步，无数据损坏）。**【真实】**
8. **~~P1-2降级~~ EngineTaskQueue 单飞注销无 identical + key 命名空间未隔离**（`engine_task_queue.dart` L59–62/L113–114；`image_cache_manager.dart` L218）：`clearQueue` 竞态不成立（见 §2），但 `as Future<T>` 隐式契约与本地/网络同 `thumb_<hash>_<dim>.jpg` 命名空间仍建议加 `identical` 守卫 + `net_` 前缀。**【降级，原 P1-2】**
9. **~~P1-6降级~~ Engine 三套容差分裂**（`puzzle_engine.dart` L237:0.05 / L402:0.035 / L170-171:0.40*min(1/cols,1/rows)；`jigsaw_puzzle_game.dart` L1393/1395 48px 上限）：推演正确，但"重复音效+undo 填满"仅 0.05~0.067 带内偶发。建议锁定/级联阈值由 `snapDist` 派生。**【降级，原 P1-6】**
10. **~~P1-9降级~~ zipSha256 声明但从不校验**（`puzzle_collection_item.dart` L23/74/122、`puzzle_event_item.dart` L16/52）：属镜像一致性预留，非功能错误；zipSha256 非空时校验失败回退下一镜像。**【降级，原 P1-9】**
11. **~~P1-11降级~~ daily/events 解压 0 文件仍成功**（`daily_content_pipeline.dart` L90-117、`events` 同）：`extracted==0` 视为失败并清理临时目录。**【降级，原 P1-11】**
12. **~~P1-18降级~~ 取图页 dispose 后长链路**（`online_image_picker_page.dart` L88-92/L345-405）：后台落盘属有意；dispose 置 `_webViewController=null` + 长链路入口 `if(!mounted||_webViewController==null) return` 短路即可。**【降级，原 P1-18】**

---

## 4. flutter analyze 补充说明 【修订：扩充统计口径】

241~242 条 info 与上述问题强相关：
- `avoid_slow_async_io`（84）：**原报告仅点名 2 处（LevelImageResolver、DownloadManager），实际内容管线同步 IO 占约 30 条**——`manifest_router.dart:129,149`、`collections_content_pipeline.dart:283,299`、`events_content_pipeline.dart:225,239`、`daily_content_pipeline.dart:35,85`、`pack_content_pipeline.dart:36,87`、`content_http_client.dart:97,102,133`、`level_image_resolver.dart:64,83,102,121`、`download_manager.dart:61,205`。主线程 `existsSync/listSync/deleteSync` 在批量下载/同步场景可掉帧（见 §7 O-5/O-6），掉帧面被原报告低估。
- `discarded_futures`（72）/ `unawaited_futures`（36）：P1-1、P0-1 即此模式的实际后果实例。**同批含 `test/`（settings_page_ui_test、victory_dialog_ui_test 等）与 `tool/` 目录条目，非全部来自 `lib/`。**
- 另有少量 `avoid_equals_and_hash_code_on_mutable_classes`（14）等类别未在 §0 展开，属风格级。

## 5. 修复优先级建议 【修订：整合两轮复核后的替换表】**【修复版：已修复条目移出待办清单】**

> **【修复版】** 下表为两轮修复后的**剩余待办**：原"立即/近期/择期"中的 P0-2、P0-3、P1-5、P1-7（上一批完成）、P1-10、P1-13、P1-14、P1-15、P1-17、P1-19（本批完成）与 O-3（本批完成）均已实施并通过验证，见各条 **【已修复】** 标注与 `docs/CHANGES-20260910.md`。

| 优先级 | 条目 | 说明 |
|---|---|---|
| **立即** | O-1 | 组1 逐项 catch 降级（§7） |
| **近期** | P0-4、P0-5（addCoins 多步 put 部分）、P1-1、P1-3、P1-4、P1-16、O-4 | bakeOrientation；Economy Future 链串行化；Achievement 回滚/重试；淘汰复查；save 按 key 互斥；Pack 管线对齐（§7） |
| **择期** | P1-8、P1-12、O-5~O-12、P2 全部 | 缓存原子写/schema 校验；同步 IO 异步化；isSolved epsilon 统一；WebView 释放等（§7） |
| **降级/移除** | P0-1→P2、P1-2→P2、P1-6→P2、P1-9→P2、P1-11→P2、P1-15(3) 删除、P1-18→P2 | 均属"建议优化/低频边际"，见 §2/§3 修订说明；P0-5 保留 addCoins 多步 put 部分为 P1 |
| **已修复** | P0-2、P0-3、P1-5、P1-7（上一批）；P1-10、P1-13、P1-14、P1-15、P1-17、P1-19、O-3（本批） | 见各条【已修复】标注；验证见 §0 修复版实测与 `docs/CHANGES-20260910.md` |

## 6. 已排除的疑点（复核阶段剔除，防止后续误修） 【修订：7 项全部成立，保留】

以下问题在初审中被提出，经回到源码逐条核对**不成立或不可达**，记录在此避免重复排查：

1. **"rotateCluster 网格重映射错误 / suggestHintPiece 方法"**：`puzzle_engine.dart` 真实文件中不存在 `suggestHintPiece` 方法，`rotateCluster`（L471–513）中也不存在初审所引的 `newR/newC` 重映射代码（真实实现只更新 nx/ny/rot）；且全 `lib/` 无任何 `rotateCluster` 调用方、UI 无 rotationEnabled 入口，旋转链路整体不可达。
2. **"托盘双重滚动"**：Flame 的拖拽事件按命中测试单组件派发，指针按在碎片上时事件走碎片路径、按在背景时才走 `TrayBackgroundComponent.onDragUpdate`（jigsaw_puzzle_game L85–89 有 `isDraggingAnyPiece` 互斥），两路径互斥，不存在同一手势双倍滚动。
3. **"碎片永久粘在光标上"**：`JigsawPuzzleGame.onTapDown`（L1123–1130）对未处理点击有 `dropHoldingPiece`（L1257）兜底，空白点击可释放。
4. **"EconomyService starter 双发 100 金币"**：`init()` 的 `if (_initialized) return; _initialized = true;` 两行之间无 await，单 isolate 同步段不可交错，第二个并发 init 直接返回。
5. **"game_page lifecycle detached 空指针崩溃"**：observer 在 dispose 中 removeObserver（L903–904），回调触发时 State 必然 mounted；`_flushSync` 有 `_game == null` 防护（L373）。
6. **"PuzzlePieceComponent triggerSnapGlow 异步回调崩溃"**：回调仅读普通字段（`isBorderFilterActive`、`edgeLayout` 已初始化的 late 字段），Dart 对象无悬垂回收问题，最坏是无效赋值。
7. 初审子任务对 Tab 页面（my_center/daily/home/collections 等）产出的"模拟续读内容"段落不可信，已弃用并另行抽查源码：上述页面的 dispose、listener 移除、StreamSubscription 取消（achievements_page L52–53）均正确，未发现严重问题。

---

## 7. 遗漏问题（原报告未覆盖，两轮复核新增）

### O-1 启动组1 `Future.wait` 无逐项降级 【新增，P1】
- **位置**：`lib/main.dart` L137–145
- **问题**：`await Future.wait([ImageCacheManager, GameRepository, Economy, Achievement, Favorite, AppContent].init())` 无 try/catch 逐项降级——任一 init 抛错（尤其 ImageCacheManager 已知可退化，见 P0-2）即**启动白屏**。与 P0-2 的 `complete()` vs `completeError()` 修复互相牵连：改 completeError 必须先给组1 加降级。
- **建议**：组1 逐项 try/catch，失败项记标志降级（如缓存回退内存、成就/收藏跳过），不阻塞首帧。

### O-2 内存回退模式无任何提示 【新增，P1】
- **位置**：`lib/data/storage_manager.dart` L370–394（`openAllWithMemoryFallback`，以 `bytes:Uint8List(0)` 打开内存 Box）
- **问题**：存储初始化失败退化为"全内存"后全会话可玩，但**重启全部数据丢失**；无 UI/日志强提示"临时内存模式"，用户不知情。
- **建议**：检测到 fallback 时顶部横幅 + AppLogger.severe 记录。

### O-3 坏图解码失败后页面滞留 loading 态 【新增，P1】**【已修复：error toast + 自动退出】**
- **位置**：`lib/pages/game_page.dart` L224–250（`_loadImage`/`decodeFlameImage`）、`lib/game/jigsaw_puzzle_game.dart` L250（onLoad）
- **问题**：`decodeFlameImage` 失败 catch 仅 GameToast（'imageDecodeFailed'）并 return，`_game` 仍为 null → 页面持续展示进度圈，**无错误态、无返回/重试入口**（用户可手动返回，但无引导）。原报告未覆盖此路径。
- **建议**：置错误态（如失败占位 + 重试按钮）。
- **【已修复 2026-09-10】**：保留 error toast，新增 `_decodeFailPopTimer`（1.2s）延迟 `Navigator.pop` 退出拼图页——给 toast 展示时间（GameToast 挂在页面 overlay，pop 即销毁）后再退出，杜绝滞留 loading；dispose 同步取消定时器。

### O-4 Pack 内容管线整体漏审 【新增，P1】
- **位置**：`lib/logic/content/pipelines/pack_content_pipeline.dart` L87/L133/L211/L329
- **问题**：与 P1-7/P1-8/P1-11 同根缺陷（无单飞、非原子写、0 文件仍成功、`existsSync` 同步链），原报告仅审了 collections/events/daily/main 四管线，pack 全模块漏审。
- **建议**：按 main 管线范本对齐（单飞 + tmp+rename + extracted 校验）。

### O-5 内容管线同步 IO 规模被低估 【新增，P2】
- **位置**：`manifest_router.dart:129,149`、`collections_content_pipeline.dart:283,299`、`events_content_pipeline.dart:225,239`、`daily_content_pipeline.dart:35,85`、`pack_content_pipeline.dart:36,87`、`content_http_client.dart:97,102,133`、`level_image_resolver.dart:64,83,102`
- **问题**：`existsSync/listSync/deleteSync` 在内容管线批量扫盘，`avoid_slow_async_io` 84 条中约 30 条集中于此，主线程批量场景可掉帧（原报告仅点名 2 处）。
- **建议**：批量场景改异步或缓存 stat 结果；收入同步 IO 治理清单。

### O-6 LevelImageResolver 每次解析全量重扫 【新增，P2】
- **位置**：`lib/logic/cache/level_image_resolver.dart` L76–86、L96–103
- **问题**：每次 `resolveLevelLocalPath` 线性扫 `mainPipeline.levels` + `existsSync`，列表页 N×M 同步 stat；应缓存 `id→localPath` 索引或复用 `ensureMainLevelDownloaded` 单飞。
- **建议**：构建 `id→localPath` 内存索引。

### O-7 缩略图生成失败回退原图可能 OOM 【新增，P2】
- **位置**：`lib/logic/cache/image_cache_manager.dart` L360（生成失败回退 `File(sourcePath)` 数十 MB 原图）、`lib/logic/cache/app_cached_image_provider.dart` L92（同步读全量）
- **问题**：超分原图未限流时，回退路径同步读全量字节可 OOM。
- **建议**：回退路径限字节数/降采样，或返回 null 走占位图。

### O-8 图片 URL 去重未归一化 【新增，P2】
- **位置**：`lib/logic/download_manager.dart` L200–206（`isDownloaded` 严格 `==`）、`lib/logic/cache/level_image_resolver.dart` L36–48（同 hash 算法）
- **问题**：`w=640` vs `w=3840`、`http://` vs `https://`、`?q=90` 变体视为不同源，重复下载/重复落盘。
- **建议**：URL 归一化（去 query 排序、协议归一、尺寸参数归一）后再判重。

### O-9 AppLogger Timer/订阅生命周期 【新增，P2】
- **位置**：`lib/services/app_logger.dart` L283–290、L503–526
- **问题**：`_flushTimer`（800ms）在 `clearAll` 后未 `cancel`；`_sink` 关闭后 `_enqueue` 仍可能吞日志；3000 条环形缓冲无淘汰回调。
- **建议**：clearAll 时 cancel timer；环形缓冲满时回调告警。

### O-10 Hive `_pendingWrites` 无界累积 【新增，P2】
- **位置**：`lib/data/storage_manager.dart` L167、L405–414
- **问题**：`whenComplete remove` 前 List 持有大量已完成 Future；高频 `putJson` 短暂膨胀；`flushPendingWrites`（L422–452）未限并发。
- **建议**：改为 Set + 完成后立即移除；flush 加并发上限。

### O-11 `isSolved` 与引擎容差三套独立 【新增，P2】
- **位置**：`lib/logic/models/puzzle_state.dart` L67（isSolved epsilon 0.035）vs `lib/logic/engine/puzzle_engine.dart` L170/L402
- **问题**：持久化判定 `isSolved(0.035)` 与引擎 `snapDist/epsilon` 三套独立，边缘吸附后可能出现 `progress 100%` 但 `isSolved false` 的极端不一致。
- **建议**：`isSolved` 从引擎同一容差派生。

### O-12 WebView 资源未释放 + 双拦截重复下载 【新增，P2】
- **位置**：`lib/pages/online_image_picker_page.dart` L88、`lib/services/webview_service.dart`
- **问题**：dispose 未 `dispose` `InAppWebView`/`_webViewController`、未清缓存；`shouldOverrideUrlLoading` 与 `onDownloadStartRequest` 双拦截同一下载可重复触发 `_handleDownload`。
- **建议**：dispose 释放 WebView 实例与缓存；拦截入口去重（按 URL 单飞）。

---

*报告结束。审查基于 2026-09-10 工作区代码状态；行号以当日文件内容为准。修订版合并自 `flutter-code-review-20260910-revision.md`（复核一）与 `flutter-code-review-20260910-revision-msf.md`（复核二），原报告存档于 `temp/backups/flutter-code-review-20260910.md.orig-20260910-0936`。*