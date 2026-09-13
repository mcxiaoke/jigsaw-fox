# 拼图高倍放大边线/阴影渲染优化 · 综合评审与最终实施方案

> **文档状态**：终稿 / 已实施
> **日期**：2026-09-13
> **综合依据**：原始方案 + 三份评审（bd / gm / ds）+ ds 终稿评审（final-review-ds）
> **改动范围**：`lib/game/puzzle_piece_component.dart`（唯一改动文件）
> **代码版本说明**：`jigsaw_puzzle_game.dart` 当前为 2641 行（评审时 2535 行），本文所有行号均为当前快照的新行号。
> **实施状态**：已按本文方案落地，`flutter analyze` 无新增问题、`flutter test` 367 项全通过。

---

## 1. 三份评审交叉核对结论（对照当前代码逐条验证）

### 1.1 三方一致、经代码核实成立（必须采纳）

| 编号 | 问题 | 代码证据（当前行号） | 裁决 |
| :--- | :--- | :--- | :--- |
| A1 | `curScale` 必须取组件自身 `scale.x`，**禁止用 `game.zoom`**（ds P0-1） | 棋盘态 `scale.setAll(_zoom)`（:513,:1688,:1833 等）、托盘态 `_trayPieceScale`（:511,:1418,:1913）、拖拽过渡插值（:1279 `currentScale = _trayPieceScale + (boardScale - _trayPieceScale) * t`） | 采纳。托盘/过渡态 ≠ `_zoom` |
| A2 | `(0.8/curScale).clamp(0.3, 0.8)` 量纲混用，放大越大阴影越悬空（bd P1-1 / gm 2.2 / ds P0-2） | `canvas.translate(0, 0.8)`（component:214）；局部值 × scale = 屏幕值，clamp 加在局部域必然破坏屏幕恒定 | 采纳。删除 clamp |
| A3 | `_cardboardBottomEdgePaint.strokeWidth = 0.8` 与 `_dragShadowPaint` 的 `MaskFilter.blur(7)` 漏在逆缩放之外（bd P0-2 / gm 2.3 / ds P1-1） | component:126、:138-142、:225 | 采纳。底边线纳入公式；blur 用预置 Paint 档位池 |
| A4 | ~~`num.clamp()` 返回 `num` 传给 `translate(double)` 会编译失败~~ **【经实测为误报，不采纳】** | bd P0-1 | **驳回**。`0.8` 是 `double` 字面量，故 `0.8 / curScale` 的静态类型是 `double`；Dart 在 `double` 类型上覆写了 `clamp`，返回类型为 `double` 而非基类 `num.clamp` 的 `num`。已用 `flutter analyze` 实测复现验证：无 error。**结论（无需 `.toDouble()`）正确，但原因是错的**，切勿据此建立"Dart clamp 返回 num"的错误认知 |
| A5 | 托盘态 `curScale < 1` 时 `1/curScale` 会让局部线宽暴增（gm 2.1） | `_trayPieceScale = 64 / pieceMaxSide`（:137-138,:886），2×2 时 ≈ 0.21 | 采纳。逆缩放仅在 `curScale > 1` 时生效 |
| A6 | 行动项遗漏 `triggerSnapGlow` 改造；且延迟回调存在"多次吸附互相截短"竞态（bd P1-3 / ds P2-1） | component:453-460，`Future.delayed(380ms)` 每次吸附各排一个回调，回调内还有筛选复辟赋值 | 采纳。代数令牌 + 仅复位 `isHighlight` |
| A7 | 取消常驻绿框不会破坏边缘筛选功能（三方核实一致） | `updatePieceVisibility`（:2127-2155）通过 `isFilteredOut` 直接隐藏非边缘碎片，筛选不依赖绿框 | 前提成立，可安全移除复辟逻辑 |

### 1.2 原始方案中被代码证伪的描述（文档需更正，不影响方向）

1. **"放大 3.0x~5.0x" 不可达**：`_maxZoom = max(minZoom=2, 72/pieceMaxSide)`（:146,:154,:879），所有缩放入口 clamp 到 `1.0.._maxZoom`（:1619,:1639）。20×20 时 `_maxZoom ≈ 2.0~2.9`（典型 ≈2.4）。第 5 节"4 倍"列全部需按 maxZoom 重算：绿框 6.0px、暗线 2.9px、高光 1.9px、阴影位移 1.9px（ds 第五节数据正确）。
2. **"为所有边缘碎片涂常驻绿框"不准确**（ds P2-2）：`isHighlight` 仅在 `triggerSnapGlow` 中赋值（component:454,458），常驻绿框只出现在"边缘筛选开启期间被吸附过的碎片"上。改法是删掉 ：458 的复辟赋值，不存在"逐碎片扫描取消绿框"这类改动。
3. **§1.2 变换公式有误导**：pan 不在碎片组件上，托盘/过渡态因子不是 `_zoom`。机制结论（strokeWidth 处于未缩放局部空间）正确。

