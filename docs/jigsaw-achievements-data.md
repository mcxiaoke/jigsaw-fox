# 拼图 · 成就系统运营数据（Achievement Catalog）

> **定位**：成就系统**单一数据源（SSOT）**。本表为运营可配置数据，代码侧 `AchievementService` 数据驱动渲染——调整成就只需改本表与对应 i18n 资源，不触碰业务逻辑。
>
> **状态**：v1.0 裁决稿（严格对齐 `jigsaw-difficulty-scoring-achievements-design.md` §8.2 定稿，25 项）
>
> **关联实现**：`lib/services/achievement_service.dart`（配置表）、`lib/services/achievement_store.dart`（计数存储）、`lib/pages/achievements_page.dart`（数据驱动渲染）

---

## 一、数据模型（AchievementDef）

```dart
enum AchievementMetric {
  solved,         // 通关次数
  snapped,        // 拼接碎片数
  threeStar,      // 获得 3 星的图数（按 canonicalId 去重）
  noHintWin,      // 无提示通关数（依赖 DifficultyRecord.minHintsUsed）
  starsEarned,    // 累计获得星数（仅 bestStars 提升时加差值）
  dailyCompleted, // 每日挑战完成
  streakDay,      // 连续签到天数
  playSeconds,    // 累计游玩秒数（生命周期增量上报）
  speedWin,       // 单局用时 ≤ target 秒且片数 ≥ minPieces（条件达标型）
}

enum AchievementKind {
  accumulative, // 累计型：current += value
  conditional,  // 条件达标型：单局事件满足即 0→1
  derived,      // 派生型：dependsOn 全解锁即达成（master_all）
}

class AchievementDef {
  String id;                   // 唯一 ID（成就表主键）
  String category;             // 分类：milestone / skill / difficulty / daily
  AchievementMetric? metric;   // derived 型为 null
  AchievementKind kind;
  int target;                  // 累计型=目标值；speedWin=秒上限 ⭐
  int? minPieces;              // 可选：最小片数（speedWin 必填）⭐
  String? difficultyKey;       // 可选：档位限定（first_win_l1~l6，如 "5x5"）
  List<String>? dependsOn;     // 派生依赖（master_all → first_win 全系）
  int coinReward;              // 金币奖励 ⭐
  String titleKey;             // i18n 键（en-US + zh-CN）
  String descKey;
  String icon;                 // 图标资源
}
```

> ⭐ = **运营可配字段**（改数值不改代码）；`difficultyKey` / `dependsOn` / `minPieces` 属规则结构，调整需回归测试。

---

## 二、成就总表（v1.0 裁决版 · 25 项）

### 里程碑类（milestone，8 项）

| id | metric | 条件 | 目标 | 奖励 ⭐ | titleKey / descKey | 说明 |
| --- | --- | --- | --- | --- | --- | --- |
| `complete_1` | solved | 累计通关 | 1 | 20 | `achievements.complete_1.title/desc` | 首次通关 |
| `complete_5` | solved | 累计通关 | 5 | 50 | `achievements.complete_5.title/desc` | |
| `complete_20` | solved | 累计通关 | 20 | 100 | `achievements.complete_20.title/desc` | |
| `complete_50` | solved | 累计通关 | 50 | 200 | `achievements.complete_50.title/desc` | |
| `snap_200` | snapped | 累计吸附 | 200 | 50 | `achievements.snap_200.title/desc` | |
| `snap_1000` | snapped | 累计吸附 | 1000 | 200 | `achievements.snap_1000.title/desc` | |
| `stars_100` | starsEarned | 累计获得星数（bestStars 增量） | 100 | 150 | `achievements.stars_100.title/desc` | 鼓励重玩多难度 |
| `time_2h` | playSeconds | 累计游玩时长 | 7200s | 100 | `achievements.time_2h.title/desc` | 生命周期口径，弃局计入 |

### 技巧类（skill，5 项）

