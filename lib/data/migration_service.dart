import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../logic/models/puzzle_state.dart';
import '../services/app_logger.dart';
import 'game_repository.dart';
import 'models/custom_puzzle_item.dart';
import 'models/daily_challenge.dart';
import 'models/level_item.dart';
import 'progress_store.dart';
import 'snapshot_store.dart';

/// 老版本快照向 SnapshotStore (文件) + ProgressStore (索引) 的一次性平滑迁移服务
class MigrationService {
  MigrationService._();
  static final MigrationService instance = MigrationService._();

  static const String _keyMigrated = 'jigsaw_snapshots_v3_migrated';

  /// 检查并执行迁移（如已迁移则直接返回）
  Future<void> migrateIfNeeded({
    required SharedPreferences prefs,
    required List<LevelItem> levels,
    required List<DailyChallengeItem> dailyChallenges,
    required List<CustomPuzzleItem> customPuzzles,
  }) async {
    final alreadyMigrated = prefs.getBool(_keyMigrated) ?? false;
    if (alreadyMigrated) return;

    AppLogger.repo.info('MigrationService: start migrating legacy snapshots to v3');
    var count = 0;

    // 1. 迁移主线关卡
    for (var i = 0; i < levels.length; i++) {
      final level = levels[i];
      final snapJson = level.savedSnapshotJson;
      if (snapJson != null && snapJson.isNotEmpty && !level.isCompleted) {
        try {
          final cid = GameRepository.canonicalForLevel(level.index);
          final map = jsonDecode(snapJson) as Map<String, dynamic>;
          final state = PuzzleBoardState.fromJson(map);
          final enriched = state.copyWith(
            canonicalId: cid,
            difficultyKey: state.effectiveDifficultyKey,
            updatedAt: DateTime.now(),
            createdAt: state.createdAt ?? DateTime.now(),
          );
          await SnapshotStore.instance.save(enriched);
          await ProgressStore.instance.updateProgress(
            canonicalId: cid,
            progressPercent: level.progressPercent,
            hasSnapshot: true,
            activeDifficultyKey: enriched.effectiveDifficultyKey,
            snapshotKeys: [enriched.effectiveDifficultyKey],
          );
          count++;
        } catch (e, st) {
          AppLogger.repo.warning('MigrationService: failed for level ${level.index}', e, st);
        }
      }
    }

    // 2. 迁移每日挑战
    for (final daily in dailyChallenges) {
      final snapJson = daily.savedSnapshotJson;
      if (snapJson != null && snapJson.isNotEmpty && !daily.isCompleted) {
        try {
          final cid = GameRepository.canonicalForDaily(daily.date);
          final map = jsonDecode(snapJson) as Map<String, dynamic>;
          final state = PuzzleBoardState.fromJson(map);
          final enriched = state.copyWith(
            canonicalId: cid,
            difficultyKey: state.effectiveDifficultyKey,
            updatedAt: DateTime.now(),
            createdAt: state.createdAt ?? DateTime.now(),
          );
          await SnapshotStore.instance.save(enriched);
          await ProgressStore.instance.updateProgress(
            canonicalId: cid,
            progressPercent: daily.progressPercent,
            hasSnapshot: true,
            activeDifficultyKey: enriched.effectiveDifficultyKey,
            snapshotKeys: [enriched.effectiveDifficultyKey],
          );
          count++;
        } catch (e, st) {
          AppLogger.repo.warning('MigrationService: failed for daily ${daily.date}', e, st);
        }
      }
    }

    // 3. 迁移自制拼图
    for (final custom in customPuzzles) {
      final snapJson = custom.savedSnapshotJson;
      if (snapJson != null && snapJson.isNotEmpty && !custom.isCompleted) {
        try {
          final cid = GameRepository.canonicalForCustom(custom.id);
          final map = jsonDecode(snapJson) as Map<String, dynamic>;
          final state = PuzzleBoardState.fromJson(map);
          final enriched = state.copyWith(
            canonicalId: cid,
            difficultyKey: state.effectiveDifficultyKey,
            updatedAt: DateTime.now(),
            createdAt: state.createdAt ?? DateTime.now(),
          );
          await SnapshotStore.instance.save(enriched);
          await ProgressStore.instance.updateProgress(
            canonicalId: cid,
            progressPercent: custom.progressPercent,
            hasSnapshot: true,
            activeDifficultyKey: enriched.effectiveDifficultyKey,
            snapshotKeys: [enriched.effectiveDifficultyKey],
          );
          count++;
        } catch (e, st) {
          AppLogger.repo.warning('MigrationService: failed for custom ${custom.id}', e, st);
        }
      }
    }

    try {
      await prefs.setBool(_keyMigrated, true);
      AppLogger.repo.info('MigrationService: done, migrated $count snapshots');
    } catch (e, st) {
      AppLogger.repo.warning('MigrationService: failed to write migrated flag', e, st);
    }
  }
}
