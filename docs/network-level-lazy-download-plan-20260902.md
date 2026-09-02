# 网络关卡懒落地统一方案（见缩略必可玩）

- 日期：2026-09-02
- 状态：Draft → 待实施（不做全量 syncAll，改为 Grid 滚动到可视即后台下载）
- 基线：`master` 4afb4ec（含 enum 档位 + 网络封面磁盘缓存）
- 目标：`AppCachedImage` 显示出缩略即代表点击可直接进 `GamePage` 离线可玩；所有 Tab 与 `EventLevelsPage` 内 Grid 均生效

---

## 1. 背景与已审现状

| 链路 | 现状缩略 | 现状游玩 | 结论 |
|---|---|---|---|
| 首页 100 关 `home_tab_view.dart:609` / 每日 `daily_tab_view.dart:201` | `AssetImage+ResizeImage` `app_cached_image.dart:87` 资产恒在线 | `rootBundle.load(assetPath)` `home_tab_view.dart:77` 恒在线 | 无需改动，天然闭环 |
| 活动封面 `events_tab_view.dart:121` `coverUrl` | 本次已改为 `AppCachedNetworkImageProvider` `app_cached_network_image_provider.dart:47` → `getNetworkThumbnailBytes` `image_cache_manager.dart:152` 只存 `thumb_720` | 仅展示，不进游戏 | 封面保持“只存缩略”最省盘，已满足 |
| 活动内关卡 `event_levels_page.dart:175` | Zip：本地 `AppCachedImageProvider`；Array：`http url` 走网络缩略（只存 thumb） | Zip：`File.readAsBytes` 可玩；Array：`_openLevel` 分支 `event_levels_page.dart:55` 需另下一次 `ensureMainLevelDownloaded` `content_manager.dart:126` | **分叉**：缩略一次下载 + 游玩又下一次，且 `缩略可见≠可玩` |
| 首页远端管线 `main_content_pipeline.dart:195` | 同 Array 网络缩略 | `ensureLevelImageDownloaded` `main_content_pipeline.dart:149` 落 `levels/main/<id>.webp` | 同分叉，未被首页消费但应统一 |
| 图包 `pack_levels_page.dart:300` / 我的拼图 `my_puzzles_tab_view.dart:292,306` | 本地 `File` → `AppCachedImageProvider` 恒命中 L2 | `File.readAsBytes` 恒可玩 | 已闭环，无需改 |

`DailyContentPipeline` `daily_content_pipeline.dart:21` 月 Zip 落 `daily/<yyyyMm>/` 与 `GameRepository` 资产兜底脱钩，暂不纳入本方案（每日仍走资产）。

---

## 2. 方案原则

1. **关卡图单次下载、落原图后再缩略**：网络关卡 URL 必下一份原图到 `appDocumentsDir` 管线目录，再由 `ThumbnailGenerator` `thumbnail_generator.dart:114` `File.readAsBytesSync` 同文件生成 `thumb`；缩略与游戏复用同一文件，`getCacheSizeBytes` 已只计 `thumb_*.jpg` `image_cache_manager.dart:308`，原图另目录按现有管线保留
2. **懒落地、可视即触发**：不做 `syncAll` 全量预下；`SliverGrid` `itemBuilder` 构建到可视项时后台 `unawaited(ensure*Downloaded)`，首帧占位 `placeholder`，下载+缩略完成 `setState` 切本地路径后缩略必可玩
3. **复用现有管线目录**：`main → levels/main/<hash>.webp` `main_content_pipeline.dart:204`、`events array →` 复用 `levels/main` 或独立 `events/array_cache`（二选一，本方案选复用 `main` 以去重）、`events zip → events/<id>/` 已落地、`daily → daily/<yyyyMm>/` 已落地
4. **单飞去重与限流**：所有下载经 `EngineTaskQueue` `engine_task_queue.dart:40` 单飞 + 限并发（沿用 `maxConcurrency` 桌面4/移动2），滚动洪峰不阻塞首屏

---

## 3. 详细设计

### 3.1 统一入口

新增 `lib/logic/cache/level_image_resolver.dart`（或直接扩展 `ContentManager`）：
```dart
Future<String> resolveLevelLocalPath(PuzzleLevelItem level) async {
  if (level.isLocalFile && File(level.imagePathOrUrl).existsSync()) return level.imagePathOrUrl;
  if (level.sourceModule == CanonicalId.prefixEvent && level.isArrayType) {
    // 复用 Main 管线落盘（或 events/array_cache）
    final ensured = await AppContent.instance.manager.ensureMainLevelDownloaded(level);
    return ensured.imagePathOrUrl;
  }
  if (level.sourceModule == CanonicalId.prefixMain) {
    final ensured = await AppContent.instance.manager.ensureMainLevelDownloaded(level);
    return ensured.imagePathOrUrl;
  }
  if (level.sourceModule == CanonicalId.prefixDaily) {
    // 按月 Zip 已落则直接返回 file.path，否则触发 ensureMonthReady
  }
  return level.imagePathOrUrl;
}
```
`ImageCacheManager` 不直接碰网络关卡原图下载，避免与管线职责重叠。

