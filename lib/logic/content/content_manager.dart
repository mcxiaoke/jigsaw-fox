import 'dart:convert';
import 'dart:io';

import 'package:jigsawpuzzle/logic/content/models/puzzle_collection_item.dart';
import 'package:jigsawpuzzle/logic/content/models/puzzle_event_item.dart';
import 'package:jigsawpuzzle/logic/content/models/puzzle_level_item.dart';
import 'package:jigsawpuzzle/logic/content/models/root_manifest.dart';
import 'package:jigsawpuzzle/logic/content/network/content_http_client.dart';
import 'package:jigsawpuzzle/logic/content/pipelines/collections_content_pipeline.dart';
import 'package:jigsawpuzzle/logic/content/pipelines/daily_content_pipeline.dart';
import 'package:jigsawpuzzle/logic/content/pipelines/events_content_pipeline.dart';
import 'package:jigsawpuzzle/logic/content/pipelines/main_content_pipeline.dart';
import 'package:jigsawpuzzle/logic/content/pipelines/manifest_router.dart';
import 'package:jigsawpuzzle/logic/content/pipelines/pack_content_pipeline.dart';
import 'package:jigsawpuzzle/services/app_logger.dart';
import 'package:path/path.dart' as p;

/// 内容与扩展系统统一门面管理器 (Facade)
class ContentManager {
  ContentManager({
    required List<String> bootstrapUrls,
    required String appSupportDir,
    ContentHttpClient? httpClient,
  }) : manifestRouter = ManifestRouter(
         bootstrapUrls: bootstrapUrls,
         cacheFilePath: p.join(appSupportDir, 'manifest_cache.json'),
         httpClient: httpClient,
       ),
       mainPipeline = MainContentPipeline(
         cacheFilePath: p.join(appSupportDir, 'main_levels_cache.json'),
         imagesStorageDir: p.join(appSupportDir, 'levels', 'main'),
         httpClient: httpClient,
       ),
       dailyPipeline = DailyContentPipeline(
         dailyStorageBaseDir: p.join(appSupportDir, 'levels', 'daily'),
         httpClient: httpClient,
       ),
       eventsPipeline = EventsContentPipeline(
         cacheFilePath: p.join(appSupportDir, 'events_cache.json'),
         eventsStorageBaseDir: p.join(appSupportDir, 'levels', 'events'),
         httpClient: httpClient,
       ),
       collectionsPipeline = CollectionsContentPipeline(
         cacheFilePath: p.join(appSupportDir, 'collections_cache.json'),
         collectionsStorageBaseDir: p.join(
           appSupportDir,
           'levels',
           'collections',
         ),
         httpClient: httpClient,
       ),
       packPipeline = PackContentPipeline(
         packsBaseDir: p.join(appSupportDir, 'levels', 'packs'),
         httpClient: httpClient,
       ),
       _httpClient = httpClient ?? ContentHttpClient(),
       _dailyIndexCacheFilePath = p.join(
         appSupportDir,
         'daily_index_cache.json',
       );

  final ContentHttpClient _httpClient;
  final ManifestRouter manifestRouter;
  final MainContentPipeline mainPipeline;
  final DailyContentPipeline dailyPipeline;
  final EventsContentPipeline eventsPipeline;
  final CollectionsContentPipeline collectionsPipeline;
  final PackContentPipeline packPipeline;
  final String _dailyIndexCacheFilePath;

  RootManifest? get currentManifest => manifestRouter.currentManifest;

  bool _isSyncing = false;
  Future<Object?>? _syncFuture;

  /// 是否有网络同步正在进行（含后台全量轮）。UI 据此避免等待互斥轮导致转圈。
  bool get isSyncing => _isSyncing;
  bool _hasFetchedDailyIndex = false;
  final Map<String, String> _dailyMonthZipUrls = {};
  final Map<String, List<String>> _dailyMonthMirrorUrls = {};
  List<String> get availableDailyMonths => _dailyMonthZipUrls.keys.toList();

  /// 检查某月份是否在每日挑战远端索引中存在有效 ZIP 地址
  bool isDailyMonthAvailable(String yyyyMm) =>
      _dailyMonthZipUrls.containsKey(yyyyMm);

  /// 指定月份的每日挑战 zip 备用镜像（zipUrl 主地址失败时轮询）
  List<String> dailyMonthMirrorUrls(String yyyyMm) =>
      _dailyMonthMirrorUrls[yyyyMm] ?? const [];

