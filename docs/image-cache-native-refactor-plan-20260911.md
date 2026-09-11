# 图片缓存体系原生化重构计划（方案 A：回归 Flutter 原生 ImageCache + 全类型闭环终版）

> 编写日期：2026-09-11（v4.1 终审修订：补齐 `SettingsPage.didChangeDependencies` 删除、还原原版 `ColorFiltered` 包装与透传、骨架屏改回常规非 Positioned 尺寸子节点）  
> 状态：待执行（方案已获确认）  
> 关联文档：
> - `docs/image-cache-and-thumbnail-pipeline-architecture.md`（历史自研架构）
> - `docs/card-thumbnail-mechanism-analysis-and-plan-20260911.md`（缺陷分析）
> - `docs/card-thumbnail-mechanism-plan-review-20260911.md`（评审，10 项缺陷）
> - `docs/card-thumbnail-simplified-reliable-architecture-20260911.md`（v3.1 快慢分流方案，已正式废弃）
> - `temp/image-cacjhe-plan-reviews.txt`（实施细节专项评审与修正对策）

---

## 1. 背景与决策

### 1.1 现状问题

卡片缩略图链路存在长时间占位、返回不自愈、弱网 CPU 满载等体验问题。根因是 **"缩略图强制排队等纯 Dart 软解生成"的机制性瓶颈 + 1500 余行自研缓存系统的过度设计与维护负担**。

除 `LevelImageResolver`（关卡 id → 本地可玩原图）外，其余缓存能力 Flutter 引擎原生即可覆盖，且覆盖路径（原生 C++ 解码器硬件降采样 + 引擎 ImageCache）正是"进入难度面板 3ms 秒出"的同款原生路径。

### 1.2 核心决策

1. **彻底删除自研缩略缓存体系**：
   删除 `ImageCacheManager` / `MemoryCache` / `EngineTaskQueue` / 两个自定义 ImageProvider / `ThumbnailGenerator` 的缩略图生成方法（净减 1500+ 行代码）。
2. **全面回归 Flutter 原生解码与内存管理**：
   无论关卡还是封面，统一通过 `ResizeImage(FileImage(File(path)), width: N)`（N = 档位长边 360 / 720），由底层 C++ 引擎（libwebp / libjpeg-turbo）硬件加速降采样（3~5ms），结果由引擎 `PaintingBinding.instance.imageCache`（默认 100MB / 1000 张 LRU）自动管理。
3. **全类型原图本地落盘闭环（网络只搬运字节，绝不跑纯 Dart 软解压缩）**：
   - **关卡图片**：保留既有 `LevelImageResolver` 管线闭环，原图落地到本地目录（“见缩略必可玩”）；
   - **Event / Collection 封面**：由 `LevelImageResolver` 扩充通用原图落盘能力，使用单飞（Single-Flight）并发去重安全写入 `levels/network/`，绝不重复软解与编码；
   - **启动预热保证冷启动秒出**：在 `main.dart` 启动组预热 Resolver 本地落地目录绝对路径，保证冷启动首帧同步探测 100% 生效，断网秒显。
4. **单次网络请求与平滑切换**：
   未落盘网络图片由轻量局部组件单次触发下载落盘，加载期展示双层 Stack 修复后的骨架屏（占位置于底层自然撑开 Stack，`AnimatedOpacity` 覆盖其上），落盘成功后局部平滑淡入切换为 `FileImage`，杜绝双重网络请求。
5. **保护离线数据，彻底移除设置页清空缓存死代码**：
   - 封面体积极小（20~200KB），`levels/network` 目录作为离线核心资产**永不清理**；
   - 用户已在设置页中注释了清理入口；本次重构顺手**彻底删除** `SettingsPage` 中的 `_loadCacheSize`、`_clearThumbnailCache`、`didChangeDependencies` 整个 override 块等残留死代码与 `ImageCacheManager` 依赖。
6. **规范分层与原有逻辑保真**：
   - 独立建立 `lib/logic/cache/thumbnail_dimension.dart`，消除 Widget 与 Logic 层的反向依赖；
   - 保留原版 `ColorFiltered` 包装与透传，绝不随意替换为有语义差异的 `color: white + BlendMode.srcIn`。
7. **不引入任何第三方图片缓存库**。

---

## 2. 现状核对与处置清单

