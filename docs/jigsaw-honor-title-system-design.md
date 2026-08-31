# 异形拼图荣誉称号系统设计 (Honor Title System) v1.0

> 状态: **v1.0 设计稿** | 日期: 2026-08-30 | 关联: `jigsaw-difficulty-scoring-achievements-design.md` v3.3.1 / `jigsaw-achievements-data.md`
> 定位: 休闲成长型主线身份轴，与 25 项成就勋章墙互补。**正向鼓励 > 挫败分层**，全量称号永久累计。

---

## 一、设计目标与原则

1.  **给主线一个身份**: 成就是分散事件勋章(墙)，称号是线性身份成长(轴)。玩家在结算/个人页能直观回答"我现在是谁"。
2.  **双轨防刷**: 纯关卡数会被 1 星速通灌水，纯星数会被单图 7 档刷星击穿。采用 `通关数 AND 总星数` 双闸门，高阶追加 `3星图数`，与现有 `ProgressStore` 三口径对齐。
3.  **休闲宽松**: 前 5 阶 1-2 天自然达成(日玩 10-15 关, 均 2 星)，终极阶需 100 关 + 接近全 3 星，给硬核荣誉但不卡日常。
4.  **叙事一致**: 异形拼图不用军事军衔(青铜/王者)，采用`匠艺/收藏/织造`叙事，与拼图手工感、异形切割一致。
5.  **可佩戴外显**: 最高阶自动装备，允许手动切回低阶，结算升阶有全屏特效。

## 二、竞品参考

| 品类 | 代表 | 借鉴 | 规避 |
|---|---|---|---|
| 重度排位 | 王者荣耀 / 皇室战争 / 部落冲突 | 段位+星星双条件、升段大特效、最高段位外显、赛季继承 | 避免青铜/黑铁等自卑感标签 |
| 休闲三消 | Candy Crush / Royal Match / 梦幻花园 | 每 10 关一徽章、星星收集即升级、皇冠/勋章墙 | 避免纯关卡数无质量要求导致刷关 |
| 收集休闲 | 动物森友会 / 星露谷 / 宝可梦图鉴 | 匠人/馆藏家/博物学家等手工/收藏叙事、图鉴完成度 | - |
| 二次元 | 原神 / 崩铁 | 名片/称号可佩戴、成就墙与称号墙分离、限时称号另表 | 避免数值属性加成 |

**结论**: 拼图适合 `匠艺成长 + 星光收藏` 双叙事，参考`原神名片 + 王者星星`做双条件闸门。

## 三、核心机制

### 3.1 解锁判定 (SSOT = ProgressStore)

```
isUnlocked(title) =
  totalSolved      >= title.needSolved      // ProgressStore.getTotalSolved()
  && totalStars    >= title.needStars       // ProgressStore.getTotalStars()  (全图全档位累加)
  && distinct3Star >= title.need3StarImages // ProgressStore.getDistinctImagesWith3Star() (按 canonicalId 去重)
```

* 主线 100 关满分 300 星 (100×3)，数值按 `2.0 ~ 3.0 星/关` 递增校准。
* 1-5 阶不设 3 星图数要求，降低新手理解成本；6 阶起追加，防止低质量刷关直通高阶。
* 判定在结算原子序列 `写进度 → 写成就 → 判称号 → 弹 UI` 中同步执行，无闪烁。

### 3.2 与成就/经济区分

| 系统 | 形态 | 触发 | 奖励 |
|---|---|---|---|
| 成就墙 (25 项) | 分散事件 | 单项 metric 达标 | 金币 (20~500) |
| **称号轴 (10+2 阶)** | 线性身份 | 主线双轨累加 | 金币 + 外观 (头像框/背景/名片/特效)，无属性加成 |
| 经济 | 货币 | 每局增量 + 复玩保底 | 消耗型 |

称号奖励计入每日 200 金币软帽之外的一次性里程碑，不影响日常经济。

## 四、完整称号表 (10 阶主线 + 2 阶隐藏)

> 稀有度对标: Common → Uncommon → Rare → Epic → Legendary → Mythic → Eternal

