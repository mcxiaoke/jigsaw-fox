// P1-4：图片/下载链路 best-effort：失败仅降级到备用来源，不阻断主流程
// ignore_for_file: avoid_catches_without_on_clauses
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:jigsawpuzzle/data/game_repository.dart';
import 'package:jigsawpuzzle/logic/cache/level_image_resolver.dart';
import 'package:jigsawpuzzle/logic/content/app_content.dart';
import 'package:jigsawpuzzle/logic/content/models/canonical_id.dart';
import 'package:jigsawpuzzle/logic/content/models/image_formats.dart';
import 'package:jigsawpuzzle/logic/content/models/puzzle_event_item.dart';
import 'package:path/path.dart' as p;

/// P0-7：按 canonicalId 直查本地已下载图片的最后兜底定位器。
///
/// - 只读不写，绝不删除任何数据；全部落空返回 null（调用方走 Toast 提示）。
/// - 正常路径仍是统一索引解析（P0-2 + P0-3），本定位器仅覆盖索引仍解析不到的
///   孤儿场景（如未被收藏的进行中关卡），不要把兜底逻辑塞进主流程。
/// - 限制：Array 模式的图集/活动关卡图片落在 `levels/network/net_<urlHash>.<ext>`，
///   hash 由 URL 决定，无法仅凭 canonicalId 反推；该场景依赖条目仍在管线
///   `_collectionsMap` / `_eventsMap`（P0-2 不删条目正是为此），经
///   `LevelImageResolver.getUrlLocalPathIfAvailable` 命中已缓存 URL。
class LocalImageLocator {
  const LocalImageLocator._();

  /// v8 修 b：扩展名探测列表派生自共享常量 [kImageExtensions]，避免与各管线
  /// 的白名单再次漂移（此前此处硬编码 4 项，与 `image_formats.dart` 重复）。
  static final List<String> _probeExtensions = <String>[
    for (final ext in kImageExtensions) '.$ext',
  ];

  /// 按 canonicalId 定位本地图片绝对路径；未命中返回 null。
  static String? locate(String canonicalId) {
    if (canonicalId.isEmpty) return null;
    if (!AppContent.instance.isInitialized) return null;
    try {
      final manager = AppContent.instance.manager;
      final info = CanonicalId.parse(canonicalId);
      switch (info.module) {
        case CanonicalId.prefixCollection:
          return _locateCollection(
            manager.collectionsPipeline.collectionsStorageBaseDir,
            collectionId: info.context ?? '',
            stem: info.name,
            canonicalId: canonicalId,
          );
        case CanonicalId.prefixEvent:
          return _locateEvent(
            manager.eventsPipeline.eventsStorageBaseDir,
            eventId: info.context ?? '',
            stem: info.name,
            canonicalId: canonicalId,
          );
        case CanonicalId.prefixMain:
          return _locateMain(
            manager.mainPipeline.imagesStorageDir,
            canonicalId: canonicalId,
          );
        case CanonicalId.prefixDaily:
          return _locateDaily(
            manager.dailyPipeline.dailyStorageBaseDir,
            dateStr: info.name,
          );
        case CanonicalId.prefixPack:
          return _locatePack(
            manager.packPipeline.packsBaseDir,
            packId: info.context ?? '',
            stem: info.name,
          );
        case CanonicalId.prefixUgc:
          return _locateUgc(info.name);
        default:
          return null;
      }
    } catch (_) {
      return null;
    }
  }

  /// 可测试的纯磁盘探测入口（不依赖 AppContent 单例）。
  @visibleForTesting
  static String? locateInDirectory(String dirPath, String stem) =>
      _findByStem(Directory(dirPath), stem);

  static String? _locateCollection(
    String baseDir, {
    required String collectionId,
    required String stem,
    required String canonicalId,
  }) {
    if (collectionId.isEmpty || stem.isEmpty) return null;
    // 1. 条目仍在管线内时优先走关卡映射（含 Array 模式的 URL 缓存）。
    try {
      final pipeline = AppContent.instance.manager.collectionsPipeline;
      final parent = pipeline.getCollectionById(collectionId);
      if (parent != null) {
        for (final lvl in pipeline.getLevelsForCollection(parent)) {
          if (lvl.id != canonicalId) continue;
          final local = lvl.localPath;
          if (local != null &&
              local.isNotEmpty &&
              !local.startsWith('http') &&
              File(local).existsSync()) {
            return local;
          }
          if (lvl.url.startsWith('http')) {
            final cached = LevelImageResolver.instance
                .getUrlLocalPathIfAvailable(lvl.url);
            if (cached != null) return cached;
          }
        }
      }
    } catch (_) {}
    // 2. zip 解压目录按文件名探测。
    return _findByStem(Directory(p.join(baseDir, collectionId)), stem);
  }

