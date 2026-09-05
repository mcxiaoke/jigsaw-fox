# UI/UX 架构重构与页面升级总结报告 (2026-09-05)

## 一、重构背景与目标

为了提升拼图游戏在移动端与桌面宽屏（Windows/macOS）下的视觉呈现与交互一致性，消灭页面跳转繁琐与横向拉伸失真问题，本次进行了全方位的 UI 架构升级：

1. **消灭宽屏拉伸失真**：针对原单卡 Banner 在宽屏/桌面上被严重横向拉伸变形的问题，引入全平台自适应固定卡宽横滑 Rails 组件；
2. **收敛底栏架构为 4-Tab 体系**：将原有复杂的底栏与多级页面整合为主页（Home）、每日（Daily）、图集（Collections）、我的（My），结构清晰明了；
3. **消除冗余工坊页面，内聚「我的」Tab**：彻底移除多余的二级独立工坊页面，将自制创作入口（相册选图、在线搜图、素材库、导入图包）内聚在「我的」Tab 顶部，并采用 NestedScrollView 实现创作卡片随滑动收起、TabBar 优雅吸顶；
4. **规范「图集」Tab 视觉流**：顶部仅呈现限时活动大卡横滑，中间加入与「每日」同规格的胶囊统计分割栏，下方采用与首页/每日完全一致的正方形卡片网格（不显示 desc，移除冗余筛选 chips），并加入 Zip 资源未下载时的点击拦截体验保障；
5. **修复图集关卡总数展示缺陷**：彻底解决部分 Zip 图集在服务端 JSON 缺漏 	otalCount 时前端未展示关卡数的问题，建立客户端本地解压图片动态计数双重兜底机制。

---

## 二、关键设计与改动清单

### 1. 全平台自适应横幅 (AdaptiveHeroBanner)
- **文件**：lib/widgets/adaptive_hero_banner.dart [NEW]
- **实现**：固定卡片宽度（290dp ~ 300dp）与高度（156dp ~ 160dp），采用 ListView.separated 横滑轨道。移动端自然展现露边 Peek 引导，桌面宽屏端自适应平铺多张卡片，两端均获得最佳视觉比例。
- **应用**：已全面替换首页（HomeTabView）与图集页（CollectionsTabView）的顶部 Banner。

### 2. 底栏架构与路由收敛 (MainScreen)
- **文件**：lib/pages/main_screen.dart [MODIFY]
- **实现**：底栏精简为 4 项 NavigationBar：主页、每日挑战、官方图集、个人中心；
- **清理**：彻底删除 lib/pages/custom_puzzles_page.dart 冗余二级页面。

### 3. 「我的」Tab 体验重构 (MyCenterTabView)
- **文件**：lib/pages/tabs/my_center_tab_view.dart [MODIFY]
- **实现**：
  - 采用 DefaultTabController + NestedScrollView 架构；
  - 顶部 4 大紧凑创作卡片（高度 80dp）：📷 相册选图（相册多图选择与智能裁切）、🌐 在线搜图、📦 素材库、📥 导入图包；
  - 向上滑动浏览关卡时，创作卡片平滑滚动隐藏；
  - 实现 _PinnedTabBarDelegate，4 个子 Tab（进行中、收藏、已完成、自制）顺滑**吸附在屏幕顶部**；
  - 子 Tab 网格配置 PageStorageKey，保证跨 Tab 切换独立保留滚动位移；
  - 自制 Tab 空状态提供一键唤起相册导入。

### 4. 「图集」Tab 视觉精简与胶囊栏 (CollectionsTabView)
- **文件**：lib/pages/tabs/collections_tab_view.dart [NEW]
- **实现**：
  - **顶部 Banner**：数据源仅限来自 vents.json 的限时活动大卡片；
  - **统计胶囊条 (Stats Bar)**：在 Banner 与网格之间引入与「每日」Tab 尺寸（外边距 16x4、内边距 16x10、圆角 16、微边框）完全对齐的统计栏，左侧显示文件夹图标与「精选图集」，右侧显示「X 套」徽章；
  - **卡片网格**：对齐首页/每日正方形网格规格（maxCrossAxisExtent: 220, childAspectRatio: 1.0），多列自适应；
  - **卡片内容**：仅展示封面与标题（及关卡数），不展示描述；彻底移除分类 Filter Chips 栏；
  - **下载安全拦截**：Zip 图集未下载完成严禁进入关卡详情页，点击就地触发下载或提示，下载就绪后方可进入。

### 5. 图集关卡详情页与底层管线 (CollectionsContentPipeline)
- **文件**：
  - lib/pages/collection_levels_page.dart [NEW]：纯图关卡列表，支持难度选择与断点续玩；
  - lib/logic/content/models/puzzle_collection_item.dart [NEW]：图集元数据模型，支持 Zip 与 Array 双载荷；
  - lib/logic/content/pipelines/collections_content_pipeline.dart [NEW]：下载解压、进度通知、以及针对本地已下载 Zip 图片数的动态计数兜底；
  - lib/logic/content/app_content.dart、content_manager.dart、
oot_manifest.dart、canonical_id.dart、catalog_index.dart [MODIFY]：整合与桥接图集管线。

---

## 三、代码质量与验证结果

1. **代码格式化规范**：改动涉及的所有 Dart 代码均执行 dart format，遵循规范；
2. **静态代码分析**：执行 lutter analyze，结果为 **No issues found!**（0 告警 0 错误）；
3. **自动化测试套件**：执行 lutter test，全量 **259 个单元与 Widget 测试 100% 全部通过**；
4. **桌面平台编译验证**：执行 lutter build windows --debug，在 18.6s 内成功编译并生成 JigsawFox.exe。