### 4.1 主线 10 阶

| 阶 | ID | 中文称号 | English Title | 短标 | 稀有度 | 配色 | 图标意象 | 解锁条件 (关/星/3星图) | 奖励 |
|---|---|---|---|---|---|---|---|---|---|
| 1 | sprout | 初心拼者 | Sprout | Sprout | Common | #9E9E9E 灰白 | 🌱 嫩叶拼块 | 1 / 1 / - | - |
| 2 | apprentice | 碎片学徒 | Apprentice | Apprentice | Uncommon | #66BB6A 绿 | 🧩 单块 | 5 / 10 / - | 20 金币 |
| 3 | seeker | 图案探寻者 | Seeker | Seeker | Rare | #42A5F5 蓝 | 🔍 放大镜+拼块 | 12 / 30 / - | 木纹头像框 |
| 4 | artisan | 拼图匠人 | Artisan | Artisan | Rare+ | #7E57C2 蓝紫 | 🔨 锤 + 画框 | 25 / 65 / - | 40 金币 + 背景 tile_001 |
| 5 | crafter | 星光巧手 | Crafter | Crafter | Epic | #AB47BC 紫 | ✨ 星星手 | 40 / 110 / - | 60 金币 |
| 6 | shapebreaker | 异形解构者 | Shapebreaker | Breaker | Epic+ | #FFB300 琥珀金 | 🌀 异形块 | 60 / 160 / 10 | 100 金币 + 异形边框 |
| 7 | lord | 拼图领主 | Lord | Lord | Legendary | #FF6F00 橙金 | 👑 皇冠拼图 | 75 / 200 / 20 | 150 金币 + 领主名片 |
| 8 | maestro | 幻境织梦师 | Maestro | Maestro | Legendary+ | #E040FB→#FF4081 渐变 | 🎨 织锦 | 88 / 240 / 35 | 200 金币 + 动态称号特效 |
| 9 | curator | 传奇馆藏家 | Curator | Curator | Mythic | #00BCD4→#FFEB3B 彩虹 | 🏛️ 博物馆 | 100 / 270 / 50 | 300 金币 + 馆藏名片 |
| 10 | paragon | 永恒圣匠 | Paragon | Paragon | Eternal | #FFD700 幻彩流光 | 💎 圣殿 | 100 / 300 / 60 + L6 通关≥1 | 500 金币 + 全场流光 + 结算专属横幅 |

**短标说明**: 徽章内仅显示短标(1 词)，完整中英标题用于详情页与分享卡。

**平均星级要求**: 2→2.0 / 3→2.5 / 4→2.6 / 5→2.75 / 6→2.67 / 7→2.67 / 8→2.73 / 9→2.7 / 10→3.0，整体平滑，无突变卡点。

### 4.2 隐藏称号 2 阶 (不占主线，惊喜触发)

| ID | 中文 | English | 触发条件 | 奖励 |
|---|---|---|---|---|
| perfectionist | 完美主义者 | Perfectionist | 任意 1 张图 L6(400块) 3 星 | 100 金币 + 完美徽章 |
| night_owl_curator | 守夜藏家 | Night Owl | 累计完成 30 次每日挑战 (daily_solved ≥30) | 80 金币 + 夜猫头像框 |

隐藏称号解锁时走与成就相同的顶部胶囊 + coinsFly 音效，不在称号墙占主线格子，单独"秘藏"分区展示。

### 4.3 称号文案 (slogan, 用于详情页)

| 阶 | 中文 slogan | English slogan |
|---|---|---|
| 1 | 每一块碎片都是起点 | Every piece is a beginning |
| 2 | 指尖初识凹凸的语言 | Learning the language of tabs and blanks |
| 3 | 在图案中寻找秩序 | Seeking order in patterns |
| 4 | 以手艺回应时间的提问 | Answering time with craftsmanship |
| 5 | 让星光落在拼合之处 | Let starlight fall where pieces meet |
| 6 | 异形亦有其规则 | Even irregularity has its rules |
| 7 | 领地由完整定义 | A realm defined by completion |
| 8 | 为幻境织就边界 | Weaving borders for dreamscapes |
| 9 | 收藏的不只是图片 | Collecting more than images |
| 10 | 时间在此停留 | Where time chooses to stay |

