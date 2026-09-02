# HomeTab 参考实现拆解 — Jigsawscapes (banana) 对标落地规格

> **来源**：`temp/hometab/Screenshot_2026-09-02-12-0*.jpg` ×3（包名 `jigsaw.puzzle.game.banana`，即 Jigsawscapes）  
> **对照文档**：`docs/jigsaw-app-comprehensive-review-20260902.md:1` v1.1 §3  
> **目标**：按该参考 1:1 复刻可直接进 Figma/Flutter 实现，已结合本项目 21 Tag / manifest / NEW / 无解锁等约束做适配  
> **结论**：该参考与 v1.1 目标形态完全一致（Header不吸顶/Tag单行+Sheet/2列纯图+NEW/无排序无序号），可直接采用

---

## 1. 参考截图精读

### 1.1 帧1 — 首屏静止

```
┌─────────────────────────────────────┐
│ 图库                [💎 100 +]      │  标题左 28sp 斜体，币胶囊右
├─────────────────────────────────────┤
│ ┌─────────────────────────────────┐ │  Banner 16dp圆角，160dp高
│ │ 编辑精选    苹果季              │ │  左1/3 暗色斜切遮罩+文字
│ │              [浣熊+苹果屋]      │ │  右2/3 实景图，页码点下方
│ └─────────────────────────────────┘ │  dots: ─ ● ─ ─ (●为选中)
├─────────────────────────────────────┤
│ [全部*] 颜色  绘画  岛屿  宠物  ☰   │  Tag栏 44dp，单行横滑
├─────────────────────────────────────┤
│ [New|甜甜圈] [New|房屋]             │  网格 2列 12/14间距
│ [New|岛屿栈桥] [New|猫狗向日葵]     │  卡片 8dp圆角 1:1 纯图
│ [New|红房]   [New|森林溪流]         │  左上 New 橙棕斜角标
└─────────────────────────────────────┘
  底部Tab：图库● 每日 旅程 我的拼图
```

- 币胶囊：`💎 100 +` 白底圆角，紫色+号，位于标题行右侧，非 AppBar 右侧成就入口（本项目可保留标题行币胶囊或按v1.1改为仅🏆，建议**保留币胶囊**与参考一致，用户对币感知更强）
- Banner：标题区 `编辑精选(11sp 灰)` + `苹果季(22sp 白粗)` 左下；指示点 4个，选中为短黑线
- Tag：选中态 `全部` 为白底+紫字+轻阴影，高度28dp，圆角14；未选中透明；最右 `☰` 固定不随横滑

### 1.2 帧2 — 全部Sheet展开

```
┌─────────────────────────────────────┐
│ [全部] 颜色 绘画 岛屿 宠物 ☰  (背景变暗)│
├─────────────────────────────────────┤
│ ┌─────────────────────────────────┐ │
│ │  全部*   颜色    绘画           │ │  Sheet：顶圆角20dp，白底
│ │  岛屿    宠物    房屋           │ │  3列文本，行高44dp
│ │  收藏    谜题    乡村           │ │  选中：浅紫 pill 背景+紫字
│ │  节日    自然    静物           │ │  未选：黑字
│ │  艺术    花朵    四季           │ │  共27项（比21多，含收藏等）
│ │  动物    食物    鸟类 ...       │ │
│ │  旅行    家      难题           │ │
│ │  幻想    模式    海洋           │ │
│ │  禅      手工制作               │ │
│ └─────────────────────────────────┘ │
└─────────────────────────────────────┘
```

- Sheet：`showModalBottomSheet`，`isScrollControlled:true`，背景 `rgba(0,0,0,0.4)`，内容区 `maxHeight 70%`，可滚动
- 布局：`Wrap`或`GridView(3列)`，`childAspectRatio ~2.8`，`crossSpacing 8` `mainSpacing 4`
- 数据：参考27类含 `收藏/谜题/家/禅/模式` 等虚构运营分类，本项目按 `jigsaw-image-tagging-specification.md:1` 21类实现，**不照搬**其27类

### 1.3 帧3 — 上滑吸顶

- Header 已滚出视口，Tag栏仍吸顶在顶部（`Pinned`），网格连续
- 证明：仅 Tag 栏吸顶，Header 不吸顶，与 v1.1 §3.2 完全一致

---

## 2. 与本项目 v1.1 差异对照与取舍

