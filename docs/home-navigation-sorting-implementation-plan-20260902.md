# 首页导航与排序重构实现方案

> **文档版本**：v1.0  
> **创建日期**：2026-09-02  
> **基础文档**：`home-navigation-and-sorting-ux-design-20260902.md` v2.0 + 4 份独立评审（dsf / bdm / gmp / msf）  
> **适用项目**：Flutter 拼图游戏（`C:\Home\Projects\jigsawpuzzle`）  
> **目标**：在现有代码基础上，产出工程可靠、用户友好、对齐主流休闲拼图游戏的首页导航与排序实现方案

---

## 0. 方案总览与决策摘要

本方案整合原设计文档 v2.0 的方向判断与四份独立评审的共识性改进，在现有 Flutter 代码库基础上产出可直接进入开发的工程方案。

### 核心决策一览（每项附理由）

| # | 决策 | 理由 |
|---|------|------|
| D1 | 采用方案 A+（吸顶分组改良版），非原方案 A | 四份评审全票指出原 7 层架构首屏超标；A+ 压至 5 层 + 吸顶，首屏网格可见 2 行，解决 P0-1 |
| D2 | 状态过滤改为正交三态 + 全部（未开始 / 进行中 / 已完成 / 全部） | 原设计"未通关"与"进行中"语义重叠（dsf 3.1 + msf P0-3）；正交三态消除歧义 |
| D3 | 排序精简为 3 项（默认序号升序 / 最新倒序 / 最近游玩） | 去掉"未通关优先"（四份评审全票，功能与"未通关"过滤重叠）；3 项可做 SegmentedControl，零步发现 |
| D4 | 21 Tag 抽屉按玩家心智分 5 组 | 原平铺 21 个决策耗时 >3s（msf P0-5 引 Hick 定律）；分组后 5 选 1 再 4~5 选 1，决策链路更短 |
| D5 | 状态栏 + Tag 栏整体 SliverPersistentHeader 吸顶 | 500 关场景下滚到第 80 关想切 Tag 需滚回顶部（msf P0-4）；竞品 Magic Jigsaw / Easybrain 全部吸顶 |
| D6 | Daily Banner 与 Smart Hero 合并为动态单行 Hero 区 | 两张大卡上下堆叠产生视觉竞争（msf P0-6 + bdm 3.3）；合并后省一整层高度，首屏多露 1 行卡片 |
| D7 | 去掉悬浮定位胶囊 | Hero 栏已实现 0 步直达，悬浮按钮与之功能重叠（gmp 重叠 A + msf P1-2 触发阈值未定义易抖动） |
| D8 | 排序用 SegmentedControl 常驻显示，不用弹窗菜单 | 排序入口隐藏过深 + 关闭时不显示当前状态（bdm 2.1 违反 Nielsen 状态可见性）；SegmentedControl 一看即知一点即切 |
| D9 | 高频 Tag 横滑栏的"全部 21 类"入口固定吸顶不随横滑移动 | 原方案放在横滑栏最右端，不横滑看不到（gmp 3.1）；固定后任何时候一眼可见 |
| D10 | 解锁公式从 `index * 2` 改为线性步进 + 封顶 | 原公式第 101 关需 200+ 星，扩展到 500 关后几乎全锁（dsf 3.2）；线性步进维持"可玩未通关"数量 |
| D11 | LevelItem 直接新增 tags + lastPlayedAt 字段，不走 PuzzleLevelItem 迁移 | home_tab_view 和 GameRepository 全链路依赖 LevelItem；PuzzleLevelItem 是管线模型不含存档状态，混用会割裂 |
| D12 | lastPlayedAt 落盘挂进 _openLevel 入口和通关回调，老数据走 MigrationService | dsf 3.3 指出未交代存储与迁移；项目已有 MigrationService 迁移链，扩展即可 |
| D13 | 所有 comparator 末尾加 `a.index.compareTo(b.index)` 二次排序 | Dart sort 不稳定，无 tie-break 时重复操作结果顺序会抖（dsf 3.4 + bdm 4.3 + msf P1） |
| D14 | 过滤后列表自动 scrollToTop + 已选条件药丸常驻 | 防止用户忘记过滤态导致困惑（msf P1-3 + bdm 缺失项） |
| D15 | 保留每日挑战 Banner 入口但降级为 Hero 区内的横滑第二项 | 不删功能，只合并层级；用户横滑可看到每日挑战，主 CTA 不被稀释 |

---

## 1. 四方评审共识与分歧分析

### 1.1 全票共识（4/4 评审一致）

| 共识项 | dsf | bdm | gmp | msf |
|--------|-----|-----|-----|-----|
| 方案 A 方向正确，首期实施 | OK | OK | OK | OK(A+) |
| 7 层首屏超标，需做减法 | - | 1.1 | 1 | P0-1 |
| "未通关优先"排序与"未通关"过滤重叠，去掉 | 3.5 | 1.2 | 2 | P0-2 |
| LevelItem 无 tags/lastPlayedAt，需补迁移 | 3.3 | 4.1 | - | P1-1 |
| 排序需加 index tie-break 保证稳定性 | 3.4 | 4.3 | - | P1 |
| 空状态需明确设计 | - | 五 | 3 | P1-3 |

### 1.2 部分分歧（本方案的裁决）

