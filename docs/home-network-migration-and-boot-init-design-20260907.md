# 首页主线全网络化 + 首启初始化 Splash 实施设计（v2 定稿）

> **状态**：方案定稿，待实施
> **日期**：2026-09-07（v2：经第三方评审 + 逐项拍板修订；替代 v1 中 D3/D5/D8 全模块严格门禁等设计）
> **关联**：`docs/home-level-network-distribution-feasibility-20260903.md`、`docs/network-level-lazy-download-plan-20260902.md`、`docs/unified-export-and-manifest-restructure-design.md`
> **影响范围**：`lib/pages/tabs/home_tab_view.dart`、`lib/logic/content/`（AppContent / ContentManager / ManifestRouter / pipelines）、`lib/main.dart`、`lib/data/game_repository.dart`、`lib/logic/catalog_index.dart`、新增 `lib/pages/boot_gate_page.dart`、i18n `lib/l10n/{zh,en}.i18n.json`
> **数据源**：`C:\Home\Projects\jigsaw-data`（deploy 脚本 → 后续 studio 产出），线上 `https://fastly.jsdelivr.net/gh/mcxiaoke/jigsaw-data@master/manifest.json`

---

## 0. 决策汇总（v2 已拍板，本设计以次为准）

| # | 决策项 | 结论 |
|---|---|---|
| D1 | 首页胜利弹窗"下一关" | **不保留**。首页进游戏不传 `levelIndex`；GamePage 现有 levelIndex/next 分支保留不删，但首页路径永不触发 |
| D2 | 内置 100 关 demo | **删除调用、保留函数**：`GameRepository.init()` 不再调 `_initLevels()`，函数体保留（预留内置 samples）；`reloadBuiltinLevelsForTest()` 供测试注入 |
| D3 | 首启门禁范围 | **只等 main**：manifest.json + main/index.json（+缺失批次 batch json）+ main 前 4 关原图。**daily / events / collections 全部后台 best-effort，不进门禁**（首页只消费 main；daily 无 index JSON 落盘机制，无法构成秒开判据；避免二级 Tab 抖动锁死 App） |
| D4 | 老用户秒开判定 | manifest 缓存存在 **且** main 元数据已缓存 **且** 前 4 关图本地存在 → 秒开；任一缺失 → 走初始化 Splash 补齐 |
| D5 | 首启失败策略 | **严格：不满足条件绝不进首页**。manifest/main 元数据/4 图任一失败（含 25s 整体超时，实现常量 `kFirstBootTotalBudget = 25s`，较 D6 原 20s 上调以容纳多源回退）→ 失败页 + 重试。无"降级放行"（没数据/没图进首页无意义；该门槛只在首次初始化发生，后续带缓存秒开） |
| D6 | 整体时限 | 首启整体上限 25s，拆阶段预算：manifest+main 元数据 ≤12s / 前 4 图各 ≤8s（外层 25s 兜底；多源轮询每 URL 4s，最坏 2 源失败 + 命中 ≈ 12s 已覆盖）。首启下载请求显式传小 timeout，防止 downloadFile 默认 60s 吃掉预算 |
| D7 | 默认难度 | studio 下发前统一默认第二档 = square **6×6 / 36 片（L1.5）**：`PuzzleAspectRatio.square1x1.tiers.firstWhere((t) => t.difficulty.recommended)`（与 daily/event/crop 一致） |
| D8 | 首启数据范围 | = D3 集合（main 相关 json + 前 4 图）。daily/events/collections 的 index json **不进首启**，仍由后台增量同步（各自 Tab 保留失败态） |
| D9 | 首启图 | main 前 4 关（order 升序，`kFirstBootMainLevelCount=4`）原图必须落盘；下载失败/超时 → 整体失败页（不因图降级放行） |
| D10 | CDN 多源 | manifest 主备多 URL 轮询（现有 ManifestRouter 机制）扩充国内可达源：gitee / modelscope / Cloudflare R2 作为备用；顺序可在环境适配后调整；后续 url-connected 探针按网络环境动态选源（见 §8）。zip 类资源契约新增 `zipUrls: []` 备用镜像数组（zipUrl 主地址不动），客户端下载失败时轮询备用 |
| D11 | 老数据兼容 | **不做**（开发中未发布，无真实用户）。`catalog_index.dart` main 段直接改扫 `mainPipeline.levels`；不做旧 demo 静态映射 |
| D12 | 工程保障 | gate 同步与后台 sync 收敛共享互斥（防双写）；`ensureFirstBootReady` 单飞防重入；批次完整性校验（防部分批次静默丢失）；Tag 保留双向映射并删除伪 tag 兜底；秒开 0 闪烁（本地初始化前置 runApp） |

