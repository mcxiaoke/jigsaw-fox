// P1-4：外部内容（manifest/JSON/网络）解析防御：脏数据跳过降级，不中断启动
// ignore_for_file: avoid_catches_without_on_clauses
import 'package:jigsawpuzzle/data/game_repository.dart';
import 'package:jigsawpuzzle/data/snapshot_store.dart';
import 'package:jigsawpuzzle/l10n/gen/strings.g.dart';
import 'package:jigsawpuzzle/logic/content/app_content.dart';
import 'package:jigsawpuzzle/logic/content/models/canonical_id.dart';
import 'package:jigsawpuzzle/logic/content/models/puzzle_level_item.dart';
import 'package:jigsawpuzzle/logic/puzzle_model.dart';
import 'package:jigsawpuzzle/services/app_logger.dart';
import 'package:jigsawpuzzle/services/locale_service.dart';

/// 五大来源统一后的单条关卡目录视图（只读数据）
class CatalogEntry {
  const CatalogEntry({
    required this.canonicalId,
    required this.title,
    required this.imagePathOrUrl,
    required this.isLocalFile,
    required this.sourceLabel,
    required this.sourceModule,
    required this.aspectRatio,
    this.author,
    this.tags = const [],
    this.addedAt,
    this.recommendedDifficulty,
    this.contextId,
    this.displaySubtitle,
  });

  final String canonicalId;
  final String title;
  final String imagePathOrUrl;
  final bool isLocalFile;
  final String sourceLabel;
  final String sourceModule;
  final PuzzleAspectRatio aspectRatio;
  final String? author;
  final List<String> tags;
  final DateTime? addedAt;
  final String? recommendedDifficulty;
  final String? contextId;
  final String? displaySubtitle;
}

/// 全局统一目录内存索引（保证“我的”Tab 与 Resolver O(1) 反查）
class UnifiedCatalogIndex {
  const UnifiedCatalogIndex(this.byId);

  final Map<String, CatalogEntry> byId;

  /// 根据 canonicalId 查询目录条目，若来源被删或下架则返回 null（代表孤儿卡）
  CatalogEntry? get(String canonicalId) => byId[canonicalId];

  static UnifiedCatalogIndex? _cached;
  static bool _dirty = true;

  // P2-10：构建中的 Future 单飞复用。build() 内部含 await，多页面并发调用
  // current() 时复用同一 Future，避免多次全量重建与后完成者覆盖。
  static Future<UnifiedCatalogIndex>? _inFlight;

  // v8 修 c：失效代次。invalidate() 自增，current() 构建前后比对，
  // 用于检出“构建进行中发生失效”的竞态（见 current() 注释）。
  static int _invalidations = 0;

  static bool _localeListenerRegistered = false;

  static void _ensureLocaleListener() {
    if (!_localeListenerRegistered) {
      _localeListenerRegistered = true;
      LocaleService.instance.addListener(invalidate);
    }
  }

  /// 标记目录脏状态（在自制拼图变动或包/活动内容更新时调用）
  static void invalidate() {
    _dirty = true;
    // v8 修 c：代次计数——用于识别“构建进行中发生失效”的竞态，
    // 避免 build 结束时把 _dirty 清成 false 而吞掉这次失效。
    _invalidations++;
  }

  /// 获取当前统一目录索引（优先读取内存缓存，避免重复全量扫描）
  static Future<UnifiedCatalogIndex> current() async {
    _ensureLocaleListener();
    if (_cached != null && !_dirty) {
      return _cached!;
    }
    final inFlight = _inFlight;
    if (inFlight != null) return inFlight;
    final genAtStart = _invalidations;
    final future = build();
    _inFlight = future;
    try {
      _cached = await future;
      // v8 修 c：构建期间若又发生过 invalidate（例如本次构建的
      // `loadAllPacks` 触发了内容更新），保持 dirty，让下一次调用重建，
      // 而不是用“构建前的快照”覆盖新状态。
      if (_invalidations == genAtStart) {
        _dirty = false;
      } else {
        AppLogger.content.fine(
          'UnifiedCatalogIndex kept dirty: invalidated during build '
          '($genAtStart -> $_invalidations)',
        );
      }
      return _cached!;
    } finally {
      if (identical(_inFlight, future)) _inFlight = null;
    }
  }

