# 图片加载缓存与缩略图引擎基础设施架构规范
## (Image Cache & Thumbnail Pipeline Architecture)

本文档详细阐述拼图游戏（Jigsaw Puzzle）内部图片加载、下采样、磁盘缩略图持久化缓存及渲染适配的基础设施架构设计。

> 修订 2026-09-02：缩略图档位 `ThumbnailDimension` 枚举化、网络封面/关卡懒落地、GamePage/裁切页解码泄漏修复、负号孤儿清理已落地。

---

## 1. 背景与痛点分析

在拼图游戏中，图片是核心内容资产，具有以下特殊业务属性：
1. **超高物理分辨率与大文件体积**：
   - 用户从相册批量导入的照片通常为手机摄像头拍摄的 1200 万 ~ 4800 万像素高清大图（例如 $4000 \times 3000$ 甚至更大，单文件 3MB ~ 15MB）；
   - 在线搜图（Pixabay / Unsplash / Pexels）下载的高清素材与自制裁切导出的拼图底图物理短边均在 1000px ~ 2160px；
2. **多列表/网格高密度并发渲染**：
   - 素材库抽屉（`DownloadedDrawerSheet`）、自制关卡合辑（`MyPuzzlesTabView`）、关卡画廊（`HomeTabView` 100 关）与每日挑战（`DailyTabView` 30 关）均为网格列表（GridView/ListView）；
   - 若直接使用 `Image.file(File(path))` 或未下采样的 `Image.asset`，Flutter 渲染引擎将在主线程以**完整原始分辨率**解码整张位图，单张 4K 图片在 RGBA_8888 格式下直接占用显存：
     $$\text{GPU Memory} = 4000 \times 3000 \times 4\text{ bytes} \approx 48\text{ MB}$$
     快速滑动十几个卡片时，显存占用瞬间突破数百兆甚至触发 OOM（内存溢出）崩溃，并造成严重的列表滚动丢帧与卡顿。
3. **第三方库（如 `flutter_cache_manager`）的局限性**：
   - `flutter_cache_manager` / `cached_network_image` 主要设计目标为「网络 HTTP GET 原文件传输与存储」，**并不提供针对本地大图文件的物理下采样与缩略图生成能力**；
   - 依赖 `sqflite` 带来了 Windows 桌面端的额外初始化配置与原生库负担；
   - 针对部分图库（如 Pixabay / Unsplash）的防爬与防盗链 403 限制，无法直接借助 InAppWebView 内部认证会话进行代理抓取。

因此，必须构建一套**轻量、全平台原生兼容、严格分层解耦且具备主动预热与懒落地能力的独立图片缓存与缩略图基础设施**。

---

## 2. 核心架构设计理念

1. **三级分级缓存流水线 (L1 内存 -> L2 磁盘 -> L3 调度生成)**：
   - **L1 纯内存 LRU 缓存 (`MemoryCache`)**：150 张 / 30MB 内存字节缓存，命中时耗时 $<0.001\text{ms}$ (0 纳秒级响应)，跳过所有磁盘与线程调度；
   - **L2 磁盘缓存内存索引 (`Set<String> _diskKeyIndex`)**：启动时异步扫描建索引，主线程判断文件是否存在全部查内存 Set，**彻底杜绝任何 `existsSync`/`stat` 等主线程同步阻塞**；`_rebuildDiskKeyIndexAsync` 自动清理历史负号键 `thumb_-*.jpg` 与旧档位 `_600/_1440` 孤儿；
   - **L3 并发受控任务调度引擎 (`EngineTaskQueue`)**：桌面平台并发数可达 4，移动端默认 2；支持 **Single Flight 请求去重合并**，50+ 大图并发时平滑排队消费，消除 CPU/Isolate 洪峰。
2. **类型安全档位收敛 (ThumbnailDimension Enum)**：
   - 仅允许 `ThumbnailDimension.card(360)`（卡片/网格）与 `eventCover(720)`（活动封面/今日大卡）两档，编译期杜绝 `360/500/600` 零散尺寸导致同源多份缩略图；`removeThumbnailForSource` 遍历全档位清理。
3. **严格分层解耦 (Decoupled Layered Architecture)**：
   - **底层纯逻辑化**：核心缓存引擎与后台 Isolate 缩略图生成器**完全不依赖任何 Flutter UI Widget**，可独立运行在后台服务、数据导入、Repository 中；
   - **适配层标准化**：提供符合 Flutter 官方规范的 `ImageProvider`（本地 `AppCachedImageProvider` + 网络 `AppCachedNetworkImageProvider`），对上支持原生 `Image`、`DecorationImage` 等；
   - **表现层便捷化**：提供开箱即用的 `AppCachedImage` 与 `LazyLevelImage`，封装骨架占位、淡入与懒落地。
