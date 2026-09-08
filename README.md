# 异形拼图 Jigsaw Puzzle 🧩

> Flutter + Flame 打造的高品质全平台异形拼图游戏 —— 真实贝塞尔咬合、集群拖拽、磁吸吸附，支持 Android / iOS / Windows / Web。

[![Flutter](https://img.shields.io/badge/Flutter-3.x-02569B?logo=flutter)](https://flutter.dev)
[![Dart](https://img.shields.io/badge/Dart-3.x-0175C2?logo=dart)](https://dart.dev)
[![Flame](https://img.shields.io/badge/Flame-1.38-orange)](https://flame-engine.org)
[![License](https://img.shields.io/badge/License-BSD--3--Clause-green)](LICENSE)

---

## 🌟 项目简介

单机优先、离线可玩的异形拼图游戏，追求「真实拼图手感」与「全平台一致体验」：

- **真实切割**：确定性随机 + 二次贝塞尔凹凸咬合，任意 `M×N` 网格，无缝互补
- **高性能渲染**：Flame 单画布批量渲染，60fps 拖拽/缩放/平移
- **全端自适应**：一套代码覆盖手机/平板/桌面，窗口任意缩放不溢出
- **本地沙盒**：进度、存档、设置均持久化于本地（Hive + 文件沙盒）

> 详见产品定义：[PRD](docs/jigsaw-puzzle-game-prd.md)

---

## ✨ 核心特性

- **拼图手感**：贝塞尔咬合 / 集群连带拖拽 / 磁吸吸附 / 3D 浮雕与阴影
- **完整闭环**：主线关卡 + 每日挑战 + 活动合集 + 自制拼图，5 种比例 / 多档难度独立记录
- **辅助系统**：撤销/重做、智能提示、底图透视、成就勋章
- **视觉交互**：高清壁纸、自适应棋盘、托盘归一化、多模态手势（触控/鼠标/滚轮/触控板）
- **自制与每日**：相册导入 + 自由裁剪 + 本地存储，每日精选支持历史回溯

> 玩法与规则详见 [PRD - 玩法规则](docs/jigsaw-puzzle-game-prd.md#2-玩法规则与难度设计)

---

## 🛠️ 技术栈

| 分层 | 选型 | 说明 |
|---|---|---|
| UI 框架 | Flutter 3.x / Material 3 | 跨端一致渲染 |
| 游戏引擎 | Flame 1.38 + flame_riverpod | 单画布 + 组件生命周期 |
| 状态管理 | flutter_riverpod 3.x | 响应式状态 |
| 本地存储 | hive_ce + shared_preferences + path_provider | 结构化持久化 |
| 图片 | image_picker / image / dart:ui | 选取、裁剪、解码 |
| 网络 | dio | 内容分发预留 |
| i18n | slang | zh-CN / en-US |
| 音效 | flame_audio | 背景与交互音效 |

> 完整依赖见 [pubspec.yaml](pubspec.yaml)

---

## 📁 目录结构

```
jigsawpuzzle/
├─ lib/                 # Flutter 游戏主项目
│  ├─ main.dart
│  ├─ data/             # 仓储与持久化（storage_manager / progress_store / snapshot_store）
│  ├─ logic/            # 纯领域逻辑（geometry / engine / content / cache）
│  ├─ game/             # Flame 引擎层（JigsawPuzzleGame / PieceComponent）
│  ├─ pages/ & tabs/    # 页面与 4-Tab 导航（Home / Daily / Events / My）
│  ├─ services/         # 成就 / 音效 / 经济 / 解锁等服务
│  ├─ widgets/          # 通用组件
│  ├─ theme/ & utils/ & l10n/ # 主题、工具、国际化
├─ studio/              # 素材处理工作室（图片处理、资源导出、Web 服务）
├─ scripts/             # 通用脚本（批量下载、AI 打标、ComfyUI 生成等）
├─ deploy/              # 部署脚本与配置
├─ assets/              # 静态资源（images / bg / icons / audio）
├─ docs/                # 项目文档与变更日志
├─ test/ & integration_test/ # 单元/Widget/集成测试
└─ pubspec.yaml
```

> 各目录职责与约束见 [AGENTS.md](AGENTS.md)

---

## 🚀 快速开始

**环境要求**：Flutter 3.x + Dart `^3.12.2`

```bash
git clone <repo-url> jigsawpuzzle && cd jigsawpuzzle
flutter pub get
dart analyze
flutter run -d windows   # 或 chrome / 已连接设备
flutter devices           # 查看可用设备
```

---

## 📚 文档索引

### 产品与设计
- [产品需求 PRD](docs/jigsaw-puzzle-game-prd.md)
- [UI/UX 架构与 Tab 重构](docs/ui-ux-architecture-and-tabs-refactor-20260905.md)
- [成就与难度设计](docs/jigsaw-difficulty-scoring-achievements-design.md) · [星级评定](docs/jigsaw-star-rating-casual-two-track-design-20260904.md)

### 架构与算法
- [工程架构](docs/jigsaw-puzzle-game-architecture.md) — 分层、渲染管线、测试策略
- [Logic 领域架构](docs/jigsaw-logic-architecture-and-technology.md) — 纯 Dart 核心能力
- [切片与渲染](docs/jigsaw-piece-cutting-and-rendering-design.md) — 贝塞尔咬合与 1:1 采样
- [物理纸板与光照](docs/physical-cardboard-rendering-and-lighting-design.md)
- [当前数据架构](docs/data-architecture-current.md)

### 内容与数据
- [内容存储与扩展](docs/puzzle-content-storage-and-expansion-design.md)
- [内容打包工具](docs/puzzle-content-packaging-tool-design.md)
- [图片缓存与缩略图管线](docs/image-cache-and-thumbnail-pipeline-architecture.md)
- [网络分发与启动初始化](docs/home-network-migration-and-boot-init-design-20260907.md)

### 工作室与工具
- [Studio 技术架构](studio/docs/studio-technical-architecture.md)
- [统一导出与存储架构](studio/docs/unified-content-export-and-storage-architecture.md)
- [ComfyUI 批量生成指南](docs/comfyui-batch-generation-guide.md)

### 变更日志
- [CHANGES-20260908](docs/CHANGES-20260908.md) · [CHANGES-20260907](docs/CHANGES-20260907.md) · 归档见 [docs/archived/](docs/archived/)

---

## 🧪 开发与测试

```bash
dart analyze              # 静态检查（0 issue）
flutter test              # 单元 + Widget 测试
flutter test --coverage   # 覆盖率

# 构建验证
flutter build windows --debug
flutter test integration_test/app_test.dart -d windows
```

> 代码风格遵循 `analysis_options.yaml`（`flutter_lints` + `very_good_analysis`），改动文件需 `dart format`

---

## 📦 构建与发布

```bash
flutter build apk --release        # Android APK
flutter build appbundle --release  # Android AAB
flutter build ios --release        # iOS
flutter build windows --release    # Windows
flutter build web --release        # Web
dart run flutter_launcher_icons    # 生成图标
```

`version: 1.0.0+1` · `minSdk 25` · 图标配置见 `flutter_launcher_icons.yaml`

---

## 🤝 贡献与许可证

- 流程：Fork → 新建分支 → `dart analyze && flutter test` 通过 → PR
- 许可证：遵循各依赖声明，建议 `BSD-3-Clause`

---

<p align="center">Made with Flutter & Flame · 祝拼图愉快！🧩</p>