  /// 扫描五大模块并一次性构建只读索引 Map（6000条关卡构建耗时 ~5ms）
  ///
  /// [mainLevels] 仅供测试注入（默认取网络 main 管线；AppContent 未初始化时为空）。
  static Future<UnifiedCatalogIndex> build({
    List<PuzzleLevelItem>? mainLevels,
  }) async {
    final sw = Stopwatch()..start();
    final map = <String, CatalogEntry>{};
    final repo = GameRepository.instance;
    final tr = LocaleSettings.instance.currentTranslations;

    // 1. 主线关卡 (main:NNN) —— 网络 main 内容
    // （首页数据源已切换网络，见 docs/home-network-migration-and-boot-init-design-20260907.md §3.5；
    //   旧 demo 关卡 main:001~100 因开发期未发布不做兼容，D11）
    try {
      final levelsToIndex =
          mainLevels ??
          (AppContent.instance.isInitialized
              ? AppContent.instance.manager.getMainLevels()
              : const <PuzzleLevelItem>[]);
      for (final level in levelsToIndex) {
        map[level.id] = CatalogEntry(
          canonicalId: level.id,
          title: level.displayTitle,
          imagePathOrUrl: level.displayPath,
          isLocalFile: level.isLocalFile,
          sourceLabel: 'main',
          sourceModule: CanonicalId.prefixMain,
          aspectRatio: PuzzleAspectRatio.square1x1,
          author: tr.source.official,
          tags: level.tags,
          addedAt: level.addedAt,
          contextId: level.order.toString(),
          displaySubtitle: tr.game.titleLevel(index: level.order),
        );
      }
    } catch (e, st) {
      AppLogger.content.warning('UnifiedCatalogIndex main scan fail', e, st);
    }

    // 2. 每日挑战 (daily:yyyyMMdd)
    try {
      if (AppContent.instance.isInitialized) {
        final currentMonth =
            AppContent
                .instance
                .manager
                .currentManifest
                ?.dailyModule
                .currentMonth ??
            '';
        final months = <String>{};
        if (currentMonth.isNotEmpty) months.add(currentMonth);
        final now = DateTime.now();
        months.add('${now.year}${now.month.toString().padLeft(2, '0')}');
        for (final m in months) {
          final levels = AppContent.instance.manager.getDailyLevelsForMonth(m);
          for (final lvl in levels) {
            map[lvl.id] = CatalogEntry(
              canonicalId: lvl.id,
              title: lvl.displayTitle,
              imagePathOrUrl: lvl.imagePathOrUrl,
              isLocalFile: lvl.isLocalFile,
              sourceLabel: 'daily',
              sourceModule: CanonicalId.prefixDaily,
              aspectRatio: PuzzleAspectRatio.square1x1,
              author: tr.nav.titleDaily,
              tags: const ['每日挑战'],
              addedAt: lvl.dailyDate != null && lvl.dailyDate!.length == 8
                  ? DateTime.tryParse(
                      '${lvl.dailyDate!.substring(0, 4)}-${lvl.dailyDate!.substring(4, 6)}-${lvl.dailyDate!.substring(6, 8)}',
                    )
                  : null,
              recommendedDifficulty: '6x6',
              contextId: lvl.dailyDate ?? '',
              displaySubtitle:
                  lvl.dailyDate != null && lvl.dailyDate!.length == 8
                  ? tr.game.titleDaily(
                      date:
                          '${lvl.dailyDate!.substring(0, 4)}-${lvl.dailyDate!.substring(4, 6)}-${lvl.dailyDate!.substring(6, 8)}',
                    )
                  : tr.game.titleDaily(date: '${lvl.dailyDate}'),
            );
          }
        }
      }
    } catch (e, st) {
      AppLogger.content.warning('UnifiedCatalogIndex daily scan fail', e, st);
    }

    // 3. 自制关卡 (ugc:id)
    for (final custom in repo.customPuzzles) {
      final cid = GameRepository.canonicalForCustom(custom.id);
      map[cid] = CatalogEntry(
        canonicalId: cid,
        title: custom.title,
        imagePathOrUrl: custom.imagePathOrUrl,
        isLocalFile: custom.isLocalFile,
        sourceLabel: 'custom',
        sourceModule: CanonicalId.prefixUgc,
        aspectRatio: PuzzleAspectRatio.fromSize(
          custom.difficulty.cols.toDouble(),
          custom.difficulty.rows.toDouble(),
        ),
        author: custom.displaySource,
        tags: const ['自制'],
        addedAt: custom.createdAt,
        recommendedDifficulty: SnapshotStore.difficultyKeyFor(
          custom.difficulty,
        ),
        contextId: custom.id,
        displaySubtitle: '${tr.game.titleCustom} · ${custom.displaySource}',
      );
    }

    // 4. 扩展包 (pack:packId:file)
    try {
      if (AppContent.instance.isInitialized) {
        final packs = AppContent.instance.packs.packsNotifier.value.isNotEmpty
            ? AppContent.instance.packs.packsNotifier.value
            : await AppContent.instance.packs.loadAllPacks();
        for (final pack in packs) {
          final levels = AppContent.instance.packs.getPackLevels(pack);
          for (final lvl in levels) {
            map[lvl.id] = CatalogEntry(
              canonicalId: lvl.id,
              title: lvl.displayTitle,
              imagePathOrUrl: lvl.imagePathOrUrl,
              isLocalFile: lvl.isLocalFile,
              sourceLabel: 'pack',
              sourceModule: CanonicalId.prefixPack,
              aspectRatio: PuzzleAspectRatio.square1x1,
              author: pack.author.isNotEmpty ? pack.author : pack.title,
              tags: pack.tags,
              addedAt: DateTime.tryParse(pack.importedAt),
              recommendedDifficulty: '6x6',
              contextId: pack.id,
              displaySubtitle: pack.title,
            );
          }
        }
      }
    } catch (e, st) {
      AppLogger.content.warning('UnifiedCatalogIndex pack scan fail', e, st);
    }

    // 5. 活动关卡 (event:eventId:file)
    // P0-2：数据源为「可见 ∪ 本地已下载」（含已下架/已禁用但本地仍有数据者），
    // 否则已下载关卡的进度卡会被误判为孤儿卡。
    try {
      if (AppContent.instance.isInitialized) {
        final pipeline = AppContent.instance.manager.eventsPipeline;
        final events = pipeline.allEvents.where(
          (e) =>
              (!e.isDisabled && !e.isDelisted) || pipeline.isEventDownloaded(e),
        );
        for (final event in events) {
          final levels = AppContent.instance.manager.getEventLevels(event);
          for (final lvl in levels) {
            map[lvl.id] = CatalogEntry(
              canonicalId: lvl.id,
              title: lvl.displayTitle,
              imagePathOrUrl: lvl.imagePathOrUrl,
              isLocalFile: lvl.isLocalFile,
              sourceLabel: 'event',
              sourceModule: CanonicalId.prefixEvent,
              aspectRatio: PuzzleAspectRatio.square1x1,
              author: event.displayTitle,
              tags: const ['活动'],
              addedAt: event.updatedAt ?? event.startTime,
              recommendedDifficulty: '6x6',
              contextId: event.id,
              displaySubtitle: event.displayTitle,
            );
          }
        }
      }
    } catch (e, st) {
      AppLogger.content.warning('UnifiedCatalogIndex event scan fail', e, st);
    }

    // 6. 图集关卡 (collection:collectionId:file)
    // P0-2：数据源为「可见 ∪ 本地已下载」（含已下架/已禁用但本地仍有数据者）。
    try {
      if (AppContent.instance.isInitialized) {
        final pipeline = AppContent.instance.manager.collectionsPipeline;
        final collections = pipeline.allCollections.where(
          (c) =>
              (!c.isDisabled && !c.isDelisted) ||
              pipeline.isCollectionDownloaded(c),
        );
        for (final col in collections) {
          final levels = AppContent.instance.manager.getCollectionLevels(col);
          for (final lvl in levels) {
            map[lvl.id] = CatalogEntry(
              canonicalId: lvl.id,
              title: lvl.displayTitle,
              imagePathOrUrl: lvl.imagePathOrUrl,
              isLocalFile: lvl.isLocalFile,
              sourceLabel: col.isEvent ? 'event' : 'official',
              sourceModule: CanonicalId.prefixCollection,
              aspectRatio: PuzzleAspectRatio.square1x1,
              author: col.displayTitle,
              tags: [col.displayTypeLabel, col.displayTitle],
              addedAt: col.updatedAt ?? col.startTime,
              recommendedDifficulty: '6x6',
              contextId: col.id,
              displaySubtitle: col.displayTitle,
            );
          }
        }
      }
    } catch (e, st) {
      AppLogger.content.warning(
        'UnifiedCatalogIndex collection scan fail',
        e,
        st,
      );
    }

    AppLogger.content.info(
      'UnifiedCatalogIndex.build done ${sw.elapsedMilliseconds}ms total=${map.length}',
    );
    return UnifiedCatalogIndex(Map.unmodifiable(map));
  }
}