4. **全管道预热 + 懒落地 (Pre-warm + Lazy Resolve)**：
   - **预热**：相册导入、下载入库、自制裁切落盘时静默 `prewarmThumbnail` 实现 0ms 秒开；
   - **懒落地**：网络关卡滚动到可视才经 `LevelImageResolver` 后台下载原图到 `network_levels/` 再生成缩略，保证“见缩略必可玩”离线闭环。

---

## 3. 总体架构分层图

```
┌────────────────────────────────────────────────────────────────────────┐
│ 4. UI 表现层 (Widget Layer)                                            │
│    lib/widgets/app_cached_image.dart                                   │
│    - AppCachedImage: 统一 File/Asset/Network/Memory，网络走磁盘缓存      │
│    lib/widgets/lazy_level_image.dart                                    │
│    - LazyLevelImage: 可视即后台落原图→再缩略，见缩略必可玩                │
│    lib/widgets/continue_dialog.dart / victory_dialog.dart 等             │
│    - Image.memory(cacheWidth: 600/1080/1440) 解码期降采样                │
│    - 动画 Fade-in 200ms、骨架占位、错误回退                              │
└───────────────────────────────────┬────────────────────────────────────┘
                                    │ 调用
                                    ▼
┌────────────────────────────────────────────────────────────────────────┐
│ 3. Flutter 渲染适配层 (ImageProvider Layer)                           │
│    lib/logic/cache/app_cached_image_provider.dart                      │
│    - AppCachedImageProvider(ImageProvider<AppImageKey>) 本地文件         │
│    lib/logic/cache/app_cached_network_image_provider.dart              │
│    - AppCachedNetworkImageProvider 网络（同样走 L1/L2/L3）               │
│    - 均通过 getTargetSize 钳长边，避免全尺寸位图进 L3                    │
│    lib/logic/cache/level_image_resolver.dart                           │
│    - LevelImageResolver 单次下载落 network_levels/ 再供缩略与游戏复用     │
└───────────────────────────────────┬────────────────────────────────────┘
                                    │ 调用 / 检索
                                    ▼
┌────────────────────────────────────────────────────────────────────────┐
│ 2. 调度引擎与并发限流器 (Engine & Concurrency Control Layer)          │
│    lib/logic/cache/engine_task_queue.dart (EngineTaskQueue)            │
│    ├─ 动态平台并发控制: 桌面 4，移动 2                                   │
│    ├─ Single Flight: 相同 Key 并发只执行 1 次后台任务                   │
│    └─ FIFO: 超额排队，本地与网络同队列限流                              │
└───────────────────────────────────┬────────────────────────────────────┘
                                    │ 调度
                                    ▼
┌────────────────────────────────────────────────────────────────────────┐
│ 1. 核心缓存引擎层 (Core Cache Layer - 纯 Dart，零 UI 依赖)             │
│    lib/logic/cache/                                                    │
│    ├─ memory_cache.dart (L1: 150 张 / 30MB)                            │
│    ├─ image_cache_manager.dart (Facade)                                │
│    │  ├─ _diskKeyIndex (0 纳秒判断) + 负号/旧档位自清理                 │
│    │  ├─ getThumbnailBytes(path, dimension) 本地 L1->L2->L3             │
│    │  ├─ getNetworkThumbnailBytes(url, dimension) 网络同流水线           │
│    │  ├─ prewarmThumbnail/prewarmThumbnails + getCacheSize/clearCache   │
│    │  └─ FNV-1a 63位掩码 0x7FFFFFFFFFFFFFFF 消负号                        │
│    └─ thumbnail_generator.dart (Isolate: decode→copyResize→encodeJpg)  │
└────────────────────────────────────────────────────────────────────────┘
```

---

## 4. 核心模块与 API 规范

### 4.1 核心缓存引擎 (`ImageCacheManager`)

作为基础设施的核心门面（Facade），单例，对外暴露纯逻辑 API（2026-09-02 后档位为枚举）：