| 文件 | 行数 | 职责 | 本次处置 |
| --- | --- | --- | --- |
| `lib/logic/cache/image_cache_manager.dart` | 770 | L1 内存 LRU + L2 磁盘索引/淘汰 + L3 任务队列 + 网络下载/预热/清缓存 | **删除** |
| `lib/logic/cache/memory_cache.dart` | 92 | L1 内存 LRU | **删除** |
| `lib/logic/cache/engine_task_queue.dart` | 148 | 并发限流 + Single-Flight 队列 | **删除** |
| `lib/logic/cache/app_cached_image_provider.dart` | 175 | 本地文件 ImageProvider，桥接 manager | **删除** |
| `lib/logic/cache/app_cached_network_image_provider.dart` | 145 | 网络 URL ImageProvider，桥接 manager | **删除** |
| `lib/logic/cache/thumbnail_generator.dart` | 339 | 缩略图生成（缓存用途）+ 原图入库裁剪（管线用途） | **部分保留**：仅删缩略图方法，裁剪方法保留（见 §4.2） |
| `lib/logic/cache/thumbnail_dimension.dart` | - | 尺寸档位枚举 `ThumbnailDimension` 与默认值 | **新建**：从待删 manager 中抽离独立（见 §4.3） |
| `lib/logic/cache/level_image_resolver.dart` | 175 | 关卡 id → 本地可玩原图（离线闭环核心） | **升级扩充**：加 Single-Flight、启动预热与通用 URL 落盘（见 §4.6） |
| `lib/widgets/app_cached_image.dart` | 152 | 通用图片 widget（占位/淡入/错误兜底/尺寸钳制） | **瘦身改造**：四分支直出 + 未落盘单次加载切换（见 §4.4） |
| `lib/widgets/lazy_level_image.dart` | 134 | 关卡卡片懒解析（resolver → AppCachedImage） | **改造**：透传 `targetDimension` 并收敛类型（见 §4.5） |
| `lib/pages/settings_page.dart` | 806 | 设置页面 | **彻底清理**：删除清缓存死代码、didChangeDependencies 与 manager 依赖（见 §4.7） |
| `integration_test/app_test.dart` | 116 | 端到端集成测试 | **适配**：更新网络异常过滤条件（见 §4.9） |

---

## 3. 目标架构

```
[UI 卡片 / Banner / 图集列表]
            │
            ▼
   [AppCachedImage] (纯展示壳，统管全部图片渲染)
            │
            ├─ 本地文件路径 ──► ResizeImage(FileImage(File(path)), width: N)
            │                     └─► 原生 C++ 解码器硬件降采样（3~5ms 秒出）
            │                         └─► 自动纳入引擎 ImageCache（解码后 LRU 内存池）
            │
            ├─ assets/ ──────► ResizeImage(AssetImage(key), width: N)
            │
            ├─ 内存字节 ──────► ResizeImage(MemoryImage(bytes), width: N)
            │
            └─ http(s) URL ──► LevelImageResolver.getUrlLocalPathIfAvailable(url)?
                                ├─【是】已落盘 ──► 立即同步返回 FileImage 快路径（离线冷启动 3ms 秒显）
                                └─【否】未落盘 ──► 私有 _NetworkImageLoader 单次异步落盘：
                                                  - 展示双层 Stack 骨架屏 (底层常规子节点，防零尺寸塌缩)
                                                  - await LevelImageResolver.resolveUrlLocalPath(url)
                                                    (内部 Single-Flight 去重，防 .part 竞态损坏)
                                                  - 落盘成功 ──► setState 平滑淡入切为 FileImage
                                                  - 落盘失败 ──► 展示 errorWidget
                    ▲
                    │ 离线游戏原图闭环（永久保留，永不清理）
   [LevelImageResolver] ──► levels/network/<fnv1a63hash>.<ext>（原图单次落盘，幂等原子）
```

---

## 4. 逐文件改动清单

### 4.1 删除文件（5 个）

```
lib/logic/cache/image_cache_manager.dart
lib/logic/cache/memory_cache.dart
lib/logic/cache/engine_task_queue.dart
lib/logic/cache/app_cached_image_provider.dart
lib/logic/cache/app_cached_network_image_provider.dart
```

### 4.2 裁剪 `lib/logic/cache/thumbnail_generator.dart`

