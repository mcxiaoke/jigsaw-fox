# 拼图 · 难度·评分·评星·成就·经济 系统设计（v3.3.1 定稿）

> 状态：**v3.3.1 定稿**（注：v3.4 画幅已由 `docs/aspect-ratio-expansion-and-grid-design-20260903.md` 扩展支持 4:3 与 3:4 比例，网格自适应扩展至 5 大黄金画幅并理论支持 L7 宗师档；核心双轴评分公式、金币防通胀与成就数据驱动保持不变）
> 决策依据：多份外部评审（`temp/reviews/`）+ 内置图库实测数据
> 关联实现：`lib/logic/puzzle_model.dart`、`lib/pages/game_page.dart`、`lib/data/progress_store.dart`、`lib/pages/achievements_page.dart`

## 一、核心决策摘要（相对 v1 的变更）

| #  | 决策                    | 变更内容                                        | 依据                                                    |
| -- | --------------------- | ------------------------------------------- | ----------------------------------------------------- |
| D1 | **移除 3:4/4:3 图片规格**   | 规格收敛为 1:1 + 2:3/3:2 双规格，配套裁剪适配              | 图库实测 3:4 占比 0%；12k² 序列稀疏导致 L4/L5 偏差 33~39% 超标、无 L1 档 |
| D2 | **1:1 保留 6×6=36 过渡档** | 7 档（6+1），36 仅 1:1 独有                        | 平滑 25→64 的 2.56× 跃升为 1.44×→1.78×；移除 3:4 后不再破坏跨规格对齐    |
| D3 | **双轴多梯度评星**           | TimeScore × HintScore 取 min，取代 v1 硬门槛       | 消除悬崖感；保护提示道具销售                                        |
| D4 | **评分基准用实际片数**         | `actualPieces × secPerPiece`，非档位代表片数        | 跨规格公平（v1 用代表片数导致 3:4 玩家被低估 8%）                        |
| D5 | **金币曲线压缩**            | `DifficultyBase + StarBonus`，高低档倍率 16×→5.5× | 防刷高难本、中低档经济可行                                         |
| D6 | **成绩绑定 PuzzleId**     | 星级存到具体图片（PuzzleId + Difficulty 复合键）         | 防同档覆盖、总星=账号积累                                         |
| D7 | **成就数据驱动彻底化**         | `AchievementMetric` 枚举 + 固定数量里程碑            | 告别硬编码；"全 3 星"改为可配置的里程碑                                |
| D8 | **v1 不做误放惩罚**         | 误放计数仅埋点（v2 扩展位）                             | 休闲定位，不惩罚乱试错                                           |

## 二、图片规格与裁剪适配

### 2.1 目标比例集合

| 规格        | 说明        | 网格公式                     |
| --------- | --------- | ------------------------ |
| 1:1       | 正方形       | n × n，片数 n²              |
| 2:3 / 3:2 | 竖屏/横屏（转置） | 2k × 3k 或 3k × 2k，片数 6k² |

`PuzzleAspectRatio` 收敛为：`square1x1`、`portrait2x3`、`landscape3x2`（删除 `portrait3x4`、`landscape4x3`）。

### 2.2 裁剪适配（移除 3:4 的必备配套）

**问题**：4:3 相机图（iPhone 默认 4032×3024）若按"最近比例归类"直接归到 3:2 网格，网格 3:2 ≠ 图片 4:3，切片将不是正方形。现有 `fromSize` 是最近归类逻辑，删枚举后必须加裁剪。

**规则**：任意比例图片，先居中裁剪到 {1:1, 3:2, 2:3} 中**面积损失最小**的档位，再进切片流程。

**比例选取算法（最小面积损失法）**：不用线性差值 `abs(r - target)`（5:4 到 1.0 和 1.5 的线性差同为 0.25，但真实裁剪损失分别为 20% / 16.7%，线性法会选错），改用面积损失公式选取：

```
CropLoss(r, target) = 1 - min(r / target, target / r)   // 等价于对数距离
选择 CropLoss 最小的 target ∈ {1.0, 1.5, 2/3}
```

| 源比例          | 目标          | 裁剪方向与损失      | 示例                                       |
| ------------ | ----------- | ------------ | ---------------------------------------- |
| 4:3 (1.333)  | 3:2 (1.5)   | **裁高** 11.1% | iPhone 4032×3024 → 4032×2688，裁掉上下各 168px |
| 3:4 (0.75)   | 2:3 (0.667) | **裁宽** 11.1% | 竖版 3024×4032 → 2688×4032，裁掉左右各 168px     |
| 16:9 (1.778) | 3:2 (1.5)   | 裁宽 15.6%     | 视频截图                                     |
| 4:5 (0.8)    | 2:3 (0.667) | 裁高 16.7%     | Instagram 竖图（线性法会误选 1:1 的 20%）           |

**管线路径（v3.3.1 冻结，按图源分叉）**：

* UGC 自制图：`CropPuzzlePage` 导出时直接保存已裁剪到目标比例的图（复用现网高质量导出管线），入库即最终态；

* 内置/下载图：进入游戏解析图片尺寸时，经 ImageCacheManager 派生缓存已裁剪图，缓存键含目标比例（`${assetPath}_${targetRatio}`），仅缓存未命中的首次执行裁剪，避免缩略图命中未裁剪原图。

```dart
// 伪代码：最小面积损失选取 + 只裁不缩的居中裁剪
AspectRatio target = minBy(candidates, (t) => cropLoss(ratio(image), t));
Image cropped = cropCenter(image, to: target); // 若 ratio < target 裁高，否则裁宽
```

**UGC 图片禁止静默裁剪**：内置图源在导入管线中静默预处理；**用户自制拼图入库前必须提供可视裁剪交互**（Crop UI）——以 {1:1, 3:2, 2:3} 比例遮罩，允许玩家平移/缩放确认构图（防止"全家福切头"类差评），保存裁剪后结果。

### 2.3 4×4=16 档位去向（删除）

现网 `square1x1.tiers` 首档为 4×4=16 且 `recommended: true`（`puzzle_model.dart:55`）。v3 L1 起步 25 片，**4×4 档位删除**：

* 选择器不再展示 4×4；1:1 推荐档改为 L1.5（6×6=36，家庭入门），2:3 推荐档为 L1（4×6=24）。

