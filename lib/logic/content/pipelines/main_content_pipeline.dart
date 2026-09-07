import 'dart:convert';
import 'dart:io';
import 'package:jigsawpuzzle/logic/content/models/canonical_id.dart';
import 'package:jigsawpuzzle/logic/content/models/puzzle_level_item.dart';
import 'package:jigsawpuzzle/logic/content/network/content_http_client.dart';
import 'package:jigsawpuzzle/services/app_logger.dart';

/// 主线不可变分卷信息模型
class MainBatchInfo {
  const MainBatchInfo({
    required this.batchId,
    required this.version,
    required this.url,
    this.count = 0,
    this.startOrder = 0,
    this.endOrder = 0,
    this.isPatch = false,
    this.levelsAffected = const [],
  });

  factory MainBatchInfo.fromJson(Map<String, dynamic> json) {
    return MainBatchInfo(
      batchId: json['batchId']?.toString() ?? '',
      version: (json['version'] as num?)?.toInt() ?? 0,
      url: json['url']?.toString() ?? '',
      count: (json['count'] as num?)?.toInt() ?? 0,
      startOrder: (json['startOrder'] as num?)?.toInt() ?? 0,
      endOrder: (json['endOrder'] as num?)?.toInt() ?? 0,
      isPatch: json['patch'] as bool? ?? false,
      levelsAffected:
          (json['levelsAffected'] as List<dynamic>?)
              ?.map((e) => (e as num).toInt())
              .toList() ??
          const [],
    );
  }

  final String batchId;
  final int version;
  final String url;
  final int count;
  final int startOrder;
  final int endOrder;
  final bool isPatch;
  final List<int> levelsAffected;
}

/// 首页主线关卡管线 (不可变批次差集同步 + 显式ID契约 + 纯异步热更修图 + 按需懒加载)
class MainContentPipeline {
  MainContentPipeline({
    required this.cacheFilePath,
    required this.imagesStorageDir,
    ContentHttpClient? httpClient,
  }) : _httpClient = httpClient ?? ContentHttpClient();

  final String cacheFilePath;
  final String imagesStorageDir;
  final ContentHttpClient _httpClient;

  int _localVersion = 0;
  int get localVersion => _localVersion;

  final Set<String> _localBatchIds = <String>{};
  Set<String> get localBatchIds => Set.unmodifiable(_localBatchIds);

  final Map<String, PuzzleLevelItem> _levelsMap = {};

  /// 获取当前已加载的所有首页关卡 (按 order 自然升序排序)
  List<PuzzleLevelItem> get levels {
    final list = _levelsMap.values.toList();
    list.sort((a, b) => a.order.compareTo(b.order));
    return list;
  }

  /// 获取所有已知不重复的标签列表
  List<String> get availableTags {
    final tagSet = <String>{};
    for (final level in _levelsMap.values) {
      tagSet.addAll(level.tags);
    }
    final list = tagSet.toList()..sort();
    return ['all', ...list];
  }

  /// 根据 Tag 标签在内存中快速过滤
  List<PuzzleLevelItem> filterByTag(String tag) {
    final trimmed = tag.trim().toLowerCase();
    if (trimmed.isEmpty || trimmed == 'all') {
      return levels;
    }
    return levels
        .where((l) => l.tags.map((t) => t.toLowerCase()).contains(trimmed))
        .toList();
  }