**保留**（图包导入管线与裁剪测试依赖）：
- `CropTaskParams`
- `ThumbnailGenerator.generateCroppedBytesFromBytes`
- `ThumbnailGenerator._processCropToBytesIsolate`
- 对 `lib/logic/image_crop.dart` 的引用与 `nearestStandardRatio` / `findSmartCropRect` 调用

**删除**（缩略图生成缓存职责）：
- `ThumbnailTaskParams`
- `ThumbnailGenerator.generateThumbnailBytes`
- `ThumbnailGenerator.generateThumbnailFromBytes`
- `ThumbnailGenerator.generateThumbnail`
- `_processThumbnailToBytesIsolate`
- `_processThumbnailToFileIsolate`
- 清理仅被缩略方法使用的无用 import。

### 4.3 [新建] `lib/logic/cache/thumbnail_dimension.dart`

独立存放尺寸档位枚举与默认常量，保持逻辑层与展示层解耦：
```dart
/// 解码与缓存档位：所有图片统一从预定义档位中选择，
/// 按单边等比下采样解码，保证原图宽高比不被破坏。
enum ThumbnailDimension {
  card(360),
  eventCover(720);

  const ThumbnailDimension(this.pixels);
  final int pixels;
}

const ThumbnailDimension kDefaultThumbnailDimension = ThumbnailDimension.card;
```

### 4.4 瘦身改造 `lib/widgets/app_cached_image.dart`

1. **导入更新**：
   导入新建的 `thumbnail_dimension.dart`，删除所有待删 Provider 和 Manager 的 import。
2. **删除无用字段**：
   删除 `useThumbnailCache` 参数与字段（已确认无外部传参）。
3. **改造 `_resolveImageProvider()` 结合未落盘私有加载器与原版滤镜**：
   ```dart
   ImageProvider _wrapResize(ImageProvider provider) {
     return ResizeImage(provider, width: targetDimension.pixels);
   }

   @override
   Widget build(BuildContext context) {
     final path = imagePathOrUrl ?? '';

     // 网络图片未落盘场景：走单次异步落地与自动切换组件
     if (memoryBytes == null &&
         (path.startsWith('http://') || path.startsWith('https://'))) {
       final localPath = LevelImageResolver.instance.getUrlLocalPathIfAvailable(path);
       if (localPath == null || !File(localPath).existsSync()) {
         return _NetworkImageLoader(
           url: path,
           width: width,
           height: height,
           targetDimension: targetDimension,
           fit: fit,
           alignment: alignment,
           borderRadius: borderRadius,
           colorFilter: colorFilter,
           placeholder: placeholder ?? _defaultPlaceholder(),
           errorWidget: errorWidget ?? _defaultError(),
           fadeInDuration: fadeInDuration,
         );
       }
     }

     // 其余场景（内存、Assets、本地文件、已落盘网络图）：同步直出
     final imageProvider = _resolveImageProvider();
     Widget content = Image(
       image: imageProvider,
       width: width,
       height: height,
       fit: fit,
       alignment: alignment,
       errorBuilder: (context, error, stackTrace) => errorWidget ?? _defaultError(),
       frameBuilder: (context, child, frame, wasSynchronouslyLoaded) {
         if (wasSynchronouslyLoaded || fadeInDuration == Duration.zero) {
           return child;
         }
         return Stack(
           fit: StackFit.passthrough,
           alignment: alignment,
           children: [
             // 1. 底层常规尺寸子节点：由占位图自然撑开 Stack 约束，避免零尺寸塌缩
             if (frame == null) placeholder ?? _defaultPlaceholder(),
             // 2. 顶层常驻平滑淡入：首帧就绪后由 0 淡入到 1.0 覆盖占位
             AnimatedOpacity(
               opacity: frame == null ? 0.0 : 1.0,
               duration: fadeInDuration,
               curve: Curves.easeOut,
               child: child,
             ),
           ],
         );
       },
     );

     // 保留原版 ColorFiltered 包装，语义 100% 保持兼容
     if (colorFilter != null) {
       content = ColorFiltered(colorFilter: colorFilter!, child: content);
     }

     if (borderRadius != null) {
       content = ClipRRect(borderRadius: borderRadius!, child: content);
     }
     return content;
   }
   ```
