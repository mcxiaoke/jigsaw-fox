# Jigsaw Puzzle 双语 UI 深度改进与全面美化方案 (v2)

> 报告日期：2026-09-06  
> 评审基准：基于 `temp/appui-en-zh` 15 张真实设备截图、现网源码（`lib/`）审计与 Material 3 休闲益智游戏视觉规范  
> 适用版本：Flutter 3.x / Android & iOS 双端双语（`zh-CN` / `en-US`）

---

## 一、双语界面核心问题诊断与技术根因审计

经过对 `temp/appui-en-zh` 目录下的 15 张真实机型截图（中英文各 7 张 + 胜利结算 1 张）以及相关 Flutter 源码的逐行审计，现有的界面问题并非单纯的“翻译文字长短”问题，而是**底层容器缺失、组件选型不当、硬编码未脱落、以及多语言光学字重未做针对性平衡**共同导致的。

### 1.1 真实截图问题对照矩阵

| 截图编号 | 所属页面 | 语言 | 视觉缺陷现象 | 源码根因定位 |
|:---|:---|:---|:---|:---|
| **15-26-35** | 胜利结算 (Victory) | 英文 | ① 标题、统计等文本出现**醒目的双黄色下划线**；<br>② "1 Stars" 单复数语法错误；<br>③ 成就横幅中英混合（"2 new achievements: 初露锋芒..."）；<br>④ 整体缺少游戏胜利氛围，按钮杂乱堆叠。 | ① `lib/widgets/victory_dialog.dart:269` 根节点为 `Container`，缺少 `Material` 祖先，触发 Flutter 缺 Material 的默认文本黄色下划线；<br>② `strings.i18n.json` 未针对 count=1 做单数匹配；<br>③ `victory_dialog.dart:512` 错误调用 `a.title`（硬编码中文）而非 `a.localizedTitle`。 |
| **20-16-08 / 20-16-36** | 首页 (Home) | 中 / 英 | ① 英文下分类标签 "Landscapes" / "Flowers" 宽度激增，右侧溢出；<br>② 英文活动卡片 Badge 出现文本溢出（`★ Limited-` 被截断）；<br>③ 英文顶栏 "Jigsaw Puzzle" 与中文 "异形拼图" 相比显得单薄、重心偏高。 | ① `home_tab_view.dart` 标签栏未设合理的自适应内边距与横向滚动边界；<br>② 轮播图角标 Badge 容器为固定宽度或受父级约束；<br>③ `main.dart` 未指定主字体，仅依赖系统 Roboto（西文）与 Noto Sans SC（汉字），笔画黑度差异悬殊。 |
| **20-16-11 / 20-16-45** | 每日挑战 (Daily) | 中 / 英 | 英文界面下**大面积残留硬编码中文**：<br>① 顶部卡片显示 "TODAY 9月6日"、"9月6日 · 今日挑战"；<br>② 按钮显示 "开始挑战"；<br>③ 统计栏显示 "每日总进度: 0/6"、"连胜 0 天"；<br>④ 月份头部显示 "2026年9月"、"已完成 0/6"。 | `lib/pages/tabs/daily_tab_view.dart:506, 515, 537-541, 613, 846` 虽在 `en.i18n.json` 中配置了 `t.daily.*` 键，但在 Dart 页面中直接硬编码了中文模板字符串，未调用 slang。 |
| **20-16-14 / 20-16-49** | 图集 (Collections) | 中 / 英 | ① 英文界面下活动卡片标题与描述仍为中文；<br>② 状态标签显示中文 "已下载"；<br>③ 关卡数量标签写死 "$effectiveCount关"；<br>④ 栏目标题写死 "4 套"。 | ① `collections_tab_view.dart:115` 与数据管道未打通双语字段；<br>② 行 418 写死 `'$effectiveCount关'`；<br>③ 栏目标题 Badge 格式化未调用 i18n。 |
| **20-16-18 / 20-16-52** | 我的中心 (My Puzzles) | 中 / 英 | **致命截断**：4 个子 Tab 英文文本全部被截成省略号：<br>`In Progre...`、`Favorites (...`、`Complete...`、`Custom (3...`。 | `lib/pages/tabs/my_center_tab_view.dart:436` 中 `TabBar` 默认为 `isScrollable: false`，屏幕宽度 360dp 均分后每个 Tab 仅 90dp，无法容纳 13~15 字符的带计数英文串。 |
| **20-16-21 / 20-16-55** | 成就统计 (Achievements) | 中 / 英 | ① 统计看板中英文严重截断：<br>`Puzzles Solv...`、`Pieces Snap...`、`Total Play Ti...`；<br>② 游玩时长 "0s" 与 "0 秒" 排版基线跳跃；<br>③ 成就墙灰色锁头+细线进度条过于呆板，像表单禁用项。 | `lib/pages/achievements_page.dart:389` 在一整行内均分 3 列，每列在横向使用 `Row(Icon, Label)`，导致文本可用宽度仅剩 ~70dp，长英文单词必截断；<br>成就项视觉层级缺乏游戏奖励质感。 |
| **20-16-25 / 20-16-29**<br>**20-17-00 / 20-17-02** | 游戏设置 (Settings) | 中 / 英 | ① **棋盘模式（碎片初始排布）换行且孤立**：上方的吸附、震动、网格均为单行 SwitchListTile，排布模式却在 ListTile 下方单独起了一行 SegmentedButton，滚动时被截断孤立在屏幕顶端；<br>② **语言选择严重挤压**：3 个选项的 SegmentedButton 在英文下 ("Follow System / Simplified Chinese / English") 严重贴边变形。 | `lib/pages/settings_page.dart:211-255, 310-350`：<br>① 未将双态排布模式作为 `trailing` 紧凑控件，而是强行写成上下双层布局，破坏列表韵律；<br>② 手机端不适合在水平 SegmentedButton 内放置 3 个长英文选项，`FittedBox` 导致字号被极端缩小。 |

