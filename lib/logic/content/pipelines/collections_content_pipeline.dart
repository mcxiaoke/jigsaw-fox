import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:flutter/foundation.dart';
import 'package:jigsawpuzzle/logic/content/models/canonical_id.dart';
import 'package:jigsawpuzzle/logic/content/models/puzzle_collection_item.dart';
import 'package:jigsawpuzzle/logic/content/models/puzzle_level_item.dart';
import 'package:jigsawpuzzle/logic/content/network/content_http_client.dart';
import 'package:jigsawpuzzle/services/app_logger.dart';
import 'package:path/path.dart' as p;

List<ArchiveFile> _decodeZipIsolate(List<int> bytes) {
  final archive = ZipDecoder().decodeBytes(bytes);
  return archive.files;
}

/// 图集中心管线 (Zip 整包 / Array 列表双载荷 + 下载进度通知 + 存储释放)
class CollectionsContentPipeline {
  CollectionsContentPipeline({
    required this.cacheFilePath,
    required this.collectionsStorageBaseDir,
    ContentHttpClient? httpClient,
  }) : _httpClient = httpClient ?? ContentHttpClient();

  final String cacheFilePath;
  final String collectionsStorageBaseDir;
  final ContentHttpClient _httpClient;

  final Map<String, PuzzleCollectionItem> _collectionsMap = {};

  /// 供 UI 响应图集列表或状态变更的通知器
  final ValueNotifier<int> updateNotifier = ValueNotifier<int>(0);

  /// 供图集卡片监听下载进度的通知器 (collectionId -> progress 0.0~1.0)
  final ValueNotifier<Map<String, double>> progressNotifier =
      ValueNotifier<Map<String, double>>({});

  static final RegExp _imageFileRegex = RegExp(
    r'\.(webp|jpg|jpeg|png)$',
    caseSensitive: false,
  );

  /// 获取面向玩家的所有非禁用图集列表 (按 displayOrder 升序排列)
  List<PuzzleCollectionItem> get visibleCollections {
    final list = _collectionsMap.values.where((c) => !c.isDisabled).toList();
    list.sort((a, b) => a.displayOrder.compareTo(b.displayOrder));
    return list;
  }

  /// 获取所有图集 (包括 disabled)
  List<PuzzleCollectionItem> get allCollections =>
      _collectionsMap.values.toList();

  /// 根据 ID 获取单个图集
  PuzzleCollectionItem? getCollectionById(String id) => _collectionsMap[id];

  /// 从本地缓存初始化加载 (秒开)
  Future<void> initializeFromCache() async {
    try {
      final file = File(cacheFilePath);
      if (file.existsSync()) {
        final text = await file.readAsString();
        final json = jsonDecode(text);
        if (json is List<dynamic>) {
          var loaded = 0;
          for (final raw in json) {
            if (raw is Map<String, dynamic>) {
              final item = PuzzleCollectionItem.fromJson(raw);
              final isDownloaded = _isCollectionLocalDownloaded(item);
              final localCount = isDownloaded
                  ? _getLocalImageCount(item.id)
                  : 0;
              final effectiveTotal = item.totalCount > 0
                  ? item.totalCount
                  : (localCount > 0 ? localCount : item.levels.length);
              _collectionsMap[item.id] = item.copyWith(
                isLocalDownloaded: isDownloaded,
                totalCount: effectiveTotal,
                downloadStatus: isDownloaded
                    ? CollectionDownloadStatus.downloaded
                    : CollectionDownloadStatus.notDownloaded,
              );
              loaded++;
            }
          }
          updateNotifier.value++;
          AppLogger.content.info(
            'Collections initializeFromCache loaded=$loaded file=${AppLogger.sanitizePath(cacheFilePath)}',
          );
        }
      } else {
        AppLogger.content.fine(
          'Collections initializeFromCache no cache ${AppLogger.sanitizePath(cacheFilePath)}',
        );
      }
    } catch (e, st) {
      AppLogger.content.warning(
        'Collections initializeFromCache failed',
        e,
        st,
      );
    }
  }