```dart
enum ThumbnailDimension { card(360), eventCover(720); const ThumbnailDimension(this.pixels); final int pixels; }

class ImageCacheManager {
  static final ImageCacheManager instance = ImageCacheManager._();
  static const ThumbnailDimension kDefaultThumbnailDimension = ThumbnailDimension.card;

  Future<void> init(); // <AppSupportDir>/thumbnail_cache/ + _rebuildDiskKeyIndexAsync 自清理

  String getCacheKey(String sourcePath, {ThumbnailDimension dimension = kDefaultThumbnailDimension}); // FNV-1a 63位 thumb_<16hex>_<dim>.jpg
  String getThumbnailFilePath(String sourcePath, {ThumbnailDimension dimension = kDefaultThumbnailDimension});
  bool isThumbnailCached(String sourcePath, {ThumbnailDimension dimension = kDefaultThumbnailDimension});
  Uint8List? getCachedThumbnailBytesFromMemory(String sourcePath, {ThumbnailDimension dimension = kDefaultThumbnailDimension});

  // 本地文件三级流水
  Future<Uint8List?> getThumbnailBytes(String sourcePath, {ThumbnailDimension dimension = kDefaultThumbnailDimension, int quality = 80});
  Future<File> getThumbnailFile(String sourcePath, {ThumbnailDimension dimension = kDefaultThumbnailDimension, int quality = 80});

  // 网络 URL 同流水线（下载→后台缩略→L1/L2，共用目录/key/队列）
  Future<Uint8List?> getNetworkThumbnailBytes(String url, {ThumbnailDimension dimension = kDefaultThumbnailDimension, int quality = 80});

  Future<void> prewarmThumbnail(String sourcePath, {ThumbnailDimension dimension = kDefaultThumbnailDimension, int quality = 80});
  Future<void> prewarmThumbnails(List<String> sourcePaths, {ThumbnailDimension dimension = kDefaultThumbnailDimension, int quality = 80});

  Future<void> removeThumbnailForSource(String sourcePath); // 遍历全档位
  Future<int> getCacheSizeBytes(); // 仅计 thumb_*.jpg
  Future<String> getFormattedCacheSize();
  Future<void> clearCache();
}
```

* `getCacheKey` 掩码 `0x7FFFFFFFFFFFFFFF` 消除 50% 负号文件名，正数键与旧算法一致可命中旧 360 缓存；`_rebuildDiskKeyIndexAsync` 首次启动自动删除 `thumb_-*.jpg` 与 `_600/_1440` 孤儿。
* `getNetworkThumbnailBytes` 与本地同 `L1→L2→L3`，L3 内 `Dio` 下载（15/30s，403/401 重试一次）→ `ThumbnailGenerator.generateThumbnailFromBytes`，写入同一 `thumbnail_cache`。

### 4.2 后台 Isolate 缩略图生成器 (`ThumbnailGenerator`)

后台 Isolate 解码、等比缩放与 JPEG 编码，全程不阻塞 UI：

```dart
class ThumbnailGenerator {
  static Future<bool> generateThumbnail({required String sourceFilePath, required String targetFilePath, int targetDimension = 360, int quality = 80});
  static Future<Uint8List?> generateThumbnailFromBytes({required Uint8List rawBytes, int targetDimension = 360, int quality = 80});
  static Future<Uint8List?> generateCroppedBytesFromBytes({required Uint8List rawBytes, double? targetRatio, int quality = 90});
}
```

#### 下采样几何与编码策略：
1. **格式自适应解码**：`image` 库支持 JPEG/PNG/WebP/BMP；
2. **等比约束**：
   $$\text{scale} = \frac{\text{targetDimension}}{\max(\text{srcWidth}, \text{srcHeight})}, \quad \text{dstW} = \text{round}(\text{srcW} \cdot \text{scale})$$
   小于 `targetDimension` 则保留原尺寸；
3. **高保真**：`Interpolation.linear` + `quality:80` JPEG 单图约 20KB；裁切 `copyCrop` 居中，`loss≤1%` 时原样返回零重编码。

### 4.3 渲染适配层

**本地** `AppCachedImageProvider extends ImageProvider<AppImageKey>`：
```dart
class AppCachedImageProvider extends ImageProvider<AppImageKey> {
  const AppCachedImageProvider(this.filePath, {this.dimension = ThumbnailDimension.card, this.scale = 1.0});
}
```
**网络** `AppCachedNetworkImageProvider extends ImageProvider<AppNetworkImageKey>` 对称实现，`_loadAsync` 调 `getNetworkThumbnailBytes`，同样 `getTargetSize` 钳长边。