### 1.3 三方分歧裁决

| 分歧点 | 各方主张 | 裁决与理由 |
| :--- | :--- | :--- |
| 线宽目标 | 原方案/gm/ds：屏幕绝对值 1.0~1.2px；bd P1-4：相对基线缩放，回归面小 | **采用"基线屏幕恒定"路线**：`局部宽 = 基线 / max(curScale, 1.0)`。① 1x 未放大状态与现状逐像素一致（bd P1-4 的 UX 副作用自动消除）；② 托盘/低难度完全不变（gm 2.1、ds P1-2 的影响面问题自动消除）；③ 暗线 1.2 / 高光 0.8 的宽度层次保留（gm 2.4 "拼缝立体感丧失"自动消解）；④ 20×20 放大到 maxZoom 时暗线屏幕 1.2px，已落在原方案 1.0~1.2px 的目标区间内——原方案真正想消灭的是 2.9px 粗沟，不是 1.2 与 1.0 的差 |
| 吸附绿框宽度 | 原方案/gm：1.2px；ds：≥2.0px（成功信号不能压太细） | **屏幕 2.5px（即基线恒定）**。吸附反馈是唯一成功正反馈（ds P1-3），不做变细处理；"遮挡图案"的诉求由 3.2.3 的流光时长机制承担 |
| 拖拽阴影 blur | bd：Paint 池；gm：保持常量 7；ds：`max(4, 7/s)` | **3 档预置 Paint 池**（零分配，bd 方案），档位按 `s` 阈值切换。ds 的 `max(4.0, ...)` 下限会让屏幕半径随缩放增长，不取 |
| 高光透明度 | 原方案/gm：下调到 0x30/0x35 | **不改**。基线路线下 1x 观感不变，放大后屏幕 0.8px 本就细腻，无白漆描边风险，少一个回归变量。**补充：gm 2.4 的前提（"暗线与高光路径几何完全重合、等宽会 100% 互相覆盖"）经代码核实为误报**——`highlightPath` 只含 Top+Left 边、`shadowPath` 只含 Right+Bottom 边（`piece_shape.dart:185-226`），二者是互补的两条路径，不存在同路径覆盖关系。故拒绝该建议同时具备"方向正确"与"前提不成立"双重理由 |

---

## 2. 最终实施方案（唯一改动文件：`puzzle_piece_component.dart`）

### 2.1 核心公式

$$\text{localWidth} = \frac{\text{baseline}}{\max(\text{curScale},\ 1.0)}, \quad \text{curScale} = \text{scale.x}$$

- `curScale > 1`（棋盘放大）：屏幕宽度恒等于基线；
- `curScale ≤ 1`（托盘 / 1x / 过渡带下探）：局部值等于基线，**与现状完全一致**；
- 全程只有一次三目和一次除法，无对象分配，零 GC 成立。

### 2.2 render() 改动（视锥剔除之后、第一层绘制之前统一赋值）

```dart
// --- 屏幕恒定（视口逻辑像素）逆缩放，仅放大方向生效 ---
// 约束：curScale 必须取组件自身 scale.x（棋盘=_zoom、托盘=_trayPieceScale、
// 拖拽过渡=逐帧插值），禁止使用 game.zoom。当前架构强制等比缩放（setAll），
// 这些 static Paint 仅供本组件 render 单线程使用，勿跨组件复用。
final s = scale.x > 1.0 ? scale.x : 1.0;
_shadowOutlinePaint.strokeWidth = 1.2 / s;       // 屏幕 1.2px（原基线）
_highlightOutlinePaint.strokeWidth = 0.8 / s;    // 屏幕 0.8px（原基线）
_snapHighlightPaint.strokeWidth = 2.5 / s;       // 屏幕 2.5px（原基线）
_cardboardBottomEdgePaint.strokeWidth = 0.8 / s; // 屏幕 0.8px（本次补齐）

// 第一层阴影
if (isElevated) {
  canvas.translate(2 / s, 6 / s);
  canvas.drawPath(shape.path, _dragShadowBlurPaintFor(s));
} else {
  canvas.translate(0, 0.8 / s);                  // 屏幕 0.8px，原 clamp 量纲错误已删除
  canvas.drawPath(shape.path, _contactShadowPaint);
}

// 第二层纸板厚度
canvas
  ..translate(0.8 / s, 1.6 / s)
  ..drawPath(shape.path, _cardboardSidePaint)
  ..drawPath(shape.shadowPath, _cardboardBottomEdgePaint);
```

