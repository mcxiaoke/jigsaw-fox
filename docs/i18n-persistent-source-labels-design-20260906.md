# 持久化数据标签「稳定 key」迁移设计 (2026-09-06)

> 状态：**方案草案，待拍板**。
> 背景：UI 静态文案三期（B1/B2/B3）已迁完并提交（`976cf36`）。`lib/` 剩余中文字面量集中在**持久化数据标签**——收藏 `sourceLabelSnapshot`、自制/下载素材的 `sourcePlatform`、自定义拼图默认标题、素材质量档等。切英文后，旧数据与按中文值做的 `==` 判断会导致英文界面残留中文 / 判断失效。
> 决策依据：早前拍板「存储改稳定 key（新写入 + 存量迁移）」而非「仅展示时映射」。本文档为落地前设计。

---

## 1. 现状盘点（值域 × 存储 × 使用面）

### 1.1 值域真源（全部中文 canonical）

| 词汇 | 语义 | 出现文件（读写） |
|---|---|---|
| `主线` | 收藏来源：主机关卡 | `favorite_store.dart`（默认值/反序列化兜底）、`choose_difficulty_sheet.dart`（收藏时推导） |
| `每日` | 收藏来源：每日挑战 | 同上 |
| `自制` | 收藏来源：自制拼图 | 同上 |
| `扩展包` | 收藏来源：扩展图包关卡 | 同上 |
| `本地相册` | 素材/自制来源：本地相册 | `custom_puzzle_item`（默认值+反序列化兜底）、`crop_puzzle_page`（push 默认）、`my_puzzles_tab_view`、`download_manager`、`downloaded_drawer_sheet`（等值判断）、`my_center_tab_view` |
| `相册` | 展示归一标签（旧版写入） | `downloaded_drawer_sheet`（等值判断）、`custom_puzzle_item.displaySource` 输出 |
| `网络` | 素材/自制来源：在线图库 | `online_image_picker_page`（写入）、`my_puzzles_tab_view`（`displaySource == '网络'` 等值）、`custom_puzzle_item`、`game_repository`（样例数据）、`unified_puzzle_resolver` |
| `网络图库` | 下载素材反序列化兜底 | `downloaded_image_item`、`catalog_index`/其它读取面 |
| `官方图集` / `限时活动` | 图集类 sourcePlatform（choose_sheet 展示 & 收藏写入） | `puzzle_collection_item.displayTypeLabel`、`collection_levels_page`（改前）、`catalog_index` |
| `官方预置` | 预置样例来源 | `custom_puzzle_item.fromJson` 兜底 |
| `相册 / 本地` | 图包来源（`sourceType=local_file`） | `puzzle_pack_item.displaySource`（展示为主，不落收藏） |
| 收藏标题兜底 `第 N 关`、样例标题 | 主机关卡标题种子/收藏 titleSnapshot | `game_repository`（种子数据）、`catalog_index`（`第 N 关` 兜底） |

### 1.2 三个存储载体

- **FavoriteStore**（Hive `game-collections-v1`，`favorite:{cid}` 单 key JSON）：`sourceLabelSnapshot`、`titleSnapshot`、`aspectRatioLabel`。
- **GameRepository 自制拼图**（`custom:{id}` 元数据 JSON，`CustomPuzzleItem.toMetadataJson`）：`sourceType` / `sourcePlatform` / `title`。
- **DownloadManager 素材库**（文件/JSON，`DownloadedImageItem`）：`sourcePlatform`。

### 1.3 使用面分类

- **写入点**：`choose_difficulty_sheet` 收藏推导（主线/每日/自制/扩展包 或透传 sourcePlatform）；`crop/my_puzzles/download_manager` 本地相册；`online` 网络；`my_center` 相册选图入口。
- **等值点（== 中文）**：`downloaded_drawer_sheet`（本地相册/相册）、`my_puzzles_tab_view`（`displaySource == '网络'`）、`custom_puzzle_item.displaySource` 内部等值、`downloaded_image_item` 无。
- **显示点**：`downloaded_drawer_sheet`（相册/网络徽章、qualityTag）、`my_puzzles`（来源 chip、displaySource）、`my_center`（收藏卡来源 chip、孤儿兜底）、choose_sheet sourcePlatform chip、收藏分组等。
- **模型归一/兜底点**：`CustomPuzzleItem.fromJson`（sourceType/platform 推导）、`DownloadedImageItem.fromJson`（默认网络图库）、`FavoriteEntry.fromJson`（默认主线）。

---

## 2. 目标稳定 key 词汇

新写入与规范化后的存量统一存**英文 key**，不再落盘任何中文标签：