  static String? _locateEvent(
    String baseDir, {
    required String eventId,
    required String stem,
    required String canonicalId,
  }) {
    if (eventId.isEmpty || stem.isEmpty) return null;
    try {
      final manager = AppContent.instance.manager;
      final pipeline = manager.eventsPipeline;
      PuzzleEventItem? parent;
      for (final e in pipeline.allEvents) {
        if (e.id == eventId) {
          parent = e;
          break;
        }
      }
      if (parent != null) {
        for (final lvl in manager.getEventLevels(parent)) {
          if (lvl.id != canonicalId) continue;
          final local = lvl.localPath;
          if (local != null &&
              local.isNotEmpty &&
              !local.startsWith('http') &&
              File(local).existsSync()) {
            return local;
          }
          if (lvl.url.startsWith('http')) {
            final cached = LevelImageResolver.instance
                .getUrlLocalPathIfAvailable(lvl.url);
            if (cached != null) return cached;
          }
        }
      }
    } catch (_) {}
    return _findByStem(Directory(p.join(baseDir, eventId)), stem);
  }

  static String? _locateMain(String imagesDir, {required String canonicalId}) {
    try {
      final levels = AppContent.instance.manager.mainPipeline.levels;
      for (final l in levels) {
        if (l.id != canonicalId) continue;
        final local = l.localPath;
        if (local != null && local.isNotEmpty && File(local).existsSync()) {
          return local;
        }
      }
    } catch (_) {}
    // main 关卡 id 不含扩展名，按路径约定逐个试扩展名。
    final sanitized = canonicalId.replaceAll(':', '_');
    for (final ext in _probeExtensions) {
      final file = File(p.join(imagesDir, '$sanitized$ext'));
      try {
        if (file.existsSync() && file.lengthSync() > 0) return file.path;
      } catch (_) {}
    }
    return null;
  }

  static String? _locateDaily(String baseDir, {required String dateStr}) {
    if (dateStr.length < 6) return null;
    final monthKey = dateStr.substring(0, 6);
    final dir = Directory(p.join(baseDir, monthKey));
    if (!dir.existsSync()) {
      // 兼容带横线/无横线两种月份目录命名。
      final alt = dateStr.length >= 7
          ? Directory(p.join(baseDir, dateStr.substring(0, 7)))
          : null;
      if (alt == null || !alt.existsSync()) return null;
      return _findByStem(alt, dateStr);
    }
    return _findByStem(dir, dateStr);
  }

  static String? _locatePack(
    String baseDir, {
    required String packId,
    required String stem,
  }) {
    if (packId.isEmpty || stem.isEmpty) return null;
    return _findByStem(Directory(p.join(baseDir, packId)), stem);
  }

  static String? _locateUgc(String id) {
    if (id.isEmpty) return null;
    try {
      for (final custom in GameRepository.instance.customPuzzles) {
        if (custom.id != id) continue;
        final path = custom.imagePathOrUrl;
        if (path.isEmpty || path.startsWith('http')) continue;
        if (path.startsWith('assets/')) return path;
        try {
          if (File(path).existsSync()) return path;
        } catch (_) {}
      }
    } catch (_) {}
    return null;
  }

  /// 在 [dir] 内按“去扩展名后的文件名”匹配 [stem]；先试常见扩展名直连，
  /// 未命中再做一次目录扫描。只读，不产生任何写操作。
  static String? _findByStem(Directory dir, String stem) {
    if (stem.isEmpty) return null;
    try {
      if (!dir.existsSync()) return null;
      for (final ext in _probeExtensions) {
        final direct = File(p.join(dir.path, '$stem$ext'));
        try {
          if (direct.existsSync() && direct.lengthSync() > 0) {
            return direct.path;
          }
        } catch (_) {}
      }
      for (final entity in dir.listSync()) {
        if (entity is! File) continue;
        final base = p.basename(entity.path);
        final dot = base.lastIndexOf('.');
        final baseStem = dot > 0 ? base.substring(0, dot) : base;
        if (baseStem == stem) {
          try {
            if (entity.existsSync() && entity.lengthSync() > 0) {
              return entity.path;
            }
          } catch (_) {}
        }
      }
    } catch (_) {}
    return null;
  }
}