  /// 从本地缓存初始化加载 (离线秒开，彻底消除 ID 漂移)
  Future<void> initializeFromCache() async {
    try {
      final file = File(cacheFilePath);
      if (file.existsSync()) {
        final text = await file.readAsString();
        final json = jsonDecode(text);
        if (json is Map<String, dynamic>) {
          _localVersion = (json['version'] as num?)?.toInt() ?? 0;
          final cachedBatchIds = json['batchIds'] as List<dynamic>? ?? [];
          _localBatchIds.clear();
          _localBatchIds.addAll(cachedBatchIds.map((e) => e.toString()));

          final rawLevels = json['items'] as List<dynamic>? ?? [];
          var loaded = 0;
          for (final raw in rawLevels) {
            if (raw is Map<String, dynamic>) {
              final level = _parseLevelItem(raw);
              if (level != null) {
                // 检查本地对应图片文件是否存在
                final localFile = File(_getLocalImagePath(level.id, level.url));
                final isLocal = localFile.existsSync();
                _levelsMap[level.id] = level.copyWith(
                  localPath: isLocal ? localFile.path : null,
                  isLocalFile: isLocal,
                );
                loaded++;
              }
            }
          }
          AppLogger.mainPipe.info(
            'initializeFromCache version=$_localVersion batches=${_localBatchIds.length} loaded=$loaded file=${AppLogger.sanitizePath(cacheFilePath)}',
          );
        } else {
          AppLogger.mainPipe.warning(
            'initializeFromCache unexpected json type ${json.runtimeType}',
          );
        }
      } else {
        AppLogger.mainPipe.fine(
          'initializeFromCache no cache file ${AppLogger.sanitizePath(cacheFilePath)}',
        );
      }
    } catch (e, st) {
      AppLogger.mainPipe.warning('initializeFromCache failed', e, st);
    }
  }

  /// 与远端同步增量更新 (统一 items 分卷架构)
  Future<bool> syncWithRemote({
    required String remoteUrl,
    required int remoteVersion,
  }) async {
    AppLogger.mainPipe.info(
      'syncWithRemote remoteVersion=$remoteVersion localVersion=$_localVersion url=${AppLogger.sanitizeUrl(remoteUrl)} existing=${_levelsMap.length}',
    );
    if (remoteUrl.isEmpty) {
      AppLogger.mainPipe.warning('syncWithRemote empty url skip');
      return false;
    }
    // 版本未变且已有数据，无需重复拉取
    if (remoteVersion <= _localVersion && _levelsMap.isNotEmpty) {
      AppLogger.mainPipe.fine('syncWithRemote skip version not newer');
      return false;
    }

    try {
      final json = await _httpClient.fetchJson(remoteUrl);
      if (json is! Map<String, dynamic>) return false;

      final newVersion = (json['version'] as num?)?.toInt() ?? remoteVersion;
      var hasNewItems = false;

      // 1. 统一分卷架构 (items / batches)
      // 统一分卷架构 (items)
      final rawBatches = json['items'] as List<dynamic>?;
      if (rawBatches != null && rawBatches.isNotEmpty) {
        final remoteBatches = rawBatches
            .whereType<Map<String, dynamic>>()
            .map(MainBatchInfo.fromJson)
            .toList();

        // 差集计算：仅下载本地未处理的批次
        final missingBatches = remoteBatches
            .where((b) => !_localBatchIds.contains(b.batchId))
            .toList();

        AppLogger.mainPipe.info(
          'syncWithRemote batches total=${remoteBatches.length} missing=${missingBatches.length}',
        );

        // 严格遵循 Append-Only 数组顺序处理批次 (顺序决定补丁覆盖优先级)
        for (final batch in missingBatches) {
          final batchUrl = ContentHttpClient.resolveUrl(remoteUrl, batch.url);
          final batchJson = await _httpClient.fetchJson(batchUrl);
          if (batchJson is! Map<String, dynamic>) continue;

          final rawLevels = batchJson['items'] as List<dynamic>? ?? [];
          for (final raw in rawLevels) {
            if (raw is! Map<String, dynamic>) continue;
            // 将相对路径图片 URL 递归解析为绝对 URL (RFC 3986)
            final rawUrl = raw['url']?.toString() ?? '';
            if (rawUrl.isNotEmpty) {
              raw['url'] = ContentHttpClient.resolveUrl(batchUrl, rawUrl);
            }

            final level = _parseLevelItem(raw);
            if (level == null) continue;

            final existing = _levelsMap[level.id];
            if (existing != null) {
              // 同一关卡再次出现（修图补丁或配置更新）
              // 严格且仅以 Hash 变化或 URL 变化为准判断是否换图！
              final isImageHashChanged =
                  (level.hash != existing.hash) ||
                  (level.url.isNotEmpty &&
                      existing.url.isNotEmpty &&
                      level.url != existing.url);
              if (isImageHashChanged) {
                final oldPath =
                    existing.localPath != null && existing.localPath!.isNotEmpty
                    ? existing.localPath!
                    : _getLocalImagePath(level.id, existing.url);
                final oldFile = File(oldPath);
                if (await oldFile.exists()) {
                  try {
                    await oldFile.delete();
                    AppLogger.mainPipe.info(
                      'Deleted stale cached image for ${level.id} due to hash/url change: ${existing.hash} -> ${level.hash}',
                    );
                  } catch (e) {
                    AppLogger.mainPipe.warning(
                      'Failed to delete stale cache: $e',
                    );
                  }
                }
                // 更新为远端新信息，重置本地缓存，标记有新内容
                _levelsMap[level.id] = level.copyWith(
                  clearLocalPath: true,
                  isLocalFile: false,
                );
                hasNewItems = true;
              } else {
                // 内容未变，平滑更新 tags / order / url (保留已有 localPath)
                _levelsMap[level.id] = existing.copyWith(
                  url: level.url,
                  tags: level.tags,
                  order: level.order != 0 ? level.order : existing.order,
                  hash: level.hash ?? existing.hash,
                );
              }
            } else {
              // 全新关卡
              final localFile = File(_getLocalImagePath(level.id, level.url));
              final isLocal = await localFile.exists();
              _levelsMap[level.id] = level.copyWith(
                localPath: isLocal ? localFile.path : null,
                isLocalFile: isLocal,
              );
              hasNewItems = true;
            }
          }
          _localBatchIds.add(batch.batchId);
        }
      }

      _localVersion = newVersion;
      await _persistToCache();
      AppLogger.mainPipe.info(
        'syncWithRemote done newVersion=$newVersion hasNew=$hasNewItems total=${_levelsMap.length}',
      );
      return hasNewItems;
    } catch (e, st) {
      AppLogger.mainPipe.warning(
        'syncWithRemote failed url=${AppLogger.sanitizeUrl(remoteUrl)}',
        e,
        st,
      );
      return false;
    }
  }

