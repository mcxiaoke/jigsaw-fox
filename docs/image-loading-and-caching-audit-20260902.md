# 图片加载与缓存全链路审计报告

- 审计日期：2026-09-02 (GMT+8)
- 审计范围：`lib/` 全量 76 个 Dart 文件
- 代码基线：分支 `master`，工作区含 `main_screen.dart` / `home_tab_view.dart` 未提交改动
- 审计方式：静态代码走查 + Dart 3.12.2 实测验证（缓存键哈希）
- 性质：**只读审计，未修改任何 `lib/` 代码**

---

## 修复状态追踪（2026-09-02 实施，见 docs/CHANGES-20260902.md）

| 条目 | 结论 | 状态 |
|---|---|---|
| §7.1 / §7.2 | 全量解码 + 泄漏 | ✅ 已修复：`Image.memory` 补 `cacheWidth`（victory 600 / continue、share、difficulty 1080）；`_decodeImageSize` 改 `ImageDescriptor` 头部探针并 dispose。**GamePage 内 2 处按产品决策保留大图** |
| §7.4 | 缓存无清理入口 | ✅ 已修复：设置页新增「缩略图缓存」占用显示 + 清理按钮（`getFormattedCacheSize` / `clearCache`）；LRU/TTL 淘汰仍未做 |
| §7.7 | 同源多份缩略图 | ✅ 已修复：档位 enum 化 `ThumbnailDimension { card(360), eventCover(720) }`，全部调用点收敛两档；`removeThumbnailForSource` 遍历全部档位 |
| §7.8 | FNV 负号文件名 | ✅ 已修复：掩码改 63 位，实测 5000 路径 0 负号；正数键与旧算法一致（旧缓存可命中） |
| §7.9 | init 失败降级 | ❌ 按用户决策不做（Windows support / Android 私有目录恒可用） |
| §7.3 | 游戏大图绕过缓存 | ❌ 按产品决策保留（GamePage 本就设计用大图） |
| §7.5 / §7.6 / §7.10 / §7.11 / §7.12 | 内容指纹键、NetworkImage 落盘、死参数、批量预热、索引失同步 | ❌ 未实施（低优先级或待后续） |

---

## 0. 结论先行

**一句话结论**：项目中存在**两套互不相通的图片链路**——卡片预览走「三级缩略图缓存」这套精心设计的架构，而拼图游戏大图走「父页面读全量字节 → 通过 Navigator 参数传给 GamePage → 全量解码」的裸链路，**完全不经过任何缓存**。

三个最关键的发现：

| # | 结论 | 证据 |
|---|---|---|
| **1** | 拼图游戏大图 100% 绕过 `ImageCacheManager`，每次进关卡都全量读盘 + 全量解码，无复用 | `game_page.dart:28,184` / `home_tab_view.dart:76` / `pack_levels_page.dart:90` / `event_levels_page.dart:56` / `my_puzzles_tab_view.dart:91` |
| **2** | 6 处 `Image.memory` / `instantiateImageCodec` **未指定降采样尺寸**，按原图分辨率全量解码。超分后 3000×4500 的图单次约 **54 MB** RGBA | `game_page.dart:650,1156`、`victory_dialog.dart:239`、`continue_dialog.dart:110`、`choose_difficulty_sheet.dart:193,437`、`share_card_generator.dart:263` |
| **3** | 三级缓存**只对本地文件生效**。首页 100 关 / 每日挑战卡传的是 `assets/...`（走 `AssetImage`），活动封面传的是远端 URL（走 `NetworkImage`），这两类卡片**根本不进缩略图缓存** | `app_cached_image.dart:80-98` / `home_tab_view.dart:608` / `events_tab_view.dart:121` |

次要但确凿的问题：磁盘缩略图缓存**无淘汰、无 TTL、无容量上限**，而清理入口 `clearCache()` 在整个 `lib/` 中**没有任何调用点**（死代码）。

---

## 1. 存储分层总览

图片在系统里一共存在 **5 个层次**，从持久化到瞬时：

