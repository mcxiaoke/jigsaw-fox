# 异形拼图 Jigsaw Puzzle 🧩

> 一款基于 Flutter + Flame 游戏引擎打造的高品质全平台异形（Jigsaw）拼图游戏 —— 真实贝塞尔咬合、集群拖拽、磁吸吸附，支持 Android / iOS / Windows / Web。

[![Flutter](https://img.shields.io/badge/Flutter-3.x-02569B?logo=flutter)](https://flutter.dev)
[![Dart](https://img.shields.io/badge/Dart-3.x-0175C2?logo=dart)](https://dart.dev)
[![Flame](https://img.shields.io/badge/Flame-1.38-orange)](https://flame-engine.org)
[![License](https://img.shields.io/badge/License-BSD--3--Clause-green)](LICENSE)
[![Analyze](https://img.shields.io/badge/dart%20analyze-pass-brightgreen)](#-开发与测试)

---

## 📖 目录

- [项目简介](#-项目简介)
- [核心特性](#-核心特性)
- [技术栈](#️-技术栈)
- [目录结构](#-目录结构)
- [快速开始](#-快速开始)
- [玩法说明](#-玩法说明)
- [架构设计](#-架构设计)
- [数据与存档](#-数据与存档)
- [开发与测试](#-开发与测试)
- [构建与发布](#-构建与发布)
- [文档索引](#-文档索引)
- [常见问题](#-常见问题)
- [贡献与许可证](#-贡献与许可证)

---

## 🌟 项目简介

`jigsawpuzzle` 是一个**单机优先、离线可玩**的异形拼图游戏，追求「真实拼图手感」与「全平台一致体验」：

- **真实异形切割**：基于确定性随机矩阵 + 二次贝塞尔曲线生成经典凹凸咬合，支持任意 `M × N` 网格，严格保证正方形基础切片与无缝互补。
- **单画布高性能渲染**：采用 Flame `FlameGame` 单画布批量渲染，规避多 Widget 堆叠的性能与手势穿透瓶颈，60fps 流畅拖拽、缩放、平移。
- **全端自适应**：一套代码覆盖手机、平板、折叠屏与桌面端，窗口任意缩放不溢出，比例恒定 1:1。
- **轻量本地沙盒**：无强制联网/登录，所有进度、自制拼图、设置均持久化于本地（`SharedPreferences` + 应用沙盒文件）。

> 适合作为 **Flutter 游戏开发 / Flame 引擎 / 几何算法 / 跨端自适应** 的参考项目。

---

## ✨ 核心特性

### 🧩 拼图手感

- **贝塞尔真实咬合**：每条切线由 `EdgeLayout` 确定性生成，`PieceShape` 构建二次贝塞尔 tab/blank，overhang 深度 `tip=0.245`，边缘互补零裂缝。
- **集群（Cluster）连带拖拽**：已拼合的碎片自动合并为同一 `clusterId`，支持整组协同拖拽、旋转与磁吸。
- **磁吸吸附（Snap）**：归一化坐标系下 `snapDistance = min(1/cols, 1/rows) * 0.48`，距离 + 角度双重校验，落点平滑 Tween 缓动 + 发光反馈。
- **3D 浮雕与悬浮投影**：静止时双色高光/阴影切缝，拖拽时动态扩大阴影与提升 `priority`，触感逼真。

### 🎮 完整游戏闭环

- **100 关主线 + 30 天每日挑战 + UGC 自制**：`GameRepository` 统一管理关卡、每日题库（`bing_daily_data.dart`）、自制拼图三类数据源。
- **5 种标准比例与多档难度**：`1:1 / 2:3 / 3:2 / 3:4 / 4:3` 五档比例，碎片数 16～300 级（`lib/logic/puzzle_model.dart:1`），难度以 `completedPieceCounts` 独立记录。
- **两层式顶部工具栏**：
  - Tier 1 AppBar：大号标题、壁纸切换、原图眼睛（`visibility`）、暂停菜单；
  - Tier 2 悬浮 Sub-Bar：实时用时 `mm:ss`、已拼胶囊 `xx/yy (zz%)`、撤销/重做、底图透视 `0%/20%/45%`、边缘筛选、一键理盘、智能提示。
- **辅助系统**：`UndoManager` 30 步撤销/重做、`PuzzleEngine.hintFor()` 优先角块/边块提示、Board Ghost 三档透视。
- **成就体系**：12 项勋章 + 统计看板（总局数/碎片数/总时长/最快纪录），入口位于 `lib/widgets/achievements_dialog.dart:1`。

### 🖼️ 视觉与交互

- **9 套高清壁纸**：`assets/images/bg_00*.webp` 全屏 `BoxFit.cover`，托盘叠加半透明纯色遮罩，保证对比度。
- **智能最大化棋盘**：根据 `imageAspect` vs `availableAspect` 自动计算 `boardSize` 并居中，`srcRect` 与 `fillRect` 1:1 像素对齐。
- **托盘尺寸归一化**：无论 16～225 块，托盘内长边统一 `64px`（`trayScale = 64 / max(w,h)`），进出棋盘平滑缩放 `Vector2` 插值。
- **多模态手势**：`AppScrollBehavior` 扩展 `dragDevices: {touch, mouse, trackpad, stylus}`（`lib/main.dart:15`），支持鼠标拖拽、滚轮横向浏览、双指捏合缩放与画布平移。

### 📱 自制与每日

- **相册导入 + 自由裁剪**：`image_picker` 选取 + `CropPuzzlePage` 正交旋转校正，本地沙盒存储，抹除 EXIF。
- **每日挑战**：无前置解锁，支持历史回溯与连胜统计，数据源 `lib/data/bing_daily_data.dart:1`。

---

## 🛠️ 技术栈

| 分层 | 选型 | 版本 / 说明 |
|---|---|---|
| UI 框架 | Flutter | 3.x / Material 3 |
| 游戏引擎 | Flame | `^1.38.0` + `flame_riverpod ^5.5.5` |
| 状态管理 | flutter_riverpod | `^3.4.2` |
| 本地存储 | shared_preferences / path_provider | `^2.5.5` / `^2.1.6` |
| 图片 | image_picker / dart:ui | `^1.2.3` / `decodeImageFromList` |
| 网络 | dio | `^5.11.0`（预留每日图源扩展） |
| 数学 | vector_math | `^2.2.0` |
| 图标 | phosphoricons_flutter | `^1.0.0` |
| 启动图标 | flutter_launcher_icons | `^0.14.4` |
| 静态检查 | flutter_lints | `^6.0.0` |

> 详见 `pubspec.yaml:30` 依赖声明。

---

## 📁 目录结构

```
jigsawpuzzle/
├─ lib/
│  ├─ main.dart                          # 入口 + AppScrollBehavior (lib/main.dart:15)
│  ├─ data/
│  │  ├─ game_repository.dart             # 统一仓储：关卡/每日/自制/设置/统计
│  │  ├─ bing_daily_data.dart             # 30 天每日题库
│  │  └─ models/ {level_item, daily_challenge, custom_puzzle_item}.dart
│  ├─ logic/
│  │  ├─ puzzle_model.dart                # 5 比例 × 多难度阶梯定义
│  │  ├─ image_source.dart                # 图源抽象
│  │  ├─ geometry/ {edge_layout, edge_curve, edge_type, piece_shape}.dart
│  │  ├─ engine/ {puzzle_engine, undo_manager}.dart  # 纯领域逻辑，零 UI 依赖
│  │  └─ models/puzzle_state.dart         # PieceState / PuzzleBoardState / Snapshot v2
│  ├─ game/
│  │  ├─ jigsaw_puzzle_game.dart          # FlameGame 主引擎 (JigsawPuzzleGame:92)
│  │  └─ puzzle_piece_component.dart      # 单碎片组件：渲染/手势/发光
│  ├─ pages/
│  │  ├─ main_screen.dart                 # 三 Tab 底导 + 顶部统计 (MainScreen:13)
│  │  ├─ home_page.dart / game_page.dart / crop_puzzle_page.dart
│  │  └─ tabs/ {home_tab_view, daily_tab_view, my_puzzles_tab_view}.dart
│  └─ widgets/
│     ├─ choose_difficulty_sheet.dart     # 难度选择 + 网格预览
│     ├─ choose_background_sheet.dart     # 9 壁纸切换
│     ├─ achievements_dialog.dart / how_to_play_dialog.dart / settings_dialog.dart
│     └─ ...
├─ assets/
│  ├─ images/  # bg_00*.webp (9) + sample_*.jpg (10) + icon/splash
│  ├─ bg/ / levels/ / temp/
├─ test/
│  ├─ logic/                 # EdgeLayout / PieceShape / Snap / Undo 单元测试
│  ├─ game_layout_test.dart / new_features_test.dart / widget_test.dart
├─ docs/
│  ├─ jigsaw-puzzle-game-prd.md                        # PRD
│  ├─ jigsaw-puzzle-game-architecture.md               # 架构
│  ├─ jigsaw-logic-architecture-and-technology.md
│  ├─ jigsaw-piece-cutting-and-rendering-design.md
│  └─ CHANGES-2026082*.md     # 变更日志
├─ pubspec.yaml / analysis_options.yaml / flutter_launcher_icons.yaml
└─ README.md
```

---

## 🚀 快速开始

### 环境要求

- Flutter 3.x + Dart `^3.12.2`（见 `pubspec.yaml:22`）
- 已配置 Android Studio / Xcode / Visual Studio（如需桌面端）

### 安装与运行

```bash
# 克隆
git clone <repo-url> jigsawpuzzle
cd jigsawpuzzle

# 获取依赖
flutter pub get

# 静态检查（需 0 issue）
dart analyze

# 运行（按需选择设备）
flutter run -d windows    # Windows 桌面
flutter run -d chrome     # Web
flutter run               # 自动选择已连接设备
```

### 指定设备查看

```bash
flutter devices
flutter run -d <deviceId>
```

---

## 🎯 玩法说明

### 关卡与难度

- **主线 100 关**：`1-10` 关 16 块 → `11-25` 关 25 块 → `26-50` 关 36 块 → `51-75` 关 64 块 → `76-90` 关 100 块 → `91-100` 关 225 块，通关任意难度即解锁下一关。
- **多难度独立记录**：同一关卡不同 `pieceCount` 的通关状态独立保存（`completedPieceCounts: Set<int>`），已通关难度在选择面板中绿底高亮 + 打勾。
- **每日挑战**：每天一张精选图，无解锁门槛，支持历史重玩与连胜天数统计。

### 操作方式

| 操作 | 移动端 | 桌面端 |
|---|---|---|
| 拖拽碎片/集群 | 单指拖拽 | 鼠标左键拖拽 |
| 旋转 90° | 双击碎片 | 右键 / 旋转按钮 |
| 缩放画布 | 双指捏合 | 滚轮 / 触控板 |
| 平移画布 | 双指拖拽 | 鼠标中键/缩放后拖拽 |
| 浏览托盘 | 单指滑动 | 鼠标拖拽 / 滚轮横向 |
| 撤销/重做 | 工具栏按钮 | 同左 + 快捷键（预留） |

### 星级与辅助

- **三星评定**：★ 通关 / ★★ 限时内 / ★★★ 限时且零高阶提示。
- **提示分级**：轻量高亮 vs 自动归位（计入 `hintsUsed` 影响三星）。
- **底图透视**：`0% → 20% → 45% → 0%` 循环，`BoardGhostComponent` 半透明水印。
- **通关表现**：接缝淡出、Ghost 置顶、结算弹窗可关闭后继续欣赏原图。

---

## 🏗️ 架构设计

### 三层分离

```
UI 表现层 (Flutter Widgets)
    ↕ 用户意图 / 状态传递
游戏引擎层 (Flame: JigsawPuzzleGame / PieceComponent / Ghost/Tray)
    ↕ 纯函数调用 / Snap 结算
领域逻辑层 (Pure Dart: EdgeLayout / PieceShape / PuzzleEngine / UndoManager / GameRepository)
```

- **领域层零依赖**：不依赖 Flutter/Flame，可 100% 脱机单元测试，见 `lib/logic/engine/puzzle_engine.dart:12`。
- **归一化坐标**：所有 `PieceState.nx/ny` 为 `[0,1]` 归一化，跨设备/窗口 Resize 无损重映射。

### 几何核心

- **EdgeLayout**：`_h[M-1][N]` + `_v[M][N-1]` 双矩阵 `Random(seed)` 确定性生成，四边推导保证相邻互补（`lib/logic/geometry/edge_layout.dart:1`）。
- **PieceShape**：以 BaseCell 左上角 `(0,0)` 为原点，`overhang.tip=0.245` 外扩，`fillRect` 与 `srcRect` 同参数 1:1 对齐（`lib/logic/geometry/piece_shape.dart:1`）。
- **Snap 两阶段**：① 棋盘槽位吸附 ② 空中正交邻居合并 + 级联 `_mergeAllAdjacentClusters`（`lib/logic/engine/puzzle_engine.dart:94`）。
- **渲染管线**：壁纸 Layer0 → Flame 透明画布 Layer1 → 托盘遮罩 Layer2 → 原图覆盖 Layer3 → 双层导航 Layer4。

> 完整推导与公式见 `docs/jigsaw-puzzle-game-architecture.md` 与 `docs/jigsaw-piece-cutting-and-rendering-design.md`。

---

## 💾 数据与存档

- **GameRepository 单例**（`lib/data/game_repository.dart:14`）：
  - `SharedPreferences` 键：`jigsaw_level_*` / `jigsaw_daily_*` / `jigsaw_custom_list` / `jigsaw_setting_*` / `jigsaw_stat_*`
  - 9 张壁纸常量 `kBackgroundAssets`，设置项：音效/震动/网格预览/选中壁纸。
- **Snapshot v2**：`PuzzleBoardState.toJson/fromJson` 归一化快照，支持断点续玩与 Undo 栈（`lib/logic/models/puzzle_state.dart:1`）。
- **自制拼图**：本地文件路径存沙盒，删除时同步清理文件（`deleteCustomPuzzle:222`），EXIF 默认抹除。

---

## 🧪 开发与测试

```bash
# 静态检查
dart analyze

# 单元 + Widget 测试
flutter test

# 查看覆盖率（需 lcov）
flutter test --coverage
```

| 测试模块 | 类型 | 验证点 |
|---|---|---|
| `EdgeLayoutTest` | 单元 | 同 seed 拓扑恒定、相邻互补 |
| `PieceShapeTest` | 几何 | 共享边重合误差、包围盒对齐 |
| `SnapAlgorithmTest` | 算法 | 阈值吸附、角度校验、Cluster 平移 |
| `SnapshotRestoreTest` | 往返 | 序列化/反序列化 100% 一致 |
| `UndoManagerTest` | 状态 | 多步撤销/重做幂等 |
| `NewFeaturesTest` | Widget | 透视循环、未解锁预览、UGC 删除、自适应网格 |

---

## 📦 构建与发布

```bash
# Android APK / AAB
flutter build apk --release
flutter build appbundle --release

# iOS
flutter build ios --release

# Windows
flutter build windows --release

# Web
flutter build web --release

# 图标生成（已配置 flutter_launcher_icons.yaml）
dart run flutter_launcher_icons
```

> `version: 1.0.0+1`（`pubspec.yaml:19`），`minSdk 25`，Web/Windows 图标分别取 `assets/images/icon-round.png`。

---

## 📚 文档索引

- [产品需求文档 PRD](docs/jigsaw-puzzle-game-prd.md)
- [工程架构与算法](docs/jigsaw-puzzle-game-architecture.md)
- [领域架构与技术选型](docs/jigsaw-logic-architecture-and-technology.md)
- [切片与渲染设计](docs/jigsaw-piece-cutting-and-rendering-design.md)
- [内容存储与扩展](docs/puzzle-content-storage-and-expansion-design.md)
- [变更日志](docs/CHANGES-20260824.md) · [历史变更](docs/CHANGES-20260823.md)

---

## ❓ 常见问题

**Q: 碎片拖拽后位置错乱？**  
A: 检查 `PuzzleBoardState` 归一化坐标与 `boardSize/zoom/panOffset` 的换算，`_screenToNormalized/_normalizedToScreen` 需与 `_updateBoardTransform` 同步（`lib/game/jigsaw_puzzle_game.dart:405`）。

**Q: 托盘碎片参与了空中合并？**  
A: 引擎层已通过 `onBoardPieceIds` 白名单隔离托盘碎片（`lib/logic/engine/puzzle_engine.dart:108`），自定义逻辑请保持该约束。

**Q: 新增关卡图片？**  
A: 放入 `assets/images/` 并在 `pubspec.yaml:71` 注册，或通过 UGC 导入；主线关卡在 `GameRepository._initLevels:75` 按 `assetSamples` 循环分配。

**Q: 如何重置存档？**  
A: 调用 `GameRepository.instance.resetAllData()`（`lib/data/game_repository.dart:383`）或清除应用存储。

---

## 🤝 贡献与许可证

- 贡献流程：Fork → 新建分支 → `dart analyze && flutter test` 通过 → 提交 PR。
- 代码风格：遵循 `analysis_options.yaml`（`package:flutter_lints/flutter.yaml`），`flutter_lints ^6.0.0`。
- 许可证：依赖库多为 `BSD-3-Clause`，本项目建议同许可证分发，详见各依赖声明。

---

<p align="center">Made with Flutter & Flame · 祝拼图愉快！🧩</p>