* **存量 16 块进度迁移**：发布前无真实用户数据，规则为「16 块 `bestStars` 并入同图 L1 记录（星星不丢），16 块进度快照作废清理」；若玩家 16 块与 25 块均有记录，合并取 `bestStars = max(star16, star25)`、`bestTimeSeconds = min(time16, time25)`，防止旧低星/长耗时记录覆盖优良成绩；若无存量则直接清理。

* 删除范围：`PuzzleDifficulty.presets` 与 `square1x1.tiers` 中的 4×4 条目；`estimatedMinutes` 表同步更新。

## 三、难度分级（7 档网格表）

| 档位   | 标签 (zh/en)  | 1:1         | 2:3/3:2     | 备注                 |
| ---- | ----------- | ----------- | ----------- | ------------------ |
| L1   | 新手 Easy     | 5×5 = 25    | 4×6 = 24    | <br>             |
| L1.5 | 入门+ (过渡)    | 6×6 = 36    | —           | **仅 1:1**，平滑 25→64 |
| L2   | 简单 Beginner | 8×8 = 64    | 6×9 = 54    | <br>             |
| L3   | 普通 Medium   | 10×10 = 100 | 8×12 = 96   | <br>             |
| L4   | 进阶 Hard     | 12×12 = 144 | 10×15 = 150 | <br>             |
| L5   | 困难 Expert   | 15×15 = 225 | 12×18 = 216 | <br>             |
| L6   | 大师 Master   | 20×20 = 400 | 16×24 = 384 | <br>             |

跨规格偏差（同档两规格片数差，口径 `bias = |sq - rect| / sq`，即以方形片数为分母；若按较大者做分母则 L2 为 18.5%）：L1 4% / L1.5 仅 1:1 / L2 15.6% / L3 4% / L4 4% / L5 4% / L6 4%，**全部 ≤16%**（远优于 v1 的 ≤39%）。

**已知妥协（矩形入门跨度）**：2:3/3:2 从 24→54 为 2.25× 跃升（全表最大），无 L1.5 过渡档。v3.3 决策：**接受该断层，不补矩形过渡档**——24 片本身极轻，54 片矩形上手难度并不显著高于 36 片方形，补档反而引入非正方形切片（5×7 偏差 6~7%）与选择器复杂度。UI 缓解：选择器置灰附注"下一档 54 块" + 选 L2 时的二次确认弹窗（"难度将明显提升，确定？"）。二次确认触发点（v3.3.1）：在点击底部"开始"按钮时校验——当前图为 2:3/3:2 且所选档位为 L2 且玩家首次选择该档，弹出确认框并附"记住选择，不再提示"复选框（存 Prefs）；选择器 Chip 点击瞬间不打断。

选择器 UI：7 档统一展示；L1.5 标注"仅正方形图"，2:3 图选中时置灰并附注"该比例最小为 24 块/下一档 54 块"。

**`estimatedMinutes`** **同步对照表**（v3.3 显式落表，`puzzle_model.dart` 各规格 `tiers` 的 `estimatedMinutes` 按此更新，两种规格片数相近共用同一区间；与 §4.1"对应 UI 预估"列一致）：

| 档位   | 1:1 片数 | 2:3/3:2 片数 | estimatedMinutes        |
| ---- | ------ | ---------- | ----------------------- |
| L1   | 25     | 24         | 1~3 分钟                 |
| L1.5 | 36     | —          | 2~4 分钟                 |
| L2   | 64     | 54         | 5~8 分钟                 |
| L3   | 100    | 96         | 12~18 分钟               |
| L4   | 144    | 150        | 25~35 分钟               |
| L5   | 225    | 216        | 50~75 分钟               |
| L6   | 400    | 384        | 90~180 分钟（"1.5~3 小时"） |

**主线 100 关默认难度阶梯**（v3.3.1，删 4×4 后 `_initLevels` 的推荐难度分配；进关时的默认档，玩家仍可自选，矩形图按上表取对应网格）：

| 关卡     | 默认档  | 关卡      | 默认档 |
| ------ | ---- | ------- | --- |
| 1~10  | L1   | 61~80  | L3  |
| 11~35 | L1.5 | 81~93  | L4  |
| 36~60 | L2   | 94~100 | L5  |

L1 仅 10 关（25 片极轻，连打 20 关会腻）；L1~L3 合计 80 关承载休闲主体；主线不设 L6，大师档留给自由选图的荣誉挑战。

## 四、评分与评星（双轴多梯度）

### 4.1 基准时间

```
BaseSeconds = 本局实际片数(actualPieces) × SecPerPiece(档位)
```

**非线性基准**（v3.3 修订）：托盘中从 N 块碎片搜索目标是 O(N²) 搜索空间，线性 SecPerPiece（v3 的 2.5→5.0s）导致高难 3 星线与 `estimatedMinutes` 预估相差 3~5 倍、休闲玩家不可达。v3.3 按档位非线性校准，使 Base 落于 `estimatedMinutes` 区间内：

| 档位   | 1:1 片数 | Sec/Piece | Base（2星线） | 3星线（≤70%） | 对应 UI 预估  |
| ---- | ------ | --------- | --------- | --------- | --------- |
| L1   | 25     | 3.0       | 75s       | 52s       | 1~3 分钟   |
| L1.5 | 36     | 3.5       | 126s      | 88s       | 2~4 分钟   |
| L2   | 64     | 5.0       | 320s      | 224s      | 5~8 分钟   |
| L3   | 100    | 8.0       | 800s      | 560s      | 12~18 分钟 |
| L4   | 144    | 12.0      | 1728s     | 1210s     | 25~35 分钟 |
| L5   | 225    | 18.0      | 4050s     | 2835s     | 50~75 分钟 |
| L6   | 400    | 25.0      | 10000s    | 7000s     | 1.5~3 小时 |

* **定位注解**：Base 是**竞速基准**，落于 estimatedMinutes 区间内（v3.3.1 修正原"区间下限"表述错误，7 档均已核算：L1 Base=1.25min ∈ \[1,3]、L4 Base=28.8min ∈ \[25,35]、L6 Base=166.7min ∈ \[90,180]），不等于预估通关时长；普通玩家按预估时长完成为 2 星，快 30% 为 3 星。