---

## 二、中英文字体一致性与排版规范化方案

### 2.1 为什么中英文字体看起来“粗细不均、大小不同”？
1. **光学黑度（Optical Density）差异**：
   - 中文字符平均包含 8~12 画，在字框（Em-square）内填充率高，视觉黑度大；
   - 英文单词由离散的拉丁字母组成，字母内部留白大（如 `o, e, a, c`），在相同字号（如 14sp）和字重（w600）下，**中文看起来明显比英文重一档**。
2. **Android 系统字体回退链脱节**：
   - `main.dart` 中仅配置了 `fontFamilyFallback: ['Microsoft YaHei', 'PingFang SC', 'sans-serif']`；
   - 在 Android 设备上，`Microsoft YaHei` 与 `PingFang SC` 均不存在，Flutter 降级使用系统默认的 **Roboto（西文）** + **Noto Sans CJK SC（汉字）**；
   - Roboto 与 Noto Sans SC 的 x-height（小写字母高度占比）与中文字盘比不一致，且 Android 对 Noto Sans SC 的粗体常采用合成加粗（Synthetic Faux-bold），导致中文字符边缘发涨，而英文 Roboto 字形细长瘦削。

### 2.2 解决方案：双语光学平衡字阶（Locale-Aware Typography）

通过扩展 `AppTextStyles`，根据当前语言动态调整 `fontWeight` 与 `fontSize` 的微调补偿，达成视觉上的均重与和谐。

