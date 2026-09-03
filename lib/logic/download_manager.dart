import 'dart:io';
import 'dart:ui' as ui;

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:hive_ce/hive_ce.dart';
import 'package:image_picker/image_picker.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../data/models/downloaded_image_item.dart';
import '../data/storage_manager.dart';
import '../services/app_logger.dart';
import 'cache/image_cache_manager.dart';

/// Singleton manager for batch downloaded and locally imported images (Material Box / 素材库)
/// with local persistence, deduplication, and metadata parsing.
///
/// 存储迁移（设计 §2.2 / §5.4）：原 原下载素材大 key 单 key 大数组
/// 改为 `game-collections-v1` 的 `material:{id}` 逐条存储；init 一次性前缀读入
/// `itemsNotifier`（内存），聚合按 `downloadedAt` 降序，失效项同步删除 box key。
class DownloadManager {
  DownloadManager._();
  static final DownloadManager instance = DownloadManager._();

  static const String _keyPrefix = 'material:';
  final Dio _dio = Dio(
    BaseOptions(
      connectTimeout: const Duration(seconds: 20),
      receiveTimeout: const Duration(seconds: 60),
      followRedirects: true,
      maxRedirects: 5,
    ),
  );

  final ValueNotifier<List<DownloadedImageItem>> itemsNotifier =
      ValueNotifier<List<DownloadedImageItem>>([]);

  List<DownloadedImageItem> get items => itemsNotifier.value;

  bool _initialized = false;

  Box<dynamic> get _box => StorageManager.instance.collections;

  Future<void> init() async {
    if (_initialized) return;
    _initialized = true;
    try {
      // 先收集后批量删（§5.4：box.keys 迭代中 delete 属未定义行为）
      final keys = _box.keys
          .cast<String>()
          .where((k) => k.startsWith(_keyPrefix))
          .toList();
      final list = <DownloadedImageItem>[];
      final staleKeys = <String>[];
      for (final key in keys) {
        final m = getJson(_box, key);
        if (m == null) continue;
        final item = DownloadedImageItem.fromJson(m);
        // 失效过滤必须保留：localPath 已不存在的项剔除，且同步删除 box key，
        // 否则失效项永久驻留 box（§5.4 v4 补充）
        if (!File(item.localPath).existsSync()) {
          staleKeys.add(key);
          continue;
        }
        list.add(item);
      }
      for (final key in staleKeys) {
        await _box.delete(key);
      }

      // 聚合按 downloadedAt 降序（§3.3 排序约定：拆条后字典序 ≠ 业务时序）
      list.sort((a, b) => b.downloadedAt.compareTo(a.downloadedAt));
      itemsNotifier.value = list;
      AppLogger.download.info(
        'Loaded ${list.length} cached images (stale removed ${staleKeys.length})',
      );
    } catch (e, st) {
      AppLogger.download.severe('Failed to load cache', e, st);
    }
  }

  /// 单条落盘
  Future<void> _saveItem(DownloadedImageItem item) async {
    try {
      await putJson(_box, '$_keyPrefix${item.id}', item.toJson());
    } catch (e, st) {
      AppLogger.download.warning('Save item to hive failed', e, st);
    }
  }

  /// 内存 + box 同步插入（新项置顶）
  Future<void> _insertAtTop(DownloadedImageItem item) async {
    itemsNotifier.value = [item, ...itemsNotifier.value];
    await _saveItem(item);
  }

  /// Check if the image sourceUrl already exists in download drawer.
  bool isDownloaded(String sourceUrl) {
    if (sourceUrl.isEmpty) return false;
    return itemsNotifier.value.any((item) => item.sourceUrl == sourceUrl);
  }

