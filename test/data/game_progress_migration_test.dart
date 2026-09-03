import 'package:flutter_test/flutter_test.dart';
import 'package:jigsawpuzzle/data/game_repository.dart';
import 'package:jigsawpuzzle/data/progress_store.dart';
import 'package:jigsawpuzzle/data/storage_manager.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../test_helper.dart';

/// Phase 1（game-progress-v1）DoD 用例（设计 §10.3 / §11）
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late StorageManager sm;

  setUp(() async {
    sm = await initTestStorage();
  });

  tearDown(() async {
    await tearDownTestStorage(sm);
  });

  group('主线水合（§7.3 step3）', () {
    test('写 main:{NNN} → 重启后静态生成 + ProgressStore 回填进度字段', () async {
      SharedPreferences.setMockInitialValues({});
      await ProgressStore.instance.reset();

      await ProgressStore.instance.updateProgress(
        canonicalId: 'main:001',
        isCompleted: true,
        progressPercent: 100,
        stars: 3,
        bestTimeSeconds: 60,
        completedPieceCount: 25,
      );
      await ProgressStore.instance.updateProgress(
        canonicalId: 'main:002',
        progressPercent: 40,
        hasSnapshot: true,
        activeDifficultyKey: '8x8',
        snapshotKeys: ['8x8'],
      );

      // 模拟重启：box 落盘 → 重新 open → 内存索引重载
      await sm.closeAll();
      await sm.openAll();
      await ProgressStore.instance.reloadForTest();

      await GameRepository.instance.init();
      final levels = GameRepository.instance.levels;
      expect(levels, hasLength(100));

      final l1 = levels.firstWhere((l) => l.index == 1);
      expect(l1.isCompleted, isTrue);
      expect(l1.progressPercent, 100);
      expect(l1.stars, 3);
      expect(l1.bestTimeSeconds, 60);
      expect(l1.completedPieceCounts, contains(25));

      final l2 = levels.firstWhere((l) => l.index == 2);
      expect(l2.isCompleted, isFalse);
      expect(l2.progressPercent, 40);

      // 未写进度的关卡保持默认值
      final l3 = levels.firstWhere((l) => l.index == 3);
      expect(l3.isCompleted, isFalse);
      expect(l3.progressPercent, 0);
      expect(l3.stars, 0);
    });

    test('通关后重启：内存 Item 进度字段来自 box 而非 prefs 副本', () async {
      SharedPreferences.setMockInitialValues({});
      await ProgressStore.instance.reset();

      // 确认全库已无 jigsaw level  读写（LevelItem 的 prefs 水合分支已删除）：
      // 走 updateLevelProgress 正常链路写进度
      await GameRepository.instance.init();
      await GameRepository.instance.updateLevelProgress(
        levelIndex: 5,
        progressPercent: 100,
        isCompleted: true,
        completedPieceCount: 25,
        stars: 2,
        timeSeconds: 90,
      );

      // box 中应有且仅有 main:005 一条（jigsaw level 5 不再存在）
      final keys = sm.progress.keys.cast<String>().toList();
      expect(keys, ['main:005']);

      // 重启水合
      await sm.closeAll();
      await sm.openAll();
      await ProgressStore.instance.reloadForTest();
      await GameRepository.instance.init();
      final l5 = GameRepository.instance.levels.firstWhere((l) => l.index == 5);
      expect(l5.isCompleted, isTrue);
      expect(l5.stars, 2);
      expect(l5.bestTimeSeconds, 90);
    });
  });

  group('每日进度随迁（§2.2）', () {
    test('daily:{YYYYMMDD} 进度写入并重启读回', () async {
      await ProgressStore.instance.reset();
      const cid = 'daily:20260902';
      await ProgressStore.instance.updateProgress(
        canonicalId: cid,
        progressPercent: 66,
        hasSnapshot: true,
        activeDifficultyKey: '6x6',
        snapshotKeys: ['6x6'],
      );

      await sm.closeAll();
      await sm.openAll();
      await ProgressStore.instance.reloadForTest();

      final p = await ProgressStore.instance.load(cid);
      expect(p.progressPercent, 66);
      expect(p.hasSnapshot, isTrue);
      expect(p.snapshotKeys, ['6x6']);
    });
  });

  group('聚合统计走内存索引（§八）', () {
    test('getTotalPlayCount / getTotalSolved / getTotalStars', () async {
      await ProgressStore.instance.reset();
      await ProgressStore.instance.recordDifficultyCompletion(
        canonicalId: 'main:001',
        difficultyKey: '5x5',
        stars: 3,
        timeSeconds: 30,
        hintsUsed: 0,
      );
      await ProgressStore.instance.recordDifficultyCompletion(
        canonicalId: 'main:001',
        difficultyKey: '6x6',
        stars: 2,
        timeSeconds: 40,
        hintsUsed: 1,
      );
      await ProgressStore.instance.recordDifficultyCompletion(
        canonicalId: 'ugc:sample_01',
        difficultyKey: '5x5',
        stars: 1,
        timeSeconds: 50,
        hintsUsed: 2,
      );

      expect(await ProgressStore.instance.getTotalPlayCount(), 3);
      expect(await ProgressStore.instance.getTotalSolved(), 2);
      // 3 + 2 + 1
      expect(await ProgressStore.instance.getTotalStars(), 6);
      expect(await ProgressStore.instance.getDistinctImagesWith3Star(), 1);
    });

    test('delete 后聚合缓存刷新且 box 键移除', () async {
      await ProgressStore.instance.reset();
      const cid = 'main:010';
      await ProgressStore.instance.recordDifficultyCompletion(
        canonicalId: cid,
        difficultyKey: '5x5',
        stars: 2,
        timeSeconds: 30,
        hintsUsed: 1,
      );
      expect(sm.progress.get(cid), isNotNull);
      expect(await ProgressStore.instance.getTotalSolved(), 1);

      await ProgressStore.instance.delete(cid);
      expect(sm.progress.get(cid), isNull);
      expect(await ProgressStore.instance.getTotalSolved(), 0);
      expect(await ProgressStore.instance.getTotalStars(), 0);
    });
  });
}
