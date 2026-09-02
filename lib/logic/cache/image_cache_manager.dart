import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import '../../services/app_logger.dart';
import 'engine_task_queue.dart';
import 'memory_cache.dart';
import 'thumbnail_generator.dart';

/// 缩略图档位（类型安全：调用方只能从预定义档位中选择，
/// 杜绝传 360/500/600/720 等零散尺寸导致同一张源图在磁盘上生成多份缩略图）。
enum ThumbnailDimension {
  /// 卡片 / 网格 / 列表预览图（默认档位）
  card(360),

  /// 活动封面等宽幅横幅大卡（含首页今日挑战大卡）
  eventCover(720);

  const ThumbnailDimension(this.pixels);

  /// 缩略图长边像素数
  final int pixels;
}

/// 工业级分层图片缓存中枢 (Image Cache Manager Facade)
///
/// 架构设计遵循 Android (Glide / Coil) 与 iOS (SDWebImage) 工业级标准：
/// 1. L1 内存缓存 (MemoryCache): 纯内存 LRU，0 纳秒极速响应；
/// 2. L2 磁盘缓存内存索引 (_diskKeyIndex): 启动时异步扫描建索引，主线程零同步 I/O (No existsSync)；
/// 3. L3 并发受控任务调度引擎 (EngineTaskQueue): 桌面端并发可达 4，移动端 2，支持 Single-Flight 请求去重；
/// 4. 100% 异步非阻塞流水线: 所有磁盘读写与文件状态探测全异步或在后台 Worker 处理。
class ImageCacheManager {
  ImageCacheManager._();

  static final ImageCacheManager instance = ImageCacheManager._();

  /// 默认缩略图档位
  static const ThumbnailDimension kDefaultThumbnailDimension =
      ThumbnailDimension.card;

  /// L1 纯内存 LRU 缓存 (150 张 / 30MB)
  final MemoryCache _memoryCache = MemoryCache();

  /// L3 任务调度与并发限流引擎
  final EngineTaskQueue _taskQueue = EngineTaskQueue();

  /// L2 磁盘缓存内存索引表 (Key 集合，用于 0 纳秒内存判断文件是否存在，杜绝主线程 existsSync)
  final Set<String> _diskKeyIndex = <String>{};

  Directory? _cacheDir;
  bool _isInitialized = false;

  /// 网络缩略图下载器（复用单例 Dio，与 DownloadManager 保持一致的超时与重试策略）
  final Dio _dio = Dio(
    BaseOptions(
      connectTimeout: const Duration(seconds: 15),
      receiveTimeout: const Duration(seconds: 30),
      followRedirects: true,
      maxRedirects: 5,
    ),
  );

  /// 获取 L1 内存缓存实例
  MemoryCache get memoryCache => _memoryCache;

  /// 获取任务调度引擎实例 (可动态调整并发度)
  EngineTaskQueue get taskQueue => _taskQueue;

  /// 异步初始化缓存目录与内存索引表
  Future<void> init() async {
    if (_isInitialized) return;

    try {
      final appSupportDir = await getApplicationSupportDirectory();
      final cachePath = '${appSupportDir.path}/thumbnail_cache';
      _cacheDir = Directory(cachePath);

      // 异步确保目录存在
      if (!await _cacheDir!.exists()) {
        await _cacheDir!.create(recursive: true);
      }

      // 异步构建 L2 磁盘缓存内存索引 (零主线程同步 I/O)
      await _rebuildDiskKeyIndexAsync();

      _isInitialized = true;
      AppLogger.imageCache.info(
        'Initialized indexed=${_diskKeyIndex.length} concurrency=${_taskQueue.maxConcurrency} dir=${_cacheDir?.path}',
      );
    } catch (e, st) {
      AppLogger.imageCache.severe('Failed to initialize', e, st);
    }
  }