  Future<void> _initializeDailyIndexFromCache() async {
    try {
      final file = File(_dailyIndexCacheFilePath);
      if (file.existsSync()) {
        final text = await file.readAsString();
        final json = jsonDecode(text);
        if (json is Map<String, dynamic>) {
          final rawZips = json['zipUrls'];
          if (rawZips is Map<String, dynamic>) {
            rawZips.forEach((k, v) {
              if (v is String) _dailyMonthZipUrls[k] = v;
            });
          }
          final rawMirrors = json['mirrorUrls'];
          if (rawMirrors is Map<String, dynamic>) {
            rawMirrors.forEach((k, v) {
              if (v is List) {
                _dailyMonthMirrorUrls[k] = v.map((e) => e.toString()).toList();
              }
            });
          }
          AppLogger.daily.info(
            'Daily index initialized from cache: ${_dailyMonthZipUrls.keys.toList()}',
          );
        }
      }
    } catch (e, st) {
      AppLogger.daily.warning('Failed to load daily index cache', e, st);
    }
  }

  Future<void> _saveDailyIndexCache() async {
    try {
      final file = File(_dailyIndexCacheFilePath);
      if (!file.parent.existsSync()) {
        file.parent.createSync(recursive: true);
      }
      final data = {
        'zipUrls': _dailyMonthZipUrls,
        'mirrorUrls': _dailyMonthMirrorUrls,
      };
      await file.writeAsString(jsonEncode(data), flush: true);
      AppLogger.daily.fine('Daily index cache saved successfully');
    } catch (e, st) {
      AppLogger.daily.warning('Failed to save daily index cache', e, st);
    }
  }

  /// 同步远端 daily/index.json 元数据 (带本地磁盘缓存与单飞防并发)
  Future<void> fetchDailyIndexMetadata({bool forceRefresh = false}) async {
    if (_hasFetchedDailyIndex && !forceRefresh) {
      return;
    }
    final manifest = currentManifest;
    if (manifest == null || manifest.dailyModule.url.isEmpty) {
      AppLogger.daily.warning(
        'fetchDailyIndexMetadata failed: manifest is null or dailyModule.url is empty',
      );
      return;
    }
    final dailyIndexUrl = ContentHttpClient.resolveUrl(
      manifest.baseUri,
      manifest.dailyModule.url,
    );
    AppLogger.daily.info(
      'fetchDailyIndexMetadata fetching daily index from $dailyIndexUrl',
    );
    try {
      final dailyJson = await _httpClient.fetchJson(dailyIndexUrl);
      if (dailyJson is Map<String, dynamic>) {
        final rawMonths = dailyJson['items'];
        if (rawMonths is List) {
          _dailyMonthZipUrls.clear();
          _dailyMonthMirrorUrls.clear();
          for (final m in rawMonths) {
            if (m is Map<String, dynamic>) {
              final monthStr = m['month']?.toString();
              final zip = m['zipUrl']?.toString();
              if (monthStr != null && zip != null) {
                _dailyMonthZipUrls[monthStr] = ContentHttpClient.resolveUrl(
                  dailyIndexUrl,
                  zip,
                );
              }
              // D10：zipUrls 备用镜像（相对地址以 daily/index.json 为基准解析）
              if (monthStr != null) {
                final rawMirrors = (m['zipUrls'] as List<dynamic>?)
                    ?.map(
                      (e) => ContentHttpClient.resolveUrl(
                        dailyIndexUrl,
                        e.toString(),
                      ),
                    )
                    .toList();
                if (rawMirrors != null && rawMirrors.isNotEmpty) {
                  _dailyMonthMirrorUrls[monthStr] = rawMirrors;
                }
              }
            }
          }
          _hasFetchedDailyIndex = true;
          AppLogger.daily.info(
            'fetchDailyIndexMetadata parsed ${rawMonths.length} months from daily index: ${_dailyMonthZipUrls.keys.toList()}',
          );
          await _saveDailyIndexCache();
        } else {
          AppLogger.daily.warning(
            'fetchDailyIndexMetadata unexpected items type: ${rawMonths.runtimeType}',
          );
        }
      }
    } catch (e, st) {
      AppLogger.daily.warning(
        'Failed to fetch daily index from $dailyIndexUrl',
        e,
        st,
      );
    }
  }

