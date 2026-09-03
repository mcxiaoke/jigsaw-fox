# 拼图画幅比例扩展与自适应切片网格重构方案（支持 1:1 / 2:3 / 3:4）

> **文档版本**：v4.1（实操全闭环定稿）  
> **更新日期**：2026-09-03  
> **核心原则**：
> 1. **画幅即插即用（Plug & Play）**：全库彻底清除比例字面量硬编码，任意注释或新增某个比例/切片阶梯时，全局零报错、零联动修改；
> 2. **裁切页面极简文本化**：UGC 裁切页去掉冗余 icon，直接采用简洁数字比例文本（`1:1` / `2:3` / `4:3` 等），由 `PuzzleAspectRatio.values` 纯动态生成；
> 3. **现网基线零破坏（Zero-regression）**：现网已有且无需改动的常量、基准秒数、解锁与经济前 7 档数值**一律保持不变**，仅在末尾安全扩展第 8 项（L7 宗师）；
> 4. **预设排序自稳定**：`presets` 动态生成后按 `pieceCount` 升序稳定排序，确保首项为 24、末项为 600，既有索引与测试断言 100% 稳定；
> 5. **全链路测试破裂全预警**：全盘收录 `crop_puzzle_test.dart`、`widget_test.dart`、`image_crop_test.dart` 等所有受影响断言的迁移方案。

---

## 一、背景与设计考量

### 1.1 历史决策追溯与松绑理由
在 v3.3.1 重构中，为了追求所有画幅在 7 个固定难度档位上的绝对同构对齐（偏差 $\le 16\%$），项目移除了 3:4 / 4:3 的原生支持，将 4:3 照片强行居中裁剪 11.1% 适配至 3:2。  
**本次松绑的核心依据**：
- **构图保护**：4:3 是摄影与相册中最经典的原生画幅，强行裁切 11.1% 极易损失人像发际线或地平线主体；
- **计分已动态化**：游戏评星（`actualPieces × secPerPiece`）和经济结算早已全面基于实际片数动态计算，难度等级（Level）本质是体量区间桶，无需强求跨比例片数绝对一致；
- **4:3 起步档决策**：4:3 规格舍弃 $k=1$（12 块幼儿档），直接从 $k=2$（48 块简单档）自然起步；由于 L2 档位的解锁门槛为 0（免费开放），所有玩家均可直接零门槛开玩，无新手障碍。

---

## 二、切片网格与难度阶梯总表（全绝对纯正方形）

### 2.1 几何网格公式
为了保证单块碎片绝对为正方形（$pieceW == pieceH$）：
- **1:1 正方形**：$Cols = n,\; Rows = n \implies \mathbf{Total = n^2}$
- **3:2 横屏（竖 2:3）**：$Cols = 3k,\; Rows = 2k$（竖屏行列对调）$\implies \mathbf{Total = 6k^2}$
- **4:3 横屏（竖 3:4）**：$Cols = 4k,\; Rows = 3k$（竖屏行列对调）$\implies \mathbf{Total = 12k^2}$

### 2.2 全比例切片对照总表（以横向展示，竖向行列对调）

> **说明**：
> - 3:4 / 4:3 规格从 **48 块**起步（跳过 12 块）；
> - 三大比例在顶端均包含 **L7 宗师档**，底层全链路贯通，常规 UI 默认隐藏；
> - **基准秒数与预估文案严格保持现网原值不变**，仅追加 L7。