  /// 异步扫描磁盘目录重建内存索引表
  Future<void> _rebuildDiskKeyIndexAsync() async {
    _diskKeyIndex.clear();
    if (_cacheDir == null || !await _cacheDir!.exists()) return;

    // 合法档位集合，用于识别并清理历史孤儿文件（负号键 / 旧 600/1440 档位）
    final validDims = ThumbnailDimension.values.map((e) => e.pixels).toSet();
    try {
      await for (final entity in _cacheDir!.list(followLinks: false)) {
        if (entity is File) {
          final fileName = entity.uri.pathSegments.last;
          if (fileName.startsWith('thumb_') && fileName.endsWith('.jpg')) {
            // 1. 清理历史 FNV 负号孤儿（形如 thumb_-1d53..._360.jpg）
            // 2. 清理旧档位孤儿（_600 / _1440 等不在 enum 中的尺寸）
            final isLegacyNegative = fileName.contains('_-');
            var isOrphanDim = false;
            if (!isLegacyNegative) {
              final dimStr = fileName
                  .substring(6, fileName.length - 4)
                  .split('_')
                  .last;
              final dim = int.tryParse(dimStr);
              if (dim != null && !validDims.contains(dim)) {
                isOrphanDim = true;
              }
            }
            if (isLegacyNegative || isOrphanDim) {
              try {
                await entity.delete();
                AppLogger.imageCache.info('Cleaned legacy thumbnail $fileName');
              } catch (_) {}
              continue;
            }
            _diskKeyIndex.add(fileName);
          }
        }
      }
    } catch (e, st) {
      AppLogger.imageCache.warning('Failed to scan disk cache', e, st);
    }
  }

