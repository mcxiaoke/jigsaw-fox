# Jigsaw Puzzle 整App综合体检与对标优化方案

> **文档版本**：v1.2 交叉验证修正版（采纳 2026-09-02 6条反馈 + 6项引用校正 + 3项补充决策）  
> **创建日期**：2026-09-02  
> **修订日期**：2026-09-02  
> **验证备注**：已按逐行代码交叉验证修正 6处引用与并行化风险；`§3.3` NEW 定为 `addedAt` 7天、`§8.4` 日帽首期200不动、`§13` 补锁态UI移除项
> **评审范围**：全App（导航/首页/每日/活动/自制/游戏内核/难度/经济/成就/内容管线/性能/无障碍）  
> **代码基线**：`lib/main.dart:1` `lib/pages/main_screen.dart:1` `lib/pages/tabs/*` `lib/pages/game_page.dart:1` `lib/data/*` `lib/logic/*` `lib/theme/*` `docs/jigsaw-puzzle-game-prd.md:1`  
> **对标竞品**：Magic Jigsaw Puzzles(ZiMAD, 40k张/1.2k块) / Jigsaw Puzzles(Easybrain, 30k张/400块, 100M+) / Jigsawscapes(Oakever, 60k张) / Microsoft Jigsaw  
> **前置评审**：`docs/home-navigation-and-sorting-ux-design-20260902.md:1` + `docs/home-navigation-sorting-implementation-plan-20260902.md:1` + 4份独立评审(dsf/bdm/gmp/msf)

> **本次修订要点**：按6条反馈冻结解锁/移除排序/精简AppBar与启动链路/明确DIY特色与关卡商店规划/GamePage优化延后/经济模型重定义为“星=荣誉/币=流通”。

---

## 0. 一句话结论

**首页范式已对齐主流：全部可浏览、无解锁墙、无排序、无统一难度筛选；差异化在“官方发布(活动/关卡商店) × 社区DIY(我的)”双轨。** 当前 `100关 Sample循环` 仅是数据接入前过渡，AI批量产能与200+精选已就绪，后续通过 `manifest` 预留的金币/兑换码等轻解锁字段做象征性运营，不阻断浏览。Flame内核与三级缓存已达商业级，本轮 **P0仅剩首页重构**，其余延后按阶收敛。

**体检总分：★★★★☆（内核强、壳层待收敛）**：引擎/异形切割/存档管线商业级；壳层P0已聚焦至首页单点。

---

## 1. 对标方法与竞品画像

| 维度 | Magic Jigsaw | Easybrain | Jigsawscapes | 本App目标态（修订后） |
|---|---|---|---|---|
| 内容体量 | 40k+ 图，每月上新 | 30k 图，每周上新 | 60k 图，每周上新 | 200精选起步，AI周更，永久活动包打底 |
| 首页心智 | 合集画廊 Pack/Collection | 分类画廊 Category | 分类+合集 | 画廊浏览，无墙 |
| 解锁 | 币/订阅解锁包 | 币解锁独占图 | 订阅Plus | 首期全开浏览；`manifest`预留`unlockCoins/redeemCode`字段，后续对**新增**合集/关卡做象征性金币解锁 |
| 筛选 | 仅分类横滑 | 仅分类横滑 | 分类+收藏 | 单行Tag横滑(热门N个)+`全部` Sheet(21)，无排序 |
| 收藏/NEW | ♥收藏+最近玩过 | ♥收藏（Top诉求） | 收藏+复玩 | 预留♥与NEW，二期接 |
| 每日 | 每日一图强入口 | 每日一图+神秘图 | 每日一图 | 按月网格+未来隐藏，已就绪 |
| 活动/商店 | 限时合集 | 活动+赛季 | 合集 | 活动=官方发布，商店=合集商城（远端manifest），二期 |
| 自制 | 自制拼图 | 自制 | 自制 | DIY特色：相册/素材库/在线搜图三通道完整 `lib/pages/tabs/my_puzzles_tab_view.dart:1` |
| 商业化 | 广告+订阅 | 广告+内购 | 广告+订阅 | 无广告，币易得（登录/活动/兑换码），星难得作荣誉 |
| 评星 | 无 | 无 | 无 | 保留1-3星双轴，仅荣誉不卡关 |

**关键洞察**：头部都不做状态过滤与排序——因为无线性束缚无需筛；都做分类横滑与合集策展——因为图多靠挑图。