### 3.2 卡片层改造（所有 Grid）

抽 `LevelThumbnailCard`/`_buildLevelCard` 为有状态组件：
* `initState` 若 `!isLocalFile` 且 `http`，`unawaited(_ensureAndRefresh())`
* `_ensureAndRefresh`：`localPath = await resolveLevelLocalPath(widget.level)` → `if(mounted) setState(()=>_resolvedPath=localPath)`
* `build`：`_resolvedPath != null ? AppCachedImage(imagePathOrUrl: _resolvedPath)` : `Placeholder`（`CircularProgressIndicator` 20px `app_cached_image.dart:100` 复用）
* 滚动到可视才 `itemBuilder` 创建 → 天然懒触发；`State.dispose` 无需取消（`ensure*` 为幂等 `localFile.existsSync` 快路径 `main_content_pipeline.dart:150`）

覆盖页：
* `home_tab_view.dart:218 _LevelCard`（资产分支保持原样，网络分支走上述）
* `daily_tab_view.dart:274 _buildDailyCard`（同）
* `events_tab_view.dart` 封面保持网络缩略，`event_levels_page.dart:147 _buildLevelCard` 改造为上述
* `pack_levels_page.dart:285 _buildLevelCard` 已本地无需改，仅加防御分支
* `my_puzzles_tab_view.dart:265 _buildCustomGridCard` 对 `assets` 保持，网络 `CustomPuzzleItem` 同理（但现自定义多为本地）

### 3.3 下载与缩略时序

```
Card visible → resolveLevelLocalPath
  → ContentHttpClient.downloadFile(url, localPath) `main_content_pipeline.dart:166`（单次）
  → File.writeAsBytes → _levelsMap[level.id]=copyWith(localPath)
  → _persistToCache `main_content_pipeline.dart:210`
  → setState → AppCachedImageProvider(localPath) → ImageCacheManager.getThumbnailBytes(localPath)
    → L2 未命中 → ThumbnailGenerator.compute(File) → thumb_*.jpg → L1/L2 → 显示
后续点击 _openLevel：直接 File.readAsBytes(localPath) → GamePage，无二次下载
```

若 `Thumb` 已存在而原图被误删，`getThumbnailBytes` 回退读原图失败会重新触发 `ensure*`（幂等）。

### 3.4 并发与容错

* 复用 `EngineTaskQueue` 单飞：同 URL 同档位并发只下一份；`prewarmThumbnails` 仍保留但关卡卡片不再用它
* 限流：管线下载本身为 `async` 串行，配合队列并发 2-4 可控；极端滚动洪峰首屏可见项优先（`SliverChildBuilderDelegate` 按需构建天然限流）
* 失败：`downloadFile` 抛异常 → 卡片保持占位 + `GameToast` 重试按钮 `event_levels_page.dart:118`；离线首访显示 `imageBroken` `app_cached_image.dart:116`，点击提示“需联网首次加载”

### 3.5 存储

* 原图目录无限增（现有管线无 LRU/TTL `image_cache_manager.dart:308` 已只计缩略），本次不新增淘汰，仅在 `settings_page.dart:232` 缩略清理旁文案注明“关卡原图在 `levels/main`/`events`/`daily`，清理缩略不删原图”；后续可加 LRU（按 `File.stat.mtime` 淘汰最旧 20%）

---

## 4. 实施步骤

1. 新增 `level_image_resolver.dart` / 或在 `ContentManager` 加 `resolveLevelLocalPath`
2. 改造 `event_levels_page.dart` `_buildLevelCard` 与 `_openLevel` 前置 `resolve`
3. 改造 `home_tab_view.dart` / `daily_tab_view.dart` 的网络分支（防御性，资产为主）
4. 回归 `my_puzzles` / `pack_levels` 防御分支自测
5. `flutter analyze` + `flutter test test/image_cache_manager_test.dart` + `flutter build windows --debug`

---

## 5. 验收

* 在线首滚：活动 Array 关卡卡片先占位→下载→缩略出现→点击立即进游戏无二次菊花
* 飞行模式复验：已滚过的活动 Array/ Main 列表缩略仍显示且可进游戏；未滚过的显示占位但不崩
* `getCacheSizeBytes` 仍仅计缩略，原图体积通过文件管理器验证落盘

---

## 6. 风险

* 首访缩略延迟比纯网络缩略多 `File.write` 一次 IO（<10ms，可忽略）
* 需联网首访才可玩——符合“见缩略必可玩”定义，不视为缺陷