| key | 语义 | 中文显示 | 英文显示 |
|---|---|---|---|
| `main` | 主线关卡 | 主线 | Main |
| `daily` | 每日挑战 | 每日 | Daily |
| `custom` | 自制拼图 | 自制 | Custom |
| `pack` | 扩展图包 | 扩展包 | Pack |
| `album` | 本地相册素材/自制 | 相册 | Gallery |
| `online` | 网络图源素材/自制 | 网络 | Online |
| `preset` | 官方预置样例 | 官方 | Official |
| `official` | 官方图集 | 官方图集 | Official Collection |
| `event` | 限时活动/活动图集 | 限时活动 | Limited-time |
| `unnamed` | 未命名兜底（标题用） | — | — |

> `sourceType` 既有字段（`gallery/online/preset/local_file`）保留不变，仅作**技术来源**；`sourcePlatform`/`sourceLabelSnapshot` 由「中文展示语」改为上述 key，作为**业务来源类别**。
> 新增 i18n 命名空间 `source.*`（对应上表显示文本），如 `source.main/source.daily/...`。

---

## 3. 方案：单一解析器 + 写入即 key + 读时归一迁移

### 3.1 新增 `lib/logic/source_label.dart`（唯一真源）

```dart
enum SourceLabel {
  main('main'), daily('daily'), custom('custom'), pack('pack'),
  album('album'), online('online'), preset('preset'),
  official('official'), event('event');

  const SourceLabel(this.key);
  final String key;

  /// 解析任意历史/新值 → 稳定 key；未知值回退 main
  static SourceLabel parse(String? raw) {
    switch (raw) {
      case 'main' || '主线' || '官方': return SourceLabel.main;
      case 'daily' || '每日': return SourceLabel.daily;
      case 'custom' || '自制': return SourceLabel.custom;
      case 'pack' || '扩展包': return SourceLabel.pack;
      case 'album' || '相册' || '本地相册' || '相册 / 本地' || 'gallery':
        return SourceLabel.album;
      case 'online' || '网络' || '网络图库': return SourceLabel.online;
      case 'preset' || '官方预置': return SourceLabel.preset;
      case 'official' || '官方图集': return SourceLabel.official;
      case 'event' || '限时活动': return SourceLabel.event;
      default: return SourceLabel.main;
    }
  }

  /// 是否「本地图源」家族（等值判断专用）
  bool get isAlbumLike => this == SourceLabel.album || this == SourceLabel.preset;
  bool get isOnlineLike => this == SourceLabel.online;

  /// 展示文本（走 slang，模型层可直接调用；同 puzzle_model 既有模式）
  String localizedLabel() {
    final tr = LocaleSettings.instance.currentTranslations.source;
    return switch (this) {
      SourceLabel.main => tr.main, ...
    };
  }
}
```

### 3.2 写点改存 key

- `choose_difficulty_sheet` 收藏推导：主线/每日/自制/扩展包 → `SourceLabel.*.key`；透传分支先 `parse(sourcePlatform).key`。
- `crop_puzzle_page` / `my_puzzles_tab_view` / `my_center` / `download_manager` 本地相册默认 → `'album'`。
- `online_image_picker_page` / 网络下载 → `'online'`。
- 模型构造函数默认值同步改 key（`CustomPuzzleItem.sourcePlatform = 'album'`、`DownloadedImageItem` 兜底 `'online'`、`FavoriteEntry.sourceLabelSnapshot = 'main'`）。

### 3.3 存量迁移：读时归一（on-load normalize）

不写一次性批扫脚本，改在 **fromJson/加载路径统一过 `SourceLabel.parse().key`** 后回写：

- `FavoriteEntry.fromJson` → `sourceLabelSnapshot: SourceLabel.parse(json[...]).key`
- `CustomPuzzleItem.fromJson` 兜底推导链 → 产出 key
- `DownloadedImageItem.fromJson` 兜底 → `'online'`

效果：任何旧存档在**首次读取即升级**（内存 key），无需版本号字段；后续 `toJson` 落盘即新 key（惰性持久化）。旧中文不再产生新写盘。

> 说明：在 fromJson 内即转 key，而非仅显示映射，故对业务侧完全透明——等值判断可统一改 `SourceLabel.parse(x) == SourceLabel.album`，不再依赖字面量。

### 3.4 等值/显示点改造