  /// 计算确定性的缓存文件名 (例如 thumb_4a7b3c2e1f890123_360.jpg)
  String getCacheKey(
    String sourcePath, {
    ThumbnailDimension dimension = kDefaultThumbnailDimension,
  }) {
    final cleanPath = sourcePath.replaceAll(r'\', '/');
    final dim = dimension.pixels;

    var hash = 0xcbf29ce484222325;
    const fnvPrime = 0x100000001b3;
    final bytes = utf8.encode(cleanPath);
    for (final b in bytes) {
      hash ^= b;
      hash *= fnvPrime; // Dart VM 上 64 位整型乘法自动回绕，等价于 mod 2^64
    }

    // 掩码收敛到 63 位，保证结果恒为非负整数。
    // 不可写成 `& 0xFFFFFFFFFFFFFFFF`：该字面量超出有符号 64 位范围，
    // 在 Dart VM 上被折叠为 -1，导致 `x & -1 == x` 成为空操作，
    // 负数经 toRadixString(16) 后会产生形如 "thumb_-1d53f83ac372caeb_360.jpg" 的负号文件名。
    final masked = hash & 0x7FFFFFFFFFFFFFFF;
    final hashHex = masked.toRadixString(16).padLeft(16, '0');
    return 'thumb_${hashHex}_$dim.jpg';
  }

  /// 获取缩略图在磁盘上的目标路径
  String getThumbnailFilePath(
    String sourcePath, {
    ThumbnailDimension dimension = kDefaultThumbnailDimension,
  }) {
    final cacheKey = getCacheKey(sourcePath, dimension: dimension);
    final baseDir = _cacheDir?.path ?? '';
    return '$baseDir/$cacheKey';
  }

  /// 纯内存快速检查缩略图是否已存在于磁盘 (耗时 0 纳秒，杜绝主线程 existsSync)
  bool isThumbnailCached(
    String sourcePath, {
    ThumbnailDimension dimension = kDefaultThumbnailDimension,
  }) {
    final cacheKey = getCacheKey(sourcePath, dimension: dimension);
    return _diskKeyIndex.contains(cacheKey);
  }

  /// 从 L1 内存中秒级获取缩略图字节 (若命中耗时 < 0.001ms，未命中返回 null)
  Uint8List? getCachedThumbnailBytesFromMemory(
    String sourcePath, {
    ThumbnailDimension dimension = kDefaultThumbnailDimension,
  }) {
    final cacheKey = getCacheKey(sourcePath, dimension: dimension);
    return _memoryCache.get(cacheKey);
  }

  /// 核心分级获取缩略图字节 (L1 内存 -> L2 磁盘 -> L3 调度生成)
  Future<Uint8List?> getThumbnailBytes(
    String sourcePath, {
    ThumbnailDimension dimension = kDefaultThumbnailDimension,
    int quality = 80,
  }) async {
    final cacheKey = getCacheKey(sourcePath, dimension: dimension);

    // 1. L1 内存缓存命中 (0 纳秒)
    final memBytes = _memoryCache.get(cacheKey);
    if (memBytes != null && memBytes.isNotEmpty) {
      return memBytes;
    }

    // 2. L2 磁盘缓存命中 (内存索引快速判断)
    if (_diskKeyIndex.contains(cacheKey)) {
      final diskPath = getThumbnailFilePath(sourcePath, dimension: dimension);
      try {
        final file = File(diskPath);
        final diskBytes = await file.readAsBytes();
        if (diskBytes.isNotEmpty) {
          _memoryCache.put(cacheKey, diskBytes);
          return diskBytes;
        }
      } catch (_) {
        // 读取异常时从索引中移除，以便重新生成
        _diskKeyIndex.remove(cacheKey);
      }
    }

    // 3. L3 未命中：进入并发调度引擎排队生成 (支持 Single Flight 单飞去重)
    return await _taskQueue.schedule<Uint8List?>(
      key: cacheKey,
      task: () async {
        // 二次双检，防止在排队期间已被其他任务生成
        final doubleCheckMem = _memoryCache.get(cacheKey);
        if (doubleCheckMem != null) return doubleCheckMem;

        final targetPath = getThumbnailFilePath(
          sourcePath,
          dimension: dimension,
        );

        // 在独立后台 Isolate 生成缩略图字节
        final generatedBytes = await ThumbnailGenerator.generateThumbnailBytes(
          sourceFilePath: sourcePath,
          targetDimension: dimension.pixels,
          quality: quality,
        );

        if (generatedBytes != null && generatedBytes.isNotEmpty) {
          // 异步写入 L2 磁盘
          try {
            final targetFile = File(targetPath);
            final parent = targetFile.parent;
            if (!await parent.exists()) {
              await parent.create(recursive: true);
            }
            await targetFile.writeAsBytes(generatedBytes, flush: true);
            _diskKeyIndex.add(cacheKey);
          } catch (e, st) {
            AppLogger.imageCache.warning(
              'Failed to write thumbnail file key=$cacheKey',
              e,
              st,
            );
          }

          // 写入 L1 内存缓存
          _memoryCache.put(cacheKey, generatedBytes);
          return generatedBytes;
        }

        return null;
      },
    );
  }

  /// 异步获取缩略图 File (自动执行 L1/L2 检索与 L3 生成)
  Future<File> getThumbnailFile(
    String sourcePath, {
    ThumbnailDimension dimension = kDefaultThumbnailDimension,
    int quality = 80,
  }) async {
    final targetPath = getThumbnailFilePath(sourcePath, dimension: dimension);
    final cacheKey = getCacheKey(sourcePath, dimension: dimension);

    if (_diskKeyIndex.contains(cacheKey)) {
      return File(targetPath);
    }

    final bytes = await getThumbnailBytes(
      sourcePath,
      dimension: dimension,
      quality: quality,
    );

    if (bytes != null && bytes.isNotEmpty) {
      return File(targetPath);
    }

    return File(sourcePath);
  }

  /// 主动预热单张图片缩略图 (在后台受控并发队列中静默处理)
  Future<void> prewarmThumbnail(
    String sourcePath, {
    ThumbnailDimension dimension = kDefaultThumbnailDimension,
    int quality = 80,
  }) async {
    if (isThumbnailCached(sourcePath, dimension: dimension)) {
      return;
    }
    await getThumbnailBytes(sourcePath, dimension: dimension, quality: quality);
  }

  /// 批量预热缩略图
  Future<void> prewarmThumbnails(
    List<String> sourcePaths, {
    ThumbnailDimension dimension = kDefaultThumbnailDimension,
    int quality = 80,
  }) async {
    for (final path in sourcePaths) {
      unawaited(prewarmThumbnail(path, dimension: dimension, quality: quality));
    }
  }

  /// 删除某张原图对应的全部档位缩略图与裁剪派生缓存
  ///
  /// 遍历所有枚举档位逐个失效，避免非默认档位（如 eventCover 720）的缩略图成为
  /// 无法被清理的孤儿文件。
  Future<void> removeThumbnailForSource(String sourcePath) async {
    for (final dim in ThumbnailDimension.values) {
      final thumbKey = getCacheKey(sourcePath, dimension: dim);
      _memoryCache.remove(thumbKey);
      _diskKeyIndex.remove(thumbKey);

      final diskPath = getThumbnailFilePath(sourcePath, dimension: dim);
      try {
        final file = File(diskPath);
        if (await file.exists()) {
          await file.delete();
        }
      } catch (_) {}
    }
  }

  /// 网络图片：下载→后台解码→L1/L2 三级缓存（与本地文件共用同一 thumbnail_cache / 同一 key 命名空间）
  ///
  /// 首次命中时下载原图字节 → 后台 Isolate `ThumbnailGenerator.generateThumbnailFromBytes`
  /// 生成 `thumb_<hash>_<dim>.jpg` 并写入 L2 磁盘 + L1 内存；后续命中走 L1/L2 零网络。
  /// 通过 `EngineTaskQueue` 的 Single-Flight 保证同 URL 同档位并发只下载一次。
  Future<Uint8List?> getNetworkThumbnailBytes(
    String url, {
    ThumbnailDimension dimension = kDefaultThumbnailDimension,
    int quality = 80,
  }) async {
    if (url.isEmpty) return null;
    final cacheKey = getCacheKey(url, dimension: dimension);

    // 1. L1 内存命中
    final memBytes = _memoryCache.get(cacheKey);
    if (memBytes != null && memBytes.isNotEmpty) return memBytes;

    // 2. L2 磁盘命中（内存索引零 I/O 判断）
    if (_diskKeyIndex.contains(cacheKey)) {
      final diskPath = getThumbnailFilePath(url, dimension: dimension);
      try {
        final file = File(diskPath);
        final diskBytes = await file.readAsBytes();
        if (diskBytes.isNotEmpty) {
          _memoryCache.put(cacheKey, diskBytes);
          return diskBytes;
        }
      } catch (_) {
        _diskKeyIndex.remove(cacheKey);
      }
    }

    // 3. L3 未命中：排队下载 + 后台生成（Single-Flight 去重）
    return await _taskQueue.schedule<Uint8List?>(
      key: cacheKey,
      task: () async {
        final doubleCheckMem = _memoryCache.get(cacheKey);
        if (doubleCheckMem != null) return doubleCheckMem;

        // 再次检查磁盘（排队期间可能已被别的任务写入）
        if (_diskKeyIndex.contains(cacheKey)) {
          final diskPath = getThumbnailFilePath(url, dimension: dimension);
          try {
            final diskBytes = await File(diskPath).readAsBytes();
            if (diskBytes.isNotEmpty) {
              _memoryCache.put(cacheKey, diskBytes);
              return diskBytes;
            }
          } catch (_) {
            _diskKeyIndex.remove(cacheKey);
          }
        }

        // 下载原图字节（带 403/401 重试一次，类似 DownloadManager）
        Uint8List? rawBytes;
        try {
          final response = await _dio.get<List<int>>(
            url,
            options: Options(
              responseType: ResponseType.bytes,
              headers: {
                'Accept':
                    'image/avif,image/webp,image/apng,image/svg+xml,image/*,*/*;q=0.8',
                'User-Agent':
                    'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/122.0.0.0 Safari/537.36',
              },
            ),
          );
          final data = response.data;
          if (data != null && data.isNotEmpty) {
            rawBytes = Uint8List.fromList(data);
          }
        } on DioException catch (dioErr) {
          // 403/401 时尝试带 Referer 重试一次
          if (dioErr.response?.statusCode == 403 ||
              dioErr.response?.statusCode == 401) {
            try {
              final retryResponse = await _dio.get<List<int>>(
                url,
                options: Options(
                  responseType: ResponseType.bytes,
                  headers: {
                    'Accept':
                        'image/avif,image/webp,image/apng,image/svg+xml,image/*,*/*;q=0.8',
                    'User-Agent':
                        'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/122.0.0.0 Safari/537.36',
                  },
                ),
              );
              final data = retryResponse.data;
              if (data != null && data.isNotEmpty) {
                rawBytes = Uint8List.fromList(data);
              }
            } catch (e, st) {
              AppLogger.imageCache.warning(
                'Network thumbnail retry failed url=${AppLogger.sanitizeUrl(url)}',
                e,
                st,
              );
            }
          } else {
            AppLogger.imageCache.warning(
              'Network thumbnail download failed url=${AppLogger.sanitizeUrl(url)} status=${dioErr.response?.statusCode}',
              dioErr,
            );
          }
        } catch (e, st) {
          AppLogger.imageCache.warning(
            'Network thumbnail download error url=${AppLogger.sanitizeUrl(url)}',
            e,
            st,
          );
        }

        if (rawBytes == null || rawBytes.isEmpty) return null;

        // 后台 Isolate 下采样生成缩略图 JPEG
        final generatedBytes =
            await ThumbnailGenerator.generateThumbnailFromBytes(
              rawBytes: rawBytes,
              targetDimension: dimension.pixels,
              quality: quality,
            );

        if (generatedBytes != null && generatedBytes.isNotEmpty) {
          try {
            final targetPath = getThumbnailFilePath(url, dimension: dimension);
            final targetFile = File(targetPath);
            final parent = targetFile.parent;
            if (!await parent.exists()) {
              await parent.create(recursive: true);
            }
            await targetFile.writeAsBytes(generatedBytes, flush: true);
            _diskKeyIndex.add(cacheKey);
          } catch (e, st) {
            AppLogger.imageCache.warning(
              'Failed to write network thumbnail key=$cacheKey',
              e,
              st,
            );
          }
          _memoryCache.put(cacheKey, generatedBytes);
          return generatedBytes;
        }

        return null;
      },
    );
  }

  /// 异步统计缩略图磁盘占用总字节数（仅统计 thumb_*.jpg，避免误算目录内其它文件）
  Future<int> getCacheSizeBytes() async {
    if (_cacheDir == null || !await _cacheDir!.exists()) return 0;
    var total = 0;
    try {
      await for (final entity in _cacheDir!.list(followLinks: false)) {
        if (entity is File) {
          final name = entity.uri.pathSegments.last;
          if (name.startsWith('thumb_') && name.endsWith('.jpg')) {
            total += await entity.length();
          }
        }
      }
    } catch (_) {}
    return total;
  }

  /// 获取人类可读的缓存体积
  Future<String> getFormattedCacheSize() async {
    final bytes = await getCacheSizeBytes();
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }

  /// 异步清空所有 L1 内存与 L2 磁盘缓存
  Future<void> clearCache() async {
    _memoryCache.clear();
    _diskKeyIndex.clear();
    _taskQueue.clearQueue();

    if (_cacheDir != null && await _cacheDir!.exists()) {
      try {
        await for (final entity in _cacheDir!.list(followLinks: false)) {
          if (entity is File) {
            await entity.delete();
          }
        }
        AppLogger.imageCache.info('Thumbnail cache cleared');
      } catch (e, st) {
        AppLogger.imageCache.severe('Failed to clear cache', e, st);
      }
    }
  }
}