  /// Batch import local image files (from system gallery / multi-picker) into material box.
  Future<List<DownloadedImageItem>> importFromLocalFiles(
    List<XFile> files,
  ) async {
    await init();
    if (files.isEmpty) return [];

    final appSupportDir = await getApplicationSupportDirectory();
    final cacheDir = Directory('${appSupportDir.path}/download_cache');
    if (!await cacheDir.exists()) {
      await cacheDir.create(recursive: true);
    }

    final newlyAdded = <DownloadedImageItem>[];

    for (var i = 0; i < files.length; i++) {
      final file = files[i];
      try {
        final rawBytes = await file.readAsBytes();
        if (rawBytes.isEmpty) continue;

        // Decode and validate
        final codec = await ui.instantiateImageCodec(rawBytes);
        final frame = await codec.getNextFrame();
        final width = frame.image.width;
        final height = frame.image.height;
        frame.image.dispose();
        codec.dispose();

        if (width < 100 || height < 100) {
          AppLogger.download.warning(
            'Skipped tiny image ${AppLogger.sanitizePath(file.path)} ${width}x$height',
          );
          continue;
        }

        final id = 'local_${DateTime.now().millisecondsSinceEpoch}_$i';
        final ext = file.name.contains('.') ? file.name.split('.').last : 'jpg';
        final targetPath = '${cacheDir.path}/mat_$id.$ext';
        final targetFile = File(targetPath);
        await targetFile.writeAsBytes(rawBytes);

        final item = DownloadedImageItem(
          id: id,
          sourceUrl: file.path,
          localPath: targetPath,
          sourcePlatform: '本地相册',
          width: width,
          height: height,
          downloadedAt: DateTime.now(),
          fileSizeBytes: rawBytes.length,
        );

        newlyAdded.add(item);
      } catch (e, st) {
        AppLogger.download.warning(
          'Error importing file ${AppLogger.sanitizePath(file.path)}',
          e,
          st,
        );
      }
    }

    if (newlyAdded.isNotEmpty) {
      // 新项置顶（下载/导入时序即列表时序），逐条落盘
      for (final item in newlyAdded) {
        await _insertAtTop(item);
      }
      AppLogger.download.info(
        'Successfully imported ${newlyAdded.length} local images total=${itemsNotifier.value.length}',
      );

      // Background pre-warm thumbnail caches for newly imported images
      for (final item in newlyAdded) {
        ImageCacheManager.instance.prewarmThumbnail(item.localPath);
      }
    }

    return newlyAdded;
  }