  /// 确保指定关卡的图片已下载至本地磁盘 (按需懒加载)
  Future<PuzzleLevelItem> ensureLevelImageDownloaded(
    PuzzleLevelItem level,
  ) async {
    if (level.isLocalFile &&
        level.localPath != null &&
        File(level.localPath!).existsSync()) {
      AppLogger.mainPipe.fine('ensureDownloaded already local ${level.id}');
      return level;
    }

    final localPath = _getLocalImagePath(level.id, level.url);
    final localFile = File(localPath);
    if (await localFile.exists()) {
      final updated = level.copyWith(localPath: localPath, isLocalFile: true);
      _levelsMap[level.id] = updated;
      AppLogger.mainPipe.fine(
        'ensureDownloaded hit local file ${level.id} -> ${AppLogger.sanitizePath(localPath)}',
      );
      return updated;
    }

    AppLogger.mainPipe.info(
      'ensureDownloaded downloading ${level.id} from ${AppLogger.sanitizeUrl(level.url)}',
    );
    try {
      final downloaded = await _httpClient.downloadFile(level.url, localPath);
      final updated = level.copyWith(
        localPath: downloaded.path,
        isLocalFile: true,
      );
      _levelsMap[level.id] = updated;
      AppLogger.mainPipe.info(
        'ensureDownloaded done ${level.id} -> ${AppLogger.sanitizePath(downloaded.path)}',
      );
      return updated;
    } catch (e, st) {
      AppLogger.mainPipe.severe('ensureDownloaded failed ${level.id}', e, st);
      rethrow;
    }
  }