| 分歧点 | dsf | bdm | gmp | msf | 本方案裁决 | 理由 |
|--------|-----|-----|-----|-----|-----------|------|
| 状态体系 | 正交三态 | 4 态保留 | 不涉及 | 4 态更名(未开始/进行中/已完成/全部) | **采用 msf 的 4 态** | msf 的"未开始"比 dsf 的"未开始"多含 `isUnlocked` 条件，避免了"未解锁的未开始"关卡混入，更精准 |
| 悬浮胶囊 | 保留(加阈值) | 不涉及 | 砍掉 | 保留(加防抖) | **砍掉** | gmp 论证最充分——Hero 已 0 步直达，胶囊纯属冗余且占视觉空间；FAB 在底部导航附近易误触 |
| Hero 与 Banner 合并 | 不涉及 | 合并或优先级 | 合并为 Carousel | 合并为单动态 Hero | **合并为单动态 Hero** | 四份中有三份倾向合并；单动态 Hero 比 Carousel 更简洁，减少一个交互维度 |
| Tag 抽屉分组 | 不涉及 | 分组或按数量排序 | 不涉及 | 5 组心智分类 | **采用 msf 的 5 组** | 按玩家心智分组比按数量排序更稳定（数量随内容变化），且降低认知负荷 |
| 排序入口形态 | 不涉及 | SegmentedControl | 不涉及 | Icon+文字胶囊 | **SegmentedControl** | bdm 论证更充分——3 项刚好做 SegmentedControl，状态可见 + 零步切换 |

---

## 2. 信息架构：5 层 + 吸顶

### 2.1 目标架构

```text
+---------------------------------------------------+
| AppBar: [fox logo] 异形拼图    [coins] [trophy] [settings] |  56dp
+---------------------------------------------------+
| Smart Hero Zone (动态单行, 72~88dp)                     |
|   有存档: [thumbnail] 继续上次 第88关 8x8 (65%) [继续]     |
|   无存档: [gradient]  下一挑战 第101关 (未开始) [挑战]     |
|   (横滑第二项: 每日挑战入口)                               |
+---------------------------------------------------+
| [SliverPersistentHeader pinned]                    |
|   Row1: [全部|未开始|进行中|已完成] (SegmentedControl)  |  44dp
|   Row2: [全部][pets][landscapes]...[全部21类 v] (横滑)  |  44dp
|         (+ 排序 SegmentedControl: 默认|最新|最近)       |
+---------------------------------------------------+
| 关卡网格 2列 (首屏可见 2 行)                            |
+---------------------------------------------------+
```

**首屏预算计算**：

| 层 | 高度 | 说明 |
|----|------|------|
| AppBar | 56dp | 含 coin/trophy/settings |
| Smart Hero | 72~88dp | 较原 Banner(160)+Hero(88)=248dp 节省 ~160dp |
| 吸顶区 Row1+Row2 | 88dp | 状态+Tag+排序合并为紧凑双行 |
| 网格首屏可见 | ~140dp | 2 行卡片(每行 ~70dp 含间距) |
| **合计控制区** | **~160~176dp** | 较原 ~390dp 节省 ~55% |

**对齐依据**：Magic Jigsaw 首屏控制区仅 Banner(120)+Filter(48)=168dp，Easybrain 无 Banner 首屏直接 4 张卡。本方案控制区 ~176dp 与 Magic Jigsaw 持平。

### 2.2 为什么是 5 层而非 7 层

原设计 7 层（AppBar / Daily Banner / Hero / 状态过滤 / Tag+排序 / 网格 / 悬浮胶囊）在 6.7 寸手机上前 5 层消耗 380~440dp，网格首屏仅露 0.5 行。MIT 媒体实验室眼动追踪证实移动端单次注视仅能处理 ~17 个视觉单元，超出部分触发选择性忽略。拼图游戏首页核心价值是"看到图、点进去玩"，关卡网格必须是首屏主角。

**减法路径**：
- Daily Banner + Hero → 合并为 Smart Hero Zone（省 ~160dp）
- 状态过滤 + 排序 → 合并为 Row1 SegmentedControl（省 ~44dp）
- 悬浮胶囊 → 删除（省视觉噪音 + 避免误触）
- Tag 栏保留独立 Row2 但整体吸顶

---

## 3. 核心模块详细设计

### 3.1 Smart Hero Zone（动态单行 Hero）

#### 3.1.1 状态机

```
Priority = 进行中存档 > 未开始下一关 > 每日挑战
```

| 场景 | 触发条件 | 视觉 | CTA |
|------|---------|------|-----|
| A 进行中 | `progressPercent > 0 && !isCompleted` 取最近 1 个 | 左侧 48x48 缩略图 + 右侧标题 + 环形进度 + 进度条 | `继续拼图` 实心品牌色按钮 |
| B 未开始 | 无进行中存档，存在 `isUnlocked && !isCompleted && progressPercent == 0` 的最小 index 关 | 渐变背景 + 大字关卡号 + 难度星级 | `立即挑战` 描边按钮 |
| C 新用户 | 通关数 < 5 时不展示 Hero | 首屏直接网格 | 降低教育成本 |
| D 每日挑战 | 用户横滑 Hero 区第二项 | 缩略图 + "每日挑战" 标签 | 跳转每日 Tab |

**理由**：
- 优先级 A > B > D：用户更可能继续未完成的拼图（bdm 3.3 + msf 3.3 共识）
- 新用户不展示 Hero：减少首屏元素，降低认知负担（msf 3.3 场景 C）
- 横滑第二项放每日挑战：不删功能只合并层级，保留入口可达性

#### 3.1.2 多存档场景

当存在多个进行中关卡时：
- Hero 主卡显示最近 1 个（按 `lastPlayedAt` 降序取首个）
- 主卡右侧显示 `还有 N 个` 小入口，点击跳转到状态过滤"进行中"视图
- **不采用水平滑动卡片**：msf 建议的 Netflix "Continue Watching" 行会再占一整层，与减法原则矛盾

**理由**：bdm 2.2 指出多存档场景缺失，但水平滑动卡片方案会重新增加首屏层级数。用一个 `还有 N 个` 文字入口既保留可达性又不占空间。

#### 3.1.3 材质区分

- Smart Hero Zone 用 `surfaceContainer` 背景 + 品牌色描边（1.5dp border）
- 不用全幅图片 + 黑色渐变（避免与已删除的 Daily Banner 同质化）
- 缩略图区域用 `ClipRRect(borderRadius: 12)`