```dart
/// lib/theme/app_text_styles.dart 优化升级
class AppTextStyles {
  const AppTextStyles._({required this.palette, required this.isZh});

  final AppPalette palette;
  final bool isZh;

  static AppTextStyles of(BuildContext context) {
    final isZh = LocaleSettings.instance.currentLocale == AppLocale.zh;
    return AppTextStyles._(
      palette: AppPalette.of(context),
      isZh: isZh,
    );
  }

  // ── H1 页面大标题 ──
  // 中文笔画重，采用 w600 (Semi-Bold) 防止黑度过大；
  // 英文留白多，采用 w700 (Bold) 增强主标题视觉压迫感，字号微调至 24sp
  TextStyle get h1 => TextStyle(
    fontSize: isZh ? 24 : 23,
    fontWeight: isZh ? FontWeight.w600 : FontWeight.w700,
    letterSpacing: isZh ? -0.2 : -0.5,
    height: 1.25,
    color: palette.primaryText,
  );

  // ── H2 模块标题 ──
  TextStyle get h2 => TextStyle(
    fontSize: isZh ? 18 : 17,
    fontWeight: isZh ? FontWeight.w600 : FontWeight.w700,
    letterSpacing: isZh ? 0.0 : -0.3,
    height: 1.3,
    color: palette.primaryText,
  );

  // ── Body 正文 ──
  // 英文 14sp 略显偏小，西文环境补偿 +0.5sp
  TextStyle get body => TextStyle(
    fontSize: isZh ? 14 : 14.5,
    fontWeight: FontWeight.w400,
    letterSpacing: isZh ? 0.2 : 0.1,
    height: 1.45,
    color: palette.primaryText,
  );

  // ── Body Bold 强调 ──
  TextStyle get bodyBold => TextStyle(
    fontSize: isZh ? 14 : 14.5,
    fontWeight: isZh ? FontWeight.w600 : FontWeight.w650,
    letterSpacing: isZh ? 0.1 : 0.0,
    height: 1.45,
    color: palette.primaryText,
  );

  // ── Caption 辅助说明 ──
  // 英文辅助文字使用 w500 保证清晰度，行高严格控制在 1.35
  TextStyle get caption => TextStyle(
    fontSize: isZh ? 12 : 11.5,
    fontWeight: isZh ? FontWeight.w400 : FontWeight.w450,
    letterSpacing: isZh ? 0.2 : 0.1,
    height: 1.35,
    color: palette.secondaryText,
  );

  // ── Tab 标签字体专用 ──
  TextStyle get tabLabel => TextStyle(
    fontSize: isZh ? 14 : 13,
    fontWeight: isZh ? FontWeight.w600 : FontWeight.w700,
    letterSpacing: isZh ? 0.2 : -0.2,
  );
}
```

### 2.3 数字与符号排版规范
1. **等宽对齐**：所有时间（`01:26`）、碎片数（`24/48`）、金币（`+100`）必须统一配置 `fontFeatures: const [FontFeature.tabularFigures()]`，防止数字跳动。
2. **单位后缀一体化**：严禁把数字和单位（如 `0` 和 `秒`、`0` 和 `s`）拆成不同样式分别渲染。统一通过 slang 参数格式化为单个字符串（如 `0s` 或 `0 秒`），保持排版基线一致。

---

## 三、设置界面重构：彻底根治排布模式换行与语言选择挤压

### 3.1 现状缺陷深度复盘
在当前 `lib/pages/settings_page.dart` 中：
- 音效、触感、网格预览采用统一的 `SwitchListTile`，右侧 Trailing 对齐，节奏清爽；
- **碎片初始排布模式**（棋盘模式）：却在 `ListTile` 下方插入 `Padding(child: Align(alignment: Alignment.centerLeft, child: SegmentedButton<String>))`；
  - 这导致该项高度达 110dp+，且分段按钮靠左悬空，打破了右侧对齐的视觉中轴；
  - 屏幕向下滚动时，由于容器高度过大，该组件被视口硬生生裁切在最上方（截图 20-16-29），显得支离破碎。
- **语言选择**：3 项分段按钮（跟随系统 / 简体中文 / English），在 360dp 手机上无论怎么算，英文 `Simplified Chinese`（18 个字符）都无法在 1/3 宽度内舒适展现，`FittedBox` 把文字挤压成小蚂蚁，且底部贴卡片边沿。