| 维度 | 参考实现 | v1.1 原计划 | 取舍决策 |
|---|---|---|---|
| 顶部标题 | `图库` 大斜体 + 右侧 `💎100+` | `异形拼图 + 🏆` | **不复刻标题样式**：保留现有 `AppBar` 简洁样式（`main_screen.dart:16` `异形拼图 + 🏆`），仅复用参考的布局逻辑；标题/币胶囊不改 |
| Header | 单Banner“苹果季”可横滑，dots | 每日+活动 PageView | **布局一致、样式简化**：Header仍为可横滑 PageView（每日+活动），但保持现有 `home_tab_view.dart:1` 简洁卡片样式，不复刻“斜切遮罩/编辑精选”视觉 |
| Tag热门 | `全部 颜色 绘画 岛屿 宠物` 4个热门 | `全部 + 6-7热门` | **一致**，N=6-7，数据源`COUNT(tags)` TOP N，末位固定 `☰` |
| Sheet | 3列文本，27类 | 3列 Emoji+中文+数量，21类 | **采纳参考布局**，但内容按21类：`全部` + 21 Tag中文（宠物/动物/鸟类/自然/风景/花卉/海洋/城市/建筑/美食/艺术/奇幻/太空/交通/人物/运动/四季/节日/抽象/卡通/其他） |
| 排序 | 无 | 无 | **一致**，不做 |
| 卡片序号 | 无 | 去掉 | **一致** |
| 卡片New | 橙棕斜角 `New` 左上 | 橙棕胶囊/斜角 `NEW` | **一致**，左上斜角飘带 `New`（`#C67A2E` 背景白字斜体） |
| 卡片块数 | 无 | 可选 `◈225` 右下 | **二期**，首期不显示块数，保持纯图 |
| 网格 | 2列 1:1 8dp圆角 12/14间距 | 2列 1:1 12/18圆角 | **采纳参考**：`borderRadius 8`，`crossSpacing 10` `mainSpacing 10`，`maxCrossAxisExtent 220` |
| 底部Tab | 图库/每日/旅程/我的拼图 | 主页/每日/活动/自制 | 保留现有4 Tab文案，图标可换为参考的线性描边风格 |

---

## 3. 落地规格（可直接给 Flutter）

### 3.1 信息架构（Sliver）

```dart
CustomScrollView(
  slivers: [
    SliverToBoxAdapter(child: _HeaderBanner()), // 不吸顶，随滚
    SliverPersistentHeader(pinned: true, delegate: _TagBarDelegate()), // 仅Tag吸顶 44dp
    SliverPadding(
      padding: EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      sliver: SliverGrid(
        gridDelegate: SliverGridDelegateWithMaxCrossAxisExtent(
          maxCrossAxisExtent: 220,
          crossAxisSpacing: 10,
          mainAxisSpacing: 10,
          childAspectRatio: 1.0,
        ),
        delegate: SliverChildBuilderDelegate((_, i) => _PuzzleCard(levels[i])),
      ),
    ),
  ],
)
```

### 3.2 标题行

- **保持现有 AppBar 简洁样式**：`lib/pages/main_screen.dart:16` `AppBar(centerTitle:false, title: Row(🦊, '异形拼图'), actions: [🏆])` 不改为参考的 `图库` 大斜体+币胶囊；`⚙️设置`仍仅 `我的` Tab显示（见 `jigsaw-app-comprehensive-review-20260902.md:2.2`）
- 如后续需展示币，可在首页首屏轻量胶囊内展示，不改 AppBar

### 3.3 Header Banner

- **布局采纳参考，样式保持现有简洁**：`height 160, borderRadius 16, clipBehavior: Clip.antiAlias, margin: 16/12` 的 `PageView` 结构不变（首项每日大卡，次项起活动封面 `AppCachedImage coverUrl` + dots），但视觉沿用现有 `_DailyBanner` 简洁渐变卡片，不复刻参考的“斜切遮罩/编辑精选/苹果季”图文排版
- PageView：`PageView.builder(itemCount: 1+events.length, onPageChanged: setDot)`
- 指示点：下方居中 `Row(dot: Container(width: selected?18:10, height:4, decoration: BoxDecoration(color: selected?Colors.black87:Colors.black26, borderRadius:4)))`，`spacing 6`

### 3.4 Tag栏

- 容器：`height 44, color: Color(0xFFF5F5F5)`，`Stack(children: [横滑区, 固定入口])`
- 横滑区：`SingleChildScrollView(scrollDirection: horizontal, padding: EdgeInsets.only(left:12, right:48), child: Row(spacing:8, children: chips))`
- Chip：`AnimatedContainer(padding: 14/7, decoration: BoxDecoration(color: isSelected?Colors.white:Colors.transparent, borderRadius:14, boxShadow: isSelected?[BoxShadow(black8, blur6)]:null), child: Text(label, style: TextStyle(fontSize:14, fontWeight: isSelected?w700:w500, color: isSelected?Color(0xFF6B4EFF):Color(0xFF333333))))`；`label` 取中文（全部/宠物/风景...）
- 固定入口：`Positioned(right:0, top:0, bottom:0, child: Container(width:48, alignment: Center, decoration: BoxDecoration(color: Color(0xFFF5F5F5), gradient: LinearGradient(white54→transparent 逆向)), child: IconButton(icon: Icon(Icons.menu, size:20), onPressed: _showAllTagsSheet)))`
- 热门N：`N=6`（含全部共7），`allTags = ['全部', ...top6]`，`top6` 由 `levels.map(tags).count` 取 TOP6，运营可覆写 `assets/config/home_hot_tags.json`

### 3.5 全部Sheet

