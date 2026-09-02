import '../data/game_repository.dart';
import '../data/snapshot_store.dart';
import '../services/app_logger.dart';
import 'content/app_content.dart';
import 'content/models/canonical_id.dart';
import 'puzzle_model.dart';

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

  /// 标记目录脏状态（在自制拼图变动或包/活动内容更新时调用）
  static void invalidate() {
    _dirty = true;
  }

  /// 获取当前统一目录索引（优先读取内存缓存，避免重复全量扫描）
  static Future<UnifiedCatalogIndex> current() async {
    if (_cached != null && !_dirty) {
      return _cached!;
    }
    _cached = await build();
    _dirty = false;
    return _cached!;
  }

  /// 扫描五大模块并一次性构建只读索引 Map（6000条关卡构建耗时 ~5ms）
  static Future<UnifiedCatalogIndex> build() async {
    final sw = Stopwatch()..start();
    final map = <String, CatalogEntry>{};
    final repo = GameRepository.instance;

    // 1. 主线关卡 (main:NNN)
    for (final level in repo.levels) {
      final cid = GameRepository.canonicalForLevel(level.index);
      map[cid] = CatalogEntry(
        canonicalId: cid,
        title: level.title,
        imagePathOrUrl: level.assetPath,
        isLocalFile: true,
        sourceLabel: '主线',
        sourceModule: CanonicalId.prefixMain,
        aspectRatio: PuzzleAspectRatio.fromSize(
          level.difficulty.cols.toDouble(),
          level.difficulty.rows.toDouble(),
        ),
        author: '官方精选',
        tags: level.tags,
        addedAt: level.addedAt,
        recommendedDifficulty: SnapshotStore.difficultyKeyFor(level.difficulty),
        contextId: level.index.toString(),
        displaySubtitle: '第 ${level.index} 关',
      );
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
              sourceLabel: '每日',
              sourceModule: CanonicalId.prefixDaily,
              aspectRatio: PuzzleAspectRatio.square1x1,
              author: '每日挑战',
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
                  ? '${lvl.dailyDate!.substring(0, 4)}-${lvl.dailyDate!.substring(4, 6)}-${lvl.dailyDate!.substring(6, 8)} 挑战'
                  : '${lvl.dailyDate} 挑战',
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
        sourceLabel: '自制',
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
        displaySubtitle: '自制拼图 · ${custom.displaySource}',
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
              sourceLabel: '扩展包',
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
    try {
      if (AppContent.instance.isInitialized) {
        final events = AppContent.instance.manager.eventsPipeline.visibleEvents;
        for (final event in events) {
          final levels = AppContent.instance.manager.getEventLevels(event);
          for (final lvl in levels) {
            map[lvl.id] = CatalogEntry(
              canonicalId: lvl.id,
              title: lvl.displayTitle,
              imagePathOrUrl: lvl.imagePathOrUrl,
              isLocalFile: lvl.isLocalFile,
              sourceLabel: '活动',
              sourceModule: CanonicalId.prefixEvent,
              aspectRatio: PuzzleAspectRatio.square1x1,
              author: event.title,
              tags: const ['活动'],
              addedAt: event.startTime,
              recommendedDifficulty: '6x6',
              contextId: event.id,
              displaySubtitle: event.title,
            );
          }
        }
      }
    } catch (e, st) {
      AppLogger.content.warning('UnifiedCatalogIndex event scan fail', e, st);
    }

    AppLogger.content.info(
      'UnifiedCatalogIndex.build done ${sw.elapsedMilliseconds}ms total=${map.length}',
    );
    return UnifiedCatalogIndex(Map.unmodifiable(map));
  }
}
