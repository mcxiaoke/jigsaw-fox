import 'package:path/path.dart' as p;
import 'models/puzzle_event_item.dart';
import 'models/puzzle_level_item.dart';
import 'models/root_manifest.dart';
import 'network/content_http_client.dart';
import 'pipelines/daily_content_pipeline.dart';
import 'pipelines/events_content_pipeline.dart';
import 'pipelines/main_content_pipeline.dart';
import 'pipelines/manifest_router.dart';

/// 内容与扩展系统统一门面管理器 (Facade)
class ContentManager {
  ContentManager({
    required List<String> bootstrapUrls,
    required String appSupportDir,
    required String appDocumentsDir,
    ContentHttpClient? httpClient,
  })  : manifestRouter = ManifestRouter(
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
        );

  final ManifestRouter manifestRouter;
  final MainContentPipeline mainPipeline;
  final DailyContentPipeline dailyPipeline;
  final EventsContentPipeline eventsPipeline;

  RootManifest? get currentManifest => manifestRouter.currentManifest;

  /// 1. 初始化所有本地缓存 (冷启动快速秒开)
  Future<void> initialize() async {
    await Future.wait([
      manifestRouter.resolveManifest(),
      mainPipeline.initializeFromCache(),
      eventsPipeline.initializeFromCache(),
    ]);
  }

  /// 2. 全局网络增量同步
  Future<void> syncAll({DateTime? overrideToday}) async {
    // 1. 获取最新 Root Manifest
    final manifest = await manifestRouter.resolveManifest(forceRefresh: true);

    // 2. 并发同步各模块元数据
    await Future.wait([
      // 同步首页关卡
      mainPipeline.syncWithRemote(
        remoteUrl: manifest.mainModule.url,
        remoteVersion: manifest.mainModule.version,
      ),
      // 同步活动列表 (自动触发 Auto-GC)
      eventsPipeline.syncWithRemote(
        remoteUrl: manifest.eventsModule.url,
      ),
      // 预备当月每日挑战
      () async {
        final currentMonth = manifest.dailyModule.currentMonth.isNotEmpty
            ? manifest.dailyModule.currentMonth
            : _formatCurrentMonth(overrideToday ?? DateTime.now());
        if (manifest.dailyModule.zipUrlPattern.isNotEmpty) {
          await dailyPipeline.ensureMonthReady(
            yyyyMm: currentMonth,
            zipUrlPattern: manifest.dailyModule.zipUrlPattern,
            overrideToday: overrideToday,
          );
        }
      }(),
    ]);
  }

  // --- 首页 Main 模块便捷代理 ---

  /// 获取首页所有关卡
  List<PuzzleLevelItem> getMainLevels() => mainPipeline.levels;

  /// 获取所有可用分类标签 (包含 'all')
  List<String> getMainTags() => mainPipeline.availableTags;

  /// 按标签过滤首页关卡
  List<PuzzleLevelItem> filterMainByTag(String tag) => mainPipeline.filterByTag(tag);

  /// 确保指定首页关卡图片已下载
  Future<PuzzleLevelItem> ensureMainLevelDownloaded(PuzzleLevelItem level) =>
      mainPipeline.ensureLevelImageDownloaded(level);

  // --- 每日挑战 Daily 模块便捷代理 ---

  /// 获取指定月份每日关卡 (带时间锁)
  List<PuzzleLevelItem> getDailyLevelsForMonth(String yyyyMm, {DateTime? overrideToday}) =>
      dailyPipeline.getLevelsForMonth(yyyyMm, overrideToday: overrideToday);

  /// 获取今日挑战关卡
  PuzzleLevelItem? getTodayDailyLevel({DateTime? overrideToday}) =>
      dailyPipeline.getTodayLevel(overrideToday: overrideToday);

  /// 确保某月份每日关卡已下载就绪
  Future<bool> ensureDailyMonthReady(String yyyyMm, {DateTime? overrideToday}) {
    final pattern = currentManifest?.dailyModule.zipUrlPattern ?? '';
    return dailyPipeline.ensureMonthReady(
      yyyyMm: yyyyMm,
      zipUrlPattern: pattern,
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

  static String _formatCurrentMonth(DateTime dt) {
    return '${dt.year.toString().padLeft(4, '0')}${dt.month.toString().padLeft(2, '0')}';
  }
}
