// P1-4：外部内容（manifest/JSON/网络）解析防御：脏数据跳过降级，不中断启动
// ignore_for_file: avoid_catches_without_on_clauses
import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:jigsawpuzzle/logic/content/models/canonical_id.dart';
import 'package:jigsawpuzzle/logic/content/models/puzzle_level_item.dart';
import 'package:jigsawpuzzle/logic/content/network/content_http_client.dart';
import 'package:jigsawpuzzle/logic/content/pipelines/atomic_replace.dart';
import 'package:jigsawpuzzle/logic/single_flight.dart';
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

  /// 最近一次 syncWithRemote 解析到的远端完整批次 ID 集合（供首启完整性校验）
  final Set<String> _lastRemoteBatchIds = <String>{};
  Set<String> get lastRemoteBatchIds => Set.unmodifiable(_lastRemoteBatchIds);

  /// 进行中的图片下载 (单飞防重：同关卡并发 ensure 复用同一 Future，防同路径并发写)
  final Map<String, Future<PuzzleLevelItem>> _inFlightDownloads = {};

  /// 图片刷新待重试的远端条目（id → 远端新元数据；外部评审①）。
  /// 刷新失败保留旧条目，有待重试时不得走版本短路，下次 sync 重试。
  /// 与批次完整性（首启门禁依赖）正交：批次 id 照常标记已处理。
  final Map<String, PuzzleLevelItem> _pendingRefresh = {};

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
          // 恢复上次 sync 解析到的远端完整批次集合（供幂等校验与短路判定）
          final cachedRemoteBatchIds =
              json['remoteBatchIds'] as List<dynamic>? ?? [];
          _lastRemoteBatchIds.clear();
          _lastRemoteBatchIds.addAll(
            cachedRemoteBatchIds.map((e) => e.toString()),
          );
          // 恢复图片刷新待重试条目（重启后同版本 sync 仍能重试，见短路条件）
          final cachedPending = json['pendingRefresh'];
          _pendingRefresh.clear();
          if (cachedPending is List) {
            for (final raw in cachedPending) {
              if (raw is Map<String, dynamic>) {
                final item = _parseLevelItem(raw);
                if (item != null && item.url.isNotEmpty) {
                  _pendingRefresh[item.id] = item;
                }
              }
            }
          }

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
    // 版本未变且已有数据，无需重复拉取 —— **仅当本地批次完整时短路**
    // （防止"某轮批次部分失败已把 localVersion 推高，后续重试/重启永久短路
    //   而本地缺角"的死局：批次不完整时必须继续拉 index 重灌 missingBatches）
    // 外部评审①：有图片刷新待重试时同样不得短路（旧 hash 仍在，下次必重试）。
    if (remoteVersion <= _localVersion &&
        _levelsMap.isNotEmpty &&
        _pendingRefresh.isEmpty &&
        _localBatchIds.containsAll(_lastRemoteBatchIds)) {
      AppLogger.mainPipe.fine('syncWithRemote skip version not newer');
      return false;
    }

    try {
      final json = await _httpClient.fetchJson(remoteUrl);
      if (json is! Map<String, dynamic>) {
        AppLogger.mainPipe.warning(
          'syncWithRemote index unexpected type ${json.runtimeType} '
          'url=${AppLogger.sanitizeUrl(remoteUrl)}',
        );
        return false;
      }

      final newVersion = (json['version'] as num?)?.toInt() ?? remoteVersion;
      var hasNewItems = false;
      // 待刷新图片：元数据循环内只收集，循环后有界并发刷新（见 ①②）。
      final pendingRefreshes = <PuzzleLevelItem>[];

      // 1. 统一分卷架构 (items / batches)
      // 统一分卷架构 (items)
      final rawBatches = json['items'] as List<dynamic>?;
      if (rawBatches != null && rawBatches.isNotEmpty) {
        final remoteBatches = rawBatches
            .whereType<Map<String, dynamic>>()
            .map(MainBatchInfo.fromJson)
            .toList();

        // 记录本次远端声明的完整批次集合（首启批次完整性校验依据）
        _lastRemoteBatchIds
          ..clear()
          ..addAll(remoteBatches.map((b) => b.batchId));

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
          if (batchJson is! Map<String, dynamic>) {
            AppLogger.mainPipe.warning(
              'syncWithRemote batch ${batch.batchId} unexpected type '
              '${batchJson.runtimeType} url=${AppLogger.sanitizeUrl(batchUrl)}',
            );
            continue;
          }

          final rawLevels = batchJson['items'] as List<dynamic>? ?? [];
          for (final raw in rawLevels) {
            if (raw is! Map<String, dynamic>) {
              AppLogger.mainPipe.warning(
                'syncWithRemote batch ${batch.batchId} skip malformed item '
                'type=${raw.runtimeType}',
              );
              continue;
            }
            // 将相对路径图片 URL 递归解析为绝对 URL (RFC 3986)
            final rawUrl = raw['url']?.toString() ?? '';
            if (rawUrl.isNotEmpty) {
              raw['url'] = ContentHttpClient.resolveUrl(batchUrl, rawUrl);
            }

            final level = _parseLevelItem(raw);
            if (level == null) {
              AppLogger.mainPipe.warning(
                'syncWithRemote batch ${batch.batchId} item missing url, skip '
                'rawKeys=${raw.keys.take(6).toList()}',
              );
              continue;
            }

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
                // P0-6（红线 R1）+ 外部评审①：远端内容更新时只推进与图片无关的
                // 元数据（tags/order），图片三元组（url/hash/fileSizeBytes）等
                // 刷新成功后再推进。失败则保留旧条目整体 → 下次 sync 因 hash
                // 仍不一致而重试，旧图持续可玩，绝不出现"新旧两空"与"永久旧图"。
                _levelsMap[level.id] = existing.copyWith(
                  tags: level.tags,
                  order: level.order != 0 ? level.order : existing.order,
                );
                hasNewItems = true;
                pendingRefreshes.add(level);
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
              // 全新关卡：若本地存在同名旧图，优先用 fileSizeBytes 快速筛查；
              // 无 fileSizeBytes 或大小匹配时再走 sha256 严格校验。
              // 红线 R1/R3（v8 修 e）：校验失配时**不删除**该文件——只把它标记为
              // “不可引用”（isLocal=false / localPath=null），后续懒下载会经
              // `.part` 原子落盘覆盖它；期间该文件不被任何条目/进度引用，
              // 因此不会出现“用错图”，也不再有任何删除既有文件的路径。
              final localFile = File(_getLocalImagePath(level.id, level.url));
              var isLocal = false;
              String? localPath = localFile.path;
              if (localFile.existsSync()) {
                final expectedSize = level.fileSizeBytes;
                if (expectedSize != null && expectedSize > 0) {
                  try {
                    final actualSize = await localFile.length();
                    if (actualSize != expectedSize) {
                      AppLogger.mainPipe.info(
                        'Stale local image for new level ${level.id} '
                        'size mismatch expected=$expectedSize actual=$actualSize '
                        '(keep file, not referenced)',
                      );
                      localPath = null;
                    }
                  } catch (_) {
                    AppLogger.mainPipe.warning(
                      'File size check failed for new level ${level.id}',
                    );
                  }
                }
                // fileSizeBytes 匹配或无法获取时，继续走 sha256 校验
                if (localPath != null) {
                  if (level.hash != null && level.hash!.isNotEmpty) {
                    final expectedHash = level.hash!;
                    final actualHash = await _sha256File(localFile);
                    if (actualHash != null && actualHash != expectedHash) {
                      // v8 修 e：同 size 分支——不删除，仅标记不可引用。
                      AppLogger.mainPipe.info(
                        'Stale local image for new level ${level.id} '
                        'expected=${expectedHash.substring(0, 12)} actual=${actualHash.substring(0, 12)} '
                        '(keep file, not referenced)',
                      );
                      localPath = null;
                    } else {
                      isLocal = true;
                    }
                  } else {
                    // 无 hash 时保守复用
                    isLocal = true;
                  }
                }
              }
              _levelsMap[level.id] = level.copyWith(
                localPath: isLocal ? localPath : null,
                isLocalFile: isLocal,
              );
              hasNewItems = true;
            }
          }
          _localBatchIds.add(batch.batchId);
        }
      }

      // 外部评审②：待刷新图片在元数据循环后有界并发执行（每批 4 个），避免
      // 串行下载拖慢同步（首启同步有 12s 预算）。单项失败保留旧条目，下次重试。
      // 批次已处理但图片仍未成功的历史待重试同样并入（循环内同 id 以远端最新为准）。
      for (final entry in _pendingRefresh.entries) {
        if (!pendingRefreshes.any((l) => l.id == entry.key)) {
          pendingRefreshes.add(entry.value);
        }
      }
      await _refreshPendingImages(pendingRefreshes);

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

  /// 确保指定关卡的图片已下载至本地磁盘 (按需懒加载，同关卡单飞防重)。
  ///
  /// [timeout] 透传至底层 Dio receiveTimeout：首启等强时限场景显式传入
  /// （如 8s）让 HTTP Socket 在超时点主动中断，避免外层 Future 已超时但底层
  /// 连接仍占用默认 60s（Dio）导致重试等待/文件并发写问题。未传则用 Dio 默认。
  Future<PuzzleLevelItem> ensureLevelImageDownloaded(
    PuzzleLevelItem level, {
    Duration? timeout,
  }) {
    return runSingleFlight(
      _inFlightDownloads,
      level.id,
      () => _ensureLevelImageDownloadedImpl(level, timeout: timeout),
    );
  }

  Future<PuzzleLevelItem> _ensureLevelImageDownloadedImpl(
    PuzzleLevelItem level, {
    Duration? timeout,
  }) async {
    // P1-1 管线内侧防呆：非 main: 前缀直接拒收，避免外部误调污染 _levelsMap
    // 与 main_levels_cache.json（见 LevelImageResolver 双重守卫）。
    if (!level.id.startsWith('${CanonicalId.prefixMain}:')) {
      throw ArgumentError.value(
        level.id,
        'level.id',
        'MainContentPipeline only accepts main: prefixed levels',
      );
    }
    if (level.isLocalFile &&
        level.localPath != null &&
        File(level.localPath!).existsSync()) {
      AppLogger.mainPipe.fine('ensureDownloaded already local ${level.id}');
      return level;
    }

    final localPath = _getLocalImagePath(level.id, level.url);
    final localFile = File(localPath);
    if (localFile.existsSync()) {
      // fileSizeBytes 快速筛查：大小不匹配时直接走下载逻辑覆盖。
      // P0-6（红线 R1）：此处不得预删旧图——downloadFile 经 .part 原子落盘，
      // 下载失败时旧图仍在；预删会制造“新旧两空”。
      final expectedSize = level.fileSizeBytes;
      if (expectedSize != null && expectedSize > 0) {
        try {
          final actualSize = await localFile.length();
          if (actualSize != expectedSize) {
            AppLogger.mainPipe.info(
              'Stale local image for ${level.id} '
              'size mismatch expected=$expectedSize actual=$actualSize, '
              'will refresh without pre-delete',
            );
            // 继续执行下面的下载逻辑（.part 落盘，失败保留旧图）
          } else {
            final updated = level.copyWith(
              localPath: localPath,
              isLocalFile: true,
            );
            _levelsMap[level.id] = updated;
            AppLogger.mainPipe.fine(
              'ensureDownloaded hit local file ${level.id} -> ${AppLogger.sanitizePath(localPath)}',
            );
            return updated;
          }
        } catch (e) {
          AppLogger.mainPipe.warning(
            'File size check failed for ${level.id}, fallback to sha256',
          );
        }
      } else {
        // 无 fileSizeBytes 时走保守路径（保持原有行为）
        final updated = level.copyWith(
          localPath: localPath,
          isLocalFile: true,
        );
        _levelsMap[level.id] = updated;
        AppLogger.mainPipe.fine(
          'ensureDownloaded hit local file ${level.id} -> ${AppLogger.sanitizePath(localPath)}',
        );
        return updated;
      }
    }

    AppLogger.mainPipe.info(
      'ensureDownloaded downloading ${level.id} from ${AppLogger.sanitizeUrl(level.url)} timeout=${timeout?.inSeconds ?? 60}s',
    );
    try {
      final downloaded = await _httpClient.downloadFile(
        level.url,
        localPath,
        timeout: timeout,
      );
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

    final title = raw['title']?.toString().trim();
    final fileSizeBytes = (raw['fileSizeBytes'] as num?)?.toInt();

    return PuzzleLevelItem(
      id: canonicalId,
      hash: hash,
      url: url,
      isLocalFile: false,
      order: order,
      tags: tags,
      title: (title != null && title.isNotEmpty) ? title : null,
      addedAt: addedAt,
      unlockCoins: (raw['unlockCoins'] as num?)?.toInt(),
      unlockCode: raw['unlockCode']?.toString(),
      fileSizeBytes: fileSizeBytes,
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

  /// P0-6：远端 hash/url 变更后的图片刷新。新图先下到临时路径并校验，
  /// 通过后再经 [_swapFileAtomically] 落位；任何失败都保留旧图与旧条目。
  ///
  /// 成功时将图片三元组（url/hash/fileSizeBytes）与新本地路径合并写入当前条目
  /// （远端 hash 缺失时显式清空以收敛，避免下次误判为变更而反复下载）；
  /// 失败时旧条目原样保留并记入 [_pendingRefreshIds] 供下次重试。
  Future<void> _refreshLevelImage(PuzzleLevelItem remote) async {
    if (remote.url.isEmpty) return;
    final targetPath = _getLocalImagePath(remote.id, remote.url);
    final tempPath = '$targetPath.new_${DateTime.now().millisecondsSinceEpoch}';
    final downloaded = await _httpClient.downloadFile(remote.url, tempPath);
    try {
      if (!downloaded.existsSync() || downloaded.lengthSync() == 0) {
        throw StateError('Downloaded empty image for ${remote.id}');
      }
      final expectedSize = remote.fileSizeBytes;
      if (expectedSize != null && expectedSize > 0) {
        final actualSize = downloaded.lengthSync();
        if (actualSize != expectedSize) {
          throw StateError(
            'Size mismatch for ${remote.id} expected=$expectedSize actual=$actualSize',
          );
        }
      }
      if (remote.hash != null && remote.hash!.isNotEmpty) {
        final actualHash = await _sha256File(downloaded);
        if (actualHash != null && actualHash != remote.hash) {
          throw StateError('Hash mismatch for ${remote.id}');
        }
      }
      await _swapFileAtomically(targetPath, tempPath);
      final base = _levelsMap[remote.id] ?? remote;
      var updated = base.copyWith(
        url: remote.url,
        tags: remote.tags,
        order: remote.order != 0 ? remote.order : base.order,
        localPath: targetPath,
        isLocalFile: true,
      );
      if (remote.hash != null) {
        updated = updated.copyWith(hash: remote.hash);
      } else {
        updated = updated.copyWith(clearHash: true);
      }
      if (remote.fileSizeBytes != null) {
        updated = updated.copyWith(fileSizeBytes: remote.fileSizeBytes);
      } else {
        updated = updated.copyWith(clearFileSizeBytes: true);
      }
      _levelsMap[remote.id] = updated;
      _pendingRefresh.remove(remote.id);
      AppLogger.mainPipe.info('Refreshed image ${remote.id} after hash change');
    } catch (_) {
      final tmp = File(tempPath);
      if (tmp.existsSync()) {
        try {
          tmp.deleteSync();
        } catch (_) {}
      }
      rethrow;
    }
  }

  /// 有界并发执行待刷新图片（外部评审②：每批 4 个，避免整批重编码时串行
  /// 下载拖慢同步乃至首启；单项失败保留旧条目并记入待重试，下次 sync 重试）。
  Future<void> _refreshPendingImages(List<PuzzleLevelItem> pending) async {
    if (pending.isEmpty) return;
    const limit = 4;
    for (var i = 0; i < pending.length; i += limit) {
      var end = i + limit;
      if (end > pending.length) end = pending.length;
      await Future.wait(
        pending.sublist(i, end).map((remote) async {
          try {
            await _refreshLevelImage(remote);
          } catch (e, st) {
            _pendingRefresh[remote.id] = remote;
            AppLogger.mainPipe.warning(
              'Refresh image failed, keep old file ${remote.id} (retry next sync)',
              e,
              st,
            );
          }
        }),
      );
    }
  }

  /// 原子文件替换：委托共享工具（P0-4），保持单一方实现。
  Future<void> _swapFileAtomically(String targetPath, String tempPath) =>
      swapFileAtomically(targetPath, tempPath);

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
              // 待重试与 ensure 体积筛查依赖（重启后仍有效）
              if (l.fileSizeBytes != null) 'fileSizeBytes': l.fileSizeBytes,
            },
          )
          .toList();
      final payload = {
        'version': _localVersion,
        'batchIds': _localBatchIds.toList(),
        if (_lastRemoteBatchIds.isNotEmpty)
          'remoteBatchIds': _lastRemoteBatchIds.toList(),
        if (_pendingRefresh.isNotEmpty)
          'pendingRefresh': _pendingRefresh.values
              .map((l) => l.toJson())
              .toList(),
        'items': items,
      };
      final tmpFile = File('$cacheFilePath.tmp');
      await tmpFile.writeAsString(jsonEncode(payload), flush: true);
      // P0-4：带回滚的原子替换（备份旧缓存，失败回滚），避免先删后改名丢派生缓存。
      await swapFileAtomically(file.path, tmpFile.path);
      AppLogger.mainPipe.fine(
        'Persisted cache version=$_localVersion batches=${_localBatchIds.length} count=${_levelsMap.length}',
      );
    } catch (e, st) {
      AppLogger.mainPipe.warning('Persist cache failed', e, st);
    }
  }

  /// 计算本地文件 SHA-256 十六进制字符串，失败返回 null
  Future<String?> _sha256File(File file) async {
    try {
      final bytes = await file.readAsBytes();
      return sha256.convert(bytes).toString();
    } catch (e) {
      AppLogger.mainPipe.warning('SHA-256 failed for ${file.path}', e);
      return null;
    }
  }
}