### 3.2 状态过滤：正交四态

#### 3.2.1 枚举定义

```dart
enum LevelStatusFilter {
  all('全部'),
  notStarted('未开始'),
  inProgress('进行中'),
  completed('已完成');

  const LevelStatusFilter(this.label);
  final String label;
}
```

#### 3.2.2 语义与过滤逻辑

| 状态 | 过滤条件 | 计数示例 | 空状态引导 |
|------|---------|---------|-----------|
| 全部 | 无过滤 | 全部(200) | — |
| 未开始 | `!isCompleted && progressPercent == 0 && isUnlocked` | 未开始(99) | "去挑战下一关吧" + Hero CTA |
| 进行中 | `progressPercent > 0 && !isCompleted` | 进行中(2) | "还没有进行中的拼图" |
| 已完成 | `isCompleted` | 已完成(99) | "完成更多关卡来收集星星" |

**关键决策理由**：
- **"未开始"加 `isUnlocked` 条件**（msf 方案）：避免锁定关卡混入"未开始"列表，防止"未通关"筛选变成一整排灰色锁墙（dsf 3.2 核心问题）
- **废弃"未通关"**：中文语境下"未通关"包含"进行中"，两态并列时用户无法判断是包含还是互斥（msf P0-3）。原设计的 `uncompleted = !isCompleted` 与 `inProgress = progress > 0 && !isCompleted` 存在严格子集关系（dsf 3.1 证明）
- **四态互斥**：全部 / 未开始 / 进行中 / 已完成，任意关卡在任意时刻仅属于后三态之一

#### 3.2.3 角标计数语义

计数显示的是**当前 Tag 筛选下的该状态关卡数**，而非全量状态分布。

```dart
// 先按 Tag 过滤，再统计状态分布
final tagFiltered = selectedTag == 'all' 
    ? allLevels 
    : allLevels.where((l) => l.tags.contains(selectedTag)).toList();
final counts = {
  LevelStatusFilter.all: tagFiltered.length,
  LevelStatusFilter.notStarted: tagFiltered.where(_isNotStarted).length,
  LevelStatusFilter.inProgress: tagFiltered.where(_isInProgress).length,
  LevelStatusFilter.completed: tagFiltered.where(_isCompleted).length,
};
```

**理由**：bdm 2.4 指出当前代码先状态过滤再 Tag 过滤，但计数需要的是 Tag 过滤后的状态分布。如果不一致，用户看到"进行中(2)"但实际过滤结果为空，产生认知混乱。计数 >99 显示 `99+` 避免三位数撑开布局（msf 3.6）。

### 3.3 排序：3 维 SegmentedControl

#### 3.3.1 排序枚举

```dart
enum LevelSortOrder {
  defaultOrder('默认'),   // 序号升序 1 -> 200
  latest('最新'),         // 序号倒序 200 -> 1
  recentlyPlayed('最近'); // lastPlayedAt 倒序

  const LevelSortOrder(this.label);
  final String label;
}
```

#### 3.3.2 排序算法（含 tie-break）

```dart
List<LevelItem> applySort(List<LevelItem> list, LevelSortOrder order) {
  final copy = List<LevelItem>.from(list);
  switch (order) {
    case LevelSortOrder.defaultOrder:
      copy.sort((a, b) => a.index.compareTo(b.index));
      break;
    case LevelSortOrder.latest:
      copy.sort((a, b) => b.index.compareTo(a.index));
      break;
    case LevelSortOrder.recentlyPlayed:
      copy.sort((a, b) {
        final aTime = a.lastPlayedAt?.millisecondsSinceEpoch ?? 0;
        final bTime = b.lastPlayedAt?.millisecondsSinceEpoch ?? 0;
        final cmp = bTime.compareTo(aTime);
        if (cmp != 0) return cmp;
        return a.index.compareTo(b.index); // tie-break
      });
      break;
  }
  return copy;
}
```

**理由**：
- **去掉"未通关优先"**：四份评审全票。该排序等价于"状态=未通关 + 序号升序"，是过滤而非排序（msf P0-2）。保留它会让用户面对"用过滤还是排序"的选择负担（违反 Hick 定律）
- **3 项做 SegmentedControl**：bdm 2.1 论证——3 个选项刚好做成 SegmentedControl 而非弹窗菜单，常驻显示当前排序状态，一点即切，零步发现。原设计的 `[排序]` 按钮关闭时不显示当前状态，违反 Nielsen 系统状态可见性
- **tie-break 统一加 `a.index.compareTo(b.index)`**：Dart 的 `List.sort` 不保证稳定性（dsf 3.4 + bdm 4.3）。`recentlyPlayed` 中两个关卡 `lastPlayedAt` 都为 null 时，不加 tie-break 则每次排序结果顺序可能不同，造成"抖动"

### 3.4 21 Tag 分组抽屉

#### 3.4.1 分组方案（按玩家心智）

```text
+-- 自然风光 -----------------------------------+
| [nature] [landscapes] [flowers] [ocean]       |
+-- 萌趣生灵 -----------------------------------+
| [pets] [animals] [birds]                      |
+-- 人文都市 -----------------------------------+
| [cities] [architecture] [food] [people] [transportation] |
+-- 想象风格 -----------------------------------+
| [art] [fantasy] [space] [abstract] [cartoon] |
+-- 季节节日 -----------------------------------+
| [seasons] [holidays] [sports] [others]        |
+-----------------------------------------------+
```

**理由**：
- msf P0-5 指出 21 选 1 的平均决策时间 >3s（Hick 定律），违背游戏轻量感
- 分组后决策链路变为 5 选 1 → 3~5 选 1，认知负荷显著降低
- 按玩家心智而非开发者 ID 分组：`Nature/Landscapes/Flowers/Ocean` 对玩家是同一类"自然"，`Animals/Pets/Birds` 是"生灵"
- 每组标题显示总数（如"自然风光 (80)"），给用户总量预期