4. **私有组件 `_NetworkImageLoader`（透传 `colorFilter`，单次下载与自动切图）**：
   ```dart
   class _NetworkImageLoader extends StatefulWidget {
     const _NetworkImageLoader({
       required this.url,
       required this.targetDimension,
       required this.placeholder,
       required this.errorWidget,
       required this.fadeInDuration,
       this.width,
       this.height,
       this.fit = BoxFit.cover,
       this.alignment = Alignment.center,
       this.borderRadius,
       this.colorFilter,
     });

     final String url;
     final ThumbnailDimension targetDimension;
     final Widget placeholder;
     final Widget errorWidget;
     final Duration fadeInDuration;
     final double? width;
     final double? height;
     final BoxFit fit;
     final Alignment alignment;
     final BorderRadius? borderRadius;
     final ColorFilter? colorFilter;

     @override
     State<_NetworkImageLoader> createState() => _NetworkImageLoaderState();
   }

   class _NetworkImageLoaderState extends State<_NetworkImageLoader> {
     String? _localPath;
     bool _failed = false;

     @override
     void initState() {
       super.initState();
       _load();
     }

     @override
     void didUpdateWidget(covariant _NetworkImageLoader oldWidget) {
       super.didUpdateWidget(oldWidget);
       if (oldWidget.url != widget.url) {
         _localPath = null;
         _failed = false;
         _load();
       }
     }

     Future<void> _load() async {
       final path = await LevelImageResolver.instance.resolveUrlLocalPath(widget.url);
       if (!mounted) return;
       if (path.isNotEmpty && File(path).existsSync()) {
         setState(() => _localPath = path);
       } else {
         setState(() => _failed = true);
       }
     }

     @override
     Widget build(BuildContext context) {
       if (_failed) return widget.errorWidget;
       if (_localPath == null) {
         return SizedBox(
           width: widget.width,
           height: widget.height,
           child: widget.placeholder,
         );
       }
       return AppCachedImage(
         imagePathOrUrl: _localPath,
         width: widget.width,
         height: widget.height,
         targetDimension: widget.targetDimension,
         fit: widget.fit,
         alignment: widget.alignment,
         borderRadius: widget.borderRadius,
         colorFilter: widget.colorFilter,
         fadeInDuration: widget.fadeInDuration,
       );
     }
   }
   ```

### 4.5 改造 `lib/widgets/lazy_level_image.dart`

1. **补齐参数透传并收敛类型**：
   `targetDimension` 类型从 `dynamic` 改为 `ThumbnailDimension?`，并在内部两处构建 `AppCachedImage` 时正确透传：
   ```dart
   targetDimension: widget.targetDimension ?? kDefaultThumbnailDimension,
   ```
2. 保留原有关卡异步解析与重试自愈逻辑。

### 4.6 升级 `lib/logic/cache/level_image_resolver.dart`

1. **增加 Single-Flight 下载去重 map**：
   ```dart
   final Map<String, Future<String>> _inFlight = {};
   ```
2. **增加启动预热方法 `warmup()`**：
   ```dart
   Future<void> warmup() async {
     await _getNetworkLevelsDir();
   }
   ```
3. **增加同步快查 `getUrlLocalPathIfAvailable(String url)`**：
   ```dart
   String? getUrlLocalPathIfAvailable(String url) {
     if (_networkLevelsDir == null) return null;
     final hash = _hashUrl(url);
     final ext = _extensionForUrl(url);
     final targetPath = p.join(_networkLevelsDir!, 'net_$hash$ext');
     final file = File(targetPath);
     if (file.existsSync() && file.lengthSync() > 0) {
       return targetPath;
     }
     return null;
   }
   ```
4. **增加通用 URL 异步落盘方法 `resolveUrlLocalPath(String url)`（全量 try-catch 保护）**：
   ```dart
   Future<String> resolveUrlLocalPath(String url) async {
     if (url.isEmpty || !url.startsWith('http')) return '';
     try {
       final dir = await _getNetworkLevelsDir();
       final hash = _hashUrl(url);
       final ext = _extensionForUrl(url);
       final targetPath = p.join(dir, 'net_$hash$ext');
       return await _downloadToNetworkDirWithSingleFlight(url, targetPath);
     } catch (e, st) {
       AppLogger.content.warning('resolveUrlLocalPath failed url=$url', e, st);
       return '';
     }
   }
   ```