  /// 解析指定月份每日挑战 ZIP 地址 (优先读缓存，无则拉取 daily/index.json 解析)
  Future<String?> resolveDailyMonthZipUrl(String yyyyMm) async {
    if (_dailyMonthZipUrls.containsKey(yyyyMm)) {
      AppLogger.daily.info(
        'resolveDailyMonthZipUrl cache hit $yyyyMm -> ${_dailyMonthZipUrls[yyyyMm]}',
      );
      return _dailyMonthZipUrls[yyyyMm];
    }
    if (!_hasFetchedDailyIndex) {
      await fetchDailyIndexMetadata();
    }
    final resolvedUrl = _dailyMonthZipUrls[yyyyMm];
    AppLogger.daily.info(
      'resolveDailyMonthZipUrl result for $yyyyMm: $resolvedUrl',
    );
    return resolvedUrl;
  }

  /// 1. 初始化所有本地缓存与扩展包 (冷启动快速秒开)
  /// P20 优化：manifest 先读盘缓存，避免弱网 4-16s 阻塞秒开
  /// [offlineOnly] = true 时（组1 纯本地）磁盘未命中不发起网络，是否联网由 BootGate 决定
  Future<void> initialize({bool offlineOnly = false}) async {
    AppLogger.content.info(
      'ContentManager initialize start offlineOnly=$offlineOnly',
    );
    final sw = Stopwatch()..start();
    try {
      // manifest 先尝试磁盘缓存，网络留后台 syncAll
      final manifestFuture = manifestRouter.resolveManifestCacheFirst(
        offlineOnly: offlineOnly,
      );
      await Future.wait([
        manifestFuture,
        mainPipeline.initializeFromCache(),
        eventsPipeline.initializeFromCache(),
        collectionsPipeline.initializeFromCache(),
        _initializeDailyIndexFromCache(),
        packPipeline.loadAllPacks(),
      ]);
      AppLogger.content.info(
        'ContentManager initialize done ${sw.elapsedMilliseconds}ms main=${mainPipeline.levels.length} events=${eventsPipeline.visibleEvents.length} collections=${collectionsPipeline.visibleCollections.length} packs=${packPipeline.packsNotifier.value.length}',
      );
    } catch (e, st) {
      AppLogger.content.severe('ContentManager initialize failed', e, st);
      rethrow;
    }
  }

  /// 2. 全局网络增量同步（P20 互斥锁：进行中则等待当前轮，杜绝双写）
  ///
  /// [includeDailyZip] = false 时仅拉取 daily/index.json 元数据（月份 zip 地址 /
  /// 镜像），**不下载当月 zip**——用于下拉轻刷新等场景，zip 仍由 daily Tab 懒加载。
  Future<void> syncAll({
    DateTime? overrideToday,
    bool includeDailyZip = true,
  }) async {
    if (_isSyncing) {
      AppLogger.content.info('syncAll already in progress, wait previous');
      try {
        await _syncFuture;
      } catch (_) {}
      return;
    }
    _isSyncing = true;
    final future = _syncAllCore(
      overrideToday: overrideToday,
      includeDailyZip: includeDailyZip,
    );
    _syncFuture = future;
    try {
      await future;
    } finally {
      _isSyncing = false;
      _syncFuture = null;
    }
  }

  /// 首启门禁用：仅同步 manifest + main 元数据（不碰 events/collections/daily/zip），
  /// 与 [syncAll] 共享同一互斥锁，返回最新 RootManifest 供调用方校验。
  /// 网络全败时 resolveManifest 会降级 offline fallback（main url 为空），
  /// 由调用方判定并抛出首启失败。
  Future<RootManifest> syncMainContent() async {
    if (_isSyncing) {
      AppLogger.content.info(
        'syncMainContent wait previous sync, then run again',
      );
      try {
        await _syncFuture;
      } catch (_) {}
    }
    if (_isSyncing) {
      throw StateError('syncMainContent concurrency guard broken');
    }
    _isSyncing = true;
    final future = _syncMainCore();
    _syncFuture = future;
    try {
      return await future;
    } finally {
      _isSyncing = false;
      _syncFuture = null;
    }
  }

  Future<RootManifest> _syncMainCore() async {
    AppLogger.content.info('syncMainContent start');
    final sw = Stopwatch()..start();
    final manifest = await manifestRouter.resolveManifest(forceRefresh: true);
    final mainUrl = ContentHttpClient.resolveUrl(
      manifest.baseUri,
      manifest.mainModule.url,
    );
    if (manifest.mainModule.url.isEmpty || mainUrl.isEmpty) {
      throw StateError(
        'syncMainContent: manifest main module url empty (all CDN unreachable)',
      );
    }
    await mainPipeline.syncWithRemote(
      remoteUrl: mainUrl,
      remoteVersion: manifest.mainModule.version,
    );
    AppLogger.content.info(
      'syncMainContent done ${sw.elapsedMilliseconds}ms levels=${mainPipeline.levels.length} remoteBatches=${mainPipeline.lastRemoteBatchIds.length} localBatches=${mainPipeline.localBatchIds.length}',
    );
    return manifest;
  }

