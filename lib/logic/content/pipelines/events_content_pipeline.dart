// P1-4：外部内容（manifest/JSON/网络）解析防御：脏数据跳过降级，不中断启动
// ignore_for_file: avoid_catches_without_on_clauses
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:flutter/foundation.dart';
import 'package:jigsawpuzzle/logic/content/models/canonical_id.dart';
import 'package:jigsawpuzzle/logic/content/models/image_formats.dart';
import 'package:jigsawpuzzle/logic/content/models/puzzle_event_item.dart';
import 'package:jigsawpuzzle/logic/content/models/puzzle_level_item.dart';
import 'package:jigsawpuzzle/logic/content/network/content_http_client.dart';
import 'package:jigsawpuzzle/logic/content/pipelines/atomic_replace.dart';
import 'package:jigsawpuzzle/logic/single_flight.dart';
import 'package:jigsawpuzzle/services/app_logger.dart';
import 'package:path/path.dart' as p;

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

  /// 供活动卡片或详情页监听下载进度的通知器 (eventId -> progress 0.0~1.0)
  final ValueNotifier<Map<String, double>> progressNotifier =
      ValueNotifier<Map<String, double>>({});

  /// 活动列表/状态更新通知器 (供 UI 响应式刷新)
  final ValueNotifier<int> updateNotifier = ValueNotifier<int>(0);

  /// 进行中的下载单飞表 (同 id 并发 ensure 复用同一 Future，防互删临时目录)
  final Map<String, Future<bool>> _inFlightDownloads = {};

  /// 节流：上次通知进度的时间戳 (eventId -> timestamp ms)，至多 2 秒派发一次
  final Map<String, int> _lastProgressReportMs = {};

  bool isDownloading(String id) => _inFlightDownloads.containsKey(id);
  double getDownloadProgress(String id) => progressNotifier.value[id] ?? 0.0;

  void _updateDownloadProgress(String id, double progress) {
    final now = DateTime.now().millisecondsSinceEpoch;
    final last = _lastProgressReportMs[id] ?? 0;
    final isTerminal = progress <= 0.0 || progress >= 1.0;
    // 节流：终态（0% 或 100%）必须立即放行；中间进度至多 1 秒派发一次
    if (!isTerminal && (now - last < 1000)) {
      return;
    }
    _lastProgressReportMs[id] = now;
    if (isTerminal) {
      _lastProgressReportMs.remove(id);
    }

    final next = Map<String, double>.from(progressNotifier.value);
    next[id] = progress;
    progressNotifier.value = next;
  }

  /// 检查活动关卡是否已在本地就绪
  bool isEventDownloaded(PuzzleEventItem event) =>
      _isEventLocalDownloaded(event);

  // P1-5：图片白名单收敛为共享常量（大小写不敏感已是现状，勿重复改）。
  static final RegExp _imageFileRegex = kImageFileRegex;

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
          var loaded = 0;
          for (final raw in json) {
            if (raw is Map<String, dynamic>) {
              final item = PuzzleEventItem.fromJson(raw);
              final isDownloaded = _isEventLocalDownloaded(item);
              _eventsMap[item.id] = item.copyWith(
                isLocalDownloaded: isDownloaded,
              );
              loaded++;
            }
          }
          AppLogger.events.info(
            'initializeFromCache loaded=$loaded file=${AppLogger.sanitizePath(cacheFilePath)}',
          );
        }
      } else {
        AppLogger.events.fine(
          'initializeFromCache no cache ${AppLogger.sanitizePath(cacheFilePath)}',
        );
      }
    } catch (e, st) {
      AppLogger.events.warning('initializeFromCache failed', e, st);
    }
  }

  /// 同步远端活动列表并执行 Auto-GC 自动垃圾清理
  Future<bool> syncWithRemote({required String remoteUrl}) async {
    if (remoteUrl.isEmpty) {
      AppLogger.events.warning('syncWithRemote empty url');
      return false;
    }
    AppLogger.events.info(
      'syncWithRemote url=${AppLogger.sanitizeUrl(remoteUrl)}',
    );
    try {
      final json = await _httpClient.fetchJson(remoteUrl);
      final List<dynamic> rawList;
      if (json is Map<String, dynamic> && json['items'] is List) {
        rawList = json['items'] as List<dynamic>;
      } else {
        AppLogger.events.warning(
          'syncWithRemote unexpected type or missing items: ${json.runtimeType}',
        );
        return false;
      }

      final updatedEvents = <PuzzleEventItem>[];
      var skipped = 0;
      // P1-10 差集清理：收集远端 id 全集（含解析失败的原始 id，避免误删）
      final remoteIds = <String>{};
      for (final raw in rawList) {
        if (raw is Map<String, dynamic>) {
          final rawId = raw['id']?.toString();
          if (rawId != null && rawId.isNotEmpty) {
            remoteIds.add(rawId);
          }
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

            final item = PuzzleEventItem.fromJson(raw);
            // P20 保留已下载标记，避免竞态回退
            final prevDownloaded =
                _eventsMap[item.id]?.isLocalDownloaded == true;
            final isDownloaded =
                prevDownloaded || _isEventLocalDownloaded(item);
            final updatedItem = item.copyWith(isLocalDownloaded: isDownloaded);
            _eventsMap[item.id] = updatedItem;
            updatedEvents.add(updatedItem);
          } catch (e, st) {
            skipped++;
            AppLogger.events.warning(
              'syncWithRemote skip malformed event $raw',
              e,
              st,
            );
          }
        }
      }

      // P0-2（红线 R1）：Auto-GC 只统计、不删正式数据。确需清理仅限 temp_* 残留。
      final gcCount = await performAutoGc();
      if (gcCount > 0) {
        AppLogger.events.info('Auto-GC cleaned $gcCount temp dirs');
      }

      // P0-2（红线 R1）：远端缺失仅标记下架，不删条目、不删磁盘。
      // 重新上架时上循环会以远端新条目覆盖并自动清除标记。
      final delistedIds = _eventsMap.keys
          .where((id) => !remoteIds.contains(id))
          .toList();
      if (delistedIds.isNotEmpty) {
        for (final id in delistedIds) {
          final existing = _eventsMap[id];
          if (existing != null && !existing.isDelisted) {
            _eventsMap[id] = existing.copyWith(isDelisted: true);
          }
          AppLogger.events.info('syncWithRemote 标记下架活动 $id（仅标记，不删数据）');
        }
        AppLogger.events.info(
          'syncWithRemote 下架标记完成 delisted=${delistedIds.length}',
        );
      }

      // 持久化到缓存
      await _persistToCache();
      updateNotifier.value++;
      AppLogger.events.info(
        'syncWithRemote done events=${_eventsMap.length} updated=${updatedEvents.length} skipped=$skipped gc=$gcCount delisted=${delistedIds.length}',
      );
      return true;
    } catch (e, st) {
      AppLogger.events.warning('syncWithRemote failed', e, st);
      return false;
    }
  }

  /// P0-2（红线 R1）：Auto-GC 只清理**本次运行产物残留**，不删除任何正式数据。
  /// v8 修 a：统一改用 [cleanupStaleAtomicArtifacts]，在原有 `temp_*` 之外
  /// 一并回收原子替换崩溃残留的 `*.bak_<ts>`。
  Future<int> performAutoGc() =>
      cleanupStaleAtomicArtifacts(eventsStorageBaseDir, logTag: 'events');

  /// 确保活动的关卡资源已就绪 (若为 Zip 模式则自动下载并解压)。
  ///
  /// 单飞（P1-7）：同 id 进行中的调用复用同一 Future，避免并发下载互删
  /// temp_extract 临时目录。
  Future<bool> ensureEventDownloaded(
    PuzzleEventItem event, {
    void Function(double progress)? onProgress,
  }) {
    return runSingleFlight(
      _inFlightDownloads,
      event.id,
      () => _ensureEventDownloadedImpl(event, onProgress: onProgress),
    );
  }

  Future<bool> _ensureEventDownloadedImpl(
    PuzzleEventItem event, {
    void Function(double progress)? onProgress,
  }) async {
    // 关键修复：只要本地磁盘已有有效关卡图片，直接标记就绪，绝不重新下载
    if (_isEventLocalDownloaded(event)) {
      if (!event.isLocalDownloaded) {
        _eventsMap[event.id] = event.copyWith(isLocalDownloaded: true);
        unawaited(_persistToCache());
        updateNotifier.value++;
      }
      _updateDownloadProgress(event.id, 1.0);
      AppLogger.events.fine('ensureEventDownloaded already ready ${event.id}');
      return true;
    }

    if (event.isZipType) {
      if (event.zipUrl == null || event.zipUrl!.isEmpty) {
        AppLogger.events.warning(
          'ensureEventDownloaded empty zipUrl ${event.id}',
        );
        return false;
      }
      AppLogger.events.info(
        'ensureEventDownloaded zip ${event.id} url=${AppLogger.sanitizeUrl(event.zipUrl!)}',
      );
      final tempZipPath = p.join(
        eventsStorageBaseDir,
        'temp_${event.id}_${DateTime.now().millisecondsSinceEpoch}.zip',
      );
      final targetDir = Directory(p.join(eventsStorageBaseDir, event.id));
      final tempExtractDir = Directory(
        p.join(eventsStorageBaseDir, 'temp_extract_${event.id}'),
      );

      _updateDownloadProgress(event.id, 0.0);

      try {
        // 1. 下载 Zip 包 (带 25s 超时与进度回调)
        final zipFile = await _httpClient.downloadFileWithMirrors(
          [event.zipUrl!, ...event.zipUrls.where((u) => u != event.zipUrl)],
          tempZipPath,
          timeout: const Duration(seconds: 25),
          onProgress: (received, total) {
            if (total > 0) {
              final pVal = (received / total).clamp(0.0, 1.0);
              _updateDownloadProgress(event.id, pVal * 0.85);
              onProgress?.call(pVal * 0.85);
            }
          },
        );
        final bytes = await zipFile.readAsBytes();

        _updateDownloadProgress(event.id, 0.9);
        onProgress?.call(0.9);

        // 2. 解压到临时目录（P07 Isolate）
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

        // P1-7：解压出 0 张有效图视为失败，不标记已下载（红线 R3-②允许清理
        // 本次新建的空产物），避免「已下载 → 无图 → 反复整包重下」循环。
        if (imageCount == 0) {
          final sample = archive
              .take(5)
              .map((f) => p.basename(f.name))
              .toList();
          AppLogger.events.warning(
            'ensureEventDownloaded empty pack ${event.id} '
            'zipEntries=${archive.length} sample=$sample',
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
          _updateDownloadProgress(event.id, 0.0);
          return false;
        }

        // 3. 原子落位到最终活动目录（P0-4：备份旧目录，失败回滚）
        await swapDirectoryAtomically(
          targetDir,
          tempExtractDir,
          logTag: event.id,
        );

        // 4. 清理临时 Zip
        if (zipFile.existsSync()) {
          zipFile.deleteSync();
        }

        _eventsMap[event.id] = event.copyWith(isLocalDownloaded: true);
        await _persistToCache();
        _updateDownloadProgress(event.id, 1.0);
        onProgress?.call(1.0);
        updateNotifier.value++;
        AppLogger.events.info(
          'ensureEventDownloaded success ${event.id} images=$imageCount',
        );
        return true;
      } catch (e, st) {
        _updateDownloadProgress(event.id, 0.0);
        AppLogger.events.severe(
          'ensureEventDownloaded failed ${event.id}',
          e,
          st,
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
    } else {
      // Array 模式无需整包下载，即刻标记就绪（P2-7：与 zip 分支对齐持久化 + 通知，
      // 否则下载完成后 UI 不刷新）。持久化 best-effort 不阻塞返回，见 collections 侧注释。
      _eventsMap[event.id] = event.copyWith(isLocalDownloaded: true);
      unawaited(_persistToCache());
      _updateDownloadProgress(event.id, 1.0);
      updateNotifier.value++;
      return true;
    }
  }

  /// P2-11：删除已下载的活动本地文件以释放存储空间（与图集/图包对等）。
  /// P0-2 移除差集清理与 Auto-GC 后，这是活动包唯一的合法磁盘释放出口
  /// （红线 R3-③：用户显式操作）。仅重置条目状态，不删进度/收藏/快照。
  Future<bool> deleteDownloadedEvent(String eventId) async {
    final item = _eventsMap[eventId];
    if (item == null) return false;

    final targetDir = Directory(p.join(eventsStorageBaseDir, eventId));
    try {
      if (targetDir.existsSync()) {
        targetDir.deleteSync(recursive: true);
      }
      _eventsMap[eventId] = item.copyWith(isLocalDownloaded: false);
      final currentMap = Map<String, double>.from(progressNotifier.value);
      currentMap.remove(eventId);
      progressNotifier.value = currentMap;
      await _persistToCache();
      updateNotifier.value++;
      AppLogger.events.info('deleteDownloadedEvent success $eventId');
      return true;
    } catch (e, st) {
      AppLogger.events.warning(
        'deleteDownloadedEvent failed $eventId',
        e,
        st,
      );
      return false;
    }
  }

  /// 获取指定活动下的所有关卡列表 (生成 Canonical ID: event:{eventId}:{filename})
  List<PuzzleLevelItem> getLevelsForEvent(PuzzleEventItem event) {
    final items = <PuzzleLevelItem>[];

    if (event.isZipType) {
      final eventDir = Directory(p.join(eventsStorageBaseDir, event.id));
      if (!eventDir.existsSync()) return const [];

      final files = eventDir
          .listSync()
          .whereType<File>()
          .where((f) => _imageFileRegex.hasMatch(f.path))
          .toList();
      // 自然排序
      files.sort((a, b) => p.basename(a.path).compareTo(p.basename(b.path)));

      final effectiveDate = event.updatedAt ?? event.startTime;
      var seq = 1;
      for (final file in files) {
        final filename = p.basename(file.path);
        final canonicalId = CanonicalId.forEvent(event.id, filename);
        items.add(
          PuzzleLevelItem(
            id: canonicalId,
            localPath: file.path,
            isLocalFile: true,
            sourceModule: CanonicalId.prefixEvent,
            eventId: event.id,
            order: seq++,
            addedAt: effectiveDate,
          ),
        );
      }
    } else if (event.isArrayType) {
      final effectiveDate = event.updatedAt ?? event.startTime;
      var seq = 1;
      for (final url in event.levels) {
        final filename = url.split('/').last.split('?').first;
        final canonicalId = CanonicalId.forEvent(event.id, filename);
        items.add(
          PuzzleLevelItem(
            id: canonicalId,
            url: url,
            isLocalFile: false,
            sourceModule: CanonicalId.prefixEvent,
            eventId: event.id,
            order: seq++,
            addedAt: effectiveDate,
          ),
        );
      }
    }

    return items;
  }

  bool _isEventLocalDownloaded(PuzzleEventItem event) {
    if (event.isArrayType) return true;
    final dir = Directory(p.join(eventsStorageBaseDir, event.id));
    if (!dir.existsSync()) return false;
    return dir.listSync().whereType<File>().any(
      (f) => _imageFileRegex.hasMatch(f.path),
    );
  }

  Future<void> _persistToCache() async {
    try {
      final file = File(cacheFilePath);
      if (!file.parent.existsSync()) {
        file.parent.createSync(recursive: true);
      }
      final payload = _eventsMap.values.map((e) => e.toJson()).toList();
      await file.writeAsString(jsonEncode(payload), flush: true);
      AppLogger.events.fine(
        'Persisted events cache count=${_eventsMap.length}',
      );
    } catch (e, st) {
      AppLogger.events.warning('Persist events cache failed', e, st);
    }
  }

  static Archive _decodeZipIsolate(List<int> bytes) {
    return ZipDecoder().decodeBytes(bytes);
  }
}