| 层 | 位置 / 载体 | 生命周期 | 容量上限 | 管理者 |
|---|---|---|---|---|
| **L0 源图（持久化）** | 见 §1.1 六个目录 | 永久（手工删除） | 无 | 各业务模块 |
| **L1 缩略图磁盘缓存** | `{appSupportDir}/thumbnail_cache/thumb_<hash>_<dim>.jpg` | 永久 | **无上限 / 无 TTL / 无 LRU** | `ImageCacheManager` |
| **L2 缩略图内存 LRU** | 进程堆内存 `LinkedHashMap<String, Uint8List>` | 进程内 | 150 张 / 30 MB | `MemoryCache` |
| **L3 引擎全局解码缓存** | `PaintingBinding.instance.imageCache`（已解码 `ui.Image`，GPU 侧） | 进程内 | 500 张 / 150 MB | Flutter 引擎（`main.dart:30-31` 调参） |
| **L4 游戏内解码图** | `ui.Image` + 传给 Flame 的 `PuzzleImage` | GamePage 存活期 | **不受任何上限约束** | `GamePage._gameImage` |

> 命名说明：代码注释里把内存 LRU 叫 L1、磁盘叫 L2、调度队列叫 L3（`image_cache_manager.dart:16-19`）。本报告的 L0~L4 是重新编号的物理层次，便于讨论；两者不要混淆。

### 1.1 L0 源图的六个存储目录

| 目录 | 内容 | 写入方 |
|---|---|---|
| `assets/images/sample_*.jpg` | 打包内置样本图（`image_source.dart:7`） | 构建期打包，只读 |
| `{appSupportDir}/download_cache/` | 素材匣：网络下载图 + 本地相册导入图 | `download_manager.dart:82,169` |
| `{appSupportDir}/custom_puzzles/` | 用户自制拼图（裁切 + 可选 2x 超分后的 PNG） | `crop_puzzle_page.dart:305` |
| `{appDocumentsDir}/levels/main/` | 首页主线关卡图（`.webp`，按需懒下载） | `main_content_pipeline.dart:206` |
| `{appDocumentsDir}/events/<eventId>/` | 活动 Zip 解压后的关卡图 | `events_content_pipeline.dart:143,170` |
| `{appDocumentsDir}/packs/` | 扩展图包解压目录 | `content_manager.dart:40` |

另有 `{appDocumentsDir}/daily/` 由 `DailyContentPipeline` 维护（`content_manager.dart:32`），但目前**未被任何 UI 消费**（详见 §4.3）。

---

## 2. 三级缓存核心：`lib/logic/cache/`

### 2.1 `ImageCacheManager`（门面 + 编排）

`image_cache_manager.dart`

**初始化**（`main.dart:54`，在 `runApp` 之前）：
1. 解析 `{appSupportDir}/thumbnail_cache` 目录，不存在则异步创建（`:51-58`）
2. 异步扫描目录重建**磁盘键索引** `_diskKeyIndex`（`:71-87`）——只收录 `thumb_*.jpg` 文件名
3. 记录日志：`Initialized indexed=N concurrency=M`

**设计亮点（确凿成立）**：
- `_diskKeyIndex` 是纯内存 `Set<String>`，判断磁盘命中时不碰文件系统，**主 isolate 全程无 `existsSync`**（`:111-114`）
- 唯一的同步 I/O（`sourceFile.existsSync()` / `readAsBytesSync()`）发生在 `compute()` 派生出的后台 isolate 内（`thumbnail_generator.dart:115-116`），不阻塞 UI

**核心取图流程 `getThumbnailBytes()`（`:123-191`）**：

```
1. L2 内存 LRU 命中？            → 直接返回（0 次 I/O）
2. _diskKeyIndex 命中？          → await file.readAsBytes() → 回填 L2 → 返回
3. 未命中 → EngineTaskQueue.schedule(key) 排队
   3a. 二次双检内存（防止排队期间被别的任务生成）
   3b. compute() 后台 isolate 生成缩略图
   3c. 异步写盘 + _diskKeyIndex.add(key)
   3d. 写入 L2 内存 LRU
```