| 档位阶梯 | 难度标签 | 预估耗时区间<br>*(现网保持不变)* | 单片基准秒数<br>`secPerPiece`*(保持不变)* | **1:1 正方形**<br>$(n \times n)$ | **3:2 横屏 (竖2:3)**<br>$(3k \times 2k)$ | **4:3 横屏 (竖3:4)**<br>$(4k \times 3k)$ | 跨规格对齐与客观说明 |
| :---: | :---: | :---: | :---: | :---: | :---: | :---: | :--- |
| **L1** | **新手 Easy** | 1 ~ 3 分钟 | 3.0 s | **$5 \times 5 = \mathbf{25}$ 块** | **$6 \times 4 = \mathbf{24}$ 块** $(k=2)$ | — *(跳过)* | 24 vs 25，高度对齐 |
| **L1.5** | **入门+ Casual** | 2 ~ 4 分钟 | 3.5 s | **$6 \times 6 = \mathbf{36}$ 块** ⭐ | — *(跳过)* | — *(跳过)* | 1:1 专属过渡（推荐） |
| **L2** | **简单 Beginner** | 5 ~ 8 分钟 | 5.0 s | **$8 \times 8 = \mathbf{64}$ 块** | **$9 \times 6 = \mathbf{54}$ 块** $(k=3)$ | **$8 \times 6 = \mathbf{48}$ 块** $(k=2)$ ⭐ | **4:3 起步推荐档**；范围 48~64 块 |
| **L3** | **普通 Medium** | 12 ~ 18 分钟 | 8.0 s | **$10 \times 10 = \mathbf{100}$ 块** | **$12 \times 8 = \mathbf{96}$ 块** $(k=4)$ | **$12 \times 9 = \mathbf{108}$ 块** $(k=3)$ | **96 / 100 / 108**，经典聚集档 |
| **L4** | **进阶 Hard** | 25 ~ 35 分钟 | 12.0 s | **$12 \times 12 = \mathbf{144}$ 块** | **$15 \times 10 = \mathbf{150}$ 块** $(k=5)$ | **$16 \times 12 = \mathbf{192}$ 块** $(k=4)$ | 144 ~ 192 块 |
| **L5** | **困难 Expert** | 50 ~ 75 分钟 | 18.0 s | **$15 \times 15 = \mathbf{225}$ 块** | **$18 \times 12 = \mathbf{216}$ 块** $(k=6)$ | **$20 \times 15 = \mathbf{300}$ 块** $(k=5)$ | 216 ~ 300 块 |
| **L6** | **大师 Master** | 1.5 ~ 3 小时 | 25.0 s | **$20 \times 20 = \mathbf{400}$ 块** | **$24 \times 16 = \mathbf{384}$ 块** $(k=8)$ | **$24 \times 18 = \mathbf{432}$ 块** $(k=6)$ | **384 / 400 / 432**，聚集在 400 |
| **L7 👑**<br>*(理论支持)* | **宗师 Grandmaster**<br>*(UI默认隐藏)* | 3 ~ 5 小时 | **28.0 s** *(新增)* | **$24 \times 24 = \mathbf{576}$ 块**<br>$(n=24)$ | **$30 \times 20 = \mathbf{600}$ 块**<br>$(k=10)$ | **$28 \times 21 = \mathbf{588}$ 块**<br>$(k=7)$ | **576 / 600 / 588**，偏差仅 $\le 4\%$！ |

> ⭐ 注：各比例推荐乘数由自身的 `recommendedK` 属性决定，不硬编码具体枚举名称。

---

## 三、核心改造实现细节

### 3.1 比例定义与乘数阶梯（`lib/logic/puzzle_model.dart`）
`PuzzleAspectRatio` 扩展 3:4 与 4:3，并自带 `recommendedK` 属性实现即插即用：

```dart
enum PuzzleAspectRatio {
  square1x1('1:1 正方形', 1, 1, recommendedK: 6),      // 6x6 (36块)
  portrait2x3('2:3 竖屏', 2, 3, recommendedK: 2),     // 4x6 (24块)
  landscape3x2('3:2 横屏', 3, 2, recommendedK: 2),    // 6x4 (24块)
  portrait3x4('3:4 竖屏', 3, 4, recommendedK: 2),     // 6x8 (48块)
  landscape4x3('4:3 横屏', 4, 3, recommendedK: 2);    // 8x6 (48块)

  const PuzzleAspectRatio(
    this.label,
    this.aspectCols,
    this.aspectRows, {
    required this.recommendedK,
  });

  final String label;
  final int aspectCols;
  final int aspectRows;
  final int recommendedK;
  final List<int> multipliers;

  double get ratio => aspectCols / aspectRows;

  /// 纯函数动态生成难度阶梯（自包含 multipliers，零硬编码，单文件彻底解耦）
  List<DifficultyTier> get tiers {
    return multipliers.map((k) {
      final cols = aspectCols * k;
      final rows = aspectRows * k;
      final count = cols * rows;
      final diff = PuzzleDifficulty(
        rows: rows,
        cols: cols,
        label: '$cols × $rows ($count 块)',
        recommended: k == recommendedK,
      );
      return DifficultyTier(
        difficulty: diff,
        tag: diff.tierTag,
        estimatedMinutes: diff.estimatedMinutes,
        secPerPiece: diff.secPerPiece,
        tierLevel: diff.tierLevel,
      );
    }).toList();
  }
}
```

### 3.2 `PuzzleDifficulty` 原生方法重写与稳定排序缓存
直接在 `PuzzleDifficulty` 原生类上重写，完整保留 `adaptiveForSize` 与 `toString`，重写 `== / hashCode`，并在 `_buildPresets` 尾部做**升序稳定排序**：

