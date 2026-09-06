import 'package:path/path.dart' as p;
import '../../services/app_logger.dart';
import 'models/puzzle_collection_item.dart';
import 'models/puzzle_event_item.dart';
import 'models/puzzle_level_item.dart';
import 'models/root_manifest.dart';
import 'network/content_http_client.dart';
import 'pipelines/collections_content_pipeline.dart';
import 'pipelines/daily_content_pipeline.dart';
import 'pipelines/events_content_pipeline.dart';
import 'pipelines/main_content_pipeline.dart';
import 'pipelines/manifest_router.dart';
import 'pipelines/pack_content_pipeline.dart';

/// 内容与扩展系统统一门面管理器 (Facade)
class ContentManager {
  ContentManager({
    required List<String> bootstrapUrls,
    required String appSupportDir,
    required String appDocumentsDir,
    ContentHttpClient? httpClient,
  }) : manifestRouter = ManifestRouter(
         bootstrapUrls: bootstrapUrls,
         cacheFilePath: p.join(appSupportDir, 'manifest_cache.json'),
         httpClient: httpClient,
       ),
       mainPipeline = MainContentPipeline(
         cacheFilePath: p.join(appSupportDir, 'main_levels_cache.json'),
         imagesStorageDir: p.join(appDocumentsDir, 'levels', 'main'),
         httpClient: httpClient,
       ),
       dailyPipeline = DailyContentPipeline(
         dailyStorageBaseDir: p.join(appDocumentsDir, 'daily'),
         httpClient: httpClient,
       ),
       eventsPipeline = EventsContentPipeline(
         cacheFilePath: p.join(appSupportDir, 'events_cache.json'),
         eventsStorageBaseDir: p.join(appDocumentsDir, 'events'),
         httpClient: httpClient,
       ),
       collectionsPipeline = CollectionsContentPipeline(
         cacheFilePath: p.join(appSupportDir, 'collections_cache.json'),
         collectionsStorageBaseDir: p.join(appDocumentsDir, 'collections'),
         httpClient: httpClient,
       ),
       packPipeline = PackContentPipeline(
         packsBaseDir: p.join(appDocumentsDir, 'packs'),
         httpClient: httpClient,
       ),
       _httpClient = httpClient ?? ContentHttpClient();

  final ContentHttpClient _httpClient;
  final ManifestRouter manifestRouter;
  final MainContentPipeline mainPipeline;
  final DailyContentPipeline dailyPipeline;
  final EventsContentPipeline eventsPipeline;
  final CollectionsContentPipeline collectionsPipeline;
  final PackContentPipeline packPipeline;

  RootManifest? get currentManifest => manifestRouter.currentManifest;

  bool _isSyncing = false;
  Future<void>? _syncFuture;
  final Map<String, String> _dailyMonthZipUrls = {};
  List<String> get availableDailyMonths => _dailyMonthZipUrls.keys.toList();