5. **抽取公共单飞下载私有方法 `_downloadToNetworkDirWithSingleFlight`**：
   ```dart
   Future<String> _downloadToNetworkDirWithSingleFlight(String url, String targetPath) {
     final existingFile = File(targetPath);
     if (existingFile.existsSync() && existingFile.lengthSync() > 0) {
       return Future.value(targetPath);
     }

     final inFlight = _inFlight[targetPath];
     if (inFlight != null) return inFlight;

     final future = () async {
       try {
         final downloaded = await _httpClient.downloadFile(url, targetPath);
         if (downloaded.existsSync() && await downloaded.length() > 0) {
           return downloaded.path;
         }
         return '';
       } finally {
         _inFlight.remove(targetPath);
       }
     }();

     _inFlight[targetPath] = future;
     return future;
   }
   ```
6. **保持关卡原有管线逻辑独立**：
   `resolveLevelLocalPath` 内部的主线探测与 `ensureMainLevelDownloaded` 原封不动保留，仅最后的通用网络兜底部分复用 `_downloadToNetworkDirWithSingleFlight`，绝不绕过主线管线。

### 4.7 彻底清理 `lib/pages/settings_page.dart` 残留死代码

鉴于清空缓存入口已被移除且确定不提供该选项：
1. **整体删除 `didChangeDependencies()` override 方法（第 49-55 行）**：
   该方法内部仅有 `_cacheSize = t.common.calculating;` 一行赋值逻辑，删除 `_cacheSize` 变量后留着必然引发编译错误，直接整体删除；
2. 删除 `_loadCacheSize()` 方法声明及其在 `initState` 中的调用（第 45 行）；
3. 删除带 `// ignore: unused_element` 的 `_clearThumbnailCache()` 方法（第 79-108 行）；
4. 删除 `_cacheSize` 和 `_clearingCache` 状态变量定义（第 37-38 行）；
5. 删除被注释的 ListTile 清缓存 UI 代码块（第 348-374 行）；
6. 删除文件顶部未使用的 `import 'package:jigsawpuzzle/logic/cache/image_cache_manager.dart';`。

### 4.8 清理启动与管线调用点

1. **`lib/main.dart`**：
   - 组 1 的 `Future.wait` 中，将 `ImageCacheManager.instance.init()` 替换为：
     ```dart
     LevelImageResolver.instance.warmup(),
     ```
   - 启动后组 2 后台区保留一次性静默清理遗留 `thumbnail_cache` 目录（若存在则删除），随后该目录彻底退出历史舞台；
   - 清理文件顶部不再使用的 `image_cache_manager.dart` import。
2. **`lib/logic/download_manager.dart`**：
   - 删除 line 190 / 395 的 `prewarmThumbnail` 调用；
   - 删除 line 411-413 / 439-441 / 482-485 的 `removeThumbnailForSource` 调用，保留源文件清理逻辑；
   - 删除未使用的 `image_cache_manager.dart` import。
3. **`lib/pages/crop_puzzle_page.dart`**：
   - 删除 line 409 的 `prewarmThumbnail(file.path)` 调用，清理 import。
4. **`lib/widgets/adaptive_hero_banner.dart`**：
   - 将 `ThumbnailDimension` 的 import 指向新建的 `lib/logic/cache/thumbnail_dimension.dart`。

### 4.9 适配 `integration_test/app_test.dart`

更新 FlutterError 过滤条件，将已被删除的 `'AppCachedNetworkImageProvider'` 替换为通用的网络加载异常过滤：
```dart
FlutterError.onError = (details) {
  final err = details.exceptionAsString();
  if (err.contains('Failed to load network thumbnail') ||
      err.contains('NetworkImageLoadException') ||
      err.contains('HttpException')) {
    return;
  }
  originalOnError?.call(details);
};
```

### 4.10 测试文件清理

1. 删除 `test/image_cache_manager_test.dart`、`test/logic/image_cache_lru_eviction_test.dart`。
2. 确保 `test/logic/image_crop_test.dart` 等其余测试不受影响。

---

## 5. 分阶段执行顺序与阶段验证

> 顺序原则：依赖底层优先（枚举与 resolver 先行），再改展示组件，最后清理调用方与删除旧实现。