## 五、进阶曲线

```
关: 1──5──12──25──40──60──75──88─100
星: 1─10─30─65─110─160─200─240─270─300  (avg 1.0→3.0)
3星图:          ──10──20──35─50─60
```

* 前 3 阶每 5-7 关一阶，高频正反馈；4 阶后每 12-15 关一阶，拉长荣誉感。
* 休闲玩家日玩 12 关×均 2 星≈24 星/天，约 1.5 天到 5 阶，5 天到 7 阶，符合"宁低勿高"宽松原则。
* 终极 10 阶需 100 关全 3 星 + 60 张不同图 3 星 + L6 通关，对应约 2-3 周深度游玩，作长线追求。

## 六、视觉与交互

### 6.1 稀有度视觉

| 稀有度 | 边框 | 背景 | 动效 |
|---|---|---|---|
| Common/Uncommon | 灰/绿细线 | 纯色 | 无 |
| Rare/Epic | 蓝/紫 2px + 内发光 | 微渐变 | 无 |
| Legendary | 金色 3px + 外发光 | 金→橙渐变 | 呼吸光 |
| Mythic/Eternal | 彩虹流光 3px | 虹彩渐变 | 流光跑马 + 粒子 |

图标沿用现有 `assets/icons/trophy_3d.png / star_3d.png` 体系，新增 `assets/icons/honor_*.png` (10 阶 + 2 隐藏)，未到位前用 emoji 占位。

### 6.2 页面与动效

1.  **个人/成就页顶部**: 当前称号徽章(彩色描边 + 短标)常驻，点击进入称号墙。
2.  **称号墙** (新页面/弹窗): 10 宫格 + 2 隐藏格，锁定态显示 `🔒 12/25关 28/65星` 双进度条与`距离下一称号还差 X 星`提示；已解锁高亮，未解锁灰度。
3.  **结算升阶**: 达标时全屏升阶动效(参考王者升段: 光柱 + 称号大字 + 星星洒落)，播放 `Sfx.coinsFly`，按钮文案"佩戴新称号"。
4.  **佩戴**: 解锁后自动装备最高阶，允许在称号墙手动切回任意已解锁低阶(类似原神名片)，`SharedPreferences: jigsaw_honor_equipped = titleId`。
5.  **分享**: 称号卡支持生成分享图(称号+星数+关卡数)，预留社交传播位。

## 七、双语与 i18n

仅 `zh-CN` / `en-US`，遵循项目既有 ARB 规范(待 `l10n.yaml` 落地)。

**Key 规范**: `honor.title.<id>.name / .shortName / .desc / .slogan / .reward`

```arb
// app_zh.arb
"honorTitleSproutName": "初心拼者",
"honorTitleSproutShort": "初心",
"honorTitleSproutDesc": "完成 1 关拼图，踏上拼合之旅",
"honorTitleSproutSlogan": "每一块碎片都是起点",
"honorTitleParagonName": "永恒圣匠",
"honorTitleParagonDesc": "100 关全 3 星，60 张 3 星图，征服 L6 极限",
"honorNextHint": "距离下一称号还差 {stars} 星",
"honorEquipped": "已佩戴",
"honorLockedProgress": "{solved}/{needSolved}关 {stars}/{needStars}星",

// app_en.arb
"honorTitleSproutName": "Sprout",
"honorTitleSproutShort": "Sprout",
"honorTitleSproutDesc": "Complete 1 puzzle to begin the journey",
"honorTitleSproutSlogan": "Every piece is a beginning",
"honorTitleParagonName": "Paragon",
"honorTitleParagonDesc": "300 stars across 100 puzzles, 60 distinct 3-star images, and a Master clear",
"honorNextHint": "{stars} more stars to next title",
"honorEquipped": "Equipped",
"honorLockedProgress": "{solved}/{needSolved} puzzles {stars}/{needStars} stars",
```

## 八、数据模型与落地

### 8.1 静态配置 (Dart const, SSOT)