### 3.2 优化落地方案

#### 方案 A：碎片初始排布模式 —— 收敛为紧凑型 Trailing Pill Toggle（强烈推荐）
将模式切换收敛为 `ListTile` 的 `trailing` 控件，恢复与上方三个 Switch 完全统一的右对齐韵律。

```dart
// 在 SettingsPage 中重构排布模式项：
ListTile(
  leading: Icon(PhosphorIconsBold.squaresFour, color: palette.brand),
  title: Text(t.settings.scatterModeTitle, style: styles.bodyBold),
  subtitle: Text(
    _repo.pieceScatterMode == 'tabletop'
        ? t.settings.scatterModeDescTabletop
        : t.settings.scatterModeDescTray,
    style: styles.caption,
  ),
  trailing: _CompactModeToggle(
    currentMode: _repo.pieceScatterMode,
    onChanged: (mode) => setState(() => _repo.pieceScatterMode = mode),
    palette: palette,
  ),
)
```

`_CompactModeToggle` 组件规格设计：
- 采用内嵌式胶囊外框（高 34dp，宽 128dp，圆角 17dp），内含两个紧凑分段；
- 选态带浅阴影与品牌色高亮，未选态保持半透明中性灰；
- 中文显示：`[ 托盘 | 桌面 ]`；英文显示：`[ Tray | Table ]`；
- **成效**：整行高度从 110dp 降至 64dp，与 SwitchListTile 完全等高，右边缘对齐严丝合缝，再也不会滚动断层！

#### 方案 B：语言设置 —— 升级为“弹窗选择器 / BottomSheet”（业界成熟范式）
彻底取缔 3 选项横向 SegmentedButton，改用原生 Settings 标准的「二级选择面板」。

```dart
// SettingsPage 语言入口改为标准列表项：
ListTile(
  leading: Icon(PhosphorIconsBold.translate, color: palette.brand),
  title: Text(t.settings.languageTitle, style: styles.bodyBold),
  subtitle: Text(_getLanguageSubtitle(), style: styles.caption),
  trailing: Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      Text(
        _getCurrentLanguageName(),
        style: styles.captionBold.copyWith(color: palette.brand),
      ),
      const SizedBox(width: 4),
      Icon(PhosphorIconsBold.caretRight, size: 16, color: palette.secondaryText),
    ],
  ),
  onTap: () => _showLanguageSelectionSheet(context),
)
```

**弹窗底板（Language BottomSheet）设计**：
- 采用 24dp 顶圆角弹窗，内含 3 个选项：
  1. 🌐 跟随系统 / Follow System
  2. 🇨🇳 简体中文 / Simplified Chinese
  3. 🇺🇸 English
- 单选 Radio 位于右侧，选中有平滑缩放反馈与即时语言重载；
- **成效**：设置主界面极为规整，彻底释放横向空间，支持未来任意新增语言扩展。

---

## 四、胜利结算弹窗美化方案 (Victory Dialog)

### 4.1 技术与功能 Bug 清除（强制执行）
1. **彻底消除黄色双下划线**：
   - 原因：`showDialog` 内部返回的根组件缺少 Material。
   - 修复：在 `VictoryDialog` 根树中，将顶层 `Container` 替换为：
     ```dart
     Material(
       type: MaterialType.transparency,
       child: Stack(
         children: [ ... ],
       ),
     )
     ```
     彻底让所有 `Text` 继承标准 `DefaultTextStyle` 与无下划线文本修饰。
2. **修复单复数语法与硬编码**：
   - 在 `strings.i18n.json` 与 `zh.i18n.json` 中配置 plural：
     - en: `stars(count): "{count} Star" | "{count} Stars"`
     - zh: `stars(count): "{count} 星评价"`
   - `victory_dialog.dart:512` 修复：
     ```dart
     // 错误: a.title
     // 修复: a.localizedTitle
     '${t.victory.newAchievements(count: widget.newAchievements.length)}: '
     '${widget.newAchievements.map((a) => a.localizedTitle).join(", ")}'
     ```

