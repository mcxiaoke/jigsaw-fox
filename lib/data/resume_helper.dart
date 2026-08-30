import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../logic/models/puzzle_state.dart';
import '../logic/puzzle_model.dart';
import '../widgets/continue_dialog.dart';
import 'progress_store.dart';
import 'snapshot_store.dart';

/// 存档续玩复用 Helper：抽取 Home/Daily/MyPuzzles/Pack 中重复的
/// `final canonicalId = ...; final progress = await ProgressStore.load(...); PuzzleBoardState? snapshot ...` 逻辑
class ResumeInfo {
  const ResumeInfo({
    required this.snapshot,
    required this.dkey,
    required this.percent,
    required this.progress,
  });
  final PuzzleBoardState snapshot;
  final String dkey;
  final int percent;
  final LevelProgress progress;
}

class ResumeHelper {
  /// 读取当前可续玩的快照（若无则返回 null）
  ///
  /// 规则：`isCompleted==true` 直接视为无续玩；否则按 `progress.activeDifficultyKey`
  /// 优先加载，失败则遍历 `listDifficultyKeys` 兜底；仅当 `0 < percent < 100` 才视为可续玩。
  static Future<ResumeInfo?> fetchResume(
    String canonicalId,
    PuzzleDifficulty fallbackDifficulty,
    bool isCompleted,
  ) async {
    if (isCompleted) return null;
    final progress = await ProgressStore.instance.load(canonicalId);
    if (!progress.hasSnapshot) return null;
    final dkey = progress.activeDifficultyKey.isNotEmpty
        ? progress.activeDifficultyKey
        : SnapshotStore.difficultyKeyFor(fallbackDifficulty);
    PuzzleBoardState? snapshot = await SnapshotStore.instance.load(canonicalId, dkey);
    String usedDkey = dkey;
    int percent = 0;
    if (snapshot != null) {
      percent = SnapshotStore.progressPercentOf(snapshot);
      usedDkey = snapshot.effectiveDifficultyKey;
    } else {
      final keys = await SnapshotStore.instance.listDifficultyKeys(canonicalId);
      for (final k in keys) {
        final ss = await SnapshotStore.instance.load(canonicalId, k);
        if (ss != null) {
          snapshot = ss;
          usedDkey = k;
          percent = SnapshotStore.progressPercentOf(ss);
          break;
        }
      }
    }
    if (snapshot == null || percent <= 0 || percent >= 100) return null;
    // 重新加载最新的 progress（保证 active 键一致）
    final freshProgress = await ProgressStore.instance.load(canonicalId);
    return ResumeInfo(snapshot: snapshot, dkey: usedDkey, percent: percent, progress: freshProgress);
  }

  /// 若存在可续玩存档，则弹出 ContinueDialog 二选一；返回原始 `ContinueDialog.show` 的 `result` 字符串
  /// （`continue:<dkey>` / `restart:<dkey>`），无存档则返回 null，弹后取消返回 `'cancelled'`。
  static Future<String?> maybeShowResumeDialog({
    required BuildContext context,
    required String canonicalId,
    required PuzzleDifficulty fallbackDifficulty,
    required bool isCompleted,
    required String title,
    required Uint8List imageBytes,
  }) async {
    final info = await fetchResume(canonicalId, fallbackDifficulty, isCompleted);
    if (info == null) return null;
    if (!context.mounted) return null;
    final result = await ContinueDialog.show(
      context: context,
      title: title,
      imageBytes: imageBytes,
      difficulties: [info.dkey],
      snapshots: {info.dkey: info.snapshot},
      progressPercents: {info.dkey: info.percent},
    );
    return result ?? 'cancelled';
  }

  static Future<LevelProgress> loadProgress(String canonicalId) =>
      ProgressStore.instance.load(canonicalId);

  /// 清理指定难度的存档（文件 + 索引）
  static Future<void> clearResume(String canonicalId, String dkey) async {
    await SnapshotStore.instance.delete(canonicalId, dkey);
    await ProgressStore.instance.clearSnapshot(canonicalId, dkey);
  }

  /// 快捷获取展示用进度百分比（优先 ProgressStore 索引，兜底旧字段）
  static int displayProgress(LevelProgress progress, int legacyPercent, bool isCompleted) {
    if (isCompleted) return 0;
    if (progress.hasSnapshot) return progress.progressPercent;
    return legacyPercent;
  }

  /// 根据 difficultyKey 找回 PuzzleDifficulty，找不到则回退
  static Future<PuzzleDifficulty> diffForKey(String k, PuzzleDifficulty fallback) async {
    for (final d in PuzzleDifficulty.presets) {
      if (SnapshotStore.difficultyKeyFor(d) == k) return d;
    }
    return fallback;
  }

  /// 统一处理 ContinueDialog 返回结果的分支逻辑，消除各 tab 重复的
  /// `if (cancelled) ... if (continue) ... else if (restart) ...` 块
  ///
  /// 返回 true 表示已处理（弹过对话框，无论继续/重开/取消），调用方应 `return`；
  /// 返回 false 表示无对话框或处理失败，调用方可继续走 ChooseDifficultySheet。
  static Future<bool> handleResumeResult({
    required BuildContext context,
    required String result,
    required String canonicalId,
    required PuzzleDifficulty fallbackDifficulty,
    required Uint8List imageBytes,
    required Future<void> Function(String dkey) onClearRepo,
    required Future<void> Function(PuzzleDifficulty diff, String? jsonStr) onPushGame,
    required VoidCallback onCancelled,
  }) async {
    if (!context.mounted) return true;
    if (result == 'cancelled') {
      onCancelled();
      return true;
    }
    if (result.startsWith('continue:')) {
      final k = result.substring('continue:'.length);
      final diff = await diffForKey(k, fallbackDifficulty);
      final jsonStr = await SnapshotStore.instance.loadJsonString(canonicalId, k);
      if (!context.mounted) return true;
      await onPushGame(diff, jsonStr);
      return true;
    } else if (result.startsWith('restart:')) {
      final k = result.substring('restart:'.length);
      await clearResume(canonicalId, k);
      await onClearRepo(k);
      final diff = await diffForKey(k, fallbackDifficulty);
      if (!context.mounted) return true;
      await onPushGame(diff, null);
      return true;
    }
    return false;
  }

  /// 一站式：若有存档则弹对话框并处理分支，返回 true 表示已处理（调用方应直接 return），
  /// false 表示无存档，调用方应继续走 ChooseDifficultySheet
  static Future<bool> tryHandleResumeFlow({
    required BuildContext context,
    required String canonicalId,
    required PuzzleDifficulty fallbackDifficulty,
    required bool isCompleted,
    required String title,
    required Uint8List imageBytes,
    required Future<void> Function(String dkey) onClearRepo,
    required Future<void> Function(PuzzleDifficulty diff, String? jsonStr) onPushGame,
    required VoidCallback onCancelled,
  }) async {
    final result = await maybeShowResumeDialog(
      context: context,
      canonicalId: canonicalId,
      fallbackDifficulty: fallbackDifficulty,
      isCompleted: isCompleted,
      title: title,
      imageBytes: imageBytes,
    );
    if (result == null) return false;
    if (!context.mounted) return true;
    return handleResumeResult(
      context: context,
      result: result,
      canonicalId: canonicalId,
      fallbackDifficulty: fallbackDifficulty,
      imageBytes: imageBytes,
      onClearRepo: onClearRepo,
      onPushGame: onPushGame,
      onCancelled: onCancelled,
    );
  }
}