---

## 1. 背景与目标

1. 首页主关卡网格 **100% 来自网络**（manifest → main 模块），停用内置 100 关 demo。
2. 首启（判据不满足）展示 **Splash 初始化页**，拉齐"必须数据"（D3/D8/D9）后进首页；失败即失败页 + 重试，**不放行**。
3. 老用户（D4 齐备）**0 闪烁秒开**，后台增量同步。

## 2. 现状速览（代码事实）

| 项 | 现状 | 位置 |
|---|---|---|
| 首页数据源 | `GameRepository._initLevels()` 生成 100 关 `LevelItem`，图片循环 10 张 sample | `lib/data/game_repository.dart:132-191` |
| 首页打开 | `rootBundle.load(level.assetPath)` | `lib/pages/tabs/home_tab_view.dart:129-249` |
| 存档主键 | 旧 demo `main:001~100`；GamePage `levelIndex` → `canonicalForLevel` | `game_repository.dart:124` |
| 网络内容体系 | ContentManager/ManifestRouter/各 Pipeline 完备；main 分卷差集同步+懒下载已实现但首页未消费；daily/events/collections/扩展包已网络化 | `lib/logic/content/` |
| daily 特殊性 | **dailyPipeline 无 index JSON 落盘**（仅 zip 解压）；月份 zip url 仅存内存 `_dailyMonthZipUrls`，拉取异常被吞返回 null | `content_manager.dart:32-34, 68-127` |
| 通用网络关卡 | `LevelImageResolver` + `LazyLevelImage` + `ProgressStore.getLevelProgress`(O(1)) + `progressNotifier` | `lib/logic/cache/level_image_resolver.dart`、`progress_store.dart:258,180` |
| 启动 | `main.dart` 组2 后台 `AppContent.init()`（内置 fire-and-forget `_backgroundSync`）；`home=MainScreen` 无 Splash | `lib/main.dart:140-170,240`；`app_content.dart:52-106` |
| CDN | `defaultBootstrapUrls` = fastly.jsdelivr + raw.githubusercontent（**均 GitHub 生态**） | `app_content.dart:47-50` |

## 3. 总设计

### 3.1 本地优先启动（0 闪烁秒开）

```
main()
 组1（runApp 前 await）：
   ... 现有 GameRepository/Storage 等
   + AppContent.initFromDiskCache()      // 新增：纯本地读缓存（manifest_cache.json + 各 pipeline cache），
                                         // 5~15ms，不触发任何网络
 组2（后台，不阻塞首帧）：
   DownloadManager / SoundService 等     // AppContent 不再在此后台自启 sync（防竞态，见 3.3）
 runApp 前同步判定：
   final isReady = AppContent.instance.isFirstBootReady();   // D4 判据（纯本地同步）
 runApp(JigsawPuzzleApp(initialHome: isReady ? MainScreen() : BootGatePage()))
```

- 老用户第一帧直接渲染 MainScreen（真 0 闪烁）；MainScreen 挂载后由 AppContent 触发后台增量 `syncAll()`。
- 首启用户第一帧即 BootGatePage（Splash），走 §3.2。

### 3.2 BootGate 初始化流程（首启）

