# 拼图核心触摸手势修复实施总结（2026-09-25）

> 实施依据：[`docs/puzzle-core-touch-review-synthesis-and-fix-plan-20260925.md`](file:///c:/Home/Projects/jigsawpuzzle/docs/puzzle-core-touch-review-synthesis-and-fix-plan-20260925.md)（`§〇 v2 修订` V1~V10 + `§〇.1 v3 修订`）
> 变更摘要：[`docs/CHANGES-20260925.md`](file:///c:/Home/Projects/jigsawpuzzle/docs/CHANGES-20260925.md)
> 实施时间：2026-09-25 17:32 首轮交付 / 17:46 v3 追加（均为 GMT+8）
> 实施范围：7 个源码/配置/测试文件（+492 / -58 行，不含文档与自动生成的插件注册文件）

---

## 1. 改动清单

| 文件 | 改动概要 |
| :--- | :--- |
| [`lib/game/jigsaw_puzzle_game.dart`](file:///c:/Home/Projects/jigsawpuzzle/lib/game/jigsaw_puzzle_game.dart) | 移除 `ScrollDetector`/`onScroll`；holding 集群整簇跳过 + 新增 `_refreshHoldingClusterLayout()`；`missingPieceCheck` 重构为整簇原子平移；新增不变量自检 `clusterGridInvariantViolation()`/`_debugAssertClusterGridInvariant()`；`effectiveSnapDistance` 注释修正；**v3：`isTabletop` 改为只取设置值，删除模式翻转机制** |
| [`lib/game/puzzle_piece_component.dart`](file:///c:/Home/Projects/jigsawpuzzle/lib/game/puzzle_piece_component.dart) | 新增 `clearMoveEffects()`（只清 `MoveEffect`，保留 `ScaleEffect`） |
| [`lib/pages/game_page.dart`](file:///c:/Home/Projects/jigsawpuzzle/lib/pages/game_page.dart) | `_onPointerSignal` 统一滚轮分发：托盘命中上下界严格匹配托盘矩形、轴优先序取绝对分量较大者、阻尼 `0.8 → 1.6` |
| [`lib/main.dart`](file:///c:/Home/Projects/jigsawpuzzle/lib/main.dart) | **v3：桌面端设置最小窗口尺寸**（`window_manager` + `kDesktopMinWindowSize = Size(800, 600)`） |
| [`pubspec.yaml`](file:///c:/Home/Projects/jigsawpuzzle/pubspec.yaml) / `pubspec.lock` | **v3：新增依赖 `window_manager: ^0.5.2`** |
| `windows/flutter/generated_plugin_registrant.cc` / `.cmake` | 构建时 Flutter 自动生成（插件注册），非手写 |
| [`test/game_layout_test.dart`](file:///c:/Home/Projects/jigsawpuzzle/test/game_layout_test.dart) | 新增 3 条回归测试（BUG-1 / BUG-3 / V10） |

## 2. v2 修订清单落地情况

| 编号 | 要求 | 落地结果 |
| :--- | :--- | :--- |
| V1 | 阻尼取 1.6 | ✅ 与修复前"页面侧 + 游戏侧各 0.8"的托盘主体速度等价 |
| V2 | 轴优先序统一 | ✅ `scrollDelta.dx.abs() > scrollDelta.dy.abs() ? -dx : -dy` |
| V3 | 刷新时机不得放进 `_updateBoardTransform` | ✅ 调用点仅两处：`zoomAt` 末尾、`_syncResizeTransform` 步骤 5/6 之后 |
| V4 | 兜底光标由主片 + 锚点反推 | ✅ 未新增缓存字段 |
| V5 | 步骤 6 过滤排除 holding 集群 | ✅ 已加 |
| V6 | 每簇一次 / 跳过含已就位成员的簇 / 只清 `MoveEffect` / 明确退化策略 | ✅ 四条全部落地 |
| V7 | `_lastIsTabletop` 在 `onLoad` 初始化 | ⛔️ **已被 v3 取代并删除**（不再存在模式翻转） |
| V8 | 静默拉回同时清两处 `inTray` | ⛔️ **已被 v3 取代并删除**（混合态不可达，步骤 6 恢复原判据） |
| V9 | 断言只对 `_boardState`、可开关 | ✅ `assertClusterGridInvariant` 开关 + 只读校验器，接入 4 个出口 |
| V10 | 反向翻转观感 | ✅ **以 v3 从根上解决**：取消运行时模式翻转 |

## 3. 关键实现决策（含与计划的差异）

1. **BUG-2 阻尼取 1.6 而非计划里的 1.2~1.4**：1.6 才是"与现状等价"（修复前托盘主体是双路径叠加）；1.2~1.4 会让托盘比现状慢约 25%，属独立手感决策，未擅自引入。
2. **BUG-3 刷新不做成通用钩子**：`_updateBoardTransform` 在 `_syncResizeTransform` 步骤 4 被调用，那时碎片 `shape`/基础尺寸还是旧的，故刷新只放在 `zoomAt` 末尾与 resize 收尾。`panBy`/`setZoomAndPan`/`resetZoom` 未接入——持有碎片时空白平移被 `isDraggingAnyPiece` 拦截、捏合会先取消持有，属不可达路径。
3. **BUG-3 兜底光标不使用缓存**：`updateHoldingPiecePosition` 内含"托盘中向上拖出"分支，缓存光标叠加 resize 后的新 `trayPosition` 可能误判脱离托盘并触发 `_realignTrayPieces`；由主片 + 锚点反推则天然随碎片同步。
4. **BUG-1 位移按"越界最严重成员"取**：整簇施加同一位移，同时满足"不变量保持"与"越界成员完整可见"；簇内含已就位成员时整簇跳过（残态防御，避免把已植入碎片搬离槽位）。
5. **BUG-1 只清 `MoveEffect`**：`clearActiveEffects()` 会连 `ScaleEffect` 一起清掉，故新增 `clearMoveEffects()`，与 `animateTo` 内部实现同源。
6. **不变量断言接在 4 个出口**：吸附结算、拖拽结束、窗口尺寸同步、防丢自检；只校验权威状态 `_boardState`。全量测试无误报，说明现有路径下不变量成立。
7. **v3：模式改为纯设置项 + 桌面端最小窗口尺寸**（原方案 §〇.1）：
   - `isTabletop => scatterMode == 'tabletop'`，删除翻转边沿检测与救援/拉回代码，步骤 6 恢复原判据；
   - `lib/main.dart` 用 `window_manager` 在桌面端设 `Size(800, 600)` 下限（移动端全屏不适用；web 目标本就无法编译——全仓 35 处 `dart:io`，故直接 import 无额外风险）；
   - 收益：BUG-4/V10 从根上消失；快照 `scatterMode` 恒等于设置值，`needsRealign` 只在玩家真的改设置时触发。
8. **回归测试的一处修正**：BUG-1 测试原拟断言"视觉偏移 = 一格宽"，实测 `hint()` 后剩余两块可能是**竖排相邻**，故改为按真实网格差量 `(dcol, drow)` 断言（横/竖/斜向通用）。

## 4. 验证记录

| 验证项 | 命令 | 结果 |
| :--- | :--- | :--- |
| 格式化 | `dart format`（仅改动文件） | 无格式残留 |
| 静态分析 | `flutter analyze` | `No issues found!` |
| 全量单元/Widget 测试 | `flutter test` | **391 passed / 8 skipped / 0 failed** |
| 编译验证 | `flutter build windows --debug` | 成功（`build\windows\x64\runner\Debug\JigsawFox.exe`，插件注册已自动生成） |
| 运行验证 | `flutter test .\integration_test\app_test.dart -d windows` | **All tests passed!**（首次交付与 v3 追加后各跑一次） |

回归测试（新增 3 条）：
1. `残局防丢自检按整簇原子平移：多片集群推至屏幕外绝不撕裂（BUG-1 回归）`——旧实现（逐片 clamp）会在相对偏移断言处失败。
2. `单击抓取集群期间滚轮缩放：整簇 scale 与相对偏移同步，不撕裂（BUG-3 回归）`——旧实现会在 scale 与偏移两处失败。
3. `模式仅由设置决定：tabletop 模式下窗口缩小到极小也不发生模式翻转（V10 回归）`——旧实现会在 400x400 处把 `isTabletop` 翻成 false 而失败。

## 5. 未处理项与待确认

1. **RISK-1 旋转功能**：维持现状（`rotationEnabled` 恒 false、无启用入口）。未来启用必须补齐渲染层旋转，否则"视觉不转、命中区已转"。
2. **BUG-2 阻尼 1.6 的手感复核**：数值按"与修复前等价"推导，仍建议真实设备确认（尤其触摸板横向/斜向滑动）。
3. **最小窗口尺寸取值**：`kDesktopMinWindowSize = Size(800, 600)` 为依据"棋盘 + 四周散落空间 + 顶部操作栏 + 底部托盘"给出的经验下限，属可调常量（单点修改，位于 `lib/main.dart` 顶部）。若后续要做"托盘模式允许更窄窗口"，可把该值改为按模式动态设置。
4. **Android 分屏/极小视口**：取消阈值后，桌面散落模式在极小视口下会得到较小的碎片（可缩放规避），不再自动降级为托盘模式——这是"模式只由设置决定"的必然结果，如需例外需单独评审。

## 6. 建议的人工验证清单

- 托盘区域滚轮/触摸板滚动：速度与修复前一致，且**不会再同时缩放棋盘**；托盘上方棋盘区域滚轮只缩放、不滚托盘；托盘最底部边距区不再误滚托盘。
- click-to-pick（单击抓取）：抓取已拼合集群后滚轮缩放且**不移动鼠标**，集群不撕裂、尺寸同步；拖拽中改窗口尺寸同理。
- 残局：最后两块已合并为一个集群，推到屏幕边缘松手触发吸附/合并后不撕裂、进度不回退；把最后一块甩到屏幕外应被整簇拉回。
- 桌面端窗口：尝试把窗口拖到小于 800x600（应被限制住，不再出现"碎片被挤到小棋盘上、托盘空着"或"碎片搁浅"）。
- 桌面散落模式（设置 → 棋盘模式 = 桌面散落）：反复缩放窗口不应发生模式切换、不应出现全盘洗牌；读档恢复/扫把整理/Undo/Redo/双指捏合缩放均正常。

## 7. 回滚方式

改动可按 Step 粒度回滚：
```
git checkout -- lib/game/jigsaw_puzzle_game.dart lib/game/puzzle_piece_component.dart lib/pages/game_page.dart lib/main.dart test/game_layout_test.dart pubspec.yaml pubspec.lock windows/flutter/generated_plugin_registrant.cc windows/flutter/generated_plugins.cmake
```
文档原稿备份在 `temp/backups/`（`*bak-before-v2-revision`、`*bak-before-v3`）。断言开关 `assertClusterGridInvariant = false` 可在排障时临时关闭不变量自检而不改逻辑。