  Future<void> _syncAllCore({
    required bool includeDailyZip,
    DateTime? overrideToday,
  }) async {
    AppLogger.content.info(
      'syncAll start overrideToday=$overrideToday includeDailyZip=$includeDailyZip',
    );
    final sw = Stopwatch()..start();
    // 1. 获取最新 Root Manifest
    final manifest = await manifestRouter.resolveManifest(forceRefresh: true);
    AppLogger.content.info(
      'syncAll manifest resolved version=${manifest.schemaVersion} main=${AppLogger.sanitizeUrl(manifest.mainModule.url)} events=${AppLogger.sanitizeUrl(manifest.eventsModule.url)}',
    );

    final baseUri = manifest.baseUri;
    final mainUrl = ContentHttpClient.resolveUrl(
      baseUri,
      manifest.mainModule.url,
    );
    final eventsUrl = ContentHttpClient.resolveUrl(
      baseUri,
      manifest.eventsModule.url,
    );
    final collectionsUrl = ContentHttpClient.resolveUrl(
      baseUri,
      manifest.collectionsModule.url,
    );

    // 2. 并发同步各模块元数据
    try {
      await Future.wait([
        // 同步首页关卡
        mainPipeline
            .syncWithRemote(
              remoteUrl: mainUrl,
              remoteVersion: manifest.mainModule.version,
            )
            .then(
              (v) => AppLogger.content.info(
                'main sync done hasNew=$v levels=${mainPipeline.levels.length}',
              ),
            ),
        // 同步活动列表 (自动触发 Auto-GC)
        eventsPipeline
            .syncWithRemote(remoteUrl: eventsUrl)
            .then(
              (v) => AppLogger.content.info(
                'events sync done $v events=${eventsPipeline.visibleEvents.length}',
              ),
            ),
        // 同步官方图集列表
        collectionsPipeline
            .syncWithRemote(remoteUrl: collectionsUrl)
            .then(
              (v) => AppLogger.content.info(
                'collections sync done $v collections=${collectionsPipeline.visibleCollections.length}',
              ),
            ),
        // 预备当月每日挑战（每日 index 元数据必拉；zip 是否下载受 includeDailyZip 控制）
        () async {
          final currentMonth = overrideToday != null
              ? _formatCurrentMonth(overrideToday)
              : (manifest.dailyModule.currentMonth.isNotEmpty
                    ? manifest.dailyModule.currentMonth
                    : _formatCurrentMonth(DateTime.now()));

          final targetZipUrl = await resolveDailyMonthZipUrl(currentMonth);

          if (!includeDailyZip) {
            AppLogger.content.info(
              'syncAll includeDailyZip=false: daily meta resolved for $currentMonth (zip skipped)',
            );
            return;
          }

          if (targetZipUrl != null ||
              manifest.dailyModule.zipUrlPattern.isNotEmpty) {
            final ok = await dailyPipeline.ensureMonthReady(
              yyyyMm: currentMonth,
              zipUrlPattern: manifest.dailyModule.zipUrlPattern,
              explicitZipUrl: targetZipUrl,
              mirrorUrls: dailyMonthMirrorUrls(currentMonth),
              overrideToday: overrideToday,
            );
            AppLogger.content.info(
              'daily ensureMonthReady $currentMonth ok=$ok levels=${dailyPipeline.getLevelsForMonth(currentMonth, overrideToday: overrideToday).length}',
            );
          } else {
            AppLogger.content.fine(
              'daily zipUrl empty skip month $currentMonth',
            );
          }
        }(),
      ]);
      AppLogger.content.info('syncAll done ${sw.elapsedMilliseconds}ms');
    } catch (e, st) {
      AppLogger.content.severe(
        'syncAll failed ${sw.elapsedMilliseconds}ms',
        e,
        st,
      );
      rethrow;
    }
  }

  // --- 首页 Main 模块便捷代理 ---

  /// 获取首页所有关卡
  List<PuzzleLevelItem> getMainLevels() => mainPipeline.levels;

  /// 获取所有可用分类标签 (包含 'all')
  List<String> getMainTags() => mainPipeline.availableTags;

  /// 按标签过滤首页关卡
  List<PuzzleLevelItem> filterMainByTag(String tag) =>
      mainPipeline.filterByTag(tag);