* **校准机制**：上线后埋点真实完成时间分布（P25/P50/P75），按分布重校 SecPerPiece，首版以本表为准。

### 4.2 双轴评星

**时间分 TimeScore**：`≤70% Base` → 3 分；`≤100% Base` → 2 分；`>100% Base` → 1 分
**提示分 HintScore**：`0 次` → 3 分；`≤ 免罚额度` → 2 分；`超额度` → 1 分
**最终星级 = min(TimeScore, HintScore)**，**完成即保底 1 星**（无 0 星可能）

**提示免罚额度随片数缩放**（v3.3 修订）：25 块与 400 块同为"1-2 次提示扣分"对 L6 过苛：

```dart
int hintAllowance(int pieces) => (pieces / 50).ceil().clamp(2, 6);
// L1(25)=2 → L2(64)=2 → L3(100)=2 → L4(144)=3 → L5(225)=5 → L6(400)=6(钳制)
```

特征：快(3分)+1次提示(2分) = 2 星（不因 1 次提示断崖）；慢但零提示也可 2 星；玩家敢于在卡壳时用提示保底，高难免罚额度更宽。

```dart
int calcStars({required int actualPieces, required double secPerPiece,
               required int hints, required int seconds}) {
  // 全程 int 毫秒比较，避免 double 取整抖动（如 63×0.7=44.1）
  final baseMs = (actualPieces * secPerPiece * 1000).round();
  final ms = seconds * 1000;
  final timeScore = ms <= baseMs * 7 ~/ 10 ? 3 : (ms <= baseMs ? 2 : 1);
  final allowance = hintAllowance(actualPieces);
  final hintScore = hints == 0 ? 3 : (hints <= allowance ? 2 : 1);
  return timeScore < hintScore ? timeScore : hintScore;
}
```

落地要求（P0）：

* 以 `StarCalculator` 替换 `game_page.dart` `_calculateStars`（现网 `hints==0 && seconds < pieces×6` 与本设计完全不一致），**必须配** **`star_calculator_test.dart`** **单测**（边界：恰好 70%/100%、额度 ±1 次、保底 1 星）。

* **提示时停**：使用提示瞬间短暂暂停计时器 1~2 秒，避免"花钱买提示还双输（扣分+耗时）"的负体验。

## 五、成绩记录（PuzzleId 粒度）

> **术语对齐（与代码一致）**：设计文档 `Difficulty` = 代码 `PuzzleDifficulty`（rows/cols）；`PuzzleId` = 代码 `canonicalId`（图唯一标识）；档位存储键 = `difficultyKey`（字符串 `rows×cols`，`SnapshotStore.difficultyKeyFor`）。**复合键 =** **`canonicalId + difficultyKey`**，下例 `puzzleId/difficulty` 仅为概念名，实现时按下表替换。

星级/最佳时间绑定到具体图片 × 档位，防止同档覆盖。**存储结构采用嵌套 Map 而非扁平复合键**（v3.3 修订）：`ProgressStore` 一级键保持 `canonicalId` 不变（一图一 JSON，读写聚合），档位记录内嵌为 Map——扁平键 `cid + dkey` 会让主页 50 关列表产生 50×7=350 次 SP 查询的 N+1 问题：

```dart
class DifficultyRecord {
  int bestStars;
  int bestTimeSeconds;
  bool isCompleted;
  int playCount;
  int minHintsUsed;   // 历史最少提示次数（初始 -1）；noHintWin 成就依赖：首次变为 0 时发事件，防同图刷 nohint_10
}

class LevelProgress {
  final String canonicalId;                       // 一级键（不变）
  final Map<String, DifficultyRecord> records;    // key = difficultyKey "5x5"（嵌套，非扁平 SP 键）
}
```

* 存储：`LevelProgress` 从单 `stars`/`bestTimeSeconds` 字段（现网）改为 `records: Map<difficultyKey, DifficultyRecord>`；未发布可直接改，无 v2 迁移负担。

* `minHintsUsed` 结算状态机（v3.3.1）：初始 -1；每局结算时若 `minHintsUsed == -1 || hintsUsed < minHintsUsed` 则更新为本次 hintsUsed；首次变为 0 时向 `AchievementService` 发 `noHintWin` 事件（每图每档仅发一次），与 bestStars 更新在同一结算事务内写入。

* daily/custom/generic 全部补 `stars` 字段，与 level 一致。

* **防刷**：星星只记 best，不重复发星；金币按增量制结算（见 §6.1）。

* 同图旧 3:4 通关记录与新 2:3 记录互不覆盖（档位键不同，旧记录仅作历史星数保留）。

**总星数口径**（v3.3 决策，双口径并存）：

| 口径    | 定义                                          | 用途                 |
| ----- | ------------------------------------------- | ------------------ |
| 累加口径  | 所有 canonicalId × 所有档位 bestStars 求和          | 成就展示、账号资产（鼓励重玩多难度） |
| 3 星图数 | `distinctImagesWith3Star`（任一档位拿过 3 星的不同图数量） | **解锁门槛专用**（见 §7.2） |

> 不用"每图取最高星"做解锁：累加口径下 2 张图全档 3 星 = 42 星会击穿 L6 门槛；取最高口径又压制重玩动力。3 星图数最直观、天然防刷、玩家一看就懂。

`distinctImagesWith3Star` 统计范围（v3.3.1 冻结）：ProgressStore 全部 canonicalId——main / daily / custom / generic / UGC / 在线图包均计入。门槛本就宽松（2/5/10 张），纳入全部来源符合"账号资产"语义，玩家在任何内容源拿 3 星都能推进解锁。

* **口径变更影响**：现网 `totalStars` 仅统计 main levels（`achievements_page.dart:37`），D6 扩到全部 canonicalId 后总星数上升。**实施前需确认** **`LevelItem.isUnlocked`** **是否依赖星数**（现网为关卡顺序解锁，`game_repository.dart:155` 注释 "Level 1 is unlocked initially"，疑似不依赖；若依赖则解锁进度会被放大，需重新定阈值）。

### 5.1 旧存档兼容策略（移除 3:4/4:3 后）

`PuzzleState.aspectLabel` 已持久化到快照 JSON（`puzzle_state.dart:308`）。删除枚举后，在途的 3:4/4:3 存档按此策略处理（`migration_service.dart` 执行）：