| id | metric | 条件 | 目标 | 奖励 ⭐ | titleKey / descKey | 说明 |
| --- | --- | --- | --- | --- | --- | --- |
| `nohint_1` | noHintWin | 无提示通关（每图每档首次归零计 1） | 1 | 30 | `achievements.nohint_1.title/desc` | |
| `nohint_10` | noHintWin | 无提示通关 | 10 | 150 | `achievements.nohint_10.title/desc` | 防刷：按 minHintsUsed 每图首次归零 |
| `three_star_1` | threeStar | 3 星图数（按 canonicalId 去重） | 1 | 30 | `achievements.three_star_1.title/desc` | 同图多档刷 3 星只计 1 |
| `three_star_10` | threeStar | 3 星图数（去重） | 10 | 150 | `achievements.three_star_10.title/desc` | |
| `speed_10min` | speedWin | **≥100 片**且单局 ≤600s | 1 | 80 | `achievements.speed_10min.title/desc` | minPieces=100，防 L1 顺手拿 |

### 难度进展类（difficulty，8 项）

| id | metric | 条件 | 目标 | 奖励 ⭐ | titleKey / descKey | 说明 |
| --- | --- | --- | --- | --- | --- | --- |
| `first_win_l1` | solved | difficultyKey=`5x5` | 1 | 50 | `achievements.first_win_l1.title/desc` | 引导尝遍各档 |
| `first_win_l2` | solved | difficultyKey=`8x8` | 1 | 50 | `achievements.first_win_l2.title/desc` | |
| `first_win_l3` | solved | difficultyKey=`10x10` | 1 | 50 | `achievements.first_win_l3.title/desc` | |
| `first_win_l4` | solved | difficultyKey=`12x12` | 1 | 50 | `achievements.first_win_l4.title/desc` | |
| `first_win_l5` | solved | difficultyKey=`15x15` | 1 | 50 | `achievements.first_win_l5.title/desc` | |
| `first_win_l6` | solved | difficultyKey=`20x20` | 1 | 50 | `achievements.first_win_l6.title/desc` | |
| `three_star_diff_10` | threeStar | 3 星图数（跨档按图去重） | 10 | 200 | `achievements.three_star_diff_10.title/desc` | |
| `three_star_diff_30` | threeStar | 3 星图数（去重） | 30 | 400 | `achievements.three_star_diff_30.title/desc` | |

> **L1.5（36 块过渡档）不给 first_win 成就**：设计 §8.2 仅 `first_win_l1~l6` 六项，过渡档通关计入 `complete_*` 里程碑，不单独设成就（与定稿一致）。

### 每日类（daily，3 项）

| id | metric | 条件 | 目标 | 奖励 ⭐ | titleKey / descKey | 说明 |
| --- | --- | --- | --- | --- | --- | --- |
| `daily_first` | dailyCompleted | 完成每日挑战 | 1 | 50 | `achievements.daily_first.title/desc` | |
| `streak_3` | streakDay | 连续签到 | 3 天 | 60 | `achievements.streak_3.title/desc` | 依赖签到存储 |
| `streak_7` | streakDay | 连续签到 | 7 天 | 200 | `achievements.streak_7.title/desc` | 依赖签到存储 |

### 终极（derived，1 项）

| id | metric | 条件 | 目标 | 奖励 ⭐ | titleKey / descKey | 说明 |
| --- | --- | --- | --- | --- | --- | --- |
| `master_all` | —（null） | derived：dependsOn = first_win 全系（l1~l6） | 1 | 500 | `achievements.master_all.title/desc` | 无特判散落，依赖列表驱动 |

**合计**：8 + 5 + 8 + 3 + 1 = **25 项** ✅

---

## 三、计数与存储规则（AchievementStore）

计数器按 **metric（+可选档位分区）** 存储而非按成就，多成就共享同一计数：

| 类型 | 存储 | 示例 |
| --- | --- | --- |
| 账号级累计 | 持久化累计值，事件到达即累加 | `solved` / `snapped` / `starsEarned` / `playSeconds` / `noHintWin` |
| 带档位限定 | 计数 key 加档位分区（`metric:difficultyKey`） | `solved:5x5`（first_win_l1）~ `solved:20x20`（first_win_l6） |
| 事件去重 | 先查重再累加 | `starredPuzzles: Set<canonicalId>`（threeStar）、`noHintWin`（minHintsUsed 首次归零）、`speedWin`（0→1） |
| 派生/状态 | 存依赖达成态 | `masterAll`（dependsOn 检查 first_win 系列解锁态） |
| 日历计数 | 最近签到日期 + 连续天数 | `lastCheckInDate`（yyyy-MM-dd 本地时区）+ `streakDays` |