  /// Download or save image bytes, extract metadata, and register to download drawer.
  Future<DownloadedImageItem> saveOrDownloadImage({
    required String sourceUrl,
    required String sourcePlatform,
    String? refererUrl,
    String? userAgent,
    String? cookie,
    Uint8List? directBytes,
    void Function(double progress)? onProgress,
  }) async {
    await init();
    AppLogger.download.info(
      'Start platform=$sourcePlatform url=${AppLogger.sanitizeUrl(sourceUrl)} directBytes=${directBytes != null ? "${directBytes.length} bytes" : "false"}',
    );

    // Check duplicate
    final existing = itemsNotifier.value.where(
      (item) => item.sourceUrl == sourceUrl,
    );
    if (existing.isNotEmpty) {
      final item = existing.first;
      if (File(item.localPath).existsSync()) {
        AppLogger.download.info(
          'CacheHit returning existing file ${AppLogger.sanitizePath(item.localPath)}',
        );
        return item;
      }
    }

    final appSupportDir = await getApplicationSupportDirectory();
    final cacheDir = Directory('${appSupportDir.path}/download_cache');
    if (!await cacheDir.exists()) {
      await cacheDir.create(recursive: true);
    }

    final id = 'dl_${DateTime.now().millisecondsSinceEpoch}';
    final filePath = '${cacheDir.path}/img_$id.jpg';
    final targetFile = File(filePath);

    Uint8List rawBytes;

    if (directBytes != null && directBytes.isNotEmpty) {
      rawBytes = directBytes;
      await targetFile.writeAsBytes(rawBytes);
      if (onProgress != null) onProgress(1.0);
      AppLogger.download.info(
        'DirectSave written ${rawBytes.length} bytes to ${AppLogger.sanitizePath(filePath)}',
      );
    } else {
      final headers = <String, dynamic>{
        'Accept': '*/*',
        'User-Agent': (userAgent != null && userAgent.isNotEmpty)
            ? userAgent
            : 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/122.0.0.0 Safari/537.36',
      };

      Response<List<int>> response;
      try {
        AppLogger.download.info(
          'Dio requesting ${AppLogger.sanitizeUrl(sourceUrl)}',
        );
        response = await _dio.get<List<int>>(
          sourceUrl,
          options: Options(responseType: ResponseType.bytes, headers: headers),
          onReceiveProgress: (received, total) {
            if (total > 0 && onProgress != null) {
              onProgress(received / total);
            }
          },
        );
      } on DioException catch (dioErr) {
        AppLogger.download.warning(
          'DioError status=${dioErr.response?.statusCode} url=${AppLogger.sanitizeUrl(sourceUrl)}',
          dioErr,
        );
        // If 403 or error occurred, retry once with desktop browser headers and referer
        if (dioErr.response?.statusCode == 403 ||
            dioErr.response?.statusCode == 401) {
          AppLogger.download.info(
            'DioRetry with desktop headers url=${AppLogger.sanitizeUrl(sourceUrl)}',
          );
          final retryHeaders = <String, dynamic>{
            'Accept':
                'image/avif,image/webp,image/apng,image/svg+xml,image/*,*/*;q=0.8',
            'User-Agent':
                'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/122.0.0.0 Safari/537.36',
            if (refererUrl != null && refererUrl.isNotEmpty)
              'Referer': refererUrl,
          };
          response = await _dio.get<List<int>>(
            sourceUrl,
            options: Options(
              responseType: ResponseType.bytes,
              headers: retryHeaders,
            ),
          );
        } else {
          rethrow;
        }
      }

      final data = response.data;
      if (data == null || data.isEmpty) {
        throw Exception('下载数据为空');
      }
      rawBytes = Uint8List.fromList(data);
      await targetFile.writeAsBytes(rawBytes);
      AppLogger.download.info(
        'DioSuccess downloaded ${rawBytes.length} bytes to ${AppLogger.sanitizePath(filePath)}',
      );
    }

    // Parse and strictly validate image dimensions
    int width;
    int height;
    try {
      final codec = await ui.instantiateImageCodec(rawBytes);
      final frame = await codec.getNextFrame();
      width = frame.image.width;
      height = frame.image.height;
      frame.image.dispose();
      codec.dispose();
      AppLogger.download.info('Metadata parsed resolution ${width}x$height');

      // Reject tiny placeholder/icon images
      if (width < 200 || height < 200) {
        if (targetFile.existsSync()) targetFile.deleteSync();
        AppLogger.download.warning(
          'ValidationError rejected tiny resolution ${width}x$height',
        );
        throw Exception('图片分辨率过小 (${width}x$height)，并非有效的高清拼图素材');
      }
    } catch (e, st) {
      if (targetFile.existsSync()) {
        try {
          targetFile.deleteSync();
        } catch (_) {}
      }
      AppLogger.download.severe(
        'MetadataError could not decode valid image',
        e,
        st,
      );
      throw Exception('下载数据不是有效图片文件: $e');
    }

    final item = DownloadedImageItem(
      id: id,
      sourceUrl: sourceUrl,
      localPath: filePath,
      sourcePlatform: sourcePlatform,
      width: width,
      height: height,
      downloadedAt: DateTime.now(),
      fileSizeBytes: rawBytes.length,
    );

    itemsNotifier.value = [item, ...itemsNotifier.value];
    await _saveItem(item);
    AppLogger.download.info(
      'Complete added item $id ${width}x$height ${rawBytes.length} bytes total=${itemsNotifier.value.length}',
    );

    // Background pre-warm thumbnail for the downloaded image
    ImageCacheManager.instance.prewarmThumbnail(filePath);

    return item;
  }