---

## 2. 全局导航与信息架构

### 2.1 现状

`lib/pages/main_screen.dart:16` 4-Tab `主页/每日/活动/自制` + AppBar `🦊异形拼图 + 🪙1280 + 🏆 + ⚙️`。`lib/main.dart:58` 起 8步串行初始化（含 `AppLogger.init():26`）。

### 2.2 定向反馈采纳

> 反馈1：数据都准备好了不存在空内容；AppBar只留成就icon，设置icon仅在“我的”Tab显示；深色模式后续放设置里；启动串行要改有些可不await；活动是官方发布、导入是用户/社区自制、我的主打DIY是特色。

| 编号 | 结论 | 落地 |
|---|---|---|
| G-01 | **不视为问题**。数据就绪仅待接入，空状态仅过渡 | 活动/商店上线前用永久活动包兜底，无需空状态运营位 |
| G-02 | **采纳**：AppBar精简为仅`🏆成就` | `main_screen.dart:72` 移除`🪙`与`⚙️`；`🪙`移至成就/设置内或首页轻量胶囊；`⚙️`仅在`_currentIndex==3`（我的）时显示 |
| G-03 | **延后**：深色模式放设置 | `main.dart:123` 保持`ThemeMode.light`首期不变；设置页新增`主题:跟随系统/亮色/暗色`开关，二期切`ThemeMode.system` |
| G-04 | **P0保留**：启动并行化 | 见§2.3 |
| G-05 | **澄清非重叠**：活动≠扩展包 | 活动=官方发布（运营侧）；导入/扩展包=用户与社区自制（UGC侧）；关卡商店=官方商店（新增，见§5）。文案上严格区分“官方活动/商店” vs “我的DIY” |

### 2.3 唯一P0：启动链路

`lib/main.dart:58` 起 8个await串行（含 `AppLogger.init():26`）易白屏。

**改法**：分组并行，仅非关键路径可不await（`EconomyService`/`AchievementStore` 必须首帧就绪，见 `main.dart:80` 注释）：

```dart
// 最前置：日志
await AppLogger.init();
// 组1 必须await（首屏/币/成就依赖）
await Future.wait([
  ImageCacheManager.instance.init(),
  GameRepository.instance.init(),
  EconomyService.instance.init(),
  AchievementStore.instance.init(),
]);
// 组2 可后台（不阻塞首帧）
unawaited(Future.wait([DownloadManager.instance.init(), AppContent.instance.init()]));
// 组3 可后台（音频等）
unawaited(SoundService.I.init());
```

> **风险备注**：`EconomyService`/`AchievementStore` 不可 unawaited——`main.dart:80` 明确“新手赠送 5券+100币与成就计数在首帧前就绪，避免首帧读 coins 返回0或成就事件阻塞”。原方案将其放入后台会导致首帧币显示为0、首个成就事件丢失。

首帧先出壳（骨架Grid），后台同步完成后 `contentUpdateNotifier` 刷新。

---

## 3. 首页主线（Home）—— 本轮唯一P0

> 反馈2/3核心：首页全部可浏览不设解锁（manifest预留`unlockCoins`等字段供后续新增合集象征性解锁）；Tag为单行热门+`全部` Sheet(21)；**不要排序**；卡片不显示关卡序号仅图+NEW；难度统一筛选去掉每关自有难度，卡片可选显示最高难度块数。

### 3.1 现状

`lib/pages/tabs/home_tab_view.dart:1`：Banner160dp + Filter6胶囊（含伪难度）+ Tag5类`index%5` mock + 网格2列。4份评审与A+方案均已指出伪难度/排序冗余/Tag过重。

### 3.2 修订后目标形态

```
┌─────────────────────────────────────────┐
│ AppBar: 异形拼图              [🏆]      │  56dp  仅成就
├─────────────────────────────────────────┤
│ Header(可滚动，不吸顶)                   │  ~120dp 横滑
│  [每日挑战大卡] ↔ [活动A] ↔ [活动B]     │  PageView/Banner
├─────────────────────────────────────────┤
│ [吸顶] Tag栏 44dp  (pinned)              │
│  [全部] [🐾宠物] [🏞️风景] ...  [▦全部]  │  横滑+固定入口
├─────────────────────────────────────────┤
│ 关卡网格 2列  纯图卡  [NEW] 角标          │
│  可选右下 `◈ 225` 最高难度块数           │
└─────────────────────────────────────────┘
```