| 存档状态              | 处理                                                               |
| ----------------- | ---------------------------------------------------------------- |
| 3:4/4:3 且进度 <100% | **作废**：删除对应 snapshot 文件与 progress 记录，玩家重新选择难度（选档时提示"图片已适配为 2:3"） |
| 3:4/4:3 且已通关      | **保留完成记录与星星**（bestStars 计入总星），不可续玩                               |
| 其他比例              | 不受影响                                                             |

理由：未发布产品，简单优先；3:4/4:3 图片重新入库时走 §2.2 裁剪适配。

**幽灵难度清理**（v3.3 补充）：旧 `6×8 (48)` 等 3:4 难度快照仍以文件 `*_6x8.snapshot` 存盘，`listDifficultyKeys` 能扫到但新档表不再展示，会形成"有存档无入口"的幽灵难度。`migration_service.dart` 显式清理：

```dart
for (final k in snapshotStore.listDifficultyKeys(cid)) {
  if (!allValidDifficultyKeys.contains(k)) {
    if (progress.records[k]?.isCompleted == true) {
      keepStars(k);   // 已通关：保留星星记录，仅删快照
    } else {
      delete(k);      // 未通关：删快照与记录
    }
  }
}
```

旧 `aspectLabel=portrait3x4` 的在途存档加载时拒绝续玩但保留 `bestStars`。

## 六、经济系统（双货币）

| 货币      | 性质      | 来源                 | 用途                  |
| ------- | ------- | ------------------ | ------------------- |
| 星星 Star | 永续、不可消耗 | 各图 best 评星累加       | 解锁内容（图集/主题/称号）、成就展示 |
| 金币 Coin | 消耗型     | 每局结算 + 成就奖励 + 每日签到 | 购买道具（提示/撤销/洗牌）      |

### 6.1 金币曲线（压缩倍率 + 增量制）

`CoinReward = DifficultyBase + StarBonus`（首通/破纪录全额）：

| 档位        | 基础 | +1星 | +2星 | +3星 | 3星总收益 |
| --------- | -- | --- | --- | --- | ----- |
| L1 (25)   | 5  | 0   | +2  | +5  | 10    |
| L1.5 (36) | 6  | 0   | +3  | +6  | 12    |
| L2 (64)   | 8  | 0   | +4  | +7  | 15    |
| L3 (100)  | 12 | 0   | +5  | +10 | 22    |
| L4 (144)  | 15 | 0   | +7  | +15 | 30    |
| L5 (225)  | 20 | 0   | +10 | +20 | 40    |
| L6 (400)  | 25 | 0   | +15 | +30 | 55    |

高低档 3 星收益倍率：55/10 = 5.5×（v1 为 16×）。中低档（L2/L3）经济可行，不被逼刷 L6。（口径注记 v3.3.1：本表"3星总收益" = Base + 3星 Bonus；§6.2 提示定价表中的"2星收益" = Base + 2星 Bonus，两表口径一致。）

**发放规则**（v3.3 修订，防刷 + 防死锁闭环）：

| 场景          | 发放                                                                                                          |
| ----------- | ----------------------------------------------------------------------------------------------------------- |
| 首次通关 / 破星纪录 | 全额 `DifficultyBase + StarBonus`（增量制：`delta = rewardFor(newStars) - bestRewardFor(cid, dkey)`，重复刷同难度 0 增量收益） |
| 复玩未破纪录      | 保底 `floor(Base × 20%)`（L1 复玩 = 1 币，L3 = 2 币，无刷金价值；杜绝"金币耗尽卡死无法买提示"死锁）                                        |
| 每日上限        | 全渠道金币获取软帽 **200/天**（超帽后仅累计成就进度，不再发币）                                                                        |

**bestReward 无需新存储**（v3.3.1）：金币收益是 (档位, 星数) 的纯函数，bestStars 已按 (cid, dkey) 存于 ProgressStore（§5），故 `bestReward = rewardFor(tier, bestStars)` 可直接推导、`delta = rewardFor(tier, newStars) - rewardFor(tier, bestStars)`，EconomyService 不自建历史金币表。

* 刷金效率对齐：复玩保底下 L1 ≈ 1 币/分钟、L6 ≈ 5 币/百分钟，低难刷金无利可图。

* **休闲原则**：金币主要在 L1~L3 即可舒适获取（活动/每日均按低难度拿满设计，见 §7.2）；L5/L6 收益仅温和高于中档，高难主要回报是荣誉（成就/称号，见 §8），不构成经济必选项。

### 6.2 道具与定价

| 道具                 | 效果           | 定价      | 说明                              |
| ------------------ | ------------ | ------- | ------------------------------- |
| 提示 Hint            | 定位 1 块可放置碎片  | 见下表     | 复用 hintsUsed 机制；使用时短暂暂停计时（§4.2） |
| 撤销 Undo            | 回退一步         | 5       | 复用 undoManager                  |
| 洗牌 Shuffle         | 重排托盘碎片       | 15      | 已有 shuffle                      |
| 高亮区域 / 碎片皮肤 / 边框皮肤 | 扩展           | 30~500 | v1.5 金币回收站（Coin Sinks），防通胀      |
| 星星商店               | 专属图集 / UI 主题 | 星星解锁    | 星星出口（v1.1）                      |

**提示定价表**（v3.3：以显式表为准，废弃一切公式；不变量 `hintPrice ≤ 该档 2 星总收益`——提示是帮助道具，用一次提示仍能保 2 星净收益，杜绝"用提示即破产/净亏"）：

| 档位   | L1 | L1.5 | L2 | L3 | L4 | L5 | L6 |
| ---- | -- | ---- | -- | -- | -- | -- | -- |
| 提示价  | 5  | 6    | 10 | 15 | 20 | 25 | 35 |
| 2星收益 | 7  | 9    | 12 | 17 | 22 | 30 | 40 |

* **提示扣费优先级**（v3.3.1）：免费提示券 → 金币；两者皆不足时弹轻量引导弹窗（提示可通过签到/完成关卡获取金币），不直接 Toast 硬拒。

* 新手赠送：注册送 5 个免费提示 + 100 金币。