  /// 同步远端图集列表 (增量合并)
  Future<bool> syncWithRemote({required String remoteUrl}) async {
    if (remoteUrl.isEmpty) {
      AppLogger.content.fine('Collections syncWithRemote empty url, skip');
      return false;
    }
    AppLogger.content.info(
      'Collections syncWithRemote url=${AppLogger.sanitizeUrl(remoteUrl)}',
    );
    try {
      final json = await _httpClient.fetchJson(remoteUrl);
      final List<dynamic> rawList;
      if (json is Map<String, dynamic> && json['items'] is List) {
        rawList = json['items'] as List<dynamic>;
      } else {
        AppLogger.content.warning(
          'Collections syncWithRemote unexpected type or missing items: ${json.runtimeType}',
        );
        return false;
      }

      final updatedCollections = <PuzzleCollectionItem>[];
      var skipped = 0;
      for (final raw in rawList) {
        if (raw is Map<String, dynamic>) {
          try {
            // 相对路径 URL 递归解析 (RFC 3986)
            final cover = raw['coverUrl']?.toString();
            if (cover != null && cover.isNotEmpty) {
              raw['coverUrl'] = ContentHttpClient.resolveUrl(remoteUrl, cover);
            }
            final zip = raw['zipUrl']?.toString();
            if (zip != null && zip.isNotEmpty) {
              raw['zipUrl'] = ContentHttpClient.resolveUrl(remoteUrl, zip);
            }
            // zipUrls 备用镜像 (D10)：相对地址同样以 index 为基准解析
            final rawZipUrls = (raw['zipUrls'] as List<dynamic>?)
                ?.map(
                  (e) => ContentHttpClient.resolveUrl(remoteUrl, e.toString()),
                )
                .toList();
            if (rawZipUrls != null && rawZipUrls.isNotEmpty) {
              raw['zipUrls'] = rawZipUrls;
            }
            final levels = (raw['levels'] as List<dynamic>?)
                ?.map(
                  (e) => ContentHttpClient.resolveUrl(remoteUrl, e.toString()),
                )
                .toList();
            if (levels != null) {
              raw['levels'] = levels;
            }

            final item = PuzzleCollectionItem.fromJson(raw);
            final prevDownloaded =
                _collectionsMap[item.id]?.isLocalDownloaded == true;
            final isDownloaded =
                prevDownloaded || _isCollectionLocalDownloaded(item);
            final localCount = isDownloaded ? _getLocalImageCount(item.id) : 0;
            final effectiveTotal = item.totalCount > 0
                ? item.totalCount
                : (localCount > 0 ? localCount : item.levels.length);
            final updatedItem = item.copyWith(
              isLocalDownloaded: isDownloaded,
              totalCount: effectiveTotal,
              downloadStatus: isDownloaded
                  ? CollectionDownloadStatus.downloaded
                  : CollectionDownloadStatus.notDownloaded,
            );
            _collectionsMap[item.id] = updatedItem;
            updatedCollections.add(updatedItem);
          } catch (e, st) {
            skipped++;
            AppLogger.content.warning(
              'Collections syncWithRemote skip malformed $raw',
              e,
              st,
            );
          }
        }
      }

      await _persistToCache();
      updateNotifier.value++;
      AppLogger.content.info(
        'Collections syncWithRemote done total=${_collectionsMap.length} updated=${updatedCollections.length} skipped=$skipped',
      );
      return true;
    } catch (e, st) {
      AppLogger.content.warning('Collections syncWithRemote failed', e, st);
      return false;
    }
  }