**交互规则**：

- **无解锁**：全部关卡 `isUnlocked=true`，`home_tab_view.dart:898` `需 ${index*2} 星解锁` 锁态文案与 `unlock_service.dart:146` `checkLevelUnlock` 关卡链式逻辑**首期禁用并移除锁态UI**（保留难度档位墙 `L4需2张3星` 亦延后或仅作提示不阻断）。`manifest` 增 `unlockCoins?: number, unlockCode?: string` 供后续新增合集/关卡做象征性金币/兑换码解锁，首期全量 `0`。
- **Tag**：单行横滑展示 `全部 + 热门N个(6-7个)`，末尾固定 `▦全部` 图标，点击弹 `BottomSheet` 展示21 Tag（3列网格，`Emoji+中文+关卡数`，选中态描边）。热门N个**数据驱动**取 `COUNT(tags) TOP N`，运营可覆写。
- **无排序**：删除 `home_tab_view.dart:16` `LevelFilter` 的 `starter/intermediate/master` 伪难度枚举（**注：`LevelSortOrder` 不存在于代码库，勿删**；全局仅 `LevelFilter` 需清理），不再提供排序入口。网格默认按 `manifest.order` 升序（即运营排序），即“精选顺序”。
- **卡片**：移除 `#index` 序号药丸；仅保留图片 + 底部渐变 + `NEW` 角标（见§3.3）+ 可选右下 `◈ 225` 最高难度块数（取该图支持的最大 `pieceCount`，如 `400`）。已完成态用 `✓` 或 `⭐⭐⭐` 轻徽标，不做大面积遮罩。
- **Header**：`_DailyBanner` 改为可横滑的 `PageView`，第1页每日挑战，第2..N页为活动/商店精选（取 `AppContent.getVisibleEvents().take(3)`），**不吸顶**，随列表滚动。**仅Tag栏吸顶** `SliverPersistentHeader(pinned:true, minExtent:44, maxExtent:44)`。

### 3.3 NEW 显示逻辑（无排序场景）

> 反馈：没有排序时需考虑数据与展示逻辑。

**数据侧**（`manifest` + `ProgressStore`）：

- `manifest.json` 每条 `level: { ..., addedAt: "2026-09-01", order: 101 }` **新增 `addedAt` 为SSOT**（运营发布时写入，AI产线自动填）。`PuzzleLevelItem:38` 已有 `order/tags`，需增 `addedAt: DateTime?`。
- 客户端本地记录 `firstSeenAt`（首次拉取到该 `canonicalId` 的时间，存 `progress_store` extra或独立key），用于“首次可见”口径兜底（**首期不启用**）。

**展示侧**（已决策：采用方案A，B废弃）：

- **采用方案A 时间口径**：`isNew = addedAt != null && now.difference(addedAt).inDays < 7`，且 `!isCompleted`。7天阈值可配置，运营可通过更新 `addedAt` 刷新NEW。**决策依据**：`addedAt` 由运营/产线写入，语义清晰可追溯、可回刷；与竞品 Jigsawscapes 的“上新7天角标”一致，且不依赖客户端本地时钟与首次拉取时机，避免 `firstSeenAt` 因用户长期未更新或重装导致的 NEW 误判与不一致。

- **废弃方案B 首次可见口径**：`isNew = firstSeenAt != null && now.difference(firstSeenAt).inDays < 3 && !isCompleted`，因依赖本地 `firstSeenAt`，不同设备/重装表现不一致，且运营不可控，**不采用**（仅作为后续“首次可见3天”补充口径的备选，需另行评估）。

**工程**：`LevelItem`/`PuzzleLevelItem` 补 `addedAt`；`home_tab_view` 卡片左上 `NEW` 斜角飘带（`#C97A2E` 橙棕，`12sp` 斜粗，见 `hometab-reference-implementation-20260902.md:3.6`）；已通关或超过7天自动消失，无需排序支撑。

### 3.4 卡片最高难度块数（可选）

取 `PuzzleAspectRatio.square1x1.tiers.last.pieceCount` 或该图 `availableDifficulties.max`，右下 `◈ 144` 半透明药丸展示，提示“可挑战至144块”，与竞品一致。不影响筛选。

### 3.5 实施清单（首页P0）