线宽赋值**无条件置于 render 开头**（而非分散在 `isHighlight` 分支内），静态画笔跨碎片复用时不会遗留上一碎片的值。

### 2.3 拖拽阴影模糊档位池（零分配替代 MaskFilter 动态重建）

```dart
/// 拖拽悬浮阴影模糊档位池：MaskFilter 不可变，无法原地改半径；
/// 预置 3 档，按缩放档位切换，全程零分配。
static final List<Paint> _dragShadowBlurTiers = <double>[7.0, 3.5, 2.5]
    .map(
      (r) => Paint()
        ..color = const Color(0x40000000)
        ..maskFilter = MaskFilter.blur(BlurStyle.normal, r)
        ..isAntiAlias = true,
    )
    .toList(growable: false);

static Paint _dragShadowBlurPaintFor(double s) {
  if (s <= 1.0) return _dragShadowBlurTiers[0];
  if (s <= 2.0) return _dragShadowBlurTiers[1];
  return _dragShadowBlurTiers[2];
}
```

**屏幕半径实际表现（实测，非"恒定"）**：局部半径 × `s` = 屏幕半径，档位在端点处存在阶跃：

| `s` | 命中档位局部 r | 屏幕半径 | 相对 7px 偏差 |
| :--- | :--- | :--- | :--- |
| 1.0 | 7.0 | 7.00px | 0% |
| 1.001（刚跨阈值） | 3.5 | **3.50px** | **−50%** |
| 2.0 | 3.5 | 7.00px | 0% |
| 2.001（刚跨阈值） | 2.5 | **5.00px** | **−29%** |
| 2.4（20×20 maxZoom） | 2.5 | 6.00px | −14% |
| 3.6（30×30 maxZoom） | 2.5 | 9.00px | +29% |

即屏幕半径落在 **3.5 ~ 7.0px 区间**，单点最大偏差 3.5px，**并非文档早期所称的"近似恒定 ~7px"**。该阶跃可接受，理由是拖拽时全局同时仅 1 个碎片/集群在渲染此阴影，且玩家注意力集中在碎片本体，阶跃不被感知；本方案的目的是**压住放大后的光晕膨胀**（不改则 `s=2.4` 时屏幕半径 16.8px），该目标已达成。

原 `_dragShadowPaint` 删除（唯一使用点在第一层阴影），其常量并入档位池。

### 2.4 triggerSnapGlow 改造（代数令牌 + 移除筛选复辟）

```dart
int _snapGlowToken = 0;

/// 碎片成功吸附就位时触发短暂的流光反馈特效
void triggerSnapGlow() {
  isHighlight = true;
  final token = ++_snapGlowToken;
  Future.delayed(const Duration(milliseconds: 380), () {
    if (isRemoved || token != _snapGlowToken) return;
    isHighlight = false;
  });
}
```

- 删除原 ：458 的 `isHighlight = game.isBorderFilterActive && ...` 复辟赋值：边缘筛选的区分由 `updatePieceVisibility`（`isFilteredOut` 隐藏）承担，已核实不产生功能空洞；
- 代数令牌消除"连续两次吸附时前一个回调截短后一次流光"的竞态；
- 原 `layout` 身份校验（:455,:457）随复辟逻辑一并删除（其唯一目的就是守卫复辟赋值）。

### 2.5 明确不做的事（KISS）

- 不改任何 Paint 颜色/透明度（含 `_snapHighlightPaint` 保持 `0xFF4CAF50`）；
- 不引入离屏 Pass、Shader、DevicePixelRatio 换算（本方案口径为**视口逻辑像素恒定**，Flutter/dp 口径，勿在渲染循环乘 DPR）；
- 不改视锥剔除 `margin = 4.0`（改动后描边屏幕外扩更小，裕量更宽裕）；
- 不动 `jigsaw_puzzle_game.dart`（缩放写入、边缘筛选均无需变更）。