**缓存键 `getCacheKey()`（`:90-101`）**：
- 算法：FNV-1a 64 位，输入为 **规范化后的文件路径字符串**（`\` → `/`）+ 目标边长
- 格式：`thumb_<16位hex>_<targetDimension>.jpg`
- **键只含路径，不含文件内容指纹 / mtime / size** → 见 §7 问题 4

### 2.2 `MemoryCache`（L2 内存 LRU）

`memory_cache.dart`

| 参数 | 值 | 位置 |
|---|---|---|
| 最大项数 | 150 | `:10` |
| 最大字节 | 30 MB | `:11` |
| 淘汰策略 | LRU（`LinkedHashMap` 移除后重插到尾部） | `:32-39` |
| 单张超限 | > 30 MB 的单张**直接不入缓存** | `:48-51` |

### 2.3 `EngineTaskQueue`（并发调度 + 单飞去重）

`engine_task_queue.dart`

| 特性 | 实现 | 位置 |
|---|---|---|
| Single-Flight 去重 | 同 key 的并发请求复用同一个 `Future` | `:58-63` |
| 并发限流 | 超出并发数进 FIFO 队列，`_pump()` 驱动 | `:82-89` |
| 默认并发数 | Web 2；桌面按核数：≥8 核→4，≥4 核→3，否则 2；移动端 2 | `:40-51` |
| 失败传播 | `completeError`，`finally` 中释放槽位并 `_pump()` | `:100-109` |

### 2.4 `ThumbnailGenerator`（后台 isolate 生成）

`thumbnail_generator.dart`

- 入口 `generateThumbnailBytes()` → `compute(_processThumbnailToBytesIsolate, params)`（`:60`）
- 处理链：`img.decodeImage` → 等比缩放至长边 ≤ `targetDimension`（默认 360）→ `copyResize(interpolation: linear)` → `encodeJpg(quality: 80)`（`:121-148`）
- 附带一个居中裁剪例程 `_processCropToBytesIsolate`（`:197-237`），在 `{1:1, 3:2, 2:3}` 中选面积损失最小的比例；已是标准比例（损失 ≤ 1%）时**原样返回不重编码**

### 2.5 `AppCachedImageProvider`（接入 Flutter ImageProvider 体系）

`app_cached_image_provider.dart`

- `obtainKey` 返回 `SynchronousFuture<AppImageKey>`（`:58-66`）——保证同步拿 key，命中 `ImageCache` 时零额外帧延迟
- `loadImage` 用 `MultiFrameImageStreamCompleter`（`:70-79`）
- `_loadAsync`（`:81-122`）：先走 `ImageCacheManager.getThumbnailBytes`；**若返回空则回退异步读原图**（`:90-95`）；解码时通过 `getTargetSize` 回调把长边钳到 `targetDimension`（`:104-116`），即**解码期降采样**，不产生全尺寸位图

---

## 3. `AppCachedImage` 的四条分支（关键分流点）

`widgets/app_cached_image.dart:68-99` 是整个 UI 层**唯一**的图片分流入口。它按字符串前缀把请求分到 4 条完全不同的路：

| 优先级 | 判据 | 使用的 Provider | 是否降采样 | 是否走缩略图缓存 |
|---|---|---|---|---|
| 1 | `memoryBytes != null` | `MemoryImage` | `ResizeImage(width: targetWidth ?? targetHeight, allowUpscaling: false)` | ❌ |
| 2 | `http://` / `https://` | **`NetworkImage`** | 同上 | ❌ **无 HTTP 磁盘缓存** |
| 3 | `assets/` 前缀 | `AssetImage` | 同上 | ❌ |
| 4 | 其他（本地文件） | **`AppCachedImageProvider`** | Provider 内 `getTargetSize` 钳长边 | ✅ **唯一走三级缓存的分支** |
| 4' | 其他 + `useThumbnailCache: false` | `FileImage` | `ResizeImage` | ❌ |

**关键结构性事实**：`ResizeImage` / `getTargetSize` 都是**解码期降采样**，所以前三条分支不会产生全尺寸位图——这点实现是正确的。真正的全量解码问题出在 §5.2 的裸 `Image.memory` 调用点。

**一个易被忽略的细节**：`_wrapResize` 取的是 `targetWidth ?? targetHeight`，**`targetHeight` 实际上永远被忽略**（`:60`, `:93`）。这是有意为之（注释：仅按单边等比下采样，保证宽高比不被破坏），但调用点同时传 `600/320`、`720/360` 有误导性——真正生效的只有第一个数。

