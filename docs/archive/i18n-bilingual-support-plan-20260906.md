# 游戏 App 中英文双语支持方案 (slang) (2026-09-06)

> 状态：**草案，待逐项拍板（已由 gen_l10n ARB 方案切换至 slang 方案）**。
> 背景：commit `00060ad` 已完成「内容侧双语」（`event`/`collection` 的 `titleZh`/`descZh`、`Tag` 本地化、`LocaleHelper`）。本文覆盖**整体策略与 UI 静态文案**，与内容侧衔接，技术栈由官方 `gen_l10n` 调整为 `slang`。
> 约定：目标仅 `zh-CN` / `en-US`（`AGENTS.md`），`zh` 覆盖全部 `zh-*`（含 `zh-TW/HK` 按简体处理）。

---

## 1. 现状盘点（源码回溯结论）

| 方面 | 现状 |
|---|---|
| 本地化基建 | 无 `flutter_localizations` / `intl` / `generate: true`；无 `l10n.yaml`；无 ARB/JSON；`lib/l10n` 目录不存在 |
| 入口 | `lib/main.dart:180` 仅一个 `MaterialApp`，未配置 `localizationsDelegates` / `supportedLocales` / `locale`；`title` 硬编码 `'异形拼图 Jigsaw Puzzle'` |
| 语言判定 | `lib/utils/locale_helper.dart:11` 静态 `overrideLanguageCode` + 读 `platformDispatcher.locale`，仅供测试，无持久化覆盖；`isChinese` / `currentLanguageCode` / `getLocalizedTagName` / `getLocalizedHomeTags` 已落地 |
| 设置持久化 | `SharedPreferences`（`GameRepository` 统一管理，键 `jigsaw_setting_*`：`sound`/`haptic`/`gridPreview`/`scatterMode`/`background`）；Hive 仅存进度类数据 |
| 状态架构 | 全工程**单例服务**模式（`StorageManager`/`EconomyService`/`AchievementStore`…）；`pubspec.yaml:42` 虽依赖 `flutter_riverpod` 但代码未用 `ProviderScope` |
| UI 文案量 | 粗扫：`lib` 含中文的字符串字面量 **769 处 / 44 文件**；`puzzle_tags.dart` 212 处为 SSOT 标签映射（数据，不迁移）；剩余 ~557 处中 UI 页面/组件/toast 约 **400+ 处**（`settings` 41、`my_center` 33、`choose_difficulty` 28、`achievements` 22、`victory_dialog` 17、`game_page` 16 等） |
| 模型层硬编码盲区 | `lib/services/achievement_service.dart:53` 25 项成就 `title`/`description`中文常量；`lib/logic/puzzle_model.dart:24` `1:1 正方形`等 5 项 `label`、`148` `tierTag` 8 档、`195` `estimatedMinutes`；`lib/logic/content/models/puzzle_collection_item.dart:116` `displayTypeLabel`；`lib/data/game_repository.dart:175` `第 $i 关`与样例拼图标题；`lib/pages/game_page.dart:669` `_pageTitle` |
| 字体 | `fontFamilyFallback` 微软雅黑/苹方，中文无缺字，英文无风险 |
| 测试 | widget 测试大量断言中文文案（`HowToPlay`/`SettingsPage`/成就页），迁移需同步改造 |
| 内容侧衔接 | `PuzzleCollectionItem`/`PuzzleEventItem` 的 `localizedTitle/displayTitle`、Tag 双语已按系统语言生效，但无用户覆盖层 |

**规模判断**：去重后一期 UI 键 ~250–350 个；全量（含攻略、导入/裁切、分享、次要 toast）约 450–550 键。

---

## 2. 技术选型对比与 slang 推荐理由

### 2.1 候选对比

| 方案 | 官方 | 类型安全 | 无需 BuildContext | 依赖重量 | 学习成本 | 与本项目契合度 |
|---|---|---|---|---|---|---|
| `gen_l10n` (ARB) | 是 | 是 | 否（`AppLocalizations.of(context)`） | 重（`intl`+`flutter_localizations`） | 低 | 稳妥但模型层需额外代理 |
| **`slang` (JSON)** | 否 | 是 | **是**（`t.xxx` 全局 + `context.t`） | 轻（零 `intl` 按需） | 中 | **最高**：单例/纯 Dart 层可直接取词 |
| `easy_localization` (JSON) | 否 | 否（`tr()` 字符串） | 是 | 中 | 低 | 可 OTA 但无类型保障 |