- `downloaded_drawer_sheet`：`sourcePlatform == '本地相册'/'相册'` → `SourceLabel.parse(...).isAlbumLike`；徽章文本 → `t.source.album/online`；qualityTag → 见 §3.5。
- `my_puzzles_tab_view`：`item.displaySource == '网络'` → `SourceLabel.parse(item.sourcePlatform).isOnlineLike`；chip 文本走 `t.source.*`。
- `custom_puzzle_item.displaySource` / `downloaded_image_item.qualityTag` 去中文 → 改输出稳定 key 或 enum + UI 映射（displaySource 同时被 catalog 复用，见 §5 边界）。
- `collection_levels_page` sourcePlatform 传参已走 `collections.typeOfficial/typeEvent` 键；后续统一改 `SourceLabel.parse(displayTypeLabel).key` 并与 `source.*` 打通（displayTypeLabel 改为返回 key，展示处 t 化）。

### 3.5 质量档位（`DownloadedImageItem.qualityTag`）

`qualityTag` 输出中文（4K 超清/…/标清）。新增 enum 化：
```dart
enum ImageQualityTier { q4k, q2k, q1080, q720, sd }
ImageQualityTier get qualityTier => ...; // 阈值逻辑不变
```
UI 侧 `t.downloads.q4k/...` 渲染；`qualityTag` 兼容层删除或仅测试用。`resolutionLabel`（纯数字）不翻译。

---

## 4. 变更文件清单（预估）

| 文件 | 类型 |
|---|---|
| `lib/l10n/en|zh.i18n.json` | 新增 `source`（9 键）+ `downloads.q*`（5 键） |
| `lib/logic/source_label.dart`（新） | 解析器 + 本地化 |
| `lib/data/models/custom_puzzle_item.dart` | 默认值→key、fromJson 归一、displaySource 去中文 |
| `lib/data/models/downloaded_image_item.dart` | 默认值→key、fromJson 归一、qualityTier enum |
| `lib/data/favorite_store.dart` | 默认值→key、fromJson 归一 |
| `lib/widgets/choose_difficulty_sheet.dart` | 收藏来源推导→key |
| `lib/widgets/downloaded_drawer_sheet.dart` | 等值→parse、徽章→t |
| `lib/pages/tabs/my_puzzles_tab_view.dart` | 等值→parse、chip→t |
| `lib/pages/crop_puzzle_page.dart` / `my_center_tab_view.dart` / `download_manager.dart` / `online_image_picker_page.dart` | 写点默认→key |
| `lib/logic/content/models/puzzle_collection_item.dart` | `displayTypeLabel` → key（或保留并在调用面 parse） |
| 测试 | `favorite_store/custom/download/…` 纯单测补 parse/归一用例；widget 测试断言文本已 t 化 |

---

## 5. 边界与暂缓（明确不做）

- **`catalog_index`**：搜索/目录构建里的 `displaySource/displayTypeLabel/第 N 关/自制拼图 · x` 组合，属「搜索数据层」且当前入口未上线；本批只保证其消费的模型 getter 不再输出中文（改 key/本地化），**不重构其组装逻辑**。
- **`game_repository` 样例标题（巴黎埃菲尔铁塔晨曦等）**：种子图片的正式命名，属「内容数据」，与事件/图集内容同体系（二期内容侧双语另立），不在本批迁移；`第 N 关` 标题生成统一在展示侧 t 化（主机关卡已有 `game.titleLevel` 覆盖路径）。
- **`resume_helper` / `level_item` 的 `X 块` 拼接**：进度/规格文案，走既有 `difficulty.pieceCount` 系键，不在本批。
- 不做一次性批扫全量重写存档（读时惰性归一 + 新写入即 key 已收敛存量），避免启动期全量 IO 风险。

---

## 6. 验证与门禁

1. 纯单测：`SourceLabel.parse` 全值域 + 未知回退；`fromJson` 旧值→key 归一（构造旧版 JSON 样本）；qualityTier 阈值。
2. 集成回归：收藏老数据（手写旧 Hive JSON 样本）读入后 chip 为 key、显示走 t；英文环境零中文标签。
3. 门禁：`dart format`（改动文件）→ `flutter analyze` 0 issue → `flutter test` 全绿 → `flutter build windows --debug` → `integration_test -d windows` 1/1。
4. 复用扫描脚本：`lib/` 数据标签中文残留为 0（允许保留清单见 §5）。

---

## 7. 待拍板项

- **A（推荐）**：按本文档 §3 实施（写入 key + fromJson 读时归一 + 等值/显示全改）。
- **B**：仅改写入与等值，存量不归一（切英文后老收藏 chip 可能仍中文，需长期兼容双值）。
- **C**：含一次性启动迁移把 `favorite:/custom:/素材文件` 全量重写为 key（改动面最大，当前无线上存量用户，收益低）。
