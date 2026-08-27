import 'dart:convert';
import 'dart:io';
import 'package:archive/archive.dart';
import 'package:path/path.dart' as p;
import '../models/canonical_id.dart';
import '../models/puzzle_event_item.dart';
import '../models/puzzle_level_item.dart';
import '../network/content_http_client.dart';

/// 活动中心管线 (Zip 整包 / Array 列表双载荷 + 状态机生命周期 + Auto-GC 垃圾回收)
class EventsContentPipeline {
  EventsContentPipeline({
    required this.cacheFilePath,
    required this.eventsStorageBaseDir,
    ContentHttpClient? httpClient,
  }) : _httpClient = httpClient ?? ContentHttpClient();

  final String cacheFilePath;
  final String eventsStorageBaseDir;
  final ContentHttpClient _httpClient;

  final Map<String, PuzzleEventItem> _eventsMap = {};

  static final RegExp _imageFileRegex = RegExp(r'\.(webp|jpg|jpeg|png)$', caseSensitive: false);

  /// 获取面向玩家的所有非禁用活动列表 (按 displayOrder 升序排列)
  List<PuzzleEventItem> get visibleEvents {
    final list = _eventsMap.values.where((e) => !e.isDisabled).toList();
    list.sort((a, b) => a.displayOrder.compareTo(b.displayOrder));
    return list;
  }

  /// 获取所有活动 (包括 disabled, 供内部状态检查)
  List<PuzzleEventItem> get allEvents => _eventsMap.values.toList();

  /// 从本地缓存初始化加载
  Future<void> initializeFromCache() async {
    try {
      final file = File(cacheFilePath);
      if (file.existsSync()) {
        final text = await file.readAsString();
        final json = jsonDecode(text);
        if (json is List<dynamic>) {
          for (final raw in json) {
            if (raw is Map<String, dynamic>) {
              final item = PuzzleEventItem.fromJson(raw);
              final isDownloaded = _isEventLocalDownloaded(item);
              _eventsMap[item.id] = item.copyWith(isLocalDownloaded: isDownloaded);
            }
          }
        }
      }
    } catch (_) {}
  }

  /// 同步远端活动列表并执行 Auto-GC 自动垃圾清理
  Future<bool> syncWithRemote({required String remoteUrl}) async {
    if (remoteUrl.isEmpty) return false;

    try {
      final json = await _httpClient.fetchJson(remoteUrl);
      if (json is! List<dynamic>) return false;

      final updatedEvents = <PuzzleEventItem>[];
      for (final raw in json) {
        if (raw is Map<String, dynamic>) {
          try {
            final item = PuzzleEventItem.fromJson(raw);
            final isDownloaded = _isEventLocalDownloaded(item);
            final updatedItem = item.copyWith(isLocalDownloaded: isDownloaded);
            _eventsMap[item.id] = updatedItem;
            updatedEvents.add(updatedItem);
          } catch (_) {
            // 跳过单条格式异常的活动
          }
        }
      }

      // 触发 Auto-GC 垃圾回收：自动清理 disabled 活动的本地沙盒目录
      await performAutoGc();

      // 持久化到缓存
      await _persistToCache();
      return true;
    } catch (_) {
      return false;
    }
  }

  /// 执行 Auto-GC 自动垃圾回收：删除已标记为 disabled 的活动的本地解压目录
  Future<int> performAutoGc() async {
    int deletedCount = 0;
    for (final event in _eventsMap.values) {
      if (event.isDisabled) {
        final eventDir = Directory(p.join(eventsStorageBaseDir, event.id));
        if (eventDir.existsSync()) {
          try {
            eventDir.deleteSync(recursive: true);
            deletedCount++;
          } catch (_) {}
        }
      }
    }
    return deletedCount;
  }