---

## 4. 各卡片实际走哪条路（逐一对账）

### 4.1 走 `AppCachedImageProvider`（三级缓存生效 ✅）

| 卡片 | 位置 | 传入值 | targetDim |
|---|---|---|---|
| 图包封面（详情页 header） | `pack_levels_page.dart:206` | `pack.coverPath`（本地） | **360**（默认值） |
| 图包关卡网格卡 | `pack_levels_page.dart:296` | `level.imagePathOrUrl`（本地） | 360 |
| 活动关卡网格卡 | `event_levels_page.dart:175` | `level.imagePathOrUrl`（本地 或 远端 URL） | 360 |
| 我的拼图卡 | `my_puzzles_tab_view.dart:292` | `item.imagePathOrUrl`（本地 或 assets） | 360 |
| 我的图包大卡 | `my_puzzles_tab_view.dart:304` | `pack.coverPath`（本地） | **600** |
| 素材匣卡片 | `downloaded_drawer_sheet.dart:253` | `item.localPath`（本地） | 360 |

### 4.2 走 `AssetImage`（三级缓存不生效 ⚠️）

| 卡片 | 位置 | 传入值 | 来源 |
|---|---|---|---|
| 首页 100 关网格卡 | `home_tab_view.dart:608` | `level.assetPath` | `game_repository.dart:125` = `assetSamples[...]` |
| 首页今日挑战大卡 | `home_tab_view.dart:278` | `todayDaily.assetPath` | 同上 |
| 每日挑战今日卡 | `daily_tab_view.dart:201` | `todayItem.assetPath` | `game_repository.dart:210` = `item.fallbackAsset` |
| 每日挑战网格卡 | `daily_tab_view.dart:284` | `item.assetPath` | 同上 |

这四处传的都是 `assets/images/sample_XX.jpg`，命中 `assets/` 分支 → `AssetImage`。
**含义**：首页与每日挑战目前**完全不产生缩略图**，也不会往 `thumbnail_cache/` 写任何文件。首页 100 张卡的流畅度完全依赖 `ResizeImage(width: 360)` 的解码期降采样 + 引擎 L3 全局缓存。

### 4.3 走 `NetworkImage`（三级缓存不生效，且无 HTTP 落盘 ⚠️⚠️）

| 卡片 | 位置 | 传入值 |
|---|---|---|
| 活动封面卡 | `events_tab_view.dart:120-126` | `event.coverUrl ?? (event.levels.isNotEmpty ? event.levels.first : '')` |

`coverUrl` 来自远端 manifest JSON（`puzzle_event_item.dart:113`），是 `http(s)://` URL → `NetworkImage`。
`NetworkImage` **没有任何磁盘缓存**：每次进「活动」页（含上下滚动导致的 widget 重建、以及引擎 L3 缓存被挤掉后）都会重新发起 HTTP 请求。这是四条分支里最脆弱的一条。

### 4.4 网络内容系统的接入现状

`AppContent` / `ContentManager` 已实现 4 条管线（main / daily / events / packs），但**只有 3 条被 UI 消费**：

| 管线 | UI 消费点 | 状态 |
|---|---|---|
| `mainPipeline` | `event_levels_page.dart:59` 调 `ensureMainLevelDownloaded()` | ⚠️ 仅活动页调用（命名与用途错位） |
| `eventsPipeline` | `events_tab_view.dart` / `event_levels_page.dart` | ✅ 已接入 |
| `packsPipeline` | `pack_levels_page.dart:44` / `import_pack_page.dart:79,81` / `my_puzzles_tab_view.dart:228` | ✅ 已接入 |
| `dailyPipeline` | **无**（`getDailyLevelsForMonth` / `getTodayDailyLevel` 在 `lib/` 内无调用点） | ❌ 未接入 |

`ContentManager.getMainLevels()` / `filterMainByTag()` / `getMainTags()` 同样**在 `lib/` 内无调用点**（`content_manager.dart:117-123`）——首页标签筛选能力已实现但未接线。
首页/每日挑战目前仍读 `GameRepository`（`home_tab_view.dart:37,138,142`），即用打包 assets。