- [ ] `level_item.dart:1` `PuzzleLevelItem:6` 补 `addedAt` + `unlockCoins?` 预留；`game_repository.dart:132` 禁用关卡墙，全部`isUnlocked=true`
- [ ] `home_tab_view.dart:1` 删除 `LevelFilter` 中 `starter/intermediate/master` 伪难度与排序（`LevelSortOrder` 不存在于代码库，勿删），Tag改为单行热门+固定`▦全部`入口，BottomSheet 21宫格（详见 `docs/hometab-reference-implementation-20260902.md:1` 按 Jigsawscapes 1:1 复刻）
- [ ] `home_tab_view.dart:898` 移除 `需 ${index*2} 星解锁` 锁态UI及灰度/锁态逻辑
- [ ] Header改为可横滑 `PageView`（每日+活动3个），不吸顶；Tag栏 `SliverPersistentHeader` 单行吸顶44dp
- [ ] 卡片移除序号，仅图+NEW+可选`◈块数`，灰度/锁态全部移除（圆角8dp、间距10dp、New斜角飘带，NEW采用 `addedAt` 7天口径见§3.3）
- [ ] `main_content_pipeline.dart:213` `_parseLevelItem` 解析 `addedAt/unlockCoins` 并透传
- [ ] 启动并行化 `main.dart:58`（含 `AppLogger.init():26`，`Economy/Achievement` 必须在组1 await，见 `main.dart:80`）
- [ ] 标题/Header保持现有简洁样式（不复刻参考的 `图库` 大字/斜切Banner），仅复用其“Header可滚、Tag单行+固定☰吸顶、网格纯图”布局

---

## 4. 每日挑战（Daily）

现状 `lib/pages/tabs/daily_tab_view.dart:1` 按月分组+连胜已优于竞品。

**结论**：保持现状，数据侧由 `bing_daily_data.dart` 静态包逐步切至 `DailyContentPipeline` 远端增量（与主线同链路），避免月更发版。首页Header已承担“今日挑战”强入口，无需额外改造。

---

## 5. 活动中心与关卡商店（Events / Shop）

> 反馈4：有计划但还没做，可加载远端manifest；正式上线至少有几个永久活动包，不存在空状态；AI批量产能不是问题。

**现状** `lib/pages/tabs/events_tab_view.dart:1` 大卡236dp，`AppContent` 已支持 `manifest` 多端点增量与ZIP离线包。

**修订**：

- **概念**：活动=官方发布（限时/永久混排），关卡商店=官方商店（常驻合集商城，远端manifest），二者数据源同为 `ContentManager`，UI可二合一或商店作为活动内二级页。
- **空状态**：**不做**。首发预置≥3个永久活动包兜底（猫咪/风景/艺术各一），`events_tab_view.dart:50` 空态分支保留但永不触发。
- **后续预留**：`manifest` 活动条目增 `unlockCoins/redeemCode/validFrom/validTo` 字段，支持金币/兑换码象征性解锁。
- **本轮不做**：商店UI与解锁流程延至二期，本文仅预留字段。

---

## 6. 我的拼图 / 自制（My Puzzles）—— 特色模块

> 反馈1：我的主打DIY是本App特色。

现状 `lib/pages/tabs/my_puzzles_tab_view.dart:1` 三通道 `相册选图/素材库/在线搜图` + 已导入扩展包 + 自制Grid，已是全App最完整。

**修订**：

- **AppBar设置收敛**：`main_screen.dart:72` `⚙️设置` 仅在 `My` Tab显示，其余Tab隐藏，保持首页清爽。
- **4卡保留**：`相册选图/导入关卡包/素材库/在线搜图` 四卡认知已清晰（前二为入口，后二为仓库），**不合并**，突出DIY特色。
- **设置入口**：设置页内保留 `外观/背景/数据管理`，暗色模式开关放设置页（见§2.2 G-03）。
- **本轮不做**：自制筛选/批量导入闭环等P1延后。

---

## 7. 游戏内核（GamePage + Flame Engine）

> 反馈5：GamePage优化可能影响拼图功能，先写但延后。

现状 `lib/pages/game_page.dart:1` + `lib/game/jigsaw_puzzle_game.dart:1` 已达商业级（异形贝塞尔、Click-to-Pick集群拖拽、像素恒定吸附阈值 `jigsaw_puzzle_game.dart:1174`、三重落盘）。

**修订**：本报告中 `G-P0-1` 顶部操作过密、`G-P1-1` Victory两套割裂等**全部标记为二期**，首期不动游戏内核，仅保证存档与性能现状。

