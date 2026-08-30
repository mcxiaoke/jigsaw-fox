import 'dart:convert';
import 'dart:io';
import '../models/canonical_id.dart';
import '../models/puzzle_level_item.dart';
import '../network/content_http_client.dart';
import '../../../services/app_logger.dart';

/// 首页主线关卡管线 (多标签筛选 + 增量版本同步 + 按需懒加载)
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
    return levels.where((l) => l.tags.map((t) => t.toLowerCase()).contains(trimmed)).toList();
  }

  /// 从本地缓存初始化加载
  Future<void> initializeFromCache() async {
    try {
      final file = File(cacheFilePath);
      if (file.existsSync()) {
        final text = await file.readAsString();
        final json = jsonDecode(text);
        if (json is Map<String, dynamic>) {
          _localVersion = (json['version'] as num?)?.toInt() ?? 0;
          final rawLevels = json['levels'] as List<dynamic>? ?? [];
          var loaded = 0;
          for (final raw in rawLevels) {
            if (raw is Map<String, dynamic>) {
              final level = _parseLevelItem(raw);
              if (level != null) {
                // 检查本地对应图片文件是否存在
                final localFile = File(_getLocalImagePath(level.id));
                final isLocal = localFile.existsSync();
                _levelsMap[level.id] = level.copyWith(
                  imagePathOrUrl: isLocal ? localFile.path : level.imagePathOrUrl,
                  isLocalFile: isLocal,
                );
                loaded++;
              }
            }
          }
          AppLogger.mainPipe.info('initializeFromCache version=$_localVersion loaded=$loaded file=${AppLogger.sanitizePath(cacheFilePath)}');
        } else {
          AppLogger.mainPipe.warning('initializeFromCache unexpected json type ${json.runtimeType}');
        }
      } else {
        AppLogger.mainPipe.fine('initializeFromCache no cache file ${AppLogger.sanitizePath(cacheFilePath)}');
      }
    } catch (e, st) {
      AppLogger.mainPipe.warning('initializeFromCache failed', e, st);
    }
  }

  /// 与远端同步增量更新 (若 remoteVersion > localVersion 则拉取)
  Future<bool> syncWithRemote({
    required String remoteUrl,
    required int remoteVersion,
  }) async {
    AppLogger.mainPipe.info('syncWithRemote remoteVersion=$remoteVersion localVersion=$_localVersion url=${AppLogger.sanitizeUrl(remoteUrl)} existing=${_levelsMap.length}');
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
      final rawLevels = json['levels'] as List<dynamic>? ?? [];

      bool hasNewItems = false;
      for (final raw in rawLevels) {
        if (raw is Map<String, dynamic>) {
          final level = _parseLevelItem(raw);
          if (level != null) {
            // Append-Only Upsert: 如果本地已存在，仅更新 tags，保留原有本地图片路径与存档
            final existing = _levelsMap[level.id];
            if (existing != null) {
              _levelsMap[level.id] = existing.copyWith(
                tags: level.tags,
                order: level.order != 0 ? level.order : existing.order,
              );
            } else {
              // 检查本地是否已有下载好的图片
              final localFile = File(_getLocalImagePath(level.id));
              final isLocal = localFile.existsSync();
              _levelsMap[level.id] = level.copyWith(
                imagePathOrUrl: isLocal ? localFile.path : level.imagePathOrUrl,
                isLocalFile: isLocal,
              );
              hasNewItems = true;
            }
          }
        }
      }

      _localVersion = newVersion;
      await _persistToCache();
      AppLogger.mainPipe.info('syncWithRemote done newVersion=$newVersion hasNew=$hasNewItems total=${_levelsMap.length}');
      return hasNewItems;
    } catch (e, st) {
      AppLogger.mainPipe.warning('syncWithRemote failed url=${AppLogger.sanitizeUrl(remoteUrl)}', e, st);
      return false;
    }
  }

  /// 确保指定关卡的图片已下载至本地磁盘 (按需懒加载)
  Future<PuzzleLevelItem> ensureLevelImageDownloaded(PuzzleLevelItem level) async {
    if (level.isLocalFile && File(level.imagePathOrUrl).existsSync()) {
      AppLogger.mainPipe.fine('ensureDownloaded already local ${level.id}');
      return level;
    }

    final localPath = _getLocalImagePath(level.id);
    final localFile = File(localPath);
    if (localFile.existsSync()) {
      final updated = level.copyWith(imagePathOrUrl: localPath, isLocalFile: true);
      _levelsMap[level.id] = updated;
      AppLogger.mainPipe.fine('ensureDownloaded hit local file ${level.id} -> ${AppLogger.sanitizePath(localPath)}');
      return updated;
    }

    AppLogger.mainPipe.info('ensureDownloaded downloading ${level.id} from ${AppLogger.sanitizeUrl(level.imagePathOrUrl)}');
    try {
      final downloaded = await _httpClient.downloadFile(level.imagePathOrUrl, localPath);
      final updated = level.copyWith(imagePathOrUrl: downloaded.path, isLocalFile: true);
      _levelsMap[level.id] = updated;
      AppLogger.mainPipe.info('ensureDownloaded done ${level.id} -> ${AppLogger.sanitizePath(downloaded.path)}');
      return updated;
    } catch (e, st) {
      AppLogger.mainPipe.severe('ensureDownloaded failed ${level.id}', e, st);
      rethrow;
    }
  }

  /// 解析单条服务端 main.json 中的 level 数据项
  PuzzleLevelItem? _parseLevelItem(Map<String, dynamic> raw) {
    final url = raw['url']?.toString();
    if (url == null || url.trim().isEmpty) return null;

    final tags = (raw['tags'] as List<dynamic>?)?.map((e) => e.toString().trim()).toList() ?? <String>[];
    final canonicalId = CanonicalId.fromSource(sourceModule: CanonicalId.prefixMain, pathOrUrl: url);

    // 从 ID 中尝试提取数字序号作为 order (如 main:101 -> 101)
    int order = 0;
    final namePart = canonicalId.split(':').last;
    final numMatch = RegExp(r'(\d+)').firstMatch(namePart);
    if (numMatch != null) {
      order = int.tryParse(numMatch.group(1)!) ?? 0;
    }

    return PuzzleLevelItem(
      id: canonicalId,
      imagePathOrUrl: url,
      isLocalFile: false,
      order: (raw['order'] as num?)?.toInt() ?? order,
      tags: tags,
      sourceModule: CanonicalId.prefixMain,
    );
  }

  /// 本地图片存储路径生成
  String _getLocalImagePath(String canonicalId) {
    final sanitized = canonicalId.replaceAll(':', '_');
    return '$imagesStorageDir/$sanitized.webp';
  }

  /// 持久化写入本地缓存 JSON
  Future<void> _persistToCache() async {
    try {
      final file = File(cacheFilePath);
      if (!file.parent.existsSync()) {
        file.parent.createSync(recursive: true);
      }
      final payload = {
        'version': _localVersion,
        'levels': _levelsMap.values.map((l) => {'url': l.imagePathOrUrl, 'order': l.order, 'tags': l.tags}).toList(),
      };
      await file.writeAsString(jsonEncode(payload), flush: true);
      AppLogger.mainPipe.fine('Persisted cache version=$_localVersion count=${_levelsMap.length}');
    } catch (e, st) {
      AppLogger.mainPipe.warning('Persist cache failed', e, st);
    }
  }
}