### 2.2 为何选 slang

1. **单例架构友好**：本项目全为单例服务，`gen_l10n` 要求 `BuildContext` 才能取词，`achievement_service.dart` / `puzzle_model.dart` 等纯 Dart 层无法直接翻译；`slang` 的全局 `t` 对象可在 `Service`/`Model` 中直接调用，贴合现有 `LocaleHelper` 静态调用习惯，迁移阻力最小。
2. **模型层解耦**：成就 25 项、难度 8 档等不应在定义处硬编码中文，`slang` 可让定义表仅保留 `id/key`，渲染时 `t.achievements.first_win.title`，彻底消除 `lib/services/achievement_service.dart:53` 等盲区；`gen_l10n` 需手写 `GlobalKey<NavigatorState>` 取 `context` 的变通。
3. **轻量与可维护**：无需 `flutter_localizations` 全量 delegates、`l10n.yaml` 与 ARB 的 `@@` 元数据；JSON 直观、`slang.yaml` 配置少、`dart run slang` 生成代码可读；`untranslated` 缺译检测、`plural`/`param` 与 ARB 等价。
4. **与内容侧一致**：内容侧 `titleZh/descZh` 保留字段双语，UI 侧 `slang` 统一通过 `LocaleService.effectiveLocale` 判定，同一真源即时生效。
5. **风险可控**：`slang` 周下载 30k+、Flutter 官方 Showcase 引用，API 稳定；仅两语且无日期格式化，不依赖 `intl` 重型能力，回退到 `gen_l10n` 成本低（JSON→ARB 可脚本转换）。

> 不推荐：手写 `Map` / `isChinese` 双分支（失去工具链与缺译检测）。

---

## 3. 总体架构（slang）

### 3.1 依赖与配置

`pubspec.yaml`：

```yaml
dependencies:
  slang: ^4.7.0
  slang_flutter: ^4.7.0

dev_dependencies:
  slang_build_runner: ^4.7.0
  build_runner: ^2.4.0
flutter:
  generate: false # slang 不使用官方 generate
```

根目录 `slang.yaml`（推荐）：

```yaml
base_locale: en
fallback_strategy: base_locale
input_directory: lib/l10n
output_directory: lib/l10n/gen
output_format: single_file
translate_var: t
enum_name: AppLocale
locale_access_modifier: private
obfuscation:
  enabled: false
# 可选：严格缺译检查
# strict: true
```

### 3.2 目录与文件

```
lib/l10n/
  strings.i18n.json        # en 基准（slang 约定 base_locale 文件）
  strings_zh.i18n.json     # zh 简中
  gen/
    strings.g.dart         # 生成（勿手改）
    strings_zh.g.dart
lib/services/locale_service.dart  # 新增：唯一真源
lib/utils/locale_helper.dart      # 改造：转发至 LocaleService，标记废弃
```

JSON 按页面/功能命名空间，避免扁平 400 键难维护：

```json
// lib/l10n/strings.i18n.json (en)
{
  "common": { "ok": "OK", "cancel": "Cancel", "confirm": "Confirm" },
  "settings": {
    "title": "Settings",
    "audioHaptics": "Audio & Haptics",
    "language": "Language",
    "language_system": "Follow System",
    "language_zh": "简体中文",
    "language_en": "English"
  },
  "game": { "level_title": "Level {index}", "daily_title": "{date} Daily" },
  "achievements": {
    "first_win": { "title": "First Win", "desc": "Complete your first puzzle" }
  },
  "difficulty": {
    "l1": "Beginner",
    "l1_5": "Beginner+",
    "l3": "Medium",
    "estimatedMinutes": "{range}"
  }
}
```

```json
// lib/l10n/strings_zh.i18n.json
{
  "settings": { "title": "游戏设置", "audioHaptics": "音效与交互" },
  "game": { "level_title": "第 {index} 关" },
  "achievements": { "first_win": { "title": "初露锋芒", "desc": "通关首张拼图" } }
}
```

`slang` 支持占位符 `Hello {name}`、复数 `apple(count: 2)` → `2 apples`，英文复数与数字文案统一走参数化，不引入 `DateFormat`（当前无日期展示，日志时间戳不翻译）。