### 4.2 胜利视觉氛围与层级美化重构

```
旧版界面（冷冰、粗糙、黄色划线）          全新设计（温暖、治愈、层次丰富）
┌─────────────────────────────────┐      ┌─────────────────────────────────┐
│              [X]                │      │              ( X ) 柔和关闭按钮 │
│       Puzzle Complete!          │      │     ✨ VICTORY / 拼图完成 ✨    │
│       ────────────────          │      │        [ 300ms 渐变暖光 ]       │
│         [ 宠物猫图片 ]          │      │    ┌───────────────────────┐    │
│                                 │      │    │  木质柔光外框 + 投影  │    │
│           ★  ☆  ☆               │      │    │      宠物猫图片       │    │
│           1 Stars               │      │    └───────────────────────┘    │
│ ┌─────────────────────────────┐ │      │         ★     ★     ★           │
│ │ ⏱ Time │ 🧩 24 │ 🪙 +5     │ │      │       ( 依次弹性弹跳动画 )      │
│ └─────────────────────────────┘ │      │   ┌─────────┬─────────┬─────────┐   │
│ [🏆 2 new achievements: ...]    │      │   │ ⏱ 01:26 │ 🧩 24片 │ 🪙 +10  │   │
│ ┌───────────────┬─────────────┐ │      │   └─────────┴─────────┴─────────┘   │
│ │    Exit       │ Next Level  │ │      │   🎖️ [新成就] 巧妙解法 · +50金币   │
│ ├───────────────┼─────────────┤ │      │   ┌─────────────────────────────┐   │
│ │ Save Wallp... │ Share       │ │      │   │   ▶ 下一关 / Next Level     │   │
│ └───────────────┴─────────────┘ │      │   └─────────────────────────────┘   │
│           View Puzzle           │      │    [ 💾 保存壁纸 ]   [ 📤 分享 ]    │
└─────────────────────────────────┘      └─────────────────────────────────┘
```

#### 具体视觉提升细则：
1. **完成图画框质感**：
   - 移除生硬单色的 4px 橙黄色线框，升级为双层阴影容器：内层 12dp 倒角图片 + 外层 4dp 暖白/原木微边框 + `BoxShadow(color: brand.withValues(alpha: 0.15), blurRadius: 24, spreadRadius: 2)`；
2. **星级动效升级**：
   - 3 颗大星（42dp）从左至右以 300ms 间隔带有 `Curves.elasticOut` 弹性缩放进入，亮起伴随极轻微金色碎星粒子扩散；
3. **战报数据徽章（Stat Pill Cards）**：
   - 放弃带细横线割裂的白板容器，改为 3 枚平分悬浮的 **浅米色独立圆角胶囊**；
   - 格式：上图标（18dp）+ 下单行等宽大字（18sp Bold），中英文皆无需长标签，彻底杜绝换行与溢出；
4. **成就解锁高光卡**：
   - 若本局解锁新成就，展示带有金黄色平滑扫光边框的横幅，成就名以独立标签 Chip 形式包裹，支持横向换行展示；
5. **按钮行为树优化**：
   - 主操作（Next Level）：全宽 52dp 高度品牌渐变实心大按钮，字号 16sp Bold；
   - 次操作（Save & Share）：并在主按钮下方，横向平分双 Outline 按钮（高 40dp）；
   - 查看画板：底部最克制的文字链接（TextButton），点击退出弹窗回到画板全貌。

---

## 五、成就与统计页面全面重构 (Achievements Page)

### 5.1 数据看板（KPI Stats）截断彻底根除
#### 痛点代码审计：
当前 `_StatMetricItem` 在横向排版中写死：
```dart
Row(
  children: [
    Icon(icon, size: 14),
    Text(label, maxLines: 1, overflow: TextOverflow.ellipsis), // 剩余空间仅 ~70dp
  ],
)
```
在英文下，`Puzzles Solved`（14 字符）、`Pieces Snapped`（14 字符）、`Total Play Time`（15 字符）必然被裁切为 `Puzzles Solv...`。