#### 3.4.2 高频横滑栏

- 首页常驻横滑栏展示 `全部` + 数据驱动的 TOP 7 高频 Tag
- "全部 21 类" 入口固定在横滑栏右侧，**不随横滑移动**（用 Stack + Positioned.right 实现）
- 点击展开 BottomSheet 抽屉，显示分组 Tag

**理由**：
- 原方案把"全部 21 类"放在横滑栏最右端，用户不横滑看不到（gmp 3.1）。固定吸顶确保任何时候一眼可见
- 高频 7 个数据驱动：上线前跑 `SELECT tag, COUNT(*) GROUP BY` 取 TOP7，而非文档写死的 7 个（msf 3.4 建议）。运营后台可配置
- 抽屉内按 `关卡数倒序` 排列 Tag，热门 Tag 置顶（bdm 2.3 建议）

#### 3.4.3 Tag 卡片设计

- 每个 Tag 卡片包含：Emoji + 中文名 + 包含关卡总数
- 卡片尺寸统一，3 列网格排布
- 选中态：品牌色描边 + 浅品牌色背景
- Emoji 兜底：Windows 上部分 Emoji（如 `landscapes` `architecture`）可能黑白，需配 `assets/icons/tag_*.svg` 兜底（msf 第 5 节）

### 3.5 已选条件药丸与空状态

#### 3.5.1 已选条件药丸

当用户选了 Tag 或状态过滤后，在吸顶区下方常驻显示：

```text
[ pets x 未开始 ]  [ 清除 ]
```

**理由**：防止用户忘记过滤态导致困惑（msf P1-3 + bdm 缺失项）。点击 `x` 清除单个条件，点击 `清除` 清除全部。

#### 3.5.2 空状态设计

```text
+---------------------------+
|        [illustration]      |
|                           |
|  没有符合「pets x 进行中」的关卡  |
|                           |
|  [清除Tag]    [查看全部pets]  |
+---------------------------+
```

**理由**：
- 原代码仅有 `🦊 小狐狸没找到符合该条件的关卡`（home_tab_view.dart:252-260），无引导动作
- 双 CTA 防止用户陷入死胡同：`清除Tag` 回到当前状态的全量，`查看全部pets` 放弃状态过滤只保留 Tag

### 3.6 网格过滤切换动画

- Tag/状态切换后，网格用 `AnimatedSwitcher`（180ms 淡入淡出）
- 不用 `SliverAnimatedGrid`：复杂度高且 500 关场景下性能不稳定
- 每次过滤后自动 `scrollController.animateTo(0, duration: 200ms)`

**理由**：bdm 缺失项指出过滤后列表突变会造成视觉跳跃。AnimatedSwitcher 轻量且稳定，180ms 符合 Material Motion 时长规范。

---

## 4. 数据模型与迁移方案

### 4.1 LevelItem 扩展

```dart
class LevelItem {
  const LevelItem({
    required this.id,
    required this.index,
    required this.title,
    required this.assetPath,
    required this.difficulty,
    this.tags = const [],           // NEW: 21 类 Primary Tag 数组
    this.isUnlocked = false,
    this.isCompleted = false,
    this.progressPercent = 0,
    this.stars = 0,
    this.bestTimeSeconds = 0,
    this.savedSnapshotJson,
    this.completedPieceCounts = const [],
    this.lastPlayedAt,              // NEW: 最后游玩时间戳
  });

  final List<String> tags;          // NEW
  final DateTime? lastPlayedAt;     // NEW
  // ... 其余字段不变
}
```

#### 4.1.1 toJson / fromJson 兼容

```dart
Map<String, dynamic> toJson() => {
  // ... 现有字段不变
  'tags': tags,
  'lastPlayedAt': lastPlayedAt?.toIso8601String(),
};

factory LevelItem.fromJson(Map<String, dynamic> json) {
  // ... 现有解析不变
  return LevelItem(
    // ... 现有字段不变
    tags: (json['tags'] as List<dynamic>?)
        ?.map((e) => e.toString()).toList() ?? const [],
    lastPlayedAt: json['lastPlayedAt'] != null
        ? DateTime.tryParse(json['lastPlayedAt'] as String)
        : null,
  );
}
```

#### 4.1.2 copyWith 扩展

```dart
LevelItem copyWith({
  // ... 现有参数不变
  List<String>? tags,
  DateTime? lastPlayedAt,
  bool clearLastPlayedAt = false,
}) {
  return LevelItem(
    // ... 现有字段不变
    tags: tags ?? this.tags,
    lastPlayedAt: clearLastPlayedAt ? null : (lastPlayedAt ?? this.lastPlayedAt),
  );
}
```

**为什么直接扩展 LevelItem 而非迁移到 PuzzleLevelItem**：
- `home_tab_view.dart` 和 `GameRepository` 全链路依赖 `LevelItem`（100+ 处引用）
- `PuzzleLevelItem` 是内容管线模型（`MainContentPipeline`），不含 `stars`、`bestTimeSeconds`、`savedSnapshotJson`、`completedPieceCounts` 等存档字段
- 两者职责不同：`LevelItem` = 关卡 + 存档状态，`PuzzleLevelItem` = 关卡 + 内容管线
- 混用会导致存档状态丢失，风险远大于给 `LevelItem` 加两个字段
- `PuzzleLevelItem` 已有 tags 字段和 `filterByTag`，未来如需管线→UI 桥接，由 `GameRepository._initLevels()` 在初始化时从 `MainContentPipeline.levels` 拉取 tags 注入 `LevelItem` 即可

### 4.2 LevelFilter 枚举迁移

