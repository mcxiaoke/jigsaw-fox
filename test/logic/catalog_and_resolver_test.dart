import 'package:flutter_test/flutter_test.dart';
import 'package:jigsawpuzzle/data/favorite_store.dart';
import 'package:jigsawpuzzle/data/game_repository.dart';
import 'package:jigsawpuzzle/data/progress_store.dart';
import 'package:jigsawpuzzle/data/storage_manager.dart';
import 'package:jigsawpuzzle/logic/catalog_index.dart';
import 'package:jigsawpuzzle/logic/content/models/puzzle_level_item.dart';
import 'package:jigsawpuzzle/logic/puzzle_model.dart';
import 'package:jigsawpuzzle/logic/unified_puzzle_resolver.dart';

import '../test_helper.dart';

/// 网络主线关卡测试桩（catalog_index 已切网络 main 源，AppContent 单测环境不初始化，
/// 通过 build(mainLevels:) 注入）
final List<PuzzleLevelItem> _fakeMainLevels = const [
  PuzzleLevelItem(
    id: 'main:001',
    order: 1,
    tags: ['Animals'],
  ),
  PuzzleLevelItem(
    id: 'main:002',
    order: 2,
    tags: ['Flowers'],
  ),
];

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late StorageManager sm;

  setUp(() async {
    sm = await initTestAppStorage();
    await GameRepository.instance.init();
    await ProgressStore.instance.init();
    await FavoriteStore.instance.init();
  });

  tearDown(() async {
    await tearDownTestStorage(sm);
  });

  group('UnifiedCatalogIndex & UnifiedPuzzleResolver Tests', () {
    test(
      'UnifiedCatalogIndex builds and indexes network main levels',
      () async {
        final index = await UnifiedCatalogIndex.build(
          mainLevels: _fakeMainLevels,
        );
        expect(index.byId.isNotEmpty, isTrue);

        // 网络主线 main:001 应当存在
        const cidLevel1 = 'main:001';
        final entry1 = index.get(cidLevel1);
        expect(entry1, isNotNull);
        expect(entry1!.sourceLabel, equals('main'));
        expect(entry1.aspectRatio, equals(PuzzleAspectRatio.square1x1));

        // 每日挑战支持按 canonicalId 检索
        final cidDaily = GameRepository.canonicalForDaily('20260901');
        final entryDaily = index.get(cidDaily);
        if (entryDaily != null) {
          expect(entryDaily.sourceLabel, equals('daily'));
        }
      },
    );

    test(
      'UnifiedPuzzleResolver resolves normal card with progress and favorites',
      () async {
        final index = await UnifiedCatalogIndex.build(
          mainLevels: _fakeMainLevels,
        );
        final resolver = UnifiedPuzzleResolver(index);
        const cid = 'main:001';

        // 1. 未游玩、未收藏状态
        final card1 = resolver.resolve(canonicalId: cid);
        expect(card1.canonicalId, equals(cid));
        expect(card1.isOrphan, isFalse);
        expect(card1.isFavorite, isFalse);
        expect(card1.isCompleted, isFalse);
        expect(card1.progressPercent, equals(0));

        // 2. 模拟通关并收藏
        await FavoriteStore.instance.toggleFavorite(cid);
        final progress = LevelProgress(
          canonicalId: cid,
          isCompleted: true,
          progressPercent: 100,
          stars: 3,
          bestTimeSeconds: 45,
          records: {
            '5x5': const DifficultyRecord(
              bestStars: 3,
              bestTimeSeconds: 45,
              isCompleted: true,
              playCount: 1,
              minHintsUsed: 0,
            ),
          },
        );

        final card2 = resolver.resolve(canonicalId: cid, progress: progress);
        expect(card2.isFavorite, isTrue);
        expect(card2.isCompleted, isTrue);
        expect(card2.maxStars, equals(3));
        expect(card2.totalPlayCount, equals(1));
        expect(card2.minHintsUsed, equals(0));
      },
    );

    test('UnifiedPuzzleResolver handles orphan card gracefully', () {
      const emptyIndex = UnifiedCatalogIndex({});
      const resolver = UnifiedPuzzleResolver(emptyIndex);
      const orphanCid = 'ugc:deleted_123';

      final favSnapshot = FavoriteEntry(
        canonicalId: orphanCid,
        favoritedAt: DateTime.now(),
        titleSnapshot: '已删除的宠物照片',
        imageSnapshot: '/data/user/deleted.jpg',
        sourceLabelSnapshot: '自制',
        aspectRatioLabel: 'portrait2x3',
      );

      final card = resolver.resolve(
        canonicalId: orphanCid,
        favoriteEntry: favSnapshot,
      );

      expect(card.isOrphan, isTrue);
      expect(card.title, equals('已删除的宠物照片'));
      expect(card.sourceLabel, equals('自制'));
      expect(card.aspectRatio, equals(PuzzleAspectRatio.portrait2x3));
      expect(card.isFavorite, isTrue);
    });

    test(
      'UnifiedCatalogIndex.current caches and invalidate triggers rebuild',
      () async {
        UnifiedCatalogIndex.invalidate();
        final index1 = await UnifiedCatalogIndex.current();
        final index2 = await UnifiedCatalogIndex.current();
        // Should return exact same cached instance
        expect(identical(index1, index2), isTrue);

        // After invalidate, next current() returns newly built instance
        UnifiedCatalogIndex.invalidate();
        final index3 = await UnifiedCatalogIndex.current();
        expect(identical(index1, index3), isFalse);
      },
    );
  });
}