#### 重构为「垂直 KPI 数据网格」：
放弃横向并排图标与文字，改为标准的 **指标看板纵向架构**：
```
┌─────────────────┐
│     [图标]      │   16dp 品牌色或分类强调色
│       100       │   22sp Bold 等宽数字，视觉重心
│  Pieces Snapped │   11sp 辅助文字，允许换行，居中对齐
└─────────────────┘
```
- **核心优势**：
  - 数值作为最关键信息位于第一视觉中心；
  - 标签置于底部，即使在 80dp 宽度下，英文也可自然折为两行（如 `Pieces` / `Snapped`），行高 1.15，**没有任何省略号，信息完备率 100%**；
  - 中文下同样紧凑美观。

### 5.2 成就勋章墙游戏化质感改造
#### 现状问题：
- 灰底 + 灰锁 + 细线灰进度条，整体灰蒙蒙，无任何激励感知；
- 缺少筛选（All / In Progress / Unlocked），当有 25 项成就时用户翻找困难。

#### 重构设计方案：
1. **成就分级与徽章质感**：
   - 引入 3 阶成就底色：普通（铜褐）、进阶（银蓝）、传奇（金橙）；
   - 未解锁状态：不是置灰，而是采用 **神秘剪影模式（Silhouette）**，半透明呈现成就图标轮廓，右下角附带小锁标；
   - 进度展示：进度条高度增至 6dp，使用圆角胶囊样式，右侧标注明确的完成度：`12 / 50` 及百分比；
   - 奖励悬赏显性化：未解锁卡片右上角直观标出悬赏奖励（如 `🪙 +50`），强力驱动玩家挑战；
2. **解锁待领取状态**：
   - 带有呼吸光圈与金色边框，右侧提供醒目的 `领取 / Claim` 按钮，领取时触发金币飞入音效与动画；
3. **顶部分类 Filter Chips**：
   - 在成就勋章墙上方增加横向筛选栏：`全部 (25)`、`进行中 (8)`、`已达成 (3)`，帮助玩家清晰聚焦目标。

---

## 六、我的拼图 (My Center) 与 Tab 栏截断治理

### 6.1 解决子 Tab 栏（In Progre...）截断
#### 根因：
在 `lib/pages/tabs/my_center_tab_view.dart:436`：
```dart
// 错误设置：均分 4 列，无法承载带计数英文
TabBar(
  tabs: [
    Tab(text: tr.myCenter.tabs.inProgress(count: ...)), // "In Progress (0)"
    Tab(text: tr.myCenter.tabs.favorites(count: ...)),  // "Favorites (0)"
    Tab(text: tr.myCenter.tabs.completed(count: ...)),  // "Completed (0)"
    Tab(text: tr.myCenter.tabs.custom(count: ...)),     // "Custom (3)"
  ],
)
```

#### 解决方案：短词标签 + 独立角标胶囊（Dual-Track Tab）
1. **精简英文 Tab 文案**（在 `strings.i18n.json` 中调整）：
   - `inProgress`: 中文 `进行中`，英文统一缩短为 `Active`（代替臃肿的 `In Progress`）；
   - `favorites`: 中文 `收藏`，英文 `Saved`（代替 `Favorites`）；
   - `completed`: 中文 `已完成`，英文 `Done`（代替 `Completed`）；
   - `custom`: 中文 `自制`，英文 `Custom`；
2. **将数字与文字解耦**：
   - 在 Tab 内使用自定义 Widget，将数字变为右上角轻量 Badge，或在 `TabBar` 开启 `isScrollable: true, tabAlignment: TabAlignment.center`；
   - 实测在 `Active (0)`、`Saved (0)`、`Done (0)`、`Custom (3)` 结构下，4 个 Tab 完全可以在 360dp 手机屏幕内舒适展开，**文字截断彻底归零**。