### 3.3 语言真源与状态流

```
系统语言 (PlatformDispatcher.locale)
        ↓
LocaleService (单例 ChangeNotifier, SharedPreferences jigsaw_setting_language)
  - AppLocale {system, zh, en}
  - effectiveLocale: AppLocale (system→解析系统, 否则显式)
  - effectiveLanguageCode: "zh"/"en" (供非 Widget 层)
  - setLanguage(AppLocale) → persist + notifyListeners()
  - onLocaleChanged 监听（仅 system 模式跟随）
        ↓  1) MaterialApp.locale  2) 内容侧 displayTitle/Tag  3) t 全局
```

* `LocaleHelper` 改造为薄转发：`isChinese()` / `currentLanguageCode` / `getLocalizedTagName` / `getLocalizedHomeTags` 均委托 `LocaleService.instance.effectiveLanguageCode`，`overrideLanguageCode` 标记 `@Deprecated` 仅测试兼容，新增 `LocaleService.overrideForTest` 替代。
* `MaterialApp` 不再需要 `flutter_localizations` delegates；`slang_flutter` 的 `TranslationProvider` 负责重建。

### 3.4 Widget / 非 Widget 取词

```dart
// Widget 层（推荐 context 形式，自动跟随重建）
Text(context.t.settings.title)
Text(t.settings.title) // 全局亦可

// 非 Widget 层（Service/Model，slang 最大优势）
class AchievementDefinition {
  final String id;
  final String titleKey; // 如 'first_win'
  String title(AppLocale locale) => t.achievements[titleKey].title;
}
// 或直接在 UI 渲染时：t.achievements.first_win.title
// puzzle_model.dart: tierTag 改为 key，UI 层 t.difficulty.l3
```

---

## 4. 编号决策项（请逐项拍板）

### 决策 1 — 语言来源策略

- **1-A（推荐）**：跟随系统 + 设置页手动覆盖。默认 `system`；设置页新增「语言 Language」，可选 `跟随系统 / 简体中文 / English`，持久化 `jigsaw_setting_language = system|zh|en`（显式字符串，便于日志与调试）。Android 跟随系统，Windows 桌面可手动切。
- **1-B**：仅跟随系统，零持久化、无设置项。Windows 无法单独切 App 语言。
- **1-C**：不做跟随系统，仅 App 内手动选择。

### 决策 2 — 状态接入方式

- **2-A（推荐）**：轻量 `LocaleService`（单例 `ChangeNotifier` + `SharedPreferences` 持久化 + `TranslationProvider`），`MaterialApp` 外层无需 `ListenableBuilder`，由 `TranslationProvider` + `LocaleSettings.setLocale()` 驱动重建。贴合现有全单例架构，不引入 Riverpod。
- **2-B**：引入 Riverpod provider（依赖已在但全工程未用，成本高，不必要）。
- **2-C**：切换后需重启生效（体验差，不推荐）。

### 决策 3 — UI 与内容双语统一「当前语言」真源

- `LocaleService` 为唯一真源：`effectiveLanguageCode = 用户覆盖 ?? 系统语言`；
- `TranslationProvider` 的 `locale` 与内容侧 `displayTitle` / Tag 双语共用同一判定 → **切语言即时整体生效**，杜绝 UI 英文、内容中文的打架。
- 是否同意此改造方向？（默认同意，无备选分支）

### 决策 4 — 迁移范围与分期

- **4-A（推荐，做减法分三期）**：
  - **0 期（基础设施闭环，约 50 键）**：`slang` 接线 + `LocaleService` + 设置页语言入口 + 1 个页面全链路验证（`settings` + `main_screen`），先让「切语言」本身可演示。
  - **1 期（核心闭环，约 200–250 键）**：主导航与四个 Tab（标题/空态/操作）、对局关键层（`game_page` 顶部与按钮、胜利弹窗 `victory_dialog`、续玩弹窗 `continue_dialog`、难度选择 `choose_difficulty_sheet`、核心 toast）、成就页 `achievements_page`、我的页统计 `my_center_tab_view`。
  - **2 期（长尾，约 150–200 键）**：`HowToPlay` 攻略 `how_to_play_page`、导入/裁切/在线图源、分享卡 `share_card_generator`、下载抽屉 `downloaded_drawer_sheet`、日志查看器 `log_viewer_page`、其余 toast/错误提示。
  - 模型层硬编码（成就 25 项、`puzzle_model.dart` 难度标签）随 1 期一并改造：定义表去中文，改为 `key → t.xxx` 映射。