**现状**（home_tab_view.dart:16-26）：
```dart
enum LevelFilter {
  all('全部关卡'),
  starter('新手 (9-16)'),
  intermediate('进阶 (24-36)'),
  master('大师 (48-100+)'),
  completed('已通关'),
  inProgress('进行中');
}
```

**目标**：
```dart
enum LevelStatusFilter {
  all('全部'),
  notStarted('未开始'),
  inProgress('进行中'),
  completed('已完成');
}
```

**迁移步骤**：
1. 全局搜索 `LevelFilter` 的所有引用（当前仅 `home_tab_view.dart` 内 12 处）
2. 重命名 `LevelFilter` → `LevelStatusFilter`
3. 删除 `starter` / `intermediate` / `master` 三个伪难度枚举值
4. 新增 `notStarted` 枚举值
5. 修改 `_getFilteredLevels` 中的 switch/case
6. 修改 `_FilterBar` widget 适配新枚举

**理由**：
- 当前伪难度过滤（`pieceCount <= 16` / `24~36` / `>=48`）与实际游玩矛盾：任何关卡点进去都可在 `ChooseDifficultySheet` 中自由选择 16~225 块（原设计 1.3 节）
- `LevelFilter` 仅在 `home_tab_view.dart` 内使用，迁移影响面可控

### 4.3 lastPlayedAt 落盘点

在 `home_tab_view.dart` 的 `_openLevel` 方法中，用户每次打开关卡时记录时间戳：

```dart
Future<void> _openLevel(LevelItem level) async {
  // 记录 lastPlayedAt
  await _repo.updateLastPlayedAt(level.index);
  // ... 其余逻辑不变
}
```

在 `GameRepository` 中新增方法：

```dart
Future<void> updateLastPlayedAt(int levelIndex) async {
  final idx = levelIndex - 1;
  if (idx < 0 || idx >= _levels.length) return;
  _levels[idx] = _levels[idx].copyWith(
    lastPlayedAt: DateTime.now(),
  );
  await _prefs?.setString(
    '$_keyLevelsPrefix$levelIndex',
    jsonEncode(_levels[idx].toJson()),
  );
}
```

**落盘时机选择**：
- `_openLevel` 入口（用户点击关卡卡片时）：覆盖"看了但没拼"的场景
- 通关回调已有 `updateLevelProgress`，可在此一并更新 `lastPlayedAt`

**理由**：dsf 3.3 指出未交代存储与迁移。选择在 `_openLevel` 入口落盘而非在游戏页面退出时，是因为 `_openLevel` 是 `home_tab_view.dart` 内方法，修改集中在一处，不需要跨页面传递回调。

### 4.4 老存档迁移

在 `MigrationService` 中新增迁移步骤：

```dart
static const String _keyTagsMigrated = 'jigsaw_tags_last_played_migrated';

// 在 migrateIfNeeded 中新增
final alreadyMigratedTags = prefs.getBool(_keyTagsMigrated) ?? false;
if (!alreadyMigratedTags) {
  await _migrateTagsAndLastPlayed(prefs, levels);
}
```

迁移逻辑：
1. 遍历已保存的关卡 JSON（`jigsaw_level_N`）
2. 对每条数据：如果无 `tags` 字段，补 `tags: []`；如果无 `lastPlayedAt` 字段，补 `null`
3. 重新写入 prefs
4. 标记迁移完成

**理由**：项目已有 `MigrationService` 迁移链（`_keyMigrated` / `_keyV33Migrated`），扩展一个新迁移步骤即可。老存档的 `LevelItem.fromJson` 已经通过 `?? const []` 和 `?? null` 做了缺省兼容，迁移是双重保险。

### 4.5 解锁公式改造

**现状**（home_tab_view.dart:898）：
```dart
Text('需 ${level.index * 2} 星解锁')
```

**目标**：线性步进 + 封顶

```dart
int getRequiredStars(int levelIndex) {
  // 前 50 关: 每关 +2 星 (1~100)
  // 51~200 关: 每关 +1 星 (100~250)
  // 201+ 关: 固定 250 星
  if (levelIndex <= 50) return levelIndex * 2;
  if (levelIndex <= 200) return 100 + (levelIndex - 50);
  return 250;
}
```

**理由**：
- 原公式 `index * 2` 在第 101 关需 202 星，而全部通关 100 关仅得 ~300 星（含 3 星评价），到 101 关时星数不够解锁，"未通关"筛选变成锁墙（dsf 3.2）
- 线性步进 + 封顶保证：前 50 关节奏不变（新手期挑战感），51~200 关步进放缓（中期平滑），201+ 封顶（后期不卡死）
- 这是数据层改动，不影响 UI 结构

### 4.6 Tag 数据注入链路

```
levels_manifest.json (打包)
    |
    v
GameRepository._initLevels()
    |-- 读取 manifest 中的 tags 字段
    |-- 注入 LevelItem.tags
    v
home_tab_view.dart
    |-- _getFilteredLevels() 使用 l.tags 过滤
    v
Tag 抽屉显示真实分类计数
```

**当前状态**：`levels_manifest.json` 文件尚不存在（glob 搜索无结果），`_initLevels()` 用 `assetSamples` 循环 100 关。Tag 过滤使用 `index % 5` mock 数据。

**迁移路径**：
1. 先给 `LevelItem` 加 `tags` 字段 + `fromJson`/`toJson` 兼容（默认空数组）
2. 运行 `scripts/ai_tag_images.py` 对关卡图片打标，产出 `tags.json`
3. 将 `tags.json` 合并入 `levels_manifest.json`（或直接在 `_initLevels` 中读取 `tags.json`）
4. 修改 `_initLevels()` 从 manifest 读取 tags 注入 `LevelItem`
5. 切换 `home_tab_view.dart` 的 `_getFilteredLevels` 从 mock 逻辑到真实 `l.tags` 过滤