### 2.6 实现补充说明（对照评审意见）

1. **`scale` 口径差异已写进注释**：视锥剔除（渲染开头）刻意使用**原始 `scale.x` / `scale.y`**，逆缩放使用**截顶后的 `s = max(scale.x, 1.0)`**。二者含义不同、不可合并——剔除本就该按真实缩放计算可见性，只有线宽/位移需要截顶。已在代码中断言该约束。
2. **公式以 `screenInvariantValue()` 单点收敛**：渲染中所有线宽与位移均改为调用 `static double screenInvariantValue(double screenValue, double scale)`，避免 6 处重复除法各自漂移，同时使单元测试可直接断言该契约（见第 3 节行动项 4）。
3. **`_snapGlowToken` 无需状态重置**：令牌单调递增，`clearActiveEffects()` 或重开游戏不重置该字段也是安全的——旧回调的 `token != _snapGlowToken` 判定天然失效。仅在组件实例复用且需强制清除挂起流光的场景才需考虑（当前不存在）。
4. **30×30 档位覆盖**：`_maxZoom` 可达 **3.6**（30×30 且棋盘约 600px 时，碎片边长 20px → `72/20 = 3.6`），此时拖拽阴影落入第 3 档。终稿 §1.2 所述「2.0~2.9」应理解为 20×20 的典型区间，30×30 会超出，已纳入验收档位。

---

## 3. 实施行动项

1. [x] `render()` 引入 `s = max(scale.x, 1.0)`，4 个描边画笔线宽 + 3 组位移按 §2.2 统一逆缩放，赋值集中在渲染开头；
2. [x] 新增 `_dragShadowBlurTiers` 档位池，删除原 `_dragShadowPaint`；
3. [x] `triggerSnapGlow()` 改代数令牌版（§2.4），删除筛选复辟（连带移除失效的 `layout` 身份校验）；
4. [x] 新增 `test/screen_invariant_stroke_test.dart`：断言 `PuzzlePieceComponent.screenInvariantValue` 的两条契约——`s ≤ 1 → 结果 == baseline`；`s > 1 → 结果 × s == baseline`（容差 1e-9），含极端缩小防暴增与非法 scale 防除零用例，共 5 项；
5. [x] `dart format`（仅改动文件）→ `flutter analyze`（改动文件 0 问题；`lib/main.dart:94` 的 2 条 info 为既存问题，与本次无关）→ `flutter test`（367 项全通过）→ `flutter build windows --debug`（成功）；
6. [ ] 实机验收（Windows + Android 双端，2×2 / 10×10 / 20×20 / **30×30** 四档）：
   - 20×20 放大到 maxZoom：暗线/高光为细线不糊图案、贴地阴影不悬空、吸附绿框清晰可见；
   - 托盘与 60px 过渡带：线宽与改前一致、无粗细跳变（重点回归，A1/A5 的风险区）；
   - 1x 默认状态：与改前逐像素一致（本路线的核心承诺）；
   - 边缘筛选：开关筛选、筛选期间吸附碎片，确认无常驻绿框且筛选功能正常；
   - 连续快速吸附两块碎片：两次流光均完整 ~380ms（代数令牌验收点）；
   - 高分屏（Windows 150% 缩放）确认 dp 口径下观感正常；
   - 移动中 1.2px 细线有无亚像素闪烁（bd P1-5），如有则将暗线基线上调至 1.4 再验；
   - 30×30 放大到 maxZoom（`s = 3.6`）：确认拖拽阴影第 3 档观感、细线清晰度；
7. [ ] 改动概要记入 `docs/CHANGES-20260913.md` 顶部（**主项目 CHANGES，非 `studio/docs/`**——本次改动文件位于 `lib/game/`）。

## 4. 残留风险（已知且接受）

- 模糊档位切换是阶跃而非连续，档位端点屏幕半径最大偏差 **3.5px（−50%）**，实际落在 3.5~7.0px 区间。拖拽动态中不可感知（全局同时仅 1 个碎片/集群在渲染此阴影，且玩家注意力集中在碎片本体）；
- 20×20 放大后 1.2px 暗线在低对比图案上可能偏淡——这是"恒定"的固有属性，实机不可接受时优先微调透明度而非线宽；
- 若未来引入非等比缩放，`scale.x` 单轴取值需同步改为 x/y 分别计算（代码注释已固化该约束）。