**关卡懒落地** `LevelImageResolver`：
```dart
class LevelImageResolver {
  Future<String> resolveLevelLocalPath(PuzzleLevelItem level); // http→下载到 network_levels/net_<hash>.ext 或 levels/main/<id>.webp 再返回本地路径
}
```
* `SliverGrid` 可视才 `LevelImageResolver` 后台下载，`LazyLevelImage` 占位→本地路径→`AppCachedImageProvider`，与 `GamePage` `File.readAsBytes` 同文件，见缩略必可玩。

#### 时序
```
obtainKey() 同步返回 AppImageKey(filePath/dimension)
loadImage() → _loadAsync:
  ├─ getThumbnailBytes / getNetworkThumbnailBytes L1→L2→L3
  └─ ui.ImmutableBuffer + decode(getTargetSize钳720/360)
```

### 4.4 可选 UI 便捷组件

```dart
AppCachedImage(
  imagePathOrUrl: item.imagePathOrUrl, // File / assets/ / http(s) / Memory 统一入口
  targetDimension: ThumbnailDimension.card, // 取代旧 targetWidth/targetHeight
  fit: BoxFit.cover,
  borderRadius: BorderRadius.circular(16),
  fadeInDuration: Duration(milliseconds: 200),
)

LazyLevelImage(level: puzzleLevelItem, fit: BoxFit.cover) // 网络关卡可视即落盘

Image.memory(bytes, cacheWidth: 1080) // victory 600 / continue/share/difficulty 1080 / GamePage 暂停1080/全屏1440 解码期降采样
```

`AppCachedImage` 内部：`http→AppCachedNetworkImageProvider`、`assets→AssetImage+ResizeImage`、`File→AppCachedImageProvider`，网络与本地同缓存目录。

---

## 5. 预热与懒落地机制

### 5.1 主动预热（源头触发，0ms 秒开）

```
[相册批量导入] [在线下载入库] [自制裁切] ──► prewarmThumbnail(localPath) ──► thumbnail_cache/thumb_<hash>_360.jpg ──► 列表 0ms 命中
```

调用点：`DownloadManager.importFromLocalFiles:138`/`saveOrDownload:278`、`CropPuzzlePage:327`

### 5.2 懒落地（可视触发，见缩略必可玩）

```
Grid itemBuilder 可视 → LevelImageResolver.resolveLevelLocalPath(url)
  → ContentHttpClient.downloadFile → network_levels/net_<hash>.jpg (单次)
  → prewarmThumbnail(localPath) → thumb → LazyLevelImage 切本地 → 点击 File.readAsBytes 同文件进 GamePage
  飞行模式：已滚过的 L2 命中仍可玩，未滚过的占位不崩
```

覆盖：`event_levels_page.dart:180 LazyLevelImage`、`pack_levels_page.dart:300`；首页/每日资产恒可用无需下载；活动封面仍只存缩略 `getNetworkThumbnailBytes` 最省盘。

批量 `prewarmThumbnails` 仍保留但关卡不再用它（旧实现 `unawaited` 洪峰已规避，复用队列限流与单飞）。

---

## 6. 自制关卡响应式刷新架构

同前：`GameRepository.customPuzzlesNotifier` 广播，`MyPuzzlesTabView` 响应式重绘。

---

## 7. 性能实测基准 (Benchmark)

| 指标 | 改造前 | 改造后 | 改善 |
| :--- | :--- | :--- | :--- |
| 单图磁盘 | 4.8~12.5 MB | **18~35 KB** | 99.6% |
| 峰值显存 | 620 MB+ | **68~92 MB** | 85%+ |
| 首开耗时 | 850~1600 ms | **<16 ms** | 50× |
| 帧率 | 35~42 FPS | **60/120 FPS** | 零掉帧 |
| 网络封面重复请求 | 每次重联网 | **首访后 L2 零网络** | 流量↓ |

> 超分后 3000×4500 原图 RGBA 约 51.5 MiB，全量 `Image.memory` 已全部加 `cacheWidth`（见 4.4），`choose_difficulty_sheet:193` 改 `ImageDescriptor.encoded` 零像素探针并 `dispose`，`game_page:126`/`crop_puzzle_page:91` 补 `codec.dispose()`。

---

## 8. 测试与质量保障

`test/image_cache_manager_test.dart`：
1. `ThumbnailGenerator` 字节下采样与压缩率；
2. `ImageCacheManager` Key 确定性与 63位正数、跨档位区分、`removeThumbnailForSource` 全档位清理、负号/旧档位自清理；
3. `getNetworkThumbnailBytes` L1/L2 命中与单飞；
4. `GameRepository.customPuzzlesNotifier` 响应式；
5. `AppCachedImage`/`LazyLevelImage` 构建与错误回退。

`flutter analyze` 0 警告。