- **4-B**：一次性全量（~450+ 键，单次改动面过大，与 `game_page` UI 收尾/音频审查并行风险高，不推荐）。
- **4-C**：两期（原方案 4-A 的两期版），可接受但 0 期基础设施与 1 期核心合并后首个 PR 仍偏大。

### 决策 5 — 语言切换入口形态

- **5-A（推荐）**：设置页新增「语言 Language」分组项（贴合现有分组卡片式设置 UI，`lib/pages/settings_page.dart:210` 外观与背景分组附近新增）。
- **5-B**：主屏 `AppBar` 常驻语言图标（快捷但占主屏空间，不符合做减法）。

### 决策 6 — 数字/时间文案处理

- 统一走 `slang` 占位符：`"X 分钟" / "{count} min"`、难度/拼块数等参数化；英文复数用 `slang` plural（`{count, plural, one{1 piece} other{{count} pieces}}`）；
- **不引入** `DateFormat` 等额外格式化（当前 UI 基本无日期展示；日志页时间戳不翻译）。
- 是否同意「数字走参数化、不引入 intl 日期格式化」？（默认同意）

---

## 5. 拍板后的实施步骤

1. `pubspec.yaml` 加 `slang`/`slang_flutter`/`slang_build_runner` + `dart pub get`；
2. 新增 `slang.yaml`、`lib/l10n/strings.i18n.json`（en 基准）/`strings_zh.i18n.json`，首轮仅含 0 期 50 键；`dart run slang` 生成 `lib/l10n/gen/`；
3. 新增 `lib/services/locale_service.dart`：`enum AppLanguage { system, zh, en }`，单例 `ChangeNotifier`，`SharedPreferences` 键 `jigsaw_setting_language`（默认 `system`），`effectiveLocale`/`effectiveLanguageCode`/`setLanguage`/`overrideForTest`，`PlatformDispatcher.onLocaleChanged` 监听（仅 `system` 模式通知）；
4. 改造 `lib/utils/locale_helper.dart:11`：`overrideLanguageCode` 标记废弃并转发至 `LocaleService`，`isChinese`/`currentLanguageCode`/`getLocalizedTagName`/`getLocalizedHomeTags` 改读 `LocaleService` 真源；
5. `lib/main.dart:78` 接线：`main()` 中 `await LocaleService.instance.init()`（在 `StorageManager.openAll` 后、`Group1` 前，避免首帧闪烁），`runApp(TranslationProvider(child: JigsawPuzzleApp()))`，`JigsawPuzzleApp` 内 `MaterialApp(locale: LocaleService.instance.effectiveLocale.flutterLocale)`；
6. 模型层去硬编码（随 1 期）：
   - `lib/services/achievement_service.dart:53`：`AchievementDefinition.title/description` 改 `titleKey/descKey`，UI 层 `t.achievements[def.id].title`；
   - `lib/logic/puzzle_model.dart:22`：`PuzzleAspectRatio.label`/`148` `tierTag`/`195` `estimatedMinutes` 改 key，UI 层 `t.difficulty.l1` / `t.difficulty.estimatedMinutes(range: '1~3')`；
   - `lib/logic/content/models/puzzle_collection_item.dart:116` `displayTypeLabel` 改 `t.collection.type_official/event`；
   - `lib/data/game_repository.dart:175` `第 $i 关` 改 `t.game.level_title(index: i)`；
7. 0 期页面替换（`settings_page` 语言入口 + `main_screen`），每批 `dart format`（仅改动文件）→ `flutter analyze` → 相关测试；
8. 1 期/2 期逐页替换 JSON 键，`dart run slang` 增量生成；
9. 测试策略：新增 `test/l10n_test_wrapper.dart`（包 `TranslationProvider` + 固定 `AppLocale.zh`），现有中文断言测试保持 `zh` 环境继续有效；补 1–2 个英文环境渲染 + 切换用例；所有直接 `pump` 页面的 widget 测试补 `TranslationProvider`；
10. `flutter build windows --debug` + Android 构建验证；
11. 更新本文档决策记录 + `docs/CHANGES-YYYYMMDD.md`。