  /// 确保活动的关卡资源已就绪 (若为 Zip 模式则自动下载并解压)
  Future<bool> ensureEventDownloaded(PuzzleEventItem event) async {
    if (event.isLocalDownloaded && _isEventLocalDownloaded(event)) {
      return true;
    }

    if (event.isZipType) {
      if (event.zipUrl == null || event.zipUrl!.isEmpty) return false;
      final tempZipPath = p.join(eventsStorageBaseDir, 'temp_${event.id}_${DateTime.now().millisecondsSinceEpoch}.zip');
      final targetDir = Directory(p.join(eventsStorageBaseDir, event.id));
      final tempExtractDir = Directory(p.join(eventsStorageBaseDir, 'temp_extract_${event.id}'));

      try {
        // 1. 下载 Zip 包
        final zipFile = await _httpClient.downloadFile(event.zipUrl!, tempZipPath);
        final bytes = await zipFile.readAsBytes();

        // 2. 解压到临时目录
        final archive = ZipDecoder().decodeBytes(bytes);
        if (tempExtractDir.existsSync()) {
          tempExtractDir.deleteSync(recursive: true);
        }
        tempExtractDir.createSync(recursive: true);

        for (final file in archive) {
          final filename = p.basename(file.name);
          if (file.isFile && _imageFileRegex.hasMatch(filename)) {
            final outFile = File(p.join(tempExtractDir.path, filename));
            await outFile.writeAsBytes(file.content as List<int>, flush: true);
          }
        }

        // 3. 原子重命名到最终活动目录
        if (targetDir.existsSync()) {
          targetDir.deleteSync(recursive: true);
        }
        await tempExtractDir.rename(targetDir.path);

        // 4. 清理临时 Zip
        if (zipFile.existsSync()) {
          zipFile.deleteSync();
        }

        _eventsMap[event.id] = event.copyWith(isLocalDownloaded: true);
        await _persistToCache();
        return true;
      } catch (_) {
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
    } else {
      // Array 模式无需整包下载，即刻标记就绪
      return true;
    }
  }

  /// 获取指定活动下的所有关卡列表 (生成 Canonical ID: event:{eventId}:{filename})
  List<PuzzleLevelItem> getLevelsForEvent(PuzzleEventItem event) {
    final items = <PuzzleLevelItem>[];

    if (event.isZipType) {
      final eventDir = Directory(p.join(eventsStorageBaseDir, event.id));
      if (!eventDir.existsSync()) return const [];

      final files = eventDir.listSync().whereType<File>().where((f) => _imageFileRegex.hasMatch(f.path)).toList();
      // 自然排序
      files.sort((a, b) => p.basename(a.path).compareTo(p.basename(b.path)));

      int seq = 1;
      for (final file in files) {
        final filename = p.basename(file.path);
        final canonicalId = CanonicalId.forEvent(event.id, filename);
        items.add(
          PuzzleLevelItem(
            id: canonicalId,
            imagePathOrUrl: file.path,
            isLocalFile: true,
            sourceModule: CanonicalId.prefixEvent,
            eventId: event.id,
            order: seq++,
          ),
        );
      }
    } else if (event.isArrayType) {
      int seq = 1;
      for (final url in event.levels) {
        final filename = url.split('/').last.split('?').first;
        final canonicalId = CanonicalId.forEvent(event.id, filename);
        items.add(
          PuzzleLevelItem(
            id: canonicalId,
            imagePathOrUrl: url,
            isLocalFile: false,
            sourceModule: CanonicalId.prefixEvent,
            eventId: event.id,
            order: seq++,
          ),
        );
      }
    }

    return items;
  }

  bool _isEventLocalDownloaded(PuzzleEventItem event) {
    if (event.isArrayType) return true;
    final dir = Directory(p.join(eventsStorageBaseDir, event.id));
    return dir.existsSync() && dir.listSync().isNotEmpty;
  }

  Future<void> _persistToCache() async {
    try {
      final file = File(cacheFilePath);
      if (!file.parent.existsSync()) {
        file.parent.createSync(recursive: true);
      }
      final payload = _eventsMap.values.map((e) => e.toJson()).toList();
      await file.writeAsString(jsonEncode(payload), flush: true);
    } catch (_) {}
  }
}