**理由**：bdm 4.1 和 msf P1-1 指出设计文档与代码脱节。`MainContentPipeline` 已有完整的 manifest 解析和 tag 过滤逻辑（`_parseLevelItem` / `filterByTag`），但 `GameRepository._initLevels` 仍用 `assetSamples` 硬编码。迁移应先铺模型兼容，再铺数据，最后切 UI。

---

## 5. 复合过滤与排序管道

### 5.1 完整管道

```dart
class FilterSortResult {
  final List<LevelItem> levels;
  final Map<LevelStatusFilter, int> statusCounts;

  FilterSortResult(this.levels, this.statusCounts);
}

FilterSortResult filterAndSortLevels({
  required List<LevelItem> allLevels,
  required LevelStatusFilter statusFilter,
  required String selectedTag,
  required LevelSortOrder sortOrder,
}) {
  // 1. Tag 过滤（先于状态过滤，用于角标计数）
  final tagFiltered = selectedTag.toLowerCase() == 'all'
      ? allLevels
      : allLevels.where((l) => l.tags.any((t) => 
          t.toLowerCase() == selectedTag.toLowerCase())).toList();

  // 2. 统计各状态计数（基于 Tag 过滤后的集合）
  final statusCounts = {
    LevelStatusFilter.all: tagFiltered.length,
    LevelStatusFilter.notStarted: tagFiltered.where(_isNotStarted).length,
    LevelStatusFilter.inProgress: tagFiltered.where(_isInProgress).length,
    LevelStatusFilter.completed: tagFiltered.where(_isCompleted).length,
  };

  // 3. 状态过滤
  var list = tagFiltered.where((l) => _matchesStatus(l, statusFilter)).toList();

  // 4. 排序（含 tie-break）
  list = _applySort(list, sortOrder);

  return FilterSortResult(list, statusCounts);
}

bool _isNotStarted(LevelItem l) =>
    !l.isCompleted && l.progressPercent == 0 && l.isUnlocked;

bool _isInProgress(LevelItem l) =>
    l.progressPercent > 0 && !l.isCompleted;

bool _isCompleted(LevelItem l) =>
    l.isCompleted;

bool _matchesStatus(LevelItem l, LevelStatusFilter filter) {
  switch (filter) {
    case LevelStatusFilter.all: return true;
    case LevelStatusFilter.notStarted: return _isNotStarted(l);
    case LevelStatusFilter.inProgress: return _isInProgress(l);
    case LevelStatusFilter.completed: return _isCompleted(l);
  }
}
```

### 5.2 性能考量

- 500 关全量拷贝 + 排序在主线程执行，耗时约 <1ms（Dart sort 对 500 元素微秒级）
- 如果未来扩展到 1000+ 关，可加 `memoization`：用 `(statusFilter, selectedTag, sortOrder)` 三元组做 key 缓存结果
- 角标计数每次过滤时计算，500 关 O(n) 遍历 <1ms，无需缓存

**理由**：msf 第 4 节建议 memoization，但当前 500 关规模下无必要。预留缓存接口即可。

---

## 6. Flutter 工程实现要点

### 6.1 SliverPersistentHeader 吸顶实现

```dart
class _StickyFilterHeader extends SliverPersistentHeaderDelegate {
  @override
  Widget build(BuildContext context, double shrinkOffset, bool overlapsContent) {
    return Container(
      decoration: BoxDecoration(
        color: palette.surface,
        border: Border(
          bottom: BorderSide(color: palette.divider, width: 0.5),
        ),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // Row1: 状态 SegmentedControl + 排序 SegmentedControl
          _StatusAndSortRow(...),
          // Row2: Tag 横滑栏 + 固定"全部 21 类"入口
          _TagScrollRow(...),
        ],
      ),
    );
  }

  @override
  double get minExtent => 88.0;  // Row1(44) + Row2(44)
  @override
  double get maxExtent => 88.0;
  @override
  bool shouldRebuild(covariant SliverPersistentHeaderDelegate oldDelegate) => true;
}
```

**关键点**：
- `minExtent == maxExtent == 88.0`：不需要折叠动画，始终全高度吸顶
- `pinned: true` 在 `CustomScrollView` 中使用
- 替换当前 `home_tab_view.dart` 中的两个独立 `SliverToBoxAdapter`（228-243 行）

**理由**：msf P0-4 指出当前 `SliverToBoxAdapter` 不吸顶，500 关场景下用户滚到第 80 关想切 Tag 需滚回顶部。竞品全部吸顶。

### 6.2 Tag 横滑栏 + 固定入口

```dart
class _TagScrollRow extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 44,
      child: Stack(
        children: [
          // 横滑 Tag 列表（右侧留 80dp 给固定入口）
          Padding(
            padding: const EdgeInsets.only(right: 80),
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                children: [
                  _TagChip(label: '全部', ...),
                  for (final tag in topTags)
                    _TagChip(label: tag.label, ...),
                ],
              ),
            ),
          ),
          // 固定"全部 21 类"入口
          Positioned(
            right: 0,
            top: 0,
            bottom: 0,
            child: _AllCategoriesButton(...),
          ),
        ],
      ),
    );
  }
}
```

**理由**：gmp 3.1 指出原方案的"全部 21 类"放在横滑栏最右端，用户不横滑看不到。用 Stack + Positioned.right 固定，确保任何时候一眼可见。

### 6.3 SegmentedControl 实现

```dart
class _SortSegmentedControl extends StatelessWidget {
  final LevelSortOrder selected;
  final ValueChanged<LevelSortOrder> onChanged;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 2, vertical: 2),
      decoration: BoxDecoration(
        color: palette.surfaceContainer,
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: LevelSortOrder.values.map((order) {
          final isActive = order == selected;
          return GestureDetector(
            onTap: () => onChanged(order),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
              decoration: BoxDecoration(
                color: isActive ? palette.brand : Colors.transparent,
                borderRadius: BorderRadius.circular(8),
              ),
              child: Text(
                order.label,
                style: TextStyle(
                  fontSize: 11,
                  fontWeight: isActive ? FontWeight.w700 : FontWeight.w500,
                  color: isActive ? palette.surface : palette.secondaryText,
                ),
              ),
            ),
          );
        }).toList(),
      ),
    );
  }
}
```