  /// 解析指定月份每日挑战 ZIP 地址 (优先读缓存，无则拉取 daily/index.json 解析)
  Future<String?> resolveDailyMonthZipUrl(String yyyyMm) async {
    if (_dailyMonthZipUrls.containsKey(yyyyMm)) {
      AppLogger.daily.info(
        'resolveDailyMonthZipUrl cache hit $yyyyMm -> ${_dailyMonthZipUrls[yyyyMm]}',
      );
      return _dailyMonthZipUrls[yyyyMm];
    }
    final manifest = currentManifest;
    if (manifest == null || manifest.dailyModule.url.isEmpty) {
      AppLogger.daily.warning(
        'resolveDailyMonthZipUrl failed: manifest is null or dailyModule.url is empty',
      );
      return null;
    }
    final dailyIndexUrl = ContentHttpClient.resolveUrl(
      manifest.baseUri,
      manifest.dailyModule.url,
    );
    AppLogger.daily.info(
      'resolveDailyMonthZipUrl fetching daily index from $dailyIndexUrl for month $yyyyMm',
    );
    try {
      final dailyJson = await _httpClient.fetchJson(dailyIndexUrl);
      if (dailyJson is Map<String, dynamic>) {
        final rawMonths = dailyJson['items'];
        if (rawMonths is List) {
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
            }
          }
          AppLogger.daily.info(
            'resolveDailyMonthZipUrl parsed ${rawMonths.length} months from daily index: ${_dailyMonthZipUrls.keys.toList()}',
          );
        } else {
          AppLogger.daily.warning(
            'resolveDailyMonthZipUrl unexpected items type: ${rawMonths.runtimeType}',
          );
        }
      }
    } catch (e, st) {
      AppLogger.daily.warning(
        'Failed to fetch daily index for month $yyyyMm from $dailyIndexUrl',
        e,
        st,
      );
    }
    final resolvedUrl = _dailyMonthZipUrls[yyyyMm];
    AppLogger.daily.info(
      'resolveDailyMonthZipUrl result for $yyyyMm: $resolvedUrl',
    );
    return resolvedUrl;
  }

  /// 1. 初始化所有本地缓存与扩展包 (冷启动快速秒开)
  /// P20 优化：manifest 先读盘缓存，避免弱网 4-16s 阻塞秒开
  Future<void> initialize() async {
    AppLogger.content.info('ContentManager initialize start');
    final sw = Stopwatch()..start();
    try {
      // manifest 先尝试磁盘缓存，网络留后台 syncAll
      final manifestFuture = manifestRouter.resolveManifestCacheFirst();
      await Future.wait([
        manifestFuture,
        mainPipeline.initializeFromCache(),
        eventsPipeline.initializeFromCache(),
        collectionsPipeline.initializeFromCache(),
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

  /// 2. 全局网络增量同步（P20 加互斥锁，二次调用等待首次结果）
  Future<void> syncAll({DateTime? overrideToday}) async {
    if (_isSyncing) {
      AppLogger.content.info('syncAll already in progress, wait previous');
      try {
        await _syncFuture;
      } catch (_) {}
      return;
    }
    _isSyncing = true;
    final future = () async {
      AppLogger.content.info('syncAll start overrideToday=$overrideToday');
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
          // 预备当月每日挑战
          () async {
            final currentMonth = overrideToday != null
                ? _formatCurrentMonth(overrideToday)
                : (manifest.dailyModule.currentMonth.isNotEmpty
                      ? manifest.dailyModule.currentMonth
                      : _formatCurrentMonth(DateTime.now()));

            final targetZipUrl = await resolveDailyMonthZipUrl(currentMonth);

            if (targetZipUrl != null ||
                manifest.dailyModule.zipUrlPattern.isNotEmpty) {
              final ok = await dailyPipeline.ensureMonthReady(
                yyyyMm: currentMonth,
                zipUrlPattern: manifest.dailyModule.zipUrlPattern,
                explicitZipUrl: targetZipUrl,
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
    }();
    _syncFuture = future;
    try {
      await future;
    } finally {
      _isSyncing = false;
      _syncFuture = null;
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

  /// 确保指定首页关卡图片已下载
  Future<PuzzleLevelItem> ensureMainLevelDownloaded(PuzzleLevelItem level) =>
      mainPipeline.ensureLevelImageDownloaded(level);

  // --- 每日挑战 Daily 模块便捷代理 ---

  /// 获取指定月份每日关卡 (带时间锁)
  List<PuzzleLevelItem> getDailyLevelsForMonth(
    String yyyyMm, {
    DateTime? overrideToday,
  }) => dailyPipeline.getLevelsForMonth(yyyyMm, overrideToday: overrideToday);

  /// 获取今日挑战关卡
  PuzzleLevelItem? getTodayDailyLevel({DateTime? overrideToday}) =>
      dailyPipeline.getTodayLevel(overrideToday: overrideToday);

  /// 确保某月份每日关卡已下载就绪 (支持历史月份懒加载)
  Future<bool> ensureDailyMonthReady(
    String yyyyMm, {
    DateTime? overrideToday,
  }) async {
    final explicitZip = await resolveDailyMonthZipUrl(yyyyMm);
    final pattern = currentManifest?.dailyModule.zipUrlPattern ?? '';
    return dailyPipeline.ensureMonthReady(
      yyyyMm: yyyyMm,
      zipUrlPattern: pattern,
      explicitZipUrl: explicitZip,
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