* 每日签到：1 次免费提示 + 少量金币（签到无门槛；连续签到奖励需通关 ≥1 局，防小号）。

* **星星→金币兑换：删除**（v3.3 修订）。星星是不可消耗的累计资产，兑换会使总星下降、已解锁内容回锁，与 §7 解锁体系冲突。改为**星数里程碑奖励**：累计星数达到 10/50/100 节点时一次性领取金币（20/100/300），星星不扣减。

## 七、内容解锁体系（Progression / Unlock）

> 休闲定位原则：**门槛值全部按"正常休闲玩家 1-2 天自然达标"校准，宁低勿高**。解锁限制的目的是防小号作弊 + 软性引导渐进体验，不是内容封锁；所有锁定项必须展示条件与进度文案，杜绝"莫名其妙锁着"的挫败感（弃坑风险）。
>
> **荣誉性原则**（v3.3）：最高难度 L6（及 L5）只是**荣誉挑战**——所有日常内容（每日/活动/图集）在 L1~L3 低难度即可拿满全部奖励，高难度不设任何独占奖励（除成就/称号类荣誉）；参考同类休闲游戏惯例：活动低难度拿满，高难度只给称号。L4~L6 门槛全部按"3 星图数"宽松校准（见下），防止用高档位刷量击穿。

### 7.1 解锁维度（6 种条件，可组合）

| 类型                      | 条件              | 适用                                                |
| ----------------------- | --------------- | ------------------------------------------------- |
| sequential 顺序解锁         | 通关前一关解锁下一关      | home 主线（现网已实现）                                    |
| threeStarImages 3星图数门槛  | 拿过 3 星的不同图 ≥ N  | 高难度档位、在线图包（v3.3.1：取代 starsThreshold 累计星数，防多档刷星击穿） |
| winsThreshold 通关数门槛     | 累计通关 ≥ N 局      | 每日/活动首次开放                                         |
| difficultyCleared 档位已通关 | 指定档位通关过         | L6 终极档位（v1 暂不启用，保持单条件）                            |
| activeDays 活跃天数         | 游玩天数 ≥ N        | 预留扩展                                              |
| timeWindow 时间窗口         | 日历限定（每日刷新/活动限时） | 每日、活动（现网已有）                                       |

### 7.2 各内容源解锁策略（宽松版）

| 内容源                 | 策略            | 门槛（默认，可调）                                    |
| ------------------- | ------------- | -------------------------------------------- |
| home 主线关卡           | 顺序解锁          | 通关第 i 关开第 i+1 关（现网）                          |
| L1 / L1.5 / L2 / L3 | 初始开放          | —                                            |
| L4 进阶               | 3 星图数门槛       | 3 星图 ≥ 2（任一档位拿过 3 星的不同图）                     |
| L5 困难               | 3 星图数门槛       | 3 星图 ≥ 5（正常玩约 1 天）                           |
| L6 大师               | 3 星图数门槛       | 3 星图 ≥ 10（约 1-2 天）；不启用"需 L5 通关"复合条件          |
| 每日挑战                | 时间刷新 + 首次开放门槛 | 通关任意 1 局（solved ≥ 1，仅挡零进度空号）                 |
| 活动 events           | 时间窗口 + 进度门槛   | 累计通关 ≥ 5 局（正常 1 天达成）；**活动奖励低难度（L1~L3）即可拿满** |
| 自制拼图 / 我的拼图         | 全解锁           | 用户自建内容不设限                                    |
| 在线图包 / 下载图          | 3 星图数解锁（包级）   | 基础包 2 / 进阶包 5 / 精品包 10（3 星图数口径）              |

宽松校准说明：

* 门槛只做"防小号 + 软引导"：每日/活动门槛挡住零进度空号，正常玩家 1 天自然达标。

* L4~L6 用"3 星图数"而非累计星数：累加口径下 2 张图全档 3 星 = 42 星会击穿任何星数门槛；3 星图数天然防刷、直观（"再 3 星 N 张图解锁"）。

* L4~L6 门槛保证新手不被 144+ 片劝退，但 1-2 天内全部自然解锁，不构成障碍；高难本身无独占奖励，纯荣誉向。

* 所有锁定项显示条件与当前进度（如"已 3 星 3/5 张"），杜绝无解谜锁；点击锁定档位 Toast 提示"再获得 X 张 3 星图即可解锁"。

### 7.3 规则引擎（数据源 SSOT：ProgressStore / GameRepository）