  /// 确保指定首页关卡图片已下载 ([timeout] 透传至底层 Dio，首启强时限场景使用)
  Future<PuzzleLevelItem> ensureMainLevelDownloaded(
    PuzzleLevelItem level, {
    Duration? timeout,
  }) => mainPipeline.ensureLevelImageDownloaded(level, timeout: timeout);

  // --- 每日挑战 Daily 模块便捷代理 ---

  /// 本地已实际就绪且关卡非空的每日挑战月份列表 (按降序排列)
  List<String> get localReadyDailyMonths => dailyPipeline.getLocalReadyMonths();

  /// 获取指定月份每日关卡 (带时间锁)
  List<PuzzleLevelItem> getDailyLevelsForMonth(
    String yyyyMm, {
    DateTime? overrideToday,
  }) => dailyPipeline.getLevelsForMonth(yyyyMm, overrideToday: overrideToday);

  /// 获取当天官方发布的正式每日挑战关卡 (严格模式：本地无则返回 null)
  PuzzleLevelItem? getOfficialTodayLevel({DateTime? overrideToday}) =>
      dailyPipeline.getOfficialTodayLevel(overrideToday: overrideToday);

  /// 获取用于 Banner / 推荐展示的每日挑战关卡 (若当天关卡未下载，自动从本地历史已下载数据中按日期确定性选取)
  PuzzleLevelItem? getDailyBannerLevel({DateTime? overrideToday}) {
    final localMain = mainPipeline.levels
        .where((l) => l.isLocalFile && l.localPath != null)
        .toList();
    return dailyPipeline.getDailyBannerLevel(
      overrideToday: overrideToday,
      fallbackLocalLevels: localMain,
    );
  }

  /// 兼容历史命名
  PuzzleLevelItem? getTodayDailyLevel({DateTime? overrideToday}) =>
      getDailyBannerLevel(overrideToday: overrideToday);

  /// 确保某月份每日关卡已下载就绪 (支持历史月份懒加载)
  Future<bool> ensureDailyMonthReady(
    String yyyyMm, {
    DateTime? overrideToday,
  }) async {
    final explicitZip = await resolveDailyMonthZipUrl(yyyyMm);
    final pattern = currentManifest?.dailyModule.zipUrlPattern ?? '';
    if ((explicitZip == null || explicitZip.isEmpty) && pattern.isEmpty) {
      AppLogger.daily.warning(
        'ensureDailyMonthReady: Month $yyyyMm not found in daily index and pattern is empty, skipping download',
      );
      return false;
    }
    return dailyPipeline.ensureMonthReady(
      yyyyMm: yyyyMm,
      zipUrlPattern: pattern,
      explicitZipUrl: explicitZip,
      mirrorUrls: dailyMonthMirrorUrls(yyyyMm),
      overrideToday: overrideToday,
    );
  }

  // --- 活动中心 Events 模块便捷代理 ---

  /// 获取所有可见活动 (过滤掉 disabled)
  List<PuzzleEventItem> getVisibleEvents() => eventsPipeline.visibleEvents;

  /// 确保活动资源就绪 (Zip 模式自动下载解压)
  Future<bool> ensureEventDownloaded(PuzzleEventItem event) =>
      eventsPipeline.ensureEventDownloaded(event);

  /// 获取指定活动的所有关卡
  List<PuzzleLevelItem> getEventLevels(PuzzleEventItem event) =>
      eventsPipeline.getLevelsForEvent(event);

  // --- 图集中心 Collections 模块便捷代理 ---

  /// 获取所有可见图集 (过滤掉 disabled，按 displayOrder 排序)
  List<PuzzleCollectionItem> getVisibleCollections() =>
      collectionsPipeline.visibleCollections;

  /// 确保图集资源就绪 (Zip 模式自动下载解压)
  Future<bool> ensureCollectionDownloaded(
    PuzzleCollectionItem collection, {
    void Function(double progress)? onProgress,
  }) => collectionsPipeline.ensureCollectionDownloaded(
    collection,
    onProgress: onProgress,
  );

  /// 获取指定图集的所有关卡
  List<PuzzleLevelItem> getCollectionLevels(PuzzleCollectionItem collection) =>
      collectionsPipeline.getLevelsForCollection(collection);

  /// 删除已下载的本地图集解压目录
  Future<bool> deleteDownloadedCollection(String collectionId) =>
      collectionsPipeline.deleteDownloadedCollection(collectionId);

  static String _formatCurrentMonth(DateTime dt) {
    return '${dt.year.toString().padLeft(4, '0')}${dt.month.toString().padLeft(2, '0')}';
  }
}