  /// 确保图集的关卡资源就绪 (若为 Zip 模式则自动下载并解压)
  Future<bool> ensureCollectionDownloaded(
    PuzzleCollectionItem collection, {
    void Function(double progress)? onProgress,
  }) async {
    if (collection.isLocalDownloaded &&
        _isCollectionLocalDownloaded(collection)) {
      AppLogger.content.fine(
        'ensureCollectionDownloaded already ready ${collection.id}',
      );
      return true;
    }

    if (collection.isArrayType) {
      // Array 模式无需整包下载，即刻标记就绪
      _collectionsMap[collection.id] = collection.copyWith(
        isLocalDownloaded: true,
        downloadStatus: CollectionDownloadStatus.downloaded,
      );
      updateNotifier.value++;
      return true;
    }

    if (collection.isZipType) {
      if (collection.zipUrl == null || collection.zipUrl!.isEmpty) {
        AppLogger.content.warning(
          'ensureCollectionDownloaded empty zipUrl ${collection.id}',
        );
        return false;
      }

      // 更新状态为下载中
      _updateDownloadState(
        collection.id,
        0,
        CollectionDownloadStatus.downloading,
      );

      final tempZipPath = p.join(
        collectionsStorageBaseDir,
        'temp_${collection.id}_${DateTime.now().millisecondsSinceEpoch}.zip',
      );
      final targetDir = Directory(
        p.join(collectionsStorageBaseDir, collection.id),
      );
      final tempExtractDir = Directory(
        p.join(collectionsStorageBaseDir, 'temp_extract_${collection.id}'),
      );

      try {
        // 1. 下载 Zip 包 (D10：zipUrl 主地址 + zipUrls 备用镜像按序轮询，带进度反馈)
        final zipFile = await _httpClient.downloadFileWithMirrors(
          [
            collection.zipUrl!,
            ...collection.zipUrls.where((u) => u != collection.zipUrl),
          ],
          tempZipPath,
          onProgress: (received, total) {
            if (total > 0) {
              final pVal = (received / total).clamp(0.0, 1.0);
              _updateDownloadState(
                collection.id,
                pVal * 0.8,
                CollectionDownloadStatus.downloading,
              );
              onProgress?.call(pVal * 0.8);
            }
          },
        );

        final bytes = await zipFile.readAsBytes();

        // 2. 解压到临时目录 (Isolate)
        _updateDownloadState(
          collection.id,
          0.85,
          CollectionDownloadStatus.downloading,
        );
        final archive = await compute(_decodeZipIsolate, bytes);
        if (archive.length > 2000) {
          throw Exception('Zip file count excessive ${archive.length}');
        }

        if (tempExtractDir.existsSync()) {
          tempExtractDir.deleteSync(recursive: true);
        }
        tempExtractDir.createSync(recursive: true);

        var imageCount = 0;
        for (final file in archive) {
          final filename = p.basename(file.name);
          if (file.isFile && _imageFileRegex.hasMatch(filename)) {
            final outFile = File(p.join(tempExtractDir.path, filename));
            await outFile.writeAsBytes(file.content as List<int>, flush: true);
            imageCount++;
          }
        }

        // 3. 原子重命名到最终目录
        if (targetDir.existsSync()) {
          targetDir.deleteSync(recursive: true);
        }
        await tempExtractDir.rename(targetDir.path);

        // 4. 清理临时 Zip
        if (zipFile.existsSync()) {
          zipFile.deleteSync();
        }

        // 5. 更新图集项数据与状态
        final updated = collection.copyWith(
          isLocalDownloaded: true,
          totalCount: imageCount > 0 ? imageCount : collection.totalCount,
          downloadProgress: 1,
          downloadStatus: CollectionDownloadStatus.downloaded,
        );
        _collectionsMap[collection.id] = updated;
        _updateDownloadState(
          collection.id,
          1,
          CollectionDownloadStatus.downloaded,
        );
        await _persistToCache();
        updateNotifier.value++;
        AppLogger.content.info(
          'ensureCollectionDownloaded success ${collection.id} images=$imageCount',
        );
        return true;
      } catch (e, st) {
        AppLogger.content.severe(
          'ensureCollectionDownloaded failed ${collection.id}',
          e,
          st,
        );
        _updateDownloadState(
          collection.id,
          0,
          CollectionDownloadStatus.error,
        );
        if (tempExtractDir.existsSync()) {
          try {
            tempExtractDir.deleteSync(recursive: true);
          } catch (_) {}
        }
        final zf = File(tempZipPath);
        if (zf.existsSync()) {
          try {
            zf.deleteSync();
          } catch (_) {}
        }
        return false;
      }
    }

    return false;
  }