---

## 6. 键治理与翻译规范

- **命名空间**：`common.*`（通用）、`settings.*`、`home.*`、`collections.*`、`events.*`、`daily.*`、`game.*`、`achievements.*`、`difficulty.*`、`victory.*`、`toast.*`、`import.*`、`share.*`，键名 `snake_case`，JSON 嵌套即命名空间。
- **占位符**：`{count}` / `{index}` / `{range}`，不在代码中拼接 `"第 $i 关"`；英文复数用 `slang` plural 语法。
- **不翻译**：日志、注释、纯数据（`canonicalId`、`zipUrl`）、品牌名 `Jigsaw Puzzle`。
- **缺译检测**：`dart run slang --strict` 或 `slang.yaml` `strict: true`，CI 拦截 `strings_zh` 缺键。

---

## 7. 风险与注意事项

- **测试基建**：`slang` 的 `t` 全局在测试中需 `LocaleSettings` 初始化，未包 `TranslationProvider` 直接 `pump` 会取到默认 `en` 而非预期 `zh` → 先加统一 `l10n_test_wrapper`，随页迁移。
- **英文溢出**：英文普遍比中文长 20–40%，`AppBar` 标题、按钮、`SegmentedButton`、Tab 需预留 `ellipsis` / 可换行 / 字号裕量，1 期即做视觉走查。
- **繁体环境**：`zh-TW/HK` 按 `zh` 展示（一期仅简中，符合约定）；`LocaleService` 中 `languageCode.startsWith('zh')` 统一收敛。
- **品牌与公告**：App 名 `异形拼图 Jigsaw Puzzle` 不翻译；远端 `notice` 双语化属 studio 侧二期可选。
- **回退**：`slang` JSON 与 ARB 可互转，若需切回官方 `gen_l10n`，脚本 `strings.i18n.json → app_en.arb` 即可，业务代码仅替换取词点。

---

## 8. 拍板速查表

| 编号 | 决策 | 推荐 |
|---|---|---|
| 1 | 语言来源策略 | 1-A 跟随系统 + 手动覆盖（`system\|zh\|en`） |
| 2 | 状态接入 | 2-A `LocaleService` 单例 + `TranslationProvider` |
| 3 | 统一语言真源 | 同意改造（`LocaleService` 唯一真源） |
| 4 | 范围与分期 | 4-A 三期（0 基础设施→1 核心→2 长尾） |
| 5 | 切换入口 | 5-A 设置页分组 |
| 6 | 数字/时间处理 | 走 `slang` 参数化/复数，不引入日期格式化 |

---

## 9. 附录

### A. `LocaleService` 接口草案

```dart
enum AppLanguage { system, zh, en }

class LocaleService extends ChangeNotifier {
  static final instance = LocaleService._();
  AppLanguage _language = AppLanguage.system;
  AppLocale get effectiveLocale => ...; // system→解析 PlatformDispatcher
  String get effectiveLanguageCode => effectiveLocale.languageCode; // 'zh'/'en'
  Future<void> init() async { /* read jigsaw_setting_language */ }
  Future<void> setLanguage(AppLanguage v) async { /* persist + LocaleSettings.setLocale() + notify */ }
  @visibleForTesting set overrideForTest(String? code) { ... }
}
```

### B. `main.dart` 接线要点

```dart
void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await StorageManager.instance.openAllWithMemoryFallback();
  await LocaleService.instance.init(); // 必须在 runApp 前
  runApp(TranslationProvider(child: const JigsawPuzzleApp()));
}
class JigsawPuzzleApp extends StatelessWidget {
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: LocaleService.instance,
      builder: (_, __) => MaterialApp(
        locale: LocaleService.instance.effectiveLocale.flutterLocale,
        supportedLocales: AppLocaleUtils.supportedLocales,
        home: const MainScreen(),
      ),
    );
  }
}
```

### C. 变更记录

- 2026-09-06：由 `gen_l10n` ARB 方案切换至 `slang` JSON 方案；新增模型层硬编码治理与三期分期；明确 `AppLanguage` 三态与 `jigsaw_setting_language` 键。