```dart
// 在 lib/logic/puzzle_model.dart 的 PuzzleDifficulty 类中：

int get pieceCount => rows * cols;

/// 难度层级区间桶（覆盖所有 20 种标准尺寸，消除 Custom 分支）
String get tierLevel {
  if (pieceCount <= 30) return 'L1';
  if (pieceCount <= 40) return 'L1.5';
  if (pieceCount <= 75) return 'L2';
  if (pieceCount <= 125) return 'L3';
  if (pieceCount <= 200) return 'L4';
  if (pieceCount <= 320) return 'L5';
  if (pieceCount <= 450) return 'L6';
  return 'L7';
}

String get tierTag {
  switch (tierLevel) {
    case 'L1': return '新手 Easy';
    case 'L1.5': return '入门+ (过渡)';
    case 'L2': return '简单 Beginner';
    case 'L3': return '普通 Medium';
    case 'L4': return '进阶 Hard';
    case 'L5': return '困难 Expert';
    case 'L6': return '大师 Master';
    case 'L7': return '宗师 Grandmaster';
    default: return '普通 Medium';
  }
}

int get tierIndex {
  switch (tierLevel) {
    case 'L1': return 0;
    case 'L1.5': return 1;
    case 'L2': return 2;
    case 'L3': return 3;
    case 'L4': return 4;
    case 'L5': return 5;
    case 'L6': return 6;
    case 'L7': return 7;
    default: return 2;
  }
}

/// 预估耗时：前 7 档严格保持现网原值不变，仅追加 L7
String get estimatedMinutes {
  switch (tierLevel) {
    case 'L1': return '1~3分钟';
    case 'L1.5': return '2~4分钟';
    case 'L2': return '5~8分钟';
    case 'L3': return '12~18分钟';
    case 'L4': return '25~35分钟';
    case 'L5': return '50~75分钟';
    case 'L6': return '1.5~3小时';
    case 'L7': return '3~5小时';
    default: return '10~20分钟';
  }
}

/// 评星基准秒数：前 7 档严格保持现网原值不变，仅追加 L7
double get secPerPiece {
  switch (tierLevel) {
    case 'L1': return 3.0;
    case 'L1.5': return 3.5;
    case 'L2': return 5.0;
    case 'L3': return 8.0;
    case 'L4': return 12.0;
    case 'L5': return 18.0;
    case 'L6': return 25.0;
    case 'L7': return 28.0;
    default: return 8.0;
  }
}

// adaptiveForSize(width, height) 保持不变，照常保留

@override
bool operator ==(Object other) =>
    identical(this, other) ||
    other is PuzzleDifficulty &&
        runtimeType == other.runtimeType &&
        rows == other.rows &&
        cols == other.cols;

@override
int get hashCode => Object.hash(rows, cols);

/// 单一数据源：静态单例缓存 + 按片数升序全序稳定排序（确保首项 24、末项 600）
static final List<PuzzleDifficulty> presets = _buildPresets();

static List<PuzzleDifficulty> _buildPresets() {
  final list = <PuzzleDifficulty>[];
  for (final aspect in PuzzleAspectRatio.values) {
    for (final t in aspect.tiers) {
      if (!list.contains(t.difficulty)) {
        list.add(t.difficulty);
      }
    }
  }
  // 关键：按片数升序全序排序，若片数相同按 cols、rows 二级排序，确保跨平台/跨 VM 顺序绝对确定
  list.sort((a, b) {
    final cmp = a.pieceCount.compareTo(b.pieceCount);
    if (cmp != 0) return cmp;
    final c2 = a.cols.compareTo(b.cols);
    return c2 != 0 ? c2 : a.rows.compareTo(b.rows);
  });
  return List.unmodifiable(list);
}
```

### 3.3 裁剪管线单一数据源（`lib/logic/image_crop.dart`）
- `kStandardRatios` 与 `nearestStandardRatio` 彻底单源代理 `PuzzleAspectRatio`，杜绝平局分歧与维护分叉：
  ```dart
  /// 支持的标准几何画幅比例（单一数据源代理 PuzzleAspectRatio）
  List<double> get kStandardRatios =>
      PuzzleAspectRatio.values.map((a) => a.ratio).toList();

  /// 选取标准几何画幅中面积损失最小的目标比例（单一数据源代理 PuzzleAspectRatio.fromSize）
  double nearestStandardRatio({required int width, required int height}) {
    if (width <= 0 || height <= 0) return 1.0;
    return PuzzleAspectRatio.fromSize(width.toDouble(), height.toDouble()).ratio;
  }
  ```