### 6.2 顶部 4 大创作入口与空状态美化
1. **快捷入口卡片排版**：
   - 英文副标题（"0 images", "Custom", "Search"）通过设置 `maxLines: 1` + 统一 11sp 字号，与主标题（13sp Semi-Bold）形成清晰主次关系；
2. **空状态页面治愈系升级**：
   - 替换当前突兀的亮绿色单色拼图图标；
   - 引入原画风格的小狐狸吉祥物插画或带有暖色底晕的米白色拼图图标；
   - 文案增添情感化温度：
     - 中文：`还没有正在进行的拼图呢` / `选一张心仪的画作，开始拼图之旅吧~`
     - 英文：`No active puzzles yet` / `Pick a beautiful picture to start relaxing!`

---

## 七、双语穿透与漏译治理清单 (i18n Scrubbing)

对现存代码中未调用 slang 翻译的盲区进行清单式清查与修正：

### 7.1 每日挑战 (`lib/pages/tabs/daily_tab_view.dart`)
- **行 506**：`Text('${now.month} 月 ${now.day} 日')`  
  👉 改造为 `Text(t.daily.dateCaption(month: now.month, day: now.day))`
- **行 515**：`Text('${now.month}月${now.day}日 · 今日挑战')`  
  👉 改造为 `Text(t.daily.todayTitle(month: now.month, day: now.day))`
- **行 537-541**：按钮文字硬编码 `'已通关 (重玩)' : '继续挑战' : '开始挑战'`  
  👉 改造为 `t.daily.btnClearedReplay` / `t.daily.btnResume` / `t.daily.btnStart`
- **行 613**：`Text('每日总进度: $totalCompletedCount/$totalVisibleCount')`  
  👉 改造为 `Text(t.daily.totalProgress(done: totalCompletedCount, total: totalVisibleCount))`
- **行 846**：`Text('已完成 $completedCount/${monthItems.length}')`  
  👉 改造为 `Text(t.daily.monthCompleted(done: completedCount, total: monthItems.length))`
- **行 711, 732, 746**：加载与下载关卡文字硬编码  
  👉 接入 `t.daily.loadingMonth` / `t.daily.loadMonthFailed` / `t.daily.downloadMonth`

### 7.2 图集画册 (`lib/pages/tabs/collections_tab_view.dart`)
- **行 115, 118**：活动卡片默认描述与角标 `'限时活动挑战'`、`'限时活动'`  
  👉 接入 `t.events.descFallback` 与 `t.events.badgeLimited`
- **行 418**：关卡数角标 `'$effectiveCount关'`  
  👉 改造为 `t.collections.levelCount(count: effectiveCount)`
- **行 65, 75**：下载提示 Toast 包含中文  
  👉 改造为 `t.collections.toastReady(title: item.displayTitle)`
- **行 223-234**：图集空状态与刷新文字  
  👉 接入 `t.collections.emptyAll`、`t.collections.emptyHint`

### 7.3 首页 (`lib/pages/tabs/home_tab_view.dart`)
- **轮播图右侧卡片 Badge 截断**：
  - 检查并修改 Badge 内边距：`EdgeInsets.symmetric(horizontal: 8, vertical: 3)`，将字体由固定大小改为允许 `FittedBox` 柔和缩放，防止 `★ Limited-` 截断。

---

## 八、全局设计系统 Tokens 规范（一致性基础）

为确保所有页面（首页、每日、图集、我的、设置、结算、成就）保持统一的视觉语调，全工程强制执行以下规范 Token：