---

## 8. 难度 / 星级 / 解锁 / 经济

> 反馈6：星是难得的荣誉，金币易得多给；每日打开自动给金币/活动送金币/兑换码；解锁暂时全部去掉，后续新增关卡/合集再考虑金币等象征性解锁。

### 8.1 难度

`lib/logic/puzzle_model.dart:1` 7档 `L1(25/24)→L6(400/384)` 自适应已完善。本轮**移除首页统一难度筛选**，每关难度在 `choose_difficulty_sheet.dart:1` 内自选，卡片可选显示最高块数。

### 8.2 星级

`lib/logic/star_calculator.dart:1` 双轴 `TimeScore×HintScore` 保留，**仅作荣誉**，不卡关卡也不卡难度（难度墙亦延后）。结算页可增“为何2星”解释，二期。

### 8.3 解锁（修订）

- **首期：全部可玩**。关卡墙与难度墙均不阻断，`unlock_service.dart:146` `checkLevelUnlock` 与 `kDifficultyStarImageRequirements` 仅作提示徽标（如“L4建议先获2张3星”），不置灰。
- **后续**：`manifest` 预留 `unlockCoins/unlockCode` 对**新增**关卡/活动做象征性解锁（例：新合集需50金币或兑换码），老内容永不追溯加锁。

### 8.4 经济（修订）

`lib/services/economy_service.dart:1` 现有 `kDifficultyBaseCoins + kStarBonusTable + 日帽200 + 新手100币5券` 自洽。

**修订**：

- **币易得**：提升产出——每日首次打开 `+10`（`EconomyService` 新增 `dailyLoginBonus`）、活动/商店合集完成额外送币、兑换码 `redeemCode → +coins`（二期）。
- **星难得**：保持 `StarCalculator` 阈值不变，星仅用于成就与荣誉榜。
- **日帽**：**首期不动，维持 200/日**（`economy_service.dart:65` `kDailyCoinCap=200`）。放宽至 400 的提议**不在本期实施**，待上线后按活跃与产出数据再评估，避免首期通胀；文档中“可保留或放宽至400”仅为二期备选，已明确结论为不动。
- **消耗**：提示 `kHintPrices[5,6,10,15,20,25,35]` 保持，券优先 `consumeHint`。

---

## 9. 成就与统计

`lib/pages/achievements_page.dart:1` 25项+6看板已完整。入口由AppBar `🏆` 保留，首页不再重复进度胶囊。解锁动效与宗师进度环二期。

---

## 10. 内容管线与存储

`lib/logic/content/app_content.dart:37` 内网 `192.168.1.118/manifest.json` 需切生产CDN多备源；`bing_daily_data.dart` 逐步切远端增量；`lib/logic/image_source.dart:7` 定义 10张 `assetSamples`，在 `game_repository.dart:137` 循环复用待200精选接入。管线架构已领先，无新增P0。

---

## 11. 设计系统 / 性能 / 稳定性 / 无障碍

- 设计：`lib/theme/app_palette.dart:1` M3 `fromSeed(#D4963C)` 规范，暗色延后放设置。
- 性能：`AppCachedImage:47` 档位化+`ResizeImage`+磁盘缩略已优；`main.dart:31` 150MB/500张二期再压。
- 稳定性：`app_logger.dart:1` + `migration_service.dart:1` 已具备。
- 无障碍：Tag抽屉Emoji在Windows黑白需 `assets/icons/tag_*.svg` 兜底（`msf:5`），二期。

---

## 12. 缺失能力矩阵（修订）

| 能力 | 竞品 | 本轮 | 后续 |
|---|---|---|---|
| ♥收藏 | Easybrain Top诉求 | 预留字段，二期UI | 二期 |
| NEW徽标 | 上新7天角标 | **P0 卡片NEW**（`addedAt`口径） | - |
| 搜索 | 搜lemur | 二期 | 本地Tag倒排 1d |
| 关卡商店 | Pack商城 | 预留manifest字段 | 二期商店页 |
| 金币解锁/兑换码 | 币解锁 | 预留`unlockCoins/unlockCode` | 二期对新增合集启用 |
| 每日登录送币 | 登录奖励 | 二期 `+10/日` | - |
| 分享/壁纸 | Victory预留 | 二期 | - |
| 横屏/平板 | 响应式Grid已做 | 二期（游戏内） | - |