- `cropLossFor` 直接代理 `PuzzleAspectRatio.cropLoss`；
- `thumbnail_generator.dart` **保持不变**（统一调用公共函数）。

### 3.4 自制图裁切页极简文本化（`lib/pages/crop_puzzle_page.dart`）
按用户指示：**去掉冗余 icon，改用纯粹简洁的数字文本（如 `1:1`, `2:3` 等）**，由 `PuzzleAspectRatio.values` 纯动态派生并单例缓存：

```dart
/// 动态自制图裁切选项（无 icon，纯简洁数字文本）
class CropRatioOption {
  final PuzzleAspectRatio aspectRatio;

  const CropRatioOption(this.aspectRatio);

  /// 简洁数字文本标签（如 '1:1', '2:3', '3:2', '3:4', '4:3'）
  String get label => '${aspectRatio.aspectCols}:${aspectRatio.aspectRows}';
  double get ratio => aspectRatio.ratio;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is CropRatioOption &&
          runtimeType == other.runtimeType &&
          aspectRatio == other.aspectRatio;

  @override
  int get hashCode => aspectRatio.hashCode;
}

/// 全局不可变常量单例（避免每帧 build 重复实例化，保证内存引用同一性）
final List<CropRatioOption> supportedCropOptions = List.unmodifiable(
  PuzzleAspectRatio.values.map(CropRatioOption.new).toList(),
);
```
- **UI 渲染变更**：`ChoiceChip` 移除 `avatar: Icon(...)`，仅保留 `label: Text(ratio.label)`，界面极度清爽；
- **自动检测联动**：`_selectedRatio = supportedCropOptions.firstWhere((c) => c.aspectRatio == detected, orElse: () => supportedCropOptions.first);` 保持自适应闭环。

### 3.5 难度选择器与 L7 隔离闭环（`lib/widgets/choose_difficulty_sheet.dart`）
- 头部显示 `_aspectRatio.label` 保持不变；
- 新增参数 `this.enableL7 = false`；
- **核心隔离**：将内部 `currentTiers` getter 直接由 `_playableTiers` 驱动，**卡片渲染循环（L801）、默认选中与解锁状态统一过滤 L7**：
  ```dart
  List<DifficultyTier> get _playableTiers => _aspectRatio.tiers.where((t) {
    if (t.difficulty.tierLevel != 'L7') return true;
    return widget.enableL7 || widget.initialDifficulty.tierLevel == 'L7';
  }).toList();

  List<DifficultyTier> get currentTiers => _playableTiers;
  ```
- 解锁查询循环改为：`for (var i = 0; i < UnlockService.kDifficultyStarImageRequirements.length; i++)`；
- **大跨度弹窗触发条件通用化（彻底清除硬编码 54）**：
  ```dart
  // 基于当前比例推荐起步档位判断是否存在越级跳档（跨越至少 2 个层级且 >= 2.5x，防小白误触防劝退）
  final baseTier = _currentTiers.firstWhere((t) => t.difficulty.recommended);
  final basePieces = baseTier.difficulty.pieceCount;
  final isBigJump = diff.pieceCount >= basePieces * 2.5 &&
      (diff.tierIndex - baseTier.difficulty.tierIndex >= 2);
  if (isBigJump) {
    // 弹窗正文动态模板插值
    ... '当前 ${diff.pieceCount} 块相比推荐档 ${basePieces} 块跨度较大，是否确认？' ...
  }
  ```

### 3.6 解锁服务与经济系统（现网数值完全不动，仅追加第 8 项）
- **注意**：现网 `UnlockService` 与 `EconomyService` 的 clamp 本来就已经是 `clamp(0, length - 1)`，**保持不变无需修改**。仅需在数组末尾追加第 8 项（L7 宗师）：

1. **`lib/services/unlock_service.dart`**：
   ```dart
   static const List<int> kDifficultyStarImageRequirements = [
     0, 0, 0, 0, 2, 5, 10, 15, // 0~3 档保持免费，L7 追加为 15
   ];
   ```
2. **`lib/services/economy_service.dart`**：
   ```dart
   static const kDifficultyBaseCoins = [5, 6, 8, 12, 15, 20, 25, 32];
   static const kHintPrices = [5, 6, 10, 15, 20, 25, 35, 45];
   static const kStarBonusTable = [
     [0, 2, 5],   // L1
     [0, 3, 6],   // L1.5
     [0, 4, 7],   // L2
     [0, 5, 10],  // L3
     [0, 7, 15],  // L4
     [0, 10, 20], // L5
     [0, 15, 30], // L6
     [0, 20, 40], // L7 新增: Base 32 + 3星 40 = 72 币
   ];
   ```