```
BootGatePage.initState
 ├─ isReady（D4）为 false 才出现
 ├─ Splash 视图（品牌图 + 分段文案，不只有转圈）
 └─ await AppContent.instance.ensureFirstBootReady()   // 单飞守卫（in-flight 防重入）
      ├─ 成功 → pushReplacement(MainScreen) + 后台续跑其余模块 sync
      └─ 失败 → 失败视图（阶段错误文案 + 重试按钮 → 重新 ensureFirstBootReady）
                不满足条件绝不进 MainScreen（D5）
```

`ensureFirstBootReady()` 严格步骤（**任一失败整体失败**）：

```
0. 单飞：同一时刻仅一轮（复用/并行 _isSyncing 语义），超时后点重试等旧轮结束
1. manifest：manifestRouter.resolveManifest(forceRefresh: true, 预算 ≤6s)
   校验：baseUri 非空 && mainModule.url 非空 && schemaVersion ≥ 要求
   （网络全败会降级 disk/fallback=空 url，此处判定失败）
2. main 元数据：mainPipeline.syncWithRemote(remoteUrl, remoteVersion)（≤6s）
   校验 A：mainPipeline.localBatchIds ⊇ 远端 index 全部 batchId   // 防部分批次静默丢失
   校验 B：levels.length ≥ min(kFirstBootMainLevelCount, 远端 totalCount)
3. 前 4 关原图：按 order 升序取前 4，并发 ensureLevelImageDownloaded（单张 ≤8s，方法失败 rethrow）
4. 整体 ≤25s 外层兜底（`kFirstBootTotalBudget`，实现较 D6 原值 20s 上调）
说明：全程收敛到 ContentManager（共享 _isSyncing 互斥）；
      events/collections/daily 的同步不在此路径，由进入 MainScreen 后的后台 syncAll 接管。
```

### 3.3 AppContent / ContentManager 改造

| 现状 | 改为 |
|---|---|
| `init()` = 本地缓存 + `_backgroundSync()` fire-and-forget | 拆 `initFromDiskCache()`（纯本地，供组1 await）；**init 不再自动后台 sync** |
| 后台 sync 由 init 派生 | 时机收口：MainScreen 挂载后 / BootGate 成功后显式调用 `syncAll()` |
| `syncAll()` 无条件含 daily 月度 zip 下载 | 增加参数 `includeDailyZip = true`；首启后的后台全量 sync 用它；**daily/events/collections 全部走此路径（best-effort，失败不阻断首页）** |
| 无互斥暴露给 gate | gate 路径直接调用 `manager.syncAll(includeDailyZip:false)` + `ensureMainLevelDownloaded`，天然共享 `_isSyncing` 互斥 |
| 多 URL 轮询已支持 | `defaultBootstrapUrls` 扩充多源（§0 D10），沿用主备轮询 |

### 3.4 首页（home_tab_view）数据源切换

| 现状 | 改为 |
|---|---|
| `_repo.levels`（LevelItem） | `AppContent.instance.manager.getMainLevels()`（PuzzleLevelItem，order 升序）；监听 `contentUpdateNotifier` + `progressNotifier` |
| Tag 过滤（home 现有双向映射逻辑 `_getFilteredLevels`） | **保留首页自身的中英双向映射过滤**（`kTagZhToId`/`kTagIdToZh`），仅数据对象换成 PuzzleLevelItem；**不直接换 `mainPipeline.filterByTag`**（其只做英文小写匹配，中文会空） |
| `_resolveTag`（按 `(index-1)%17` 伪 tag 兜底，home_tab_view:66-70） | **删除**；关卡 tags 为空时归入 `Others` |
| 卡片缩略 `AppCachedImage(assetPath)` | `LazyLevelImage(level: level)`（与 event_levels_page 同款） |
| NEW / 进度角标（LevelItem 内存字段） | `ProgressStore.instance.getLevelProgress(level.id)` 合成；`isNew` 用 level.addedAt |
| 打开关卡 `rootBundle.load` | `LevelImageResolver.instance.resolveLevelLocalPath(level)` → 本地文件读 bytes；http 结果 toast 失败（照抄 `event_levels_page.dart:71-115`） |
| `GamePage(levelIndex:)` | `GamePage(canonicalId: level.id, packTitle: level.displayTitle, difficulty: 默认第二档 D7/用户所选)`；存档落 `main:NNN`，胜利无"下一关"（D1） |
| 进度清档 `updateLevelProgress(levelIndex,0)` | `updateGenericProgress(canonicalId: level.id, progressPercent: 0)` |
| `RefreshIndicator` 仅 setState | 触发 `AppContent.instance.syncAll()`，等 notifier 刷新 |
| 空态 | 保留"分类无图"空态；数据未就绪已被 BootGate 拦截 |