---

## 5. 拼图游戏内的大图链路（重点）

### 5.1 入场：全量字节 → Navigator 参数

**所有**进入 `GamePage` 的路径都先把**完整原图**读成 `Uint8List`：

| 入口 | 位置 | 读法 |
|---|---|---|
| 首页关卡 | `home_tab_view.dart:76` | `rootBundle.load(level.assetPath)` |
| 每日挑战 | `daily_tab_view.dart:29` | `rootBundle.load(item.assetPath)` |
| 活动关卡 | `event_levels_page.dart:55-61` | 本地则 `File.readAsBytes()`，否则先 `ensureMainLevelDownloaded` 再读 |
| 图包关卡 | `pack_levels_page.dart:90` | `imageFile.readAsBytes()` |
| 自制拼图 | `my_puzzles_tab_view.dart:89-91` | `File.readAsBytes()` |
| 通关下一关 | `game_page.dart:583` | `rootBundle.load(nextLevel.assetPath)` |

然后 `Navigator.push(MaterialPageRoute(builder: (_) => GamePage(imageBytes: bytes, ...)))`
→ `GamePage.imageBytes` 是 **required final 字段**（`game_page.dart:28,38`）

**结论**：游戏大图与 `ImageCacheManager` **零交互**。没有全尺寸图的内存缓存，也没有磁盘缓存。重复进出同一关卡 = 重复全量读盘 + 全量解码。

### 5.2 `GamePage` 内部

```
initState → _loadImage()                              (game_page.dart:94, 183)
  ├─ decodeFlameImage(widget.imageBytes) → ui.Image    (:184)  ← 全量解码，无降采样
  ├─ 难度自适应 adaptiveForSize(w, h)                  (:211)
  ├─ JigsawPuzzleGame(image: img, rows, cols, ...)     (:215)
  └─ dispose() 中 _gameImage?.dispose()                (:886)
```

- 解码走的是 Flame 的 `decodeFlameImage`（`ui.instantiateImageCodec`），**不经过 `ImageProvider`**，因此**不受引擎 L3 的 500 张 / 150 MB 上限约束**（`main.dart:30-31` 的调参对它无效）
- 好消息：所有拼图块**共享同一个 `ui.Image`**，按源矩形切分绘制，不做逐块位图拷贝（`jigsaw_puzzle_game.dart:276-277, 323`）

**裸 `Image.memory` 调用点（无 `cacheWidth` / `cacheHeight`）**：

| 位置 | 用途 | 布局尺寸 |
|---|---|---|
| `game_page.dart:650` | 暂停/结算面板缩略图 | 300×160 |
| `game_page.dart:1156` | 全屏原图预览（眼睛图标） | 全屏 |
| `victory_dialog.dart:239` | 胜利弹窗缩略图 | 200×200 |
| `continue_dialog.dart:110` | 继续游戏弹窗 | aspectRatio 1.4 |
| `choose_difficulty_sheet.dart:437` | 难度选择预览 | — |
| `share_card_generator.dart:263` | 分享卡片 | — |
| `choose_difficulty_sheet.dart:193` | `ui.instantiateImageCodec` 取尺寸 | — |

这 7 处**布局尺寸受限但解码不受限**：`Image.memory` 未传 `cacheWidth`/`cacheHeight` 时会按原图分辨率完整解码成 RGBA 位图，再塞进引擎 L3（150 MB 上限）。

**量化**：经 2x 超分的图（如 1500×2250 → 3000×4500）单张 RGBA = 3000 × 4500 × 4 = **54,000,000 B ≈ 51.5 MiB**。
一次「进入关卡 → 打开难度选择 → 胜利 → 生成分享卡」的流程会**叠加多次**这个量级。

额外缺陷：`choose_difficulty_sheet.dart:193-194` 创建的 `ui.Image` **从未 `dispose()`**，codec 也未 dispose——每次打开难度选择都泄漏一张解码位图。

### 5.3 背景纹理（非业务图，供完整性参考）

