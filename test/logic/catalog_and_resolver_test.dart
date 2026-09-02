import 'package:flutter_test/flutter_test.dart';
import 'package:jigsawpuzzle/data/favorite_store.dart';
import 'package:jigsawpuzzle/data/game_repository.dart';
import 'package:jigsawpuzzle/data/progress_store.dart';
import 'package:jigsawpuzzle/logic/catalog_index.dart';
import 'package:jigsawpuzzle/logic/puzzle_model.dart';
import 'package:jigsawpuzzle/logic/unified_puzzle_resolver.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await GameRepository.instance.init();
    await ProgressStore.instance.init();
    await FavoriteStore.instance.init();
  });

  group('UnifiedCatalogIndex & UnifiedPuzzleResolver Tests', () {
    test(
      'UnifiedCatalogIndex builds and indexes repo levels and daily challenges',
      () async {
        final index = await UnifiedCatalogIndex.build();
        expect(index.byId.isNotEmpty, isTrue);

        // 主线第 1 关应当存在
        final cidLevel1 = GameRepository.canonicalForLevel(1);
        final entry1 = index.get(cidLevel1);
        expect(entry1, isNotNull);
        expect(entry1!.sourceLabel, equals('主线'));
        expect(entry1.aspectRatio, equals(PuzzleAspectRatio.square1x1));

        // 每日挑战应当存在
        if (GameRepository.instance.dailyChallenges.isNotEmpty) {
          final d1 = GameRepository.instance.dailyChallenges.first;
          final cidDaily = GameRepository.canonicalForDaily(d1.date);
          final entryDaily = index.get(cidDaily);
          expect(entryDaily, isNotNull);
          expect(entryDaily!.sourceLabel, equals('每日'));
        }
      },
    );

    test(
      'UnifiedPuzzleResolver resolves normal card with progress and favorites',
      () async {
        final index = await UnifiedCatalogIndex.build();
        final resolver = UnifiedPuzzleResolver(index);
        final cid = GameRepository.canonicalForLevel(1);

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
            '5x5': DifficultyRecord(
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
      final emptyIndex = const UnifiedCatalogIndex({});
      final resolver = UnifiedPuzzleResolver(emptyIndex);
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