  /// Delete a downloaded item from storage and file system.
  Future<void> deleteItem(String id) async {
    final list = List<DownloadedImageItem>.from(itemsNotifier.value);
    final idx = list.indexWhere((e) => e.id == id);
    if (idx != -1) {
      final item = list[idx];
      try {
        final f = File(item.localPath);
        if (f.existsSync()) {
          f.deleteSync();
        }
        await ImageCacheManager.instance.removeThumbnailForSource(
          item.localPath,
        );
      } catch (e, st) {
        AppLogger.download.warning('Delete error id=$id', e, st);
      }
      list.removeAt(idx);
      itemsNotifier.value = list;
      try {
        await _box.delete('$_keyPrefix$id');
      } catch (e, st) {
        AppLogger.download.warning('Delete box key failed id=$id', e, st);
      }
      AppLogger.download.info('Removed item $id remaining=${list.length}');
    } else {
      AppLogger.download.warning('Delete not found id=$id');
    }
  }

  /// Alias for deleteItem
  Future<void> removeItem(String id) => deleteItem(id);

  /// Clear all downloaded items
  Future<void> clearAll() async {
    for (final item in itemsNotifier.value) {
      try {
        final f = File(item.localPath);
        if (f.existsSync()) f.deleteSync();
        await ImageCacheManager.instance.removeThumbnailForSource(
          item.localPath,
        );
      } catch (_) {}
    }
    // 先收集后批量删（§5.4）
    final keys = _box.keys
        .cast<String>()
        .where((k) => k.startsWith(_keyPrefix))
        .toList();
    for (final key in keys) {
      try {
        await _box.delete(key);
      } catch (_) {}
    }
    itemsNotifier.value = [];
    AppLogger.download.info('All downloaded images cleared');
  }

  /// 重置（§7.6 步骤 4，本次新建）：直接清空 download_cache 目录——
  /// 物理文件命名有本地导入 `mat_*.{ext}` 与网络下载 `img_*.jpg` 两种，
  /// 重置语义即归零，不做脆弱的前缀匹配。
  Future<void> reset() async {
    // ① 遍历 {appSupport}/download_cache/ 全部文件逐个删除（扫盘天然覆盖
    //    内存可能为空的情形——init() 在 main 组2 后台不 await）
    try {
      final appSupportDir = await getApplicationSupportDirectory();
      final cacheDir = Directory('${appSupportDir.path}/download_cache');
      if (await cacheDir.exists()) {
        await for (final entity in cacheDir.list()) {
          if (entity is File) {
            try {
              await entity.delete();
            } catch (_) {}
          }
        }
      }
    } catch (e, st) {
      AppLogger.download.warning('reset download_cache failed', e, st);
    }
    // ② 清理 ImageCacheManager 缩略图缓存
    for (final item in itemsNotifier.value) {
      try {
        await ImageCacheManager.instance.removeThumbnailForSource(
          item.localPath,
        );
      } catch (_) {}
    }
    // ③ 清 box keys + itemsNotifier + _initialized 标志
    try {
      final keys = _box.keys
          .cast<String>()
          .where((k) => k.startsWith(_keyPrefix))
          .toList();
      for (final key in keys) {
        try {
          await _box.delete(key);
        } catch (_) {}
      }
    } catch (_) {}
    itemsNotifier.value = [];
    _initialized = false;
    AppLogger.download.info('DownloadManager.reset done');
  }

  /// 资源目录（供测试断言物理文件清理）
  static String materialKeyFor(String id) => '$_keyPrefix$id';

  /// 供测试/重置逻辑定位 download_cache 目录
  static Future<Directory> downloadCacheDir() async {
    final appSupportDir = await getApplicationSupportDirectory();
    return Directory(p.join(appSupportDir.path, 'download_cache'));
  }
}