- 游戏背景贴图：`Image.asset(..., repeat: ImageRepeat.repeat)`（`game_page.dart:1073`）→ `AssetImage`，由引擎 L3 缓存
- 顶栏取色：`rootBundle.load` → `instantiateImageCodec(targetWidth: 48, targetHeight: 48)`（`game_page.dart:124-132`）→ **已正确降采样**，且用完 `image.dispose()` ✅
- 亚麻布纹：`LinenTextureManager` 程序化生成 64×64 无缝贴图，单例持有 + `ImageShader(TileMode.repeated)`（`linen_texture_manager.dart:40-61, 70-136`）< 16 KB，零 I/O ✅

---

## 6. 写入侧：图是从哪来的

### 6.1 素材匣（DownloadManager）

| 来源 | 流程 | 位置 |
|---|---|---|
| 本地相册批量导入 | `readAsBytes` → `instantiateImageCodec` 校验 **宽高 ≥ 100px** → 复制到 `download_cache/mat_<id>.<ext>` → `prewarmThumbnail` | `download_manager.dart:77-143` |
| 网络下载 | **Dio** `ResponseType.bytes`（自定义 UA，403/401 时带 Referer 重试一次）→ 写 `download_cache/img_<id>.jpg` → `prewarmThumbnail` | `download_manager.dart:146-281` |
| 直接字节保存 | 跳过网络，直接写盘 | `download_manager.dart:180-184` |
| 在线图库选取 | WebView 选图 → `saveOrDownloadImage()` | `online_image_picker_page.dart:338` |
| 删除 | 删源图 + `removeThumbnailForSource` | `download_manager.dart:294,316` |

重复下载防护：按 `sourceUrl` 去重，命中且本地文件存在则直接返回（`download_manager.dart:159-166`）。

### 6.2 自制拼图（CropPuzzlePage）

```
PictureRecorder 裁切导出 PNG (crop_puzzle_page.dart:280-287)
  ↓
ImageUpscaler.shouldUpscale(短边 ≤ 750 或 长边 ≤ 1000)？ (:290-292)
  ↓ 是
ImageUpscaler.upscaleBytes(scale: 2.0) — Isolate.run 后台执行
  管线：导向滤波降噪 → cubic 插值 2x → Luma-Gated CAS 锐化
  输出 PNG                              (image_upscaler.dart:50-134)
  ↓
写 {appSupportDir}/custom_puzzles/puzzle_<ts>.png   (:310-312)
  ↓
prewarmThumbnail(file.path)                        (:327)
```

超分管线本身质量很好（自适应锐化强度、噪声门限 Early Exit），但输出 **PNG** 无损格式——2x 超分后的 PNG 体积可观，且这份字节随后会被 `readAsBytes()` 全量读入 GamePage。

### 6.3 内容管线（AppContent）

```
AppContent.init()  (app_content.dart:36-56)
  ├─ 1. 本地秒开：manifestRouter / main / events / packs 并发读本地缓存 JSON
  └─ 2. _backgroundSync()：Future.microtask 异步增量同步
        ContentManager.syncAll()  (content_manager.dart:71-112)
          ├─ resolveManifest(forceRefresh)
          ├─ mainPipeline.syncWithRemote()   — 版本比对，仅拉元数据
          ├─ eventsPipeline.syncWithRemote() — 带 Auto-GC（删除 disabled 活动目录）
          └─ dailyPipeline.ensureMonthReady() — 下载当月 zip
```

**图片本体是按需懒下载**（`main_content_pipeline.dart:149-175`）：只有点开关卡时才 `ensureLevelImageDownloaded` → `downloadFile` 到 `{appDocumentsDir}/levels/main/<id>.webp`。
活动则是整包 Zip 下载 → 解压 → 原子 rename（`events_content_pipeline.dart:142-179`）。

**注意**：这些管线**下载完原图后都不调用 `prewarmThumbnail`**，缩略图要等卡片首次渲染时才生成（首次显示会走一次后台 isolate 生成，有短暂占位符）。

---

## 7. 问题清单（按严重度）

### P0 — 全量解码导致的内存风险