  /// 解析单条 level 数据项 (显式 ID 与 Hash 绝对优先，根除动态反推缺陷)
  PuzzleLevelItem? _parseLevelItem(Map<String, dynamic> raw) {
    final url = raw['url']?.toString();
    if (url == null || url.trim().isEmpty) return null;

    final tags =
        (raw['tags'] as List<dynamic>?)
            ?.map((e) => e.toString().trim())
            .toList() ??
        <String>[];

    // 核心硬规则：优先使用显式下发的稳定 Canonical ID (如 main:101)
    // 坚决杜绝补丁图片 0105-r2.webp 反推成 main:0105-r2 产生孪生关卡
    final explicitId = raw['id']?.toString().trim();
    final canonicalId = (explicitId != null && explicitId.isNotEmpty)
        ? explicitId
        : CanonicalId.fromSource(
            sourceModule: CanonicalId.prefixMain,
            pathOrUrl: url,
          );

    var order = (raw['order'] as num?)?.toInt() ?? 0;
    if (order == 0) {
      final namePart = canonicalId.split(':').last;
      final numMatch = RegExp(r'(\d+)').firstMatch(namePart);
      if (numMatch != null) {
        order = int.tryParse(numMatch.group(1)!) ?? 0;
      }
    }

    final hash = raw['hash']?.toString();
    final addedAt = raw['addedAt'] != null
        ? DateTime.tryParse(raw['addedAt'].toString())
        : null;

    return PuzzleLevelItem(
      id: canonicalId,
      hash: hash,
      url: url,
      isLocalFile: false,
      order: order,
      tags: tags,
      addedAt: addedAt,
      unlockCoins: (raw['unlockCoins'] as num?)?.toInt(),
      unlockCode: raw['unlockCode']?.toString(),
    );
  }

  /// 本地图片存储路径生成 (根据 URL 真实扩展名动态生成后缀)
  String _getLocalImagePath(String canonicalId, [String? url]) {
    final sanitized = canonicalId.replaceAll(':', '_');
    var ext = '.webp';
    if (url != null && url.isNotEmpty) {
      final lastDot = url.lastIndexOf('.');
      if (lastDot != -1 && lastDot > url.lastIndexOf('/')) {
        final rawExt = url.substring(lastDot).toLowerCase();
        final queryIndex = rawExt.indexOf('?');
        final cleanExt = queryIndex != -1
            ? rawExt.substring(0, queryIndex)
            : rawExt;
        if (['.webp', '.jpg', '.jpeg', '.png'].contains(cleanExt)) {
          ext = cleanExt;
        }
      }
    }
    return '$imagesStorageDir/$sanitized$ext';
  }

  /// 持久化写入本地缓存 JSON (原子安全落盘，显式保存 id 与 hash)
  Future<void> _persistToCache() async {
    try {
      final file = File(cacheFilePath);
      if (!file.parent.existsSync()) {
        file.parent.createSync(recursive: true);
      }
      final items = _levelsMap.values
          .map(
            (l) => {
              'id': l.id,
              if (l.hash != null) 'hash': l.hash,
              'url': l.url,
              if (l.localPath != null) 'localPath': l.localPath,
              'order': l.order,
              'tags': l.tags,
              if (l.addedAt != null) 'addedAt': l.addedAt!.toIso8601String(),
              if (l.unlockCoins != null) 'unlockCoins': l.unlockCoins,
              if (l.unlockCode != null) 'unlockCode': l.unlockCode,
            },
          )
          .toList();
      final payload = {
        'version': _localVersion,
        'batchIds': _localBatchIds.toList(),
        'items': items,
      };
      final tmpFile = File('$cacheFilePath.tmp');
      await tmpFile.writeAsString(jsonEncode(payload), flush: true);
      if (await file.exists()) {
        await file.delete();
      }
      await tmpFile.rename(file.path);
      AppLogger.mainPipe.fine(
        'Persisted cache version=$_localVersion batches=${_localBatchIds.length} count=${_levelsMap.length}',
      );
    } catch (e, st) {
      AppLogger.mainPipe.warning('Persist cache failed', e, st);
    }
  }
}