**理由**：bdm 2.1 论证——3 个排序选项刚好做成 SegmentedControl 常驻显示，一看即知当前排序，一点即切。原设计的 `[排序]` 按钮隐藏入口 + 关闭时不显示状态，违反 Nielsen 状态可见性。

### 6.4 过滤状态持久化

```dart
// 在 _HomeTabViewState 中
late SharedPreferences _prefs;

@override
void initState() {
  super.initState();
  _loadFilterState();
}

void _loadFilterState() {
  // 持久化 Tag + 状态选择，不持久化排序
  _selectedTag = _prefs.getString('home_selected_tag') ?? 'all';
  _selectedFilter = LevelStatusFilter.values.firstWhere(
    (f) => f.name == _prefs.getString('home_selected_status'),
    orElse: () => LevelStatusFilter.all,
  );
}

void _saveFilterState() {
  _prefs.setString('home_selected_tag', _selectedTag);
  _prefs.setString('home_selected_status', _selectedFilter.name);
}
```

**理由**：bdm 缺失项建议持久化 Tag + 状态选择，但不持久化排序。排序是临时浏览意图（"看看最新"或"看看最近玩的"），每次打开 App 应重置为默认排序。

---

## 7. 与现有代码的改动清单

### 7.1 需修改的文件

| 文件 | 改动范围 | 改动内容 |
|------|---------|---------|
| `lib/data/models/level_item.dart` | 新增字段 | `tags`, `lastPlayedAt` + toJson/fromJson/copyWith |
| `lib/data/game_repository.dart` | 新增方法 | `updateLastPlayedAt()`, 修改 `_initLevels()` 读 manifest tags |
| `lib/data/migration_service.dart` | 新增迁移步骤 | `_migrateTagsAndLastPlayed()` + 迁移标记 |
| `lib/pages/tabs/home_tab_view.dart` | 大幅重构 | 替换 LevelFilter 枚举, 新增 Smart Hero, 吸顶区, SegmentedControl, Tag 抽屉, 空状态, 过滤管道 |
| `lib/pages/main_screen.dart` | 微调 | AppBar 可选增加总进度显示 |

### 7.2 需新增的文件

| 文件 | 职责 |
|------|------|
| `lib/pages/tabs/widgets/smart_hero_zone.dart` | Smart Hero Zone 组件 |
| `lib/pages/tabs/widgets/sticky_filter_header.dart` | 吸顶过滤区 SliverPersistentHeaderDelegate |
| `lib/pages/tabs/widgets/tag_drawer_sheet.dart` | 21 Tag 分组抽屉 BottomSheet |
| `lib/pages/tabs/widgets/filter_pill_bar.dart` | 已选条件药丸栏 |
| `lib/pages/tabs/widgets/empty_state.dart` | 空状态组件 |
| `lib/logic/level_filter_sort.dart` | 复合过滤与排序管道（纯逻辑，可单测） |

### 7.3 不需修改的文件

- `lib/logic/content/pipelines/main_content_pipeline.dart`：已有 tag 过滤逻辑，未来桥接时复用
- `lib/logic/content/models/puzzle_level_item.dart`：管线模型保持不变
- `lib/data/snapshot_store.dart` / `lib/data/progress_store.dart`：快照与进度存储不受影响
- `lib/theme/app_palette.dart`：色板已有 `brand` / `surfaceContainer` / `divider`，无需新增

---

## 8. 实施路线（分阶段）

### Phase 1：数据层（无 UI 变更，可独立验证）

| 步骤 | 内容 | 验证方式 |
|------|------|---------|
| 1.1 | `LevelItem` 新增 `tags` + `lastPlayedAt` 字段，扩展 toJson/fromJson/copyWith | `flutter test` 确认现有测试通过 |
| 1.2 | `MigrationService` 新增 `_migrateTagsAndLastPlayed` 迁移步骤 | 手动测试老存档启动不崩 |
| 1.3 | `GameRepository` 新增 `updateLastPlayedAt()` 方法 | 单元测试 |
| 1.4 | `GameRepository._initLevels()` 增加 manifest tags 读取（manifest 存在时） | 启动测试 |
| 1.5 | 新建 `lib/logic/level_filter_sort.dart`，实现复合过滤排序管道 | 单元测试覆盖 4 态 x 3 排序 x Tag 过滤 |

### Phase 2：UI 层（依赖 Phase 1）

| 步骤 | 内容 | 验证方式 |
|------|------|---------|
| 2.1 | 重命名 `LevelFilter` → `LevelStatusFilter`，删除伪难度，新增 `notStarted` | `flutter analyze` 无报错 |
| 2.2 | 新建 `smart_hero_zone.dart`，实现动态单行 Hero | 手动测试 3 种场景 |
| 2.3 | 新建 `sticky_filter_header.dart`，实现吸顶双行（状态 SegmentedControl + Tag 横滑 + 排序 SegmentedControl） | 手动测试滚动吸顶 |
| 2.4 | 新建 `tag_drawer_sheet.dart`，实现 5 组分类抽屉 | 手动测试 Tag 选择与过滤 |
| 2.5 | 新建 `filter_pill_bar.dart` + `empty_state.dart` | 手动测试交叉筛选空状态 |
| 2.6 | 重构 `home_tab_view.dart`，替换为新组件，接入 `level_filter_sort.dart` | `flutter analyze` + `flutter test` |

### Phase 3：打磨与验收

