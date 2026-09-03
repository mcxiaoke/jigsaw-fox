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
  /// 规则：不再以 `isCompleted` 阻断（已通关重玩的残局仍需可继续）；仅按
  /// `hasSnapshot` + 快照存在且未通关（`percent < 100` 且非 isSolved）判定；
  /// `percent==0` 的自由摆放也视为可续玩（修复 P1-5）。
  /// 若索引为 true 但文件丢失，会自动执行对账自愈（修复 P1-8）。
  static Future<ResumeInfo?> fetchResume(
    String canonicalId,
    PuzzleDifficulty fallbackDifficulty, [
    bool? isCompleted,
  ]) async {
    final progress = await ProgressStore.instance.load(canonicalId);
    if (!progress.hasSnapshot) return null;
    final dkey = progress.activeDifficultyKey.isNotEmpty
        ? progress.activeDifficultyKey
        : SnapshotStore.difficultyKeyFor(fallbackDifficulty);
    PuzzleBoardState? snapshot = await SnapshotStore.instance.load(
      canonicalId,
      dkey,
    );
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
    if (snapshot == null) {
      // 索引记录有快照但实际文件不存在或已损坏被删：自动对账纠正索引（P1-8）
      await ProgressStore.instance.clearAllSnapshots(canonicalId);
      return null;
    }
    if (percent >= 100 || snapshot.isSolved) return null;
    // 过滤“点进去即退”的无意义残局：0% 且无合并/提示/时长<5s则不视为可续玩，避免“只要点进去就有记录”
    final isTrivial =
        percent == 0 &&
        snapshot.hintsUsed == 0 &&
        snapshot.elapsedSeconds < 5 &&
        snapshot.pieces.every((p) => p.clusterId == p.id);
    if (isTrivial) return null;

    // 直接复用 progress，消除多余的第二次 load IO（P2-16）
    return ResumeInfo(
      snapshot: snapshot,
      dkey: usedDkey,
      percent: percent,
      progress: progress,
    );
  }

  /// 若存在可续玩存档，则弹出 ContinueDialog 二选一；返回原始 `ContinueDialog.show` 的 `result` 字符串
  /// （`continue:<dkey>` / `restart:<dkey>`），无存档则返回 null，弹后取消返回 `'cancelled'`。
  /// `isCompleted` 已废弃（为兼容保留），不再阻断续玩。
  static Future<String?> maybeShowResumeDialog({
    required BuildContext context,
    required String canonicalId,
    required PuzzleDifficulty fallbackDifficulty,
    bool isCompleted = false,
    required String title,
    required Uint8List imageBytes,
  }) async {
    final info = await fetchResume(canonicalId, fallbackDifficulty);
    if (info == null) return null;
    if (!context.mounted) return null;
    final result = await ContinueDialog.show(
      context: context,
      title: title,
      imageBytes: imageBytes,
      difficultyKey: info.dkey,
      snapshot: info.snapshot,
      progressPercent: info.percent,
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
  /// 已通关重玩的残局也应显示进度，故 hasSnapshot 优先于 isCompleted
  static int displayProgress(
    LevelProgress progress,
    int legacyPercent,
    bool isCompleted,
  ) {
    if (progress.hasSnapshot) return progress.progressPercent;
    if (isCompleted) return 0;
    return legacyPercent;
  }

  /// 根据 difficultyKey 找回 PuzzleDifficulty，找不到则尝试解析字符串格式或回退
  static Future<PuzzleDifficulty> diffForKey(
    String k,
    PuzzleDifficulty fallback,
  ) async {
    for (final d in PuzzleDifficulty.presets) {
      if (SnapshotStore.difficultyKeyFor(d) == k) return d;
    }
    // 字符串动态解析兜底（格式 'rows x cols'），增强容错清洗确保历史快照 100% 恢复
    final normalized = k
        .trim()
        .toLowerCase()
        .replaceAll('×', 'x')
        .replaceAll(' ', '');
    final parts = normalized.split('x');
    if (parts.length == 2) {
      final r = int.tryParse(parts[0].trim());
      final c = int.tryParse(parts[1].trim());
      if (r != null && c != null && r > 0 && c > 0) {
        return PuzzleDifficulty(
          rows: r,
          cols: c,
          label: '$c × $r (${r * c} 块)',
        );
      }
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
    required Future<void> Function(PuzzleDifficulty diff, String? jsonStr)
    onPushGame,
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
      final jsonStr = await SnapshotStore.instance.loadJsonString(
        canonicalId,
        k,
      );
      if (!context.mounted) return true;
      await onPushGame(diff, jsonStr);
      return true;
    } else if (result.startsWith('restart:')) {
      final k = result.substring('restart:'.length);
      await clearResume(canonicalId, k);
      await onClearRepo(k);
      // 重开不直接进游戏，清除后返回 false 让调用方展示无记录的难度选择页
      return false;
    }
    return false;
  }

  /// 一站式：若有存档则弹对话框并处理分支，返回 true 表示已处理（调用方应直接 return），
  /// false 表示无存档，调用方应继续走 ChooseDifficultySheet。
  /// `isCompleted` 已废弃，仅为兼容保留。
  static Future<bool> tryHandleResumeFlow({
    required BuildContext context,
    required String canonicalId,
    required PuzzleDifficulty fallbackDifficulty,
    bool isCompleted = false,
    required String title,
    required Uint8List imageBytes,
    required Future<void> Function(String dkey) onClearRepo,
    required Future<void> Function(PuzzleDifficulty diff, String? jsonStr)
    onPushGame,
    required VoidCallback onCancelled,
  }) async {
    final result = await maybeShowResumeDialog(
      context: context,
      canonicalId: canonicalId,
      fallbackDifficulty: fallbackDifficulty,
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