---

## 13. 分阶段实施路线图（修订版，P0聚焦首页）

### Phase 0 首页P0（2-3天，本轮必做）

- [x] `main.dart:58` 启动并行化（最前置 `await AppLogger.init():26`，组1 `await [ImageCacheManager, GameRepository, EconomyService, AchievementStore]`，组2/3 `unawaited [DownloadManager, AppContent, SoundService]`；`Economy/Achievement` 不可后台，见 `main.dart:80`）
- [x] `main_screen.dart:16` AppBar仅留`🏆`，`⚙️`仅My Tab显示
- [x] `level_item.dart:1` / `PuzzleLevelItem:6` / `main_content_pipeline.dart:213` 补 `addedAt` + `unlockCoins?/unlockCode?` 预留，`game_repository.dart:132` 全量可玩
- [x] `home_tab_view.dart:1` 重构：删 `LevelFilter` 伪难度（`starter/intermediate/master`）与排序（`LevelSortOrder` 不存在勿删），单行Tag(热门N+固定全部) + 21 Sheet，Header可横滑(每日+活动)，仅Tag吸顶44dp，卡片去序号仅图+NEW(+可选◈块数)
- [x] `home_tab_view.dart:898` 移除 `需 ${index*2} 星解锁` 锁态UI及灰度/置灰逻辑（与全量可玩一致）
- [x] `lib/logic/cache/image_cache_manager.dart` 等无改动

### Phase 1 内容接入（1-2天，并行）

- [ ] AI产线 `scripts/ai_tag_images.py` + `addedAt` 写入，`manifest.json` 200精选接入，运营定 `addedAt` 与 `order`
- [ ] CDN多备源 `app_content.dart:37`，Bing日更切远端增量

### Phase 2 运营与经济（1-2天，二期）

- [ ] 关卡商店页（远端manifest，永久包打底）
- [ ] 经济：每日登录`+10`、活动送币、兑换码
- [ ] ♥收藏与搜索

### Phase 3 内核打磨（二期，游戏功能稳定后）

- [ ] `game_page.dart:1` 顶部操作收敛、Victory统一、撤销暴露、横屏
- [ ] 暗色模式开关放设置页

---

## 14. 风险与缓解

| 风险 | 概率 | 缓解 |
|---|---|---|
| Tag数据未打标 | 高 | `tags:[]`视为全部，不阻塞UI |
| NEW阈值争议 | 低 | `addedAt` 7天可配置，运营可刷新 |
| 活动包未就绪 | 低 | 已有产能保证首发≥3永久包 |
| 启动并行竞态 | 低 | 组1 await保证首屏数据，组2/3后台刷新+`contentUpdateNotifier` |

---

## 15. 附录：关键文件索引

- 导航：`lib/pages/main_screen.dart:1` `lib/main.dart:22`
- 首页：`lib/pages/tabs/home_tab_view.dart:1` `lib/data/models/level_item.dart:1` `lib/data/game_repository.dart:132` `lib/logic/content/models/puzzle_level_item.dart:6`
- 每日：`lib/pages/tabs/daily_tab_view.dart:1` `lib/data/models/daily_challenge.dart:1`
- 活动/商店：`lib/pages/tabs/events_tab_view.dart:1` `lib/pages/event_levels_page.dart:1` `lib/logic/content/pipelines/*`
- 自制：`lib/pages/tabs/my_puzzles_tab_view.dart:1` `lib/data/models/custom_puzzle_item.dart:1`
- 游戏：`lib/pages/game_page.dart:1` `lib/game/jigsaw_puzzle_game.dart:1` `lib/logic/puzzle_model.dart:1` `lib/logic/star_calculator.dart:1`
- 经济/解锁/成就：`lib/services/economy_service.dart:1` `lib/services/unlock_service.dart:1` `lib/services/achievement_service.dart:1` `lib/data/progress_store.dart:1`
- 设计：`lib/theme/app_palette.dart:1` `lib/widgets/choose_difficulty_sheet.dart:1` `lib/widgets/app_cached_image.dart:1`

---

> **修订说明**：本版已按6条反馈收敛：首页无墙无排序、Tag单行+Sheet、Header可滚Tag吸顶、卡片去序号留NEW、AppBar与启动精简、活动/商店与DIY双轨、经济“星荣誉币流通”、GamePage延后。P0仅首页，余量二期。