**签到存储依赖顺序**：签到存储（`lastCheckInDate` / `streakDays`）**必须先于** `streak_3/_7` 成就落地（设计 §9 内部依赖顺序），否则每日连签成就死锁。

---

## 四、防刷规则

1. **threeStar 按 canonicalId 去重**：同一张图在多个档位拿 3 星只计 1 次（`starredPuzzles` 集合），杜绝单图灌水刷 `three_star_10/_diff_30`。
2. **nohint_10 防刷**：按 `DifficultyRecord.minHintsUsed` 每图每档首次归零才计 1 次，同图反复刷不重复计。
3. **speed_10min 限片数**：`minPieces = 100`，防止打 25 块小图顺手拿。
4. **master_all 依赖驱动**：`dependsOn` 列表全解锁即达成，无硬编码计数（不耦合"恰好 N 项"）。
5. **奖励计入日上限**：成就金币发放走每日 200 币软帽（全渠道口径），超帽仅累计进度不发币。

---

## 五、i18n 键规范

- `titleKey` / `descKey` 一律使用 **i18n 键**（非内联文案），支持 en-US + zh-CN 双语。
- 命名规则：`achievements.<id>.title` / `achievements.<id>.desc`。

---

## 六、与代码映射与待落地清单

| 数据源 | 当前实现 | 落地状态 |
| --- | --- | --- |
| 成就配置表 | `AchievementService.allAchievements`（Dart 静态表） | ⚠️ 内容与本表不符，待按 v1.0 重排 |
| 数据模型 | `metricKey` 字符串 + 硬编码 title/description | ⚠️ 待改 `AchievementMetric` 枚举 + `titleKey/descKey` + `minPieces/difficultyKey/dependsOn` |
| 档位分区计数 | 无（tier_l3~l6 单调门槛） | ⚠️ 待改 `solved:5x5` 分区键 |
| 3 星去重 | ✅ `starredPuzzles` 已落地 | ✅ |
| playSeconds 生命周期 | ✅ 已落地 | ✅ |
| 签到存储 | ❌ 无 `lastCheckInDate`/`streakDays` | ⚠️ 待新增（先于 streak 成就） |
| master_all | 硬编码 `unlockedCount >= 24` | ⚠️ 待改 derived + dependsOn |
| 成就页 | 数据驱动（遍历 allAchievements） | ✅ 无需结构改动，仅随配置表自动更新 |
| 奖励日上限 | ✅ `claimReward` 已计入 | ✅ |

**代码重排步骤（后续独立一轮）**：
1. `AchievementDef` 模型升级（枚举 metric、kind、新字段、i18n 键）；
2. `allAchievements` 按本表 25 项重写；
3. `onPuzzleSolved` 支持档位分区计数（`solved:$difficultyKey`）与 derived 依赖检查；
4. 签到存储 + `onDailyCompleted` 调用点（解锁 daily_first / streak_3/7）；
5. i18n 资源补全（zh-CN / en-US）；
6. 重写 `achievement_service_test.dart` 覆盖：首局 `distinct_tiers==1`、档位分区、去重、dependsOn、签到连击。

---

## 七、决策记录

| # | 决策 | 说明 |
| --- | --- | --- |
| D1 | **严格对齐设计 §8.2 的 25 项**（用户拍板 2026-08-30） | 删除实现新增的 `custom_1/_5`、`night_owl`、`time_30m/10h`；补齐 `first_win_l1~l6`、`stars_100`、`nohint_10`、`three_star_diff_10/30`、`daily_first`、`streak_3/7` |
| D2 | `master_all` 奖励 500 币（设计值） | 当前实现 1000 币为偏离，重排时回改 |
| D3 | `time_2h` 奖励 100 币（设计值） | 当前实现 120 币为偏离，重排时回改 |
| D4 | L1.5（36 块过渡档）不设 first_win 成就 | 设计 §8.2 仅 `first_win_l1~l6` 六项，过渡档通关计入 complete_* 里程碑 |
| D5 | 奖励统一计入日上限 200 | 已落地（`claimReward` 无 bypassCap） |

---

> 依据：`docs/jigsaw-difficulty-scoring-achievements-design.md` §8.1/§8.2/§8.3（v3.3.1 定稿）；评审 `temp/codereviews/jigsaw-difficulty-scoring-achievements-design-review-dsf.md` P1-B。