### 3.5 demo 数据停用（D2/D11）

| 位置 | 改动 |
|---|---|
| `game_repository.dart:116` | `init()` 删 `_initLevels();` 调用（函数体保留，注释预留内置 samples） |
| `game_repository.dart` | `levels`/`updateLevelProgress`/`canonicalForLevel`/`loadLevelSnapshot*` 等方法保留不删；新增 `@visibleForTesting reloadBuiltinLevelsForTest()` |
| `catalog_index.dart:88` | main 段改扫 `mainPipeline.levels`；**不做旧 demo 静态映射**（D11，未发布） |
| `unlock_service.dart` / `achievements_page.dart:71` | 保留（levels 空时天然无行为影响） |
| `assets/images/sample_*.jpg` | 保留：自制拼图默认样例 + 每日卡片占位；仅不再是主线关卡内容 |

### 3.6 CDN 多源（D10）

- `lib/logic/content/app_content.dart`：`defaultBootstrapUrls` 已恢复多源（2026-09-07）：
  `[fastly.jsdelivr (海外主), raw.giteeusercontent macitee 镜像 (国内主), raw.githubusercontent (海外备)]`；
  modelscope / Cloudflare R2 备用在**镜像 URL 就绪后追加**（切勿编造不存在的 URL 拖慢轮询）。
  ⚠️ 所有镜像仓库内容须与 `mcxiaoke/jigsaw-data` 同步一致，否则回退会拉到版本不一致的 manifest；
  顺序轮询 + 后续 url-connected 探针动态分组选源（见 §8）。
- 数据契约：zip 类资源（daily 月度 zip / collections zip / events zip）字段扩展 `zipUrls: []`（镜像数组，`zipUrl` 主地址不变）；客户端下载失败时按序轮询备用镜像（download 层小改）。
- ManifestRouter 现有顺序轮询已支持多 URL，无需重构；首启阶段预算已按多源回退上调（D6）。

## 4. 改动文件清单

### 4.1 新增

| 文件 | 内容 |
|---|---|
| `lib/pages/boot_gate_page.dart` | BootGate 状态机：判定 → Splash(分段文案) / 失败视图(重试) / 跳 MainScreen |
| `docs/CHANGES-20260907.md` | 实施后顶部追加变更摘要 |

### 4.2 修改

| 文件 | 改动摘要 |
|---|---|
| `lib/logic/content/app_content.dart` | `initFromDiskCache()`、`initializedFuture`、`isFirstBootReady()`、`ensureFirstBootReady()`、`defaultBootstrapUrls` 多源、常量 `kFirstBootMainLevelCount=4` / 阶段预算；移除 init 内自动 `_backgroundSync`（时机收口调用方） |
| `lib/logic/content/content_manager.dart` | `syncAll({bool includeDailyZip=true})`；批次完整性校验辅助；gate 路径收敛互斥 |
| `lib/logic/content/pipelines/main_content_pipeline.dart` | `ensureLevelImageDownloaded` 增加 in-flight 单飞 Map（防同 URL 并发写） |
| `lib/main.dart` | `AppContent.initFromDiskCache()` 进组1 await；runApp 前判 `initialHome`；`home:` 条件路由 |
| `lib/pages/tabs/home_tab_view.dart` | §3.4 全部切换 |
| `lib/data/game_repository.dart` | 停用 `_initLevels` + 测试钩子（§3.5） |
| `lib/logic/catalog_index.dart` | main 段改扫 `mainPipeline.levels` |
| `lib/l10n/zh.i18n.json` / `en.i18n.json` | `boot.*` 文案 + slang 重新生成 |