解锁是核心玩法逻辑，**单一真实数据源（SSOT）为** **`ProgressStore`** **/** **`GameRepository`**（v3.3 修订：原设计读 `AchievementStore` 属依赖倒置——成就是下游观察者，不应做上游数据源）。解锁所需指标（solved / 3 星图数 / activeDays）直接从 `ProgressStore` 聚合，不单独存：

```dart
enum UnlockType { sequential, threeStarImages, winsThreshold,
                  difficultyCleared, activeDays, timeWindow }

class UnlockRule {
  final UnlockType type;
  final int threshold;              // 图数/局数/天数
  final Set<String>? requiredTiers; // difficultyCleared 用（如 {L5}），v1 未启用
}

class UnlockService {
  bool isUnlocked(UnlockRule rule) {
    switch (rule.type) {
      case threeStarImages: return progressStore.distinctImagesWith3Star >= rule.threshold;
      case winsThreshold:    return progressStore.totalSolved >= rule.threshold;
      case sequential:       return progressStore.levelCompleted(prevId);   // 现网逻辑收敛于此
      ...
    }
  }
}
```

* **与现网衔接**：`LevelItem.isUnlocked` 从"纯顺序"扩展为 `UnlockService` 统一判定（顺序 + 3 星图数），判定逻辑收敛到一处；切换时保留现网"第 1 关默认解锁"兜底。

* 一个内容可挂多条规则（全部满足才解锁）；v1 尽量单条件，保持宽松。

* UI：锁定关卡/档位/入口统一"锁 + 条件文案 + 进度条"组件；难度档位置灰复用 v3 选择器机制，点击锁定项 Toast 提示差距。

* **日历口径**：`timeWindow` / 每日刷新 / 签到一律按**本地日历日**（`yyyy-MM-dd`，本地午夜切换），休闲游戏不用 UTC。跨天归属（v3.3.1）：每日挑战严格按该关的 `dateStr` 判定归属日；签到与每日金币上限按**动作发生时**的本地系统时间判定——23:59 开局、00:05 通关的跨天局不影响两者。

* **结算原子性**（P0 质量门）：单局结算固定顺序 **写进度 → 写成就 → 判解锁 → 弹结算 UI**，一次性 await 序列全部完成后才渲染结果；防止"刚拿够 5 张 3 星图 L5 仍显示锁定"的闪烁。与现网异步存档的关系（v3.3.1）：结算路径是独立的一次性同步序列，与游戏内周期性 `_saveDebounce` 自动存档互不干扰、并存不冲突。

* **isUnlocked 双来源治理**（v3.3.1）：现网 `LevelItem.isUnlocked` 已随关卡 JSON 持久化到 SharedPreferences；切换 `UnlockService` 后统一为运行时判定，旧持久化字段迁移后不再读取（字段保留以便回滚），消除双写歧义。

## 八、成就系统（数据驱动）

### 8.1 数据模型

```dart
enum AchievementMetric {
  solved,         // 通关次数
  snapped,        // 拼接碎片数
  threeStar,      // 获得 3 星的图数（按 canonicalId 去重）
  noHintWin,      // 无提示通关数（依赖 DifficultyRecord.minHintsUsed，见 §5）
  starsEarned,    // 累计获得星数（仅 bestStars 提升时加差值）
  dailyCompleted, // 每日挑战完成
  streakDay,      // 连续签到天数
  playSeconds,    // 累计游玩秒数（time_2h 用）
  speedWin,       // 单局用时 ≤ target 秒且片数 ≥ minPieces 通关（条件达标型）
}

enum AchievementKind {
  accumulative,   // 累计型：current += value（solved / snapped / starsEarned / playSeconds）
  conditional,    // 条件达标型：单局事件满足即 0→1（speedWin；noHintWin/ threeStar 亦按事件判定）
  derived,        // 依赖派生型：dependsOn 全解锁即达成（master_all），不进 metric 枚举
}

class AchievementDef {
  final String id;
  final AchievementMetric? metric;  // derived 型为 null
  final AchievementKind kind;       // 三类模型显式区分（v3.3）
  final int target;                  // 累计型=目标值；speedWin=秒上限
  final int? minPieces;              // 可选：限定最小片数（speedWin 必填）
  final String? difficultyKey;       // 可选：限定档位（first_win_l1~l6 用）
  final List<String>? dependsOn;     // 派生型依赖（master_all 用）
  final int coinReward;
  // UI: titleKey / descKey / icon（i18n 键，en-US + zh-CN）
}
```

**覆盖说明**（v3.3 修订）：

* `time_2h` → `metric: playSeconds, target: 7200`。**口径**：`playSeconds` 在对局生命周期增量上报（暂停/切后台/结算时上报增量），弃局/挂机中途的时间同样计入——不能只在通关时累计（现网 `recordSnapStats` 只记通关，与定义不符）。秒级数据在内存累计，切后台或结算时批量落盘，避免高频磁盘 I/O。

* `speed_10min` → `kind: conditional, metric: speedWin, target: 600, minPieces: 100`（限片数防 L1 顺手拿；进度 0→1，不做次数累计）。**保持 ≥100 片**（v3.3.1 用户决策）：与 L3 三星线 560s 相近是有意设计——能以 3 星水平打通 L3 者拿到"专家速度"属实至名归；一次性 80 币且日上限 200 兜底，无通胀风险，符合荣誉性宽松原则（不提高到 144 片设卡）。

* `master_all` → `kind: derived, dependsOn: ['first_win_l1', ..., 'first_win_l6']`（**从 metric 枚举移除**，`AchievementService` 在任意成就解锁后检查依赖列表全解锁即达成，无特判散落）。

* `first_win_l1~l6` → `metric: solved, difficultyKey: '10x10'` 等，靠 `difficultyKey` 限定档位。

### 8.2 初始成就表（25 项，里程碑式）

| 类别     | id                               | metric / 条件                       | 目标        | 奖励            |
| ------ | -------------------------------- | --------------------------------- | --------- | ------------- |
| 里程碑    | complete_1 / _5 / _20 / _50  | solved                            | 1/5/20/50 | 20/50/100/200 |
| <br> | snap_200 / _1000               | snapped                           | 200/1000  | 50/200        |
| <br> | stars_100                       | starsEarned                       | 100       | 150           |
| <br> | time_2h                         | 累计时长                              | 2h        | 100           |
| 技巧     | nohint_1 / _10                 | noHintWin（minHintsUsed 首次归零计）     | 1/10      | 30/150        |
| <br> | three_star_1 / _10            | threeStar                         | 1/10 张不同图 | 30/150        |
| <br> | speed_10min                     | speedWin（**≥100 片**且用时 ≤600s）     | 1         | 80            |
| 难度进展   | first_win_l1 ~ first_win_l6 | solved + difficultyKey 限定         | 各 1       | 各 50          |
| <br> | three_star_diff_10 / _30     | threeStar（跨档，按图去重）                | 10/30     | 200/400       |
| <br> | master_all                      | derived（dependsOn: first_win 全系） | 1         | 500           |
| 每日     | daily_first                     | dailyCompleted                    | 1         | 50            |
| <br> | streak_3 / _7                  | streakDay                         | 3/7       | 60/200        |

设计要点：

* "全 3 星"类成就改为**固定数量里程碑**（`three_star_diff_10/30`，v3.3 从 50 降为 30——图库 63 张的 79% 对休闲玩家过肝），不随图库规模膨胀，玩家目标可达。

* `nohint_10` 防刷：按 `minHintsUsed` 每图首次归零才计 1 次，同图反复刷不重复计。

* `master_all` 为终极成就（荣誉性质，高难的回报核心）；`first_win_l1~l6` 引导玩家尝遍各档难度。

* 全部通过 `AchievementService.handleEvent(metric, value, {difficultyKey})` 统一分发，UI 遍历 `kAchievements` 渲染，新增成就仅加一条配置。

* `AchievementProgress` 含 `isClaimed` 标记（v1.1 可选手动领奖 + 红点，强化正反馈；v1 先自动发放）。

* **达成即时反馈**（v3.3.1）：对局中或结算瞬间达成成就时，GamePage 顶部弹轻量浮动胶囊横幅（成就名 + 图标），配 `Sfx.coinsFly` 音效（现网音效枚举已预留）；结算时达成的成就并入结算面板列表一并展示。

### 8.3 成就计数器存储

**新建** **`AchievementStore`**（独立于 ProgressStore，避免污染关卡进度），持久化单文件（如 `achievements.json`）。计数器分四类：

| 类型       | 存储                                                                                  | 示例                                                                              |
| -------- | ----------------------------------------------------------------------------------- | ------------------------------------------------------------------------------- |
| 账号级累计指标  | 持久化累计值，事件到达即累加                                                                      | solved / snapped / starsEarned / playSeconds / noHintWin                        |
| 带档位限定的累计 | 计数 key 加档位分区（`"solved:10x10"`），`handleEvent(metric, value, difficultyKey)` 分发时拼 key | first_win_l1~l6（v3.3：否则单一 `counters['solved']` 无法区分 L3 胜与 L6 胜）              |
| 事件去重计数   | 事件发生即累计（先查重再累加）                                                                     | threeStar（按 `Set<canonicalId>` 去重）、noHintWin（按 minHintsUsed 首次归零）、speedWin（0→1） |
| 派生/状态    | 存依赖达成态                                                                              | masterAll（dependsOn 检查 first_win 系列解锁状态）                                       |
| 日历计数     | 存最近签到日期序列                                                                           | streakDay（存 `lastCheckInDate` + 连续天数，本地日历日跨天校验，断签归零）                            |

```dart
class AchievementStore {
  Map<String, int> counters;          // 计数 key（含档位分区），多成就共享
  Set<String> starredPuzzles;         // 已计 3 星的 canonicalId 集合（threeStar 去重）
  String? lastCheckInDate;            // 签到日（yyyy-MM-dd，本地时区）
  int streakDays;
  Map<String, AchievementProgress> progress;  // 成就解锁态（id → 进度）
}
```

关键点：

* **计数器按 metric（+可选档位分区）存储而非按成就**：多个成就共享同一计数（如 solved 同时服务 complete_1/5/20/50 与 first_win 系列）；`counters` 的 key 规则 = `metric` 或 `metric:difficultyKey`。

* **`starredPuzzles`** **按 canonicalId 去重（有意为之，v3.3 决策）**：`threeStar` 成就语义是"N 张不同图 3 星"，若改复合键一图刷 7 档算 7 次反而灌水；复合键仅用于进度存储（§5），成就去重始终按图。

* **落盘策略**：`playSeconds` 等秒级高频更新在内存累计（Timer 批量），切后台 / 单局结算时刷入持久层，避免高频磁盘 I/O。

* **依赖顺序**：签到存储必须先于 `streakDay` 成就落地（P1 内部依赖顺序，见 §9）。

## 九、落地 Roadmap

| 优先级       | 任务                                                                                                                                                                                                                                                         | 对应文件                                                                  |
| --------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | --------------------------------------------------------------------- |
| P0        | 收敛 `PuzzleAspectRatio` 为 3 方向 + 裁剪适配 `cropToAspect`（最小面积损失法）+ 缓存键含 targetRatio                                                                                                                                                                             | `puzzle_model.dart`                                                   |
| P0        | **删除 3:4/4:3 裁剪入口** + 裁剪结果缓存管线（导入/入库预处理）+ **UGC 可视裁剪 UI**（比例遮罩 + 平移/缩放）                                                                                                                                                                                    | `crop_puzzle_page.dart`（删 21-22 行选项）、`image_source.dart` / 内容管线       |
| P0        | 网格表对齐 7 档（含 L1.5 仅 1:1、删 4×4）+ 选择器 UI（置灰/附注/二次确认）+ `estimatedMinutes` 按 v3.3 表同步                                                                                                                                                                           | `puzzle_model.dart`、`choose_difficulty_sheet.dart`                    |
| P0        | **L6=400 片性能实测**：渲染/托盘滑动/快照体积（400 片快照 JSON 大小、建块耗时）；阈值：建块 >500ms 或托盘滚动 <45fps 即降档 18×18=324（降档预案：片数偏差/SecPerPiece/金币表/first_win_l6 全表联动）。**实测前先落地两项渲染优化**：① `RepaintBoundary` 隔离动态碎片与已拼合的静态碎片；② 组合体（Group）合并——两碎片正确拼接后在逻辑与渲染层合并为单一实体，随游戏进行渲染节点递减而非恒为 400 | 实测先行 + 降档预案表                                                          |
| P0        | `StarCalculator` 双轴评星替换 `_calculateStars`（含提示免罚额度、int 毫秒、提示时停）+ **`star_calculator_test.dart`** **单测**；结算面板四要素                                                                                                                                             | `game_page.dart`、新增 `lib/logic/star_calculator.dart`                  |
| P0        | 成绩粒度迁移：`LevelProgress.records: Map<difficultyKey, DifficultyRecord>`（含 `minHintsUsed`）+ 16→25 合并（max/min）+ 幽灵难度清理；daily/custom/generic 补 stars；旧 3:4/4:3 存档迁移（§5.1）+ **`migration_service_test.dart`**                                                     | `progress_store.dart`、`game_repository.dart`、`migration_service.dart` |
| P0        | 确认 `LevelItem.isUnlocked` 是否依赖星数（§5 口径变更影响）                                                                                                                                                                                                                | `game_repository.dart`                                                |
| P0        | **结算原子性**：写进度 → 写成就 → 判解锁 → 弹结算 UI（§7.3 质量门）                                                                                                                                                                                                               | `game_page.dart` / `game_repository.dart`                             |
| P1        | `UnlockService`：解锁判定收敛（顺序 + 3 星图数门槛，SSOT=ProgressStore）、每日/活动首次开放门槛、锁定 UI 组件（锁 + 条件文案 + 进度 + Toast）                                                                                                                                                        | 新增 `lib/data/unlock_service.dart`、`game_repository.dart`、各 tab 视图     |
| P1        | `EconomyService`：金币增量制 + 复玩保底（Base×20%）+ 日上限 200 + 商店 + 新手赠送 + **`economy_service_test.dart`** **防刷单测**                                                                                                                                                    | 新增 `lib/data/economy_service.dart`                                    |
| P1        | **每日签到存储**（`AchievementStore` 的签到字段，本地日历日）先于 `streakDay` 成就落地                                                                                                                                                                                              | 新增签到逻辑 + 依赖顺序                                                         |
| P1        | 成就重构：`AchievementStore`（计数分区）+ `AchievementDef` 三类模型 + `AchievementService`（handleEvent 带 difficultyKey）+ 页改数据驱动                                                                                                                                           | 新增 `lib/data/achievement_store.dart`、`achievements_page.dart` 等       |
| P2 (v1.1) | 星数里程碑奖励领取、星星商店、金币回收站（盲盒/皮肤）、成就手动领奖（isClaimed + 红点）、误放埋点（`snapErrorCount` 仅统计不扣分）                                                                                                                                                                           | —                                                                     |

**分阶段实施顺序**（v3.3.1，两份实现就绪度评审共识：地基 → 规则层 → UI → 实测）：

1. **Phase 1 地基**：`puzzle_model`（删 3:4 + 最小面积损失法 + `cropToAspect` + 主线阶梯）→ `progress_store` 嵌套 records + 迁移（16→25 合并、幽灵难度清理）→ `StarCalculator` + 单测
2. **Phase 2 结算原子化**：`game_page` 结算路径改造（写进度 → 写成就 → 判解锁 → 弹 UI 一次性序列）
3. **Phase 3 三大 Service**：`EconomyService` / `UnlockService` / `AchievementStore` + `AchievementService`，各配单测（economy / unlock / achievement）
4. **Phase 4 UI**：选择器（置灰/锁/二次确认）+ 裁剪页 + 成就页数据驱动 + i18n（zh-CN / en-US）
5. **Phase 5 实测**：L6=400 片真机性能（先落 RepaintBoundary + Group 合并两项优化）+ 降档决策

## 十、决策记录与参考

* 本定稿取代：`temp/docs/jigsaw-difficulty-level-design.md`（v1）、`temp/docs/jigsaw-scoring-stars-achievements-design.md`（v1）、`temp/docs/jigsaw-optimal-difficulty-scoring-design.md`（v2）。

* 评审来源：`temp/reviews/` 下 5 份评审报告（跨规格偏差 D1、36 档 D2、3:4 L1 断层 D3、评分 S3、UI 空档、经济通胀等）。

* **v3.1 修订**（2026-08-30 14:55 外部评审）：补 7 处设计缺口——4×4 档位去向（§2.3）、术语与代码对齐（§5）、旧 3:4/4:3 存档兼容（§5.1）、提示定价显式表（§6.2）、metric 覆盖 speed_10min/time_2h/master_all（§8.1）、成就计数器存储（§8.3）、P0 文件清单补全（§9，含 crop 入口与性能实测）。

* **v3.2 修订**（2026-08-30 15:02）：新增**内容解锁体系**（§7，原成就系统顺延为 §8）——6 种解锁维度 + 分层解锁策略表 + `UnlockService` 规则引擎（复用 AchievementStore 计数器）。**休闲宽松原则**：所有门槛按 1-2 天自然达标校准，防小号为主、软引导为辅，锁定项必显条件与进度文案。

* **v3.3 修订**（2026-08-30 15:23，基于 4 份外部评审的 P0 清单）：

  * **三项用户决策**：① 矩形 24→54 断层**接受不补档**（§3 已知妥协 + 二次确认弹窗）；② 解锁门槛改用**3 星图数**（L4/L5/L6 = 2/5/10 张，成就展示仍用累加口径，§5/§7.2）；③ SecPerPiece 采用**非线性表**（3.0→25.0，与 estimatedMinutes 对齐，§4.1）+ 上线后埋点校准。

  * **总体原则（荣誉性）**：休闲游戏，难度与解锁全宽；所有日常内容 L1~L3 低难度拿满奖励，L5/L6 纯荣誉挑战（成就/称号），不设独占奖励。

  * 数值修复：§2.2 裁剪示例方向算反（4:3→3:2 应裁高）+ 最小面积损失法 + UGC 裁剪 UI；§4.2 评星删冗余区间 + 提示免罚额度随片数缩放 + int 毫秒 + 提示时停。

  * 结构修复：§5 存储改嵌套 `records: Map`（避免 350 次 SP 查询）+ `minHintsUsed` + 16→25 合并规则 + 幽灵难度清理；§6 金币增量制 + 复玩保底 20% + 日上限 200 + 提示定价以表为准（不变量 `hintPrice ≤ 2星收益`）+ 删星币兑换改星数里程碑；§7.3 解锁 SSOT 改 ProgressStore + 结算原子性 + 本地日历日；§8 三类成就模型 + 计数档位分区 + speedWin 限 ≥100 片 + playSeconds 生命周期口径。

* **v3.3.1 修订**（2026-08-30 15:50，两份实现就绪度评审 `temp/reviews/`）：冻结 11 处实现歧义——
* ① §2.2 裁剪管线按图源分叉（UGC 导出时裁剪 / 内置下载图 ImageCacheManager 派生缓存）；
* ② §3 主线 100 关默认难度阶梯（L1×10 / L1.5×25 / L2×25 / L3×20 / L4×13 / L5×7）；
* ③ §3 L2 二次确认在"开始"时触发 + 不再提示存 Prefs；
* ④ §4.1 修正"Base=区间下限"表述（实为落于区间内）；
* ⑤ §5 minHintsUsed 结算状态机；
* ⑥ §5 3 星图数统计范围=全部 canonicalId；
* ⑦ §6.1 bestReward 由 bestStars 推导无需新存储 + 金币/提示两表口径注记；
* ⑧ §6.2 提示扣费优先级（免费券→金币→引导弹窗）；
* ⑨ §7.3 跨天归属 + 结算原子性与 _saveDebounce 并存说明 + isUnlocked 双来源治理；
* ⑩ §8.1 speed_10min 保持 ≥100 片（用户决策：荣誉性宽松、日上限兜底）；
* ⑪ §8.2 成就达成即时反馈（顶部胶囊 + coinsFly 音效）。§9 增分阶段实施顺序（Phase 1~5）。

* 关键量化：内置图库 63 张实测 1:1 68% + 2:3/3:2 32% + 3:4 0%。