| 步骤 | 内容 | 验证方式 |
|------|------|---------|
| 3.1 | 过滤切换动画（AnimatedSwitcher 180ms 淡入淡出） | 手动测试 |
| 3.2 | 解锁公式改造（线性步进 + 封顶） | 单元测试 |
| 3.3 | 过滤状态持久化（Tag + 状态持久化，排序不持久化） | 重启 App 验证 |
| 3.4 | 深色模式适配验证 | 手动切换暗色模式 |
| 3.5 | `dart format` 有改动的文件 | `dart format` 无 diff |
| 3.6 | `flutter analyze` + `flutter test` 全通过 | CI 验证 |
| 3.7 | `flutter build windows --debug` 编译验证 | 编译无错误 |

### Phase 4：数据管线（可与 Phase 2 并行）

| 步骤 | 内容 | 验证方式 |
|------|------|---------|
| 4.1 | 运行 `scripts/ai_tag_images.py` 对关卡图片打标 | 产出 `tags.json` |
| 4.2 | 人工校对 tags（特别是 Nature/Landscapes/Flowers 易混组） | 抽检通过 |
| 4.3 | 合并为 `levels_manifest.json` 或独立 `tags.json` | 文件存在且格式正确 |
| 4.4 | `GameRepository._initLevels()` 读取真实 tags 注入 LevelItem | 启动测试 Tag 过滤生效 |

---

## 9. 远期演进：方案 B（分卷体系）

当关卡数 > 300 且完成率 > 40% 时，可平滑演进为方案 B（篇章分卷体系）。

**演进路径**：
1. `LevelItem.index` 已是线性整数，分卷时按 `index ~/ 50` 计算 Volume 号
2. 首页在最外层增加 `Volume 1~N` 的横滑/折叠控件
3. 卷内保留当前的 Tag + 状态 + 排序过滤
4. 通关卷折叠为徽章，给予阶段性成就感

**不在首期实施的理由**：
- msf 1.2 指出分卷会让新用户误判"必须按卷顺序解锁"，增加心智负担
- 当前 100 关（目标 200 关）规模不够触发分卷
- 方案 A+ 的 Hero + 过滤已解决找关问题，分卷非必要

---

## 10. 竞品对齐总结

| 设计决策 | 本方案 | Magic Jigsaw (ZiMAD) | Easybrain | Candy Crush |
|---------|--------|---------------------|-----------|-------------|
| 首屏控制区高度 | ~176dp | ~168dp (Banner120+Filter48) | ~48dp (仅Filter) | 地图式无Filter |
| 首屏可见卡片行数 | 2 行 | 2 行 | 4 行 | N/A |
| 分类系统 | 5 组 21 Tag | 多分类横滑+全部入口 | 多分类 | 无分类(地图式) |
| 继续游戏入口 | Smart Hero (顶部第1层) | 有(顶部) | 有(顶部) | 有(地图位置) |
| 多存档支持 | Hero+文字入口 | 多存档并行 | 多存档并行 | 单存档 |
| 排序方式 | 3 维 SegmentedControl | 无排序(按分类浏览) | 无排序 | 无排序(线性地图) |
| 吸顶过滤 | SliverPersistentHeader | 有 | 有 | N/A |
| 每日挑战 | Hero 横滑第二项 | 每日免费拼图 | 每日挑战 | 每日奖励 |
| 空状态 | 插画+双CTA | 无明确设计 | 无明确设计 | N/A |

**关键差异说明**：
- 本方案比 Magic Jigsaw 多了排序功能：拼图游戏从 100→500 关后，用户需要按"最近游玩"找回上次玩的关卡，Magic Jigsaw 的 40000+ 拼图不排序是因为其分类浏览已足够
- 本方案比 Easybrain 多了 Hero 和每日挑战：Easybrain 是极简风格，但缺失"继续上次"的直达入口
- 本方案不采用 Candy Crush 的地图式：拼图游戏无闯关路径依赖（任何关卡可独立玩），地图式增加不必要的线性束缚

---

## 11. 风险与缓解

| 风险 | 概率 | 影响 | 缓解措施 |
|------|------|------|---------|
| Tag 数据尚未打标 | 高 | Tag 过滤无数据 | Phase 1 先用空 tags (默认 all)，Phase 4 补数据后自动生效 |
| Emoji 在 Windows 黑白 | 中 | Tag 显示不一致 | 配 `assets/icons/tag_*.svg` 兜底 |
| 500 关列表滚动卡顿 | 低 | 体验下降 | SliverGrid 已懒加载构建；如需进一步优化加 `cacheExtent` |
| 老存档迁移失败 | 低 | 用户数据丢失 | fromJson 已有缺省兼容；MigrationService 有 try-catch |
| 吸顶区高度在不同设备偏差 | 中 | 布局抖动 | minExtent == maxExtent 固定 88dp，不设折叠动画 |

---

## 12. 结论

本方案在原设计 v2.0 方向正确的基础上，整合四份独立评审的共识性改进，产出可直接进入开发的工程方案：

1. **架构做减法**：7 层 → 5 层 + 吸顶，首屏控制区从 ~390dp 压至 ~176dp，网格首屏可见 2 行
2. **语义做正交**：状态从含混四态改为正交四态（全部/未开始/进行中/已完成），排序从 4 维精简为 3 维
3. **交互做减法**：去掉悬浮胶囊，排序改为 SegmentedControl 常驻，Tag 抽屉按心智分组
4. **工程做加法**：LevelItem 扩展两个字段 + 迁移链扩展 + tie-break + 空状态 + 过滤持久化

每个决策都有四份评审中的至少一份作为依据，并在本文档中附了理由。方案可分 4 个 Phase 渐进实施，Phase 1（数据层）不改变 UI 可独立验证，Phase 2（UI 层）依赖 Phase 1，Phase 4（数据管线）可与 Phase 2 并行。