### 4.3 受影响测试（需适配）

`test/data/game_progress_migration_test.dart`、`test/data/game_state_migration_test.dart`、`test/new_features_test.dart`、`test/widgets/locale_switch_refresh_test.dart`、`test/widget_test.dart` → 用 `reloadBuiltinLevelsForTest()` 注入或改网络管线 stub；`flutter test` 全绿为准。

## 5. 验证方案

1. `dart format`（仅改动文件）→ `flutter analyze` 0 error → `flutter test` 全绿 → `flutter build windows --debug`。
2. 手动场景（清 support/documents 目录对应缓存模拟首次）：

| 场景 | 预期 |
|---|---|
| 冷启动无缓存（有网） | Splash → 拉 manifest + main 元数据 + 前 4 图 → 进首页，网格 ≥4 关有图 |
| 二次启动（缓存+4 图齐） | **0 闪烁**直进首页，后台增量 |
| 删掉前 4 图任一（manifest/main 缓存仍在） | 判定不满足 → Splash 补齐 4 图后进 |
| events/collections/daily JSON 全挂（main 正常） | **不影响首启**，正常进首页；切到对应 Tab 显示各自失败态/重试 |
| 断网冷启动（无缓存） | 失败页（≤25s），重试按钮；联网后成功进入；断网下不进入（D5） |
| 首页点开网络关卡 | 懒下载原图 → 选难度(默认 36) → 进游戏 → 进度落 `main:NNN` |
| 胜利弹窗 | 无"下一关" |
| 分类过滤 | 中英双向映射过滤正确；无 tag 关卡归 Others；无伪 tag 轮转 |
| manifest 主 URL 挂（jsdelivr 不通） | 轮询到 gitee/raw 等备源成功初始化 |

## 6. 实施顺序

1. `game_repository.dart` 停用 demo + 测试钩子 → 修受影响测试。
2. `home_tab_view.dart` 数据源切换（含 Tag 过滤保留/伪 tag 删除）。
3. `catalog_index.dart` main 段切 `mainPipeline.levels`。
4. AppContent/ContentManager：`initFromDiskCache` / `isFirstBootReady` / `ensureFirstBootReady` / `syncAll(includeDailyZip)` / 单飞与批次校验 / 多源 URL / boot 文案 i18n。
5. 新增 `boot_gate_page.dart` + `main.dart` 0 闪烁接线。
6. analyze / test / build + 手动场景表。
7. `docs/CHANGES-20260907.md` 顶部追加。

## 7. 风险与边界

- **首启硬门槛被接受**：D5/D9 下弱网首启可能停在失败页重试（开发中未发布，可接受；图片存 appDocuments 非可清理缓存，D4"图被清"场景发生概率低，图被清时重新补齐即可，行为一致）。
- CDN：主备轮询已覆盖多源；同源风险由 gitee/modelscope/r2 分散；最终动态选源见 §8。
- 竞态/双写：由 3.3 收敛 + 单飞守卫 + `_isSyncing` 互斥消除。
- 已知遗留（非本期）：daily Tab 运行期"index 拉取失败 vs 当月缺失"不可区分（`resolveDailyMonthZipUrl` 吞异常）——已在 UI 有失败兜底，增强留 daily 专项（§8）。

## 8. 后续（非本期）

- studio 导出就绪：batch item 增 `difficulty`，客户端读字段替代默认第二档（D7 解除）。
- url-connected 探针：按网络环境（大陆/海外）动态选择 manifest 与 zip 镜像源；zipUrls 轮询完善为探针驱动。
- daily 专项：`resolveDailyMonthZipUrl` 区分"失败/当月缺失"，daily Tab 明确错误态；可加 index json 落盘以支持 daily 离线秒开。
- 可选：换图语义（`status:retired`/`replacedBy`）、缩略图最小集软超时、EngineTaskQueue 限流、磁盘 LRU。