```dart
Future<String?> showAllTagsSheet(BuildContext context, String selected) {
  return showModalBottomSheet<String>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    builder: (_) => Container(
      constraints: BoxConstraints(maxHeight: MediaQuery.of(context).size.height*0.7),
      decoration: BoxDecoration(color: Color(0xFFF2F2F2), borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      child: Column(children: [
        SizedBox(height:12, child: Center(child: Container(width:40, height:4, decoration: BoxDecoration(color: Colors.black12, borderRadius:4)))),
        Expanded(child: GridView.count(crossAxisCount:3, childAspectRatio:2.8, padding: EdgeInsets.fromLTRB(16,12,16,24),
          children: all21Tags.map((tag) => _SheetItem(tag, isSelected: tag==selected)).toList())),
      ]),
    ),
  );
}
```

- `_SheetItem`：`InkWell(onTap: (){Navigator.pop(tag); setState(()=>selectedTag=tag); scrollToTop();}, child: Container(padding: 10/6, decoration: BoxDecoration(color: isSelected?Colors.white:Colors.transparent, borderRadius:12), child: Center(child: Text(tagLabel, style: TextStyle(fontSize:15, color: isSelected?Color(0xFF6B4EFF):Colors.black87, fontWeight: isSelected?w700:w400)))))`

### 3.6 网格卡片

```dart
Widget _PuzzleCard(PuzzleLevelItem level) {
  final isNew = level.addedAt != null && DateTime.now().difference(level.addedAt!).inDays < 7 && !level.isCompleted;
  return ClipRRect(borderRadius: BorderRadius.circular(8), child: Stack(fit: StackFit.expand, children: [
    AppCachedImage(imagePathOrUrl: level.imagePathOrUrl, fit: BoxFit.cover, targetDimension: ThumbnailDimension.card),
    if (isNew) Positioned(left:0, top:8, child: _NewRibbon()),
    // 可选块数：Positioned(right:6, bottom:6, child: Container(padding:6/3, decoration:BoxDecoration(color: Colors.black54, borderRadius:6), child: Text('◈ 225', style: TextStyle(color:Colors.white, fontSize:10))))
  ]));
}
Widget _NewRibbon() => Container(
  padding: EdgeInsets.symmetric(horizontal:10, vertical:3),
  decoration: BoxDecoration(color: Color(0xFFC97A2E), borderRadius: BorderRadius.only(topRight: Radius.circular(4), bottomRight: Radius.circular(4))),
  child: Text('New', style: TextStyle(color:Colors.white, fontSize:12, fontWeight: FontWeight.w800, fontStyle: FontStyle.italic)),
);
```

- 卡片尺寸：`borderRadius 8`（参考为8非12），阴影 `BoxShadow(black12, blur6, offset(0,2))` 可选，参考阴影极淡
- 占位：`placeholder: Container(color: Colors.grey200)`，`errorWidget: Icon(Icons.broken_image)`
- 点击：`onTap: () => ChooseDifficultySheet.show(...)`，难度由 `ChooseDifficultySheet` 内自选，无统一筛选

### 3.7 滚动与埋点

- 右侧固定入口需 `rightFade` 渐变遮罩避免硬切
- 选中Tag后 `scrollController.animateTo(0, duration:200ms)` + `AnimatedSwitcher(180ms)` 淡入
- 埋点：`tag_hot_click / tag_sheet_open / tag_sheet_select / header_banner_swipe / card_new_impression`

---

## 4. 与 v1.1 实施清单增量

在 `docs/jigsaw-app-comprehensive-review-20260902.md:13` Phase0 基础上，首页P0按本规格细化：

- [ ] **标题/Header样式不改**：保留现有 `AppBar` 简洁样式与 `_DailyBanner` 简洁卡片，仅调整布局为 `PageView` + dots，首项每日次项活动 `AppContent.getVisibleEvents().take(3)`，160dp 不吸顶
- [ ] Tag栏单行吸顶44dp，`SingleChildScrollView` + 右侧固定 `☰`，热门6个数据驱动
- [ ] Sheet 3列文本 27→21 调整，选中白底紫字，圆角20，70%高
- [ ] Grid 2列 `crossSpacing 10` `borderRadius 8`，卡片仅图+New飘带，移除序号
- [ ] `addedAt` 7天 NEW 口径，`ChooseDifficultySheet` 保持每关自选

---

## 5. 视觉标注（供 Figma）

- 背景：`#F5F5F5` 极浅灰（非纯白）
- 选中紫：`#6B4EFF`（参考紫），可用 `palette.brand` `#D4963C` 替换但建议**按参考用紫**以贴近品类心智（Jigsawscapes紫为品类色）
- New橙：`#C67A2E` / `#C97A2E`
- 圆角：Banner16 / Chip14 / Card8 / Sheet20
- 字阶：标题28斜粗 / Tag14 / Sheet15 / New12斜粗
- 间距：页面左右12 / Tag左右12 / Grid 10

---

> **落地建议**：直接按本规格出 `home_tab_view.dart:1` 重构PR，Figma可1:1临摹截图，仅替换Tag文案为21类中文。首版热门Tag硬编码 `['全部','宠物','风景','花卉','城市','艺术','幻想']` 亦可，数据驱动二期再接。