### 3.7 历史存档与统一卡片解析增强
1. **`lib/data/resume_helper.dart`**：
   `diffForKey` 增加 `rows x cols` 字符串格式解析兜底，保证任何被注释比例的历史存档 100% 可玩；
2. **`lib/logic/unified_puzzle_resolver.dart:164`**：
   孤儿卡比例恢复消除三目分支，改用 `PuzzleAspectRatio.values.firstWhere((a) => a.name == label, orElse: () => values.first)` 优雅兜底。

---

## 四、保持不变（无需改动）清单

- **`lib/logic/star_calculator.dart`**：`hintAllowance` **维持现网 `clamp(2, 6)` 不变**（避免评星单测破裂）；
- **`lib/services/achievement_service.dart`**：成就系统共 24 项**维持不变**，`tierIndex >= 6` 自然覆盖 L7 达成大师成就，不新增第 25 项独立成就；
- **`lib/pages/daily_tab_view.dart:171`**：建议将 `presets[2]` 优化为具名查找 `presets.firstWhere((p) => p.recommended, orElse: () => presets.first)`；
- **`lib/data/game_repository.dart`**：主线 100 关分布**保持不变**；
- **`lib/logic/catalog_index.dart`**：内置每日挑战和扩展包索引**保持不变**；
- **`lib/logic/cache/thumbnail_generator.dart`**：调用公共方法逻辑**保持不变**；
- **国际化 / 本地化**：现阶段**保持不变**，暂不引入 i18n/arb 扩展。

---

## 五、受影响单元测试更新清单

实施本方案后，以下受比例扩充（4:3）影响的测试断言需同步更新：
1. **`test/crop_puzzle_test.dart:30`**：
   - 裁切选项断言更新为 5：`expect(supportedCropOptions.length, 5)`（或相应代理）。
2. **`test/widget_test.dart:120`**：
   - 原断言：`expect(PuzzleDifficulty.presets.last.pieceCount, 400)`；
   - 排序后末项更新为：`expect(PuzzleDifficulty.presets.last.pieceCount, 600)`；
   - 注：首项 `presets.first.pieceCount == 24` 经排序后**继续成立，无需修改**。
3. **`test/widget_test.dart:158-174`**（全部 4 处精确尺寸命中更新）：
   - `(900, 1200)` 与 `(1080, 1440)` 从 2:3 更新为精确命中 `portrait3x4`；
   - `(1200, 900)` 与 `(1440, 1080)` 从 3:2 更新为精确命中 `landscape4x3`。
4. **`test/logic/star_calculator_test.dart:185, 189`**：
   - 原断言：`fromSize(4032, 3024)` 期望命中 `landscape3x2`；
   - 更新为：精确命中原生的 `landscape4x3`。
5. **`test/logic/image_crop_test.dart:112-124`**：
   - `nearestStandardRatio(4032, 3024)` 从 1.5 更新为 4/3 (1.333)；
   - `nearestStandardRatio(3024, 4032)` 从 2/3 更新为 3/4 (0.75)。
6. **`test/logic/image_crop_test.dart:140`**：
   - 4:5 原选 2:3，因距离 3:4 损失更小，更新为选择 3:4。
7. **`test/services/economy_service_test.dart` & `unlock_service_test.dart`**：
   - 循环测试从 `< 7` 更新为 `< 8` 覆盖新增的 L7，前 7 项断言完全不变。

---

## 六、自检核查确认

- [x] **即插即用彻底成立**：全库无具体比例字面量硬编码，注释掉任何比例全局 0 处编译报错。
- [x] **裁切页极简文本化**：去除了对 `icon` 字段的依赖，仅展示简洁数字文本标签。
- [x] **现网零破坏 100% 成立**：`secPerPiece`、耗时文案、解锁门槛、金币基准前 7 档完全保持现网原值不变。
- [x] **预设升序稳定**：首项严格为 24，末项严格为 600，索引与测试断言高度稳定。
- [x] **L7 隔离与防吞闭环**：`currentTiers` 由 `_playableTiers` 驱动，常规界面零展示，已有 L7 存档自动放行。
- [x] **测试破裂全覆盖**：补全 `crop_puzzle_test` 与 `widget_test` 全部 4 处尺寸断言，实施零卡壳。
