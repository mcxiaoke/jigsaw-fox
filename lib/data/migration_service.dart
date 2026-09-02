import 'dart:convert';
import 'dart:math' as math;

import 'package:shared_preferences/shared_preferences.dart';

import '../logic/models/puzzle_state.dart';
import '../services/app_logger.dart';
import 'game_repository.dart';
import 'models/custom_puzzle_item.dart';
import 'models/daily_challenge.dart';
import 'models/level_item.dart';
import 'progress_store.dart';
import 'snapshot_store.dart';

/// 老版本快照与旧档位（16块/3:4幽灵难度）向 v3.3.1 规范的一次性平滑迁移服务
class MigrationService {
  MigrationService._();
  static final MigrationService instance = MigrationService._();

  static const String _keyMigrated = 'jigsaw_snapshots_v3_migrated';
  static const String _keyV33Migrated = 'jigsaw_difficulty_v3_3_migrated';

  /// 被废弃的旧版本 3:4/4:3 与 4x4 档位集合（用于清理在途幽灵快照）
  static const Set<String> kDeprecatedDifficultyKeys = {
    '4x4',
    '6x8',
    '8x6',
    '9x12',
    '12x9',
    '12x16',
    '16x12',
    '15x20',
    '20x15',
  };

  /// 检查并执行迁移（如已迁移则直接返回）
  Future<void> migrateIfNeeded({
    required SharedPreferences prefs,
    required List<LevelItem> levels,
    required List<DailyChallengeItem> dailyChallenges,
    required List<CustomPuzzleItem> customPuzzles,
  }) async {
    final alreadyMigratedV3 = prefs.getBool(_keyMigrated) ?? false;
    if (!alreadyMigratedV3) {
      await _migrateLegacyPrefsSnapshots(
        prefs,
        levels,
        dailyChallenges,
        customPuzzles,
      );
    }

    final alreadyMigratedV33 = prefs.getBool(_keyV33Migrated) ?? false;
    if (!alreadyMigratedV33) {
      await _migrate16PieceAndGhostSnapshots(prefs);
    }
  }

  /// 1. 迁移老版 Prefs 快照大 JSON 到 SnapshotStore
  Future<void> _migrateLegacyPrefsSnapshots(
    SharedPreferences prefs,
    List<LevelItem> levels,
    List<DailyChallengeItem> dailyChallenges,
    List<CustomPuzzleItem> customPuzzles,
  ) async {
    AppLogger.repo.info(
      'MigrationService: start migrating legacy snapshots to v3',
    );
    var count = 0;

    // 主线关卡
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
          AppLogger.repo.warning(
            'MigrationService: failed for level ${level.index}',
            e,
            st,
          );
        }
      }
    }

    // 每日挑战
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
          AppLogger.repo.warning(
            'MigrationService: failed for daily ${daily.date}',
            e,
            st,
          );
        }
      }
    }

    // 自制拼图
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
          AppLogger.repo.warning(
            'MigrationService: failed for custom ${custom.id}',
            e,
            st,
          );
        }
      }
    }

    try {
      await prefs.setBool(_keyMigrated, true);
      AppLogger.repo.info(
        'MigrationService: legacy migration done, migrated $count snapshots',
      );
    } catch (e, st) {
      AppLogger.repo.warning(
        'MigrationService: failed to write migrated flag',
        e,
        st,
      );
    }
  }

  /// 2. 迁移 16 块进度到 25 块，并清理幽灵难度与作废的 3:4/4:3 快照
  Future<void> _migrate16PieceAndGhostSnapshots(SharedPreferences prefs) async {
    AppLogger.repo.info(
      'MigrationService: start v3.3.1 16-piece merge and ghost cleanup',
    );
    final allCids = await ProgressStore.instance.listAllCanonicalIds();

    for (final cid in allCids) {
      try {
        final progress = await ProgressStore.instance.load(cid);
        final existingRecords = Map<String, DifficultyRecord>.from(
          progress.records,
        );
        var changed = false;

        // 16 块合并：若有 4x4 记录，并入 5x5
        if (existingRecords.containsKey('4x4')) {
          final r16 = existingRecords['4x4']!;
          final r25 = existingRecords['5x5'] ?? const DifficultyRecord();

          final mergedBestStars = math.max(r16.bestStars, r25.bestStars);
          final mergedBestTime = r25.bestTimeSeconds > 0
              ? (r16.bestTimeSeconds > 0
                    ? math.min(r16.bestTimeSeconds, r25.bestTimeSeconds)
                    : r25.bestTimeSeconds)
              : r16.bestTimeSeconds;

          final mergedMinHints = r25.minHintsUsed >= 0
              ? (r16.minHintsUsed >= 0
                    ? math.min(r16.minHintsUsed, r25.minHintsUsed)
                    : r25.minHintsUsed)
              : r16.minHintsUsed;

          existingRecords['5x5'] = r25.copyWith(
            bestStars: mergedBestStars,
            bestTimeSeconds: mergedBestTime,
            isCompleted: r25.isCompleted || r16.isCompleted,
            playCount: r25.playCount + r16.playCount,
            minHintsUsed: mergedMinHints,
          );

          existingRecords.remove('4x4');
          changed = true;
          // 删除 4x4 快照
          await SnapshotStore.instance.delete(cid, '4x4');
        }

        // 幽灵难度与作废 3:4/4:3 记录与快照清理
        final recordKeys = List<String>.from(existingRecords.keys);
        for (final k in recordKeys) {
          if (kDeprecatedDifficultyKeys.contains(k)) {
            final rec = existingRecords[k];
            if (rec != null && rec.isCompleted) {
              // 已通关：保留星星记录，仅删快照文件
              await SnapshotStore.instance.delete(cid, k);
            } else {
              // 未通关：删快照与 records 记录
              await SnapshotStore.instance.delete(cid, k);
              existingRecords.remove(k);
              changed = true;
            }
          }
        }

        // 进一步扫描磁盘快照文件，删除任何属于废弃档位的快照
        final diskKeys = await SnapshotStore.instance.listDifficultyKeys(cid);
        for (final k in diskKeys) {
          if (kDeprecatedDifficultyKeys.contains(k)) {
            final rec = existingRecords[k];
            if (rec == null || !rec.isCompleted) {
              await SnapshotStore.instance.delete(cid, k);
            }
          }
        }

        if (changed) {
          final next = progress.copyWith(
            records: existingRecords,
            stars: progress.maxStars,
          );
          await ProgressStore.instance.save(next);
        }
      } catch (e, st) {
        AppLogger.repo.warning(
          'MigrationService: failed 16-piece merge for cid=$cid',
          e,
          st,
        );
      }
    }

    try {
      await prefs.setBool(_keyV33Migrated, true);
      AppLogger.repo.info('MigrationService: v3.3.1 migration completed');
    } catch (e, st) {
      AppLogger.repo.warning(
        'MigrationService: failed to write v3.3.1 migrated flag',
        e,
        st,
      );
    }
  }
}