| 阶段 | 动作 | 阶段验证 |
| --- | --- | --- |
| **P0 准备** | 确认工作树状态，通读最终清单 | `git status` 干净 |
| **P1 基础层** | 新建 `thumbnail_dimension.dart`，升级 `level_image_resolver.dart`（单飞 + 预热 + 通用落盘） | `flutter analyze` 0 error |
| **P2 展示层** | 改造 `app_cached_image.dart`（四分支 + `_NetworkImageLoader` + 骨架屏 Stack），改造 `lazy_level_image.dart` 透传尺寸 | `flutter analyze` 0 error |
| **P3 清理调用方** | `settings_page.dart` 删死代码（含 `didChangeDependencies`），`main.dart` 换 warmup，清理 `download_manager` 与 `crop_puzzle_page` 中的 prewarm，更新 `adaptive_hero_banner` import | `flutter analyze` 0 error |
| **P4 删除旧实现** | 删除 §4.1 五个文件 + §4.2 缩略方法 + §4.10 两个旧测试文件 | `flutter analyze` 0 error，`flutter test` 通过 |
| **P5 测试适配** | 适配 `integration_test/app_test.dart` 过滤规则 | `flutter test .\integration_test\app_test.dart -d windows` |
| **P6 全量验证** | 按照 §6 验收标准全部走查 | 见 §6 |
| **P7 规范收尾** | 对改动文件执行 `dart format`，登记变更日志 | 检查无多余 diff 与未使用的 import |

---

## 6. 验证与验收标准

### 6.1 自动化测试
1. `flutter analyze --no-fatal-infos --no-fatal-warnings` — 0 error。
2. `flutter test` — 全绿，重点确认 `image_crop_test.dart` 裁剪测试仍通过。
3. `flutter build windows --debug` — 编译通过。
4. `flutter test .\integration_test\app_test.dart -d windows` — 运行通过。

### 6.2 交互走查（全类型图片覆盖）
1. **本地关卡卡片**：每日挑战（30 张本地解压图）、主线关卡冷启动 3~5ms 瞬显，无排队、无骨架屏透明白洞。
2. **Event Hero Banner**：首屏横幅单次下载落盘后自动平滑淡入展示；杀进程二次启动毫秒级秒出；**断网开启飞行模式启动，Banner 仍能正常显示（离线可用）**。
3. **Collection 封面**：合集网格封面正常单次加载落盘并秒显；离线二次冷启动不裂图。
4. **并发去重验证**：快速滚动包含多个相同未落盘图片的列表，观察日志确认触发 Single-Flight 去重，无 `.part` 文件竞争写坏现象。
5. **设置页检查**：设置页无缓存清理入口，页面秒开无报错，无任何 `ImageCacheManager` 遗留调用。

---

## 7. 行为变化与风险登记

| # | 变化/风险 | 影响 | 缓解对策 |
| --- | --- | --- | --- |
| 1 | **远程封面离线持久化** | 远端封面（Banner / 图集）需在断网时可用 | 通过 `LevelImageResolver.resolveUrlLocalPath` 自动原子落盘，兼具离线秒显与防冷启动白屏 |
| 2 | **网络并发下载去重** | 删去 TaskQueue 后并发写同一文件风险 | Resolver 内置 Single-Flight 机制，相同目标文件共享 Future，杜绝冲突 |
| 3 | **设置页功能变更** | 不再提供清空缓存功能 | 符合用户决策，且封面与关卡占用小、离线价值高，保护数据永不被误删 |
| 4 | **引擎 ImageCache 上限** | 默认 100MB / 1000 张 | 360px 解码图约 0.4MB，720px 约 1.5MB，列表可见窗口 ~15MB，远低于 100MB 上限，极端情况自动 LRU 淘汰 |
| 5 | **集成测试稳定性** | 异常类型变动引起测试偶发报错 | 适配 `app_test.dart` 过滤通用网络加载异常 |

---

## 8. 覆盖范围说明（不在本次范围）

- `DownloadManager` 的 `download_cache`、`AppContent` 的 manifest/levels 内容缓存、`levels/main|daily|events|packs|custom` 目录语义均不受影响。
- `levels/network` 目录受保护，永久作为离线资产保留。
- `GamePage` 拼图切片算法、难度选择面板核心逻辑保持零改动。
- 不引入任何第三方图片缓存插件（`cached_network_image` / `flutter_cache_manager` 等）。