**7.1 `Image.memory` 未指定降采样尺寸（7 处）**
见 §5.2 表。单张超分图 ≈ 51.5 MiB RGBA，多次叠加会顶穿引擎 L3 的 150 MB 上限并触发 LRU 抖动，极端情况 OOM。
`GamePage` 自己解码的那份 `ui.Image` 更是**完全不受 150 MB 上限约束**。
**修复方向**：给所有 `Image.memory` 加 `cacheWidth`/`cacheHeight`；`choose_difficulty_sheet.dart:193` 改用 `instantiateImageCodec(bytes, targetWidth: 64)` 并 `dispose()`。

**7.2 `choose_difficulty_sheet.dart:193` 的 `ui.Image` 泄漏**
创建的 `frame.image` 与 codec 均未释放。

### P1 — 缓存正确性与覆盖缺口

**7.3 游戏大图完全绕过缓存**
每次进关卡全量读盘 + 全量解码，无复用。对超分后的自制拼图（PNG，数 MB 级）尤其明显。

**7.4 磁盘缩略图缓存无淘汰机制**
`thumbnail_cache/` 无 TTL、无容量上限、无 LRU。唯一的清理入口 `ImageCacheManager.clearCache()`（`:280`）与统计入口 `getCacheSizeBytes()`（`:258`）/`getFormattedCacheSize()`（`:272`）在**整个 `lib/` 内无任何调用点**（已核验，仅 `test/image_cache_manager_test.dart` 引用）——即**没有 UI 能查看或清理缩略图缓存**，长期运行只增不减。

**7.5 缓存键不含内容指纹 → 陈旧缩略图**
`getCacheKey` = FNV-1a(路径) + 边长（`:90-101`）。同路径文件被覆盖后（重新下载、重新生成自制拼图）会**永久命中旧缩略图**，且无自愈路径。
唯一的失效入口 `removeThumbnailForSource`（`:243`）只在素材匣删除时被调用（`download_manager.dart:294,316`）。

**7.6 `NetworkImage` 无 HTTP 磁盘缓存**
活动封面（`events_tab_view.dart:121`）每次重新联网，无 ETag / If-Modified-Since / 本地落盘。

**7.7 同源图被生成多份缩略图**
同一张图包封面在两个页面以不同 `targetWidth` 请求，产生两份磁盘缩略图：
- `pack_levels_page.dart:206`（默认 → dim **360**）
- `my_puzzles_tab_view.dart:304`（`targetWidth: 600` → dim **600**）

而 `my_puzzles_tab_view.dart:304` 的卡片实际只有 140 px 高，却生成 600 px 缩略图。
且 `removeThumbnailForSource` **只删默认 360 那份**（`:244,248` 未传 `targetDimension`），600 那份成为孤儿文件。

### P2 — 健壮性与代码卫生

**7.8 FNV 哈希约 50% 输出带负号的文件名（实测）**
`hash & 0xFFFFFFFFFFFFFFFF` 在 Dart VM 上是**空操作**——`0xFFFFFFFFFFFFFFFF` 字面量超出有符号 64 位范围被折叠为 `-1`，`x & -1 == x`。因此 `hash.toRadixString(16)` 对负数输出 `-1d53f83ac372caeb`，文件名形如 `thumb_-1d53f83ac372caeb_360.jpg`。

实测（Dart 3.12.2 / windows_x64，`temp/cachekey_hash_probe_v2.dart`，2000 条合成路径）：

```
negative over 2000 synthetic paths: 996 (49.8%)
样例：
  pos  thumb_513384d325f62870_360.jpg   <= C:\Users\x\...\puzzle_001.png
  NEG  thumb_-1d53f83ac372caeb_360.jpg   <= assets/images/sample_01.jpg
  NEG  thumb_-3959c5ee1599dd6a_360.jpg   <= https://cdn.example.com/a.webp
```

功能上**无害**（确定性、文件系统合法、`thumb_` 前缀与 `.jpg` 后缀的索引扫描仍然匹配），但：
- 原意「截断为无符号 64 位」未生效
- **Web 平台 `&` 会退化为 32 位运算**，键空间骤降到 32 位，碰撞概率显著上升（虽当前未以 Web 为主要目标）