  /// 删除已下载的图集本地文件以释放存储空间
  Future<bool> deleteDownloadedCollection(String collectionId) async {
    final item = _collectionsMap[collectionId];
    if (item == null) return false;

    final targetDir = Directory(
      p.join(collectionsStorageBaseDir, collectionId),
    );
    try {
      if (targetDir.existsSync()) {
        targetDir.deleteSync(recursive: true);
      }
      _collectionsMap[collectionId] = item.copyWith(
        isLocalDownloaded: false,
        downloadProgress: 0,
        downloadStatus: CollectionDownloadStatus.notDownloaded,
      );
      final currentMap = Map<String, double>.from(progressNotifier.value);
      currentMap.remove(collectionId);
      progressNotifier.value = currentMap;
      await _persistToCache();
      updateNotifier.value++;
      AppLogger.content.info(
        'deleteDownloadedCollection success $collectionId',
      );
      return true;
    } catch (e, st) {
      AppLogger.content.warning(
        'deleteDownloadedCollection failed $collectionId',
        e,
        st,
      );
      return false;
    }
  }

  /// 获取指定图集下的所有关卡列表 (生成 Canonical ID: collection:{collectionId}:{filename})
  List<PuzzleLevelItem> getLevelsForCollection(
    PuzzleCollectionItem collection,
  ) {
    final items = <PuzzleLevelItem>[];

    if (collection.isZipType) {
      final colDir = Directory(
        p.join(collectionsStorageBaseDir, collection.id),
      );
      if (!colDir.existsSync()) return const [];

      final files = colDir
          .listSync()
          .whereType<File>()
          .where((f) => _imageFileRegex.hasMatch(f.path))
          .toList();
      files.sort((a, b) => p.basename(a.path).compareTo(p.basename(b.path)));

      final effectiveDate = collection.updatedAt ?? collection.startTime;
      var seq = 1;
      for (final file in files) {
        final filename = p.basename(file.path);
        final canonicalId = CanonicalId.forCollection(collection.id, filename);
        items.add(
          PuzzleLevelItem(
            id: canonicalId,
            localPath: file.path,
            isLocalFile: true,
            sourceModule: CanonicalId.prefixCollection,
            eventId: collection.id,
            order: seq++,
            addedAt: effectiveDate,
          ),
        );
      }
    } else if (collection.isArrayType) {
      final effectiveDate = collection.updatedAt ?? collection.startTime;
      var seq = 1;
      for (final url in collection.levels) {
        final filename = url.split('/').last.split('?').first;
        final canonicalId = CanonicalId.forCollection(collection.id, filename);
        items.add(
          PuzzleLevelItem(
            id: canonicalId,
            url: url,
            isLocalFile: false,
            sourceModule: CanonicalId.prefixCollection,
            eventId: collection.id,
            order: seq++,
            addedAt: effectiveDate,
          ),
        );
      }
    }

    return items;
  }

  bool _isCollectionLocalDownloaded(PuzzleCollectionItem collection) {
    if (collection.isArrayType) return true;
    final dir = Directory(p.join(collectionsStorageBaseDir, collection.id));
    if (!dir.existsSync()) return false;
    final hasImages = dir.listSync().whereType<File>().any(
      (f) => _imageFileRegex.hasMatch(f.path),
    );
    return hasImages;
  }

  int _getLocalImageCount(String collectionId) {
    final dir = Directory(p.join(collectionsStorageBaseDir, collectionId));
    if (!dir.existsSync()) return 0;
    return dir
        .listSync()
        .whereType<File>()
        .where((f) => _imageFileRegex.hasMatch(f.path))
        .length;
  }

  void _updateDownloadState(
    String id,
    double progress,
    CollectionDownloadStatus status,
  ) {
    final cur = _collectionsMap[id];
    if (cur != null) {
      _collectionsMap[id] = cur.copyWith(
        downloadProgress: progress,
        downloadStatus: status,
      );
    }
    final next = Map<String, double>.from(progressNotifier.value);
    next[id] = progress;
    progressNotifier.value = next;
  }

  Future<void> _persistToCache() async {
    try {
      final file = File(cacheFilePath);
      if (!file.parent.existsSync()) {
        file.parent.createSync(recursive: true);
      }
      final list = _collectionsMap.values.map((e) => e.toJson()).toList();
      await file.writeAsString(jsonEncode(list), flush: true);
    } catch (e, st) {
      AppLogger.content.warning('Collections _persistToCache failed', e, st);
    }
  }
}