### 8.1 调色板系统 (Palette)
- **品牌主色 (Brand Primary)**：`#D4963C`（温润暖金），次主色 `#BF7C28`；
- **页面底色 (Surface)**：`#FAF7F2`（温暖木纹浅底），深色模式 `#1E1B18`；
- **卡片底色 (Surface Container)**：`#FFFFFF`（纯白带暖感微光），深色模式 `#2A2622`；
- **分割线与边框 (Divider / Border)**：`#EADECF`（微浅米色，透明度 0.8）；
- **主文本 (Primary Text)**：`#2E2721`（暖碳深褐，避免纯黑死板）；
- **次文本 (Secondary Text)**：`#8C8074`（温润中灰褐）。

### 8.2 圆角阶梯 (Radii)
- **Small (8dp)**：微型 Badge、内部下载进度角标；
- **Medium (12dp)**：按钮 Segment、卡片内部子元素；
- **Large (16dp)**：主列表卡片、通用面板；
- **Pill (999dp)**：所有操作胶囊、Tag 分类 Chip、Trailing 切换开关。

### 8.3 交互尺寸标准 (Touch Target Standard)
- 所有独立可点击图标/按钮，最小热区不小于 **48 × 48 dp**；
- 列表项高度统一下限：标准开关/跳转项为 **60~64dp**，杜绝 110dp+ 的单项巨型畸形容器。

---

## 九、实施路线与分步验证方案 (Implementation Roadmap)

| 阶段 | 核心任务 | 交付物与验证指标 | 影响范围 |
|:---|:---|:---|:---|
| **Phase 1<br>(紧急修复)** | ① 移除 `VictoryDialog` 黄色双下划线，补全 `Material`；<br>② 修复 `victory_dialog.dart:512` 成就多语言字段；<br>③ 修复单复数 `1 Star` 语法；<br>④ 改造 `SettingsPage` 棋盘模式为 Trailing 紧凑开关，语言设置改为 BottomSheet；<br>⑤ 修正 `DailyTabView` 与 `CollectionsTabView` 的硬编码漏译。 | • 截图验证：胜利弹窗下划线消失；<br>• 截图验证：设置页棋盘模式不换行、滚动不碎裂；<br>• 英文模式下无中文残留。 | `victory_dialog.dart`<br>`settings_page.dart`<br>`daily_tab_view.dart`<br>`collections_tab_view.dart` |
| **Phase 2<br>(排版与防截断)** | ① 改造 `MyCenterTabView` 子 Tab 栏（`Active`、`Saved`、`Done`、`Custom`）彻底解除截断；<br>② 改造 `AchievementsPage` 数据看板为垂直 KPI 网格（无横向文本截断）；<br>③ 扩展 `AppTextStyles` 加入中英文光学字重与字号微调。 | • 英文模式下 `My Center` 与 `Achievements` 没有任何省略号 `...`；<br>• 360dp 物理分辨率设备上视觉无溢出。 | `my_center_tab_view.dart`<br>`achievements_page.dart`<br>`app_text_styles.dart` |
| **Phase 3<br>(美化与体验提升)** | ① 胜利结算页全套视觉升级（木纹相框投影、弹跳星级动效、胶囊战报、整洁按钮组）；<br>② 成就墙勋章化升级（分级轮廓态、悬赏预览、过滤筛选 Chip）；<br>③ 我的中心空状态情感化吉祥物升级。 | • 游戏胜利氛围浓厚，界面达到现代商业益智游戏第一梯队美学水准；<br>• 用户收集成就动机显著提升。 | `victory_dialog.dart`<br>`achievements_page.dart`<br>`main.dart` (Theme) |

---

## 十、总结

本方案针对用户反馈的“双语后变丑、字体粗细大小不一、字符太长截断、设置页棋盘模式换行、胜利结算和成就页不好看”等痛点进行了**零盲区审计**，并给出了具备**代码级可落地性**的整改标准。从底层架构修复、组件交互提炼到视觉氛围渲染，全面消除了原本拼凑松散的工业感，让 App 在中英文两种语言环境下皆能呈现出**高度一致、精致治愈、严谨规整**的高品质游戏体验。