**7.9 `init()` 失败时降级路径不安全**
若 `getApplicationSupportDirectory()` 抛异常，`_cacheDir` 保持 null、`_isInitialized` 保持 false，后续 `getThumbnailFilePath` 返回 `'/thumb_xxx_360.jpg'`（`:106-107`，`baseDir` 为空串）→ 写盘目标落到**文件系统根目录**。Windows 上通常被拒绝并记 warning（不崩溃），但类 Unix 平台可能真的写入。

**7.10 `AppCachedImage` 的 `colorBlendMode` 是死参数**
`color: colorFilter != null ? null : null`（`:138`）恒为 `null`，`colorBlendMode: BlendMode.srcIn`（`:139`）因此永不生效；实际着色由外层 `ColorFiltered` 完成（`:156-161`）。

**7.11 批量预热无节流**
`prewarmThumbnails`（`:232-240`）对列表逐个 `unawaited(prewarmThumbnail(...))`，一次性塞满队列，会挤占真正需要立即显示的图片。
该方法当前在 `lib/` 内**无调用点**（死代码）；实际被使用的是单张版 `prewarmThumbnail`（3 处：`download_manager.dart:138,278`、`crop_puzzle_page.dart:327`）。

**7.12 L2 磁盘索引与磁盘可能失同步**
`_rebuildDiskKeyIndexAsync` 只在 `init()` 时执行一次；此后只通过 `add`/`remove` 增量维护。若外部进程改动了缓存目录，索引不会感知。

---

## 8. 修复建议（按性价比排序）

| 优先级 | 建议 | 预期收益 | 成本 |
|---|---|---|---|
| 1 | 给 7 处 `Image.memory` / `instantiateImageCodec` 加 `cacheWidth`/`cacheHeight`，并 `dispose()` _codec/_image | 消除 51.5 MiB/次的全量解码与泄漏，直接降低 OOM 风险 | 低（几行） |
| 2 | 在设置页接上 `getFormattedCacheSize()` + `clearCache()`（已实现，仅缺 UI） | 让缓存可见、可控；顺带消灭死代码 | 低 |
| 3 | 统一缩略图请求尺寸（建议卡片一律 360），或对 `targetDimension` 做**档位收敛**（如只允许 360 / 720 两档） | 消除同源多份缩略图与孤儿文件 | 低 |
| 4 | 缓存键加入 `size` + `mtimeMs`（或内容前 64KB 的哈希） | 根治陈旧缩略图 | 中 |
| 5 | 磁盘缓存加 LRU/容量上限（如 200 MB，超限时按 atime 淘汰最旧 20%） | 防止缓存无限膨胀 | 中 |
| 6 | 活动封面改为先落盘再走 `AppCachedImageProvider`（复用 `DownloadManager` 的能力） | 消除重复联网，封面秒开 | 中 |
| 7 | 游戏大图加一层「全尺寸图内存 LRU」（2~3 张 / 按字节上限），键为 `canonicalId` | 消除重复进出关卡的全量读盘+解码 | 中 |
| 8 | 修 FNV 掩码（用 `hash & 0x7FFFFFFFFFFFFFFF` 或 `BigInt`），消除负号文件名与 Web 端 32 位退化 | 键空间正确、文件名整洁 | 低 |
| 9 | `init()` 失败时置 `_cacheDir = null` 并让 `getThumbnailBytes` 直接走「读原图 + 不写缓存」分支，避免写根目录 | 消除异常路径下的越界写入 | 低 |

---

## 附：核验方法与覆盖度

- 全量走查 `lib/logic/cache/`（4 文件）、`lib/widgets/app_cached_image.dart`、`lib/pages/`（11 文件）、`lib/logic/content/`（9 文件）、`lib/logic/download_manager.dart`、`lib/logic/image_upscaler.dart`、`lib/data/game_repository.dart`
- 用 `Grep` 交叉验证 `ImageProvider` 全部子类的使用点、`ImageCacheManager` API 的全部调用点
- 用 Dart 3.12.2 实测验证 FNV 缓存键行为（脚本：`temp/cachekey_hash_probe_v2.dart`）
- **未做**：运行时内存 profiling（需真机/桌面长跑采样）、`thumbnail_cache/` 实际磁盘占用统计（需运行期数据）
- 本报告为只读审计，**未修改任何 `lib/` 代码**，故不产生 `docs/CHANGES-20260902.md` 条目