```dart
class HonorTitleDefinition {
  const HonorTitleDefinition({
    required this.id,           // sprout / apprentice / ...
    required this.rank,         // 1..10 (隐藏 101/102)
    required this.nameKey,      // i18n key: honor.title.sprout.name
    required this.shortNameKey,
    required this.descKey,
    required this.sloganKey,
    required this.needSolved,   // 关卡数
    required this.needStars,    // 总星数
    required this.need3StarImages, // 3星图数 (1-5 阶为 0)
    this.needL6Clear = false,   // 仅 Paragon
    required this.rarity,       // common..eternal
    required this.colorHex,
    required this.iconAsset,    // assets/icons/honor_<id>.png
    required this.coinReward,
    this.isHidden = false,
  });
}
```

配置表即 §4.1/4.2，`allTitles` 按 rank 排序，运营可调阈值无需改逻辑。

### 8.2 运行时服务

```dart
class HonorTitleService {
  HonorTitleDefinition get currentTitle;     // 已解锁最高阶
  HonorTitleDefinition? get nextTitle;      // 下一阶
  HonorTitleDefinition? get equippedTitle;  // 手动佩戴 (Prefs)
  List<HonorTitleDefinition> get unlockedTitles;
  double progressToNext; // 0..1, 按星数进度
  Future<List<HonorTitleDefinition>> evaluateNewlyUnlocked(); // 结算后调用
  Future<void> equip(String id);
}
```

* 数据源: `ProgressStore` 三聚合值，不自建计数，不与 `AchievementStore` 耦合。
* 持久化: `SharedPreferences: jigsaw_honor_equipped` + 解锁时间 `jigsaw_honor_unlocked: {id: isoDate}` (用于展示获得日期)。
* 解锁广播: `Stream<HonorTitleDefinition> onTitleUnlocked` 供结算页监听弹特效。

### 8.3 结算接入

```
GamePage._handleSolved:
  1. recordDifficultyCompletion → deltaStars
  2. GameRepository.updateProgress
  3. AchievementService.onPuzzleSolved
  4. HonorTitleService.evaluateNewlyUnlocked()  // 新增
  5. EconomyService.addCoins(增量 + 称号奖励)
  6. 弹结算 UI (若有新称号，叠加升阶横幅)
```

### 8.4 文件清单

| 优先级 | 文件 | 说明 |
|---|---|---|
| P1 | `lib/logic/honor_title.dart` | 10+2 阶 const 配置表 |
| P1 | `lib/services/honor_title_service.dart` | 判定/佩戴/广播 |
| P1 | `lib/pages/honor_titles_page.dart` | 称号墙 UI |
| P1 | `lib/pages/achievements_page.dart` | 顶部当前称号徽章入口 |
| P1 | `lib/pages/game_page.dart` | 结算接入 + 升阶动效 |
| P2 | `assets/icons/honor_*.png` | 12 枚徽章图标 |
| P2 | `l10n/app_zh.arb, app_en.arb` | i18n 键 |

## 九、与现有系统协同

* **难度解锁 (UnlockService 2/5/10 张 3 星)**: 称号 6/7/9 阶阈值(10/20/50) 高于难度门槛，形成"先开难度，后拿称号"的自然递进，不冲突。
* **成就 master_all (500 金币)**: 称号 Paragon 为更长线目标(300 星 vs 成就 24 项)，两者终极奖励错峰。
* **经济**: 称号一次性金币总计约 1240，金币曲线已按 5.5× 压缩 + 日上限 200 兜底，无通胀风险。

## 十、扩展预留

* 赛季/活动限定称号另表 `SeasonalHonorTitle`，带 `seasonId + expireAt`，不进主线永久轴。
* 后续可加"称号属性"仅作展示用(如拼图时称号水印)，不加数值加成，守住休闲定位。

## 十一、决策记录

* 2026-08-30: 采用匠艺线 10+2 阶，双条件+3星图数闸门，配色对标原神/王者稀有度，隐藏称号作惊喜。
* 待确认: 美术资源到位前是否先用 emoji/现有 trophy_3d 占位上线。

```

