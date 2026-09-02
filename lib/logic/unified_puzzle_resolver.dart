import 'package:flutter/material.dart';

import '../data/favorite_store.dart';
import '../data/progress_store.dart';
import 'catalog_index.dart';
import 'puzzle_model.dart';

/// 统一卡片视图模型（供给“我的”Tab 渲染与交互）
class UnifiedPuzzleCardData {
  const UnifiedPuzzleCardData({
    required this.canonicalId,
    required this.title,
    required this.imagePathOrUrl,
    required this.isLocalFile,
    required this.sourceLabel,
    required this.sourceColor,
    required this.sourceModule,
    required this.aspectRatio,
    this.author,
    this.tags = const [],
    this.progressPercent = 0,
    this.isCompleted = false,
    this.hasActiveSnapshot = false,
    this.activeDifficultyKey = '',
    this.maxStars = 0,
    this.bestTimeSeconds = 0,
    this.completedPieceCounts = const {},
    this.highestDifficultyKey,
    this.allDifficultyStars = const {},
    this.completedDifficultyCount = 0,
    this.totalPlayCount = 0,
    this.minHintsUsed = -1,
    this.lastSavedAt,
    this.lastCompletedAt,
    this.firstCompletedAt,
    this.firstPlayedAt,
    this.favoritedAt,
    this.isFavorite = false,
    this.isOrphan = false,
    this.contextId,
    this.displaySubtitle,
  });

  final String canonicalId;
  final String title;
  final String imagePathOrUrl;
  final bool isLocalFile;
  final String sourceLabel;
  final Color sourceColor;
  final String sourceModule;
  final PuzzleAspectRatio aspectRatio;
  final String? author;
  final List<String> tags;

  // 进度与状态
  final int progressPercent;
  final bool isCompleted;
  final bool hasActiveSnapshot;
  final String activeDifficultyKey;
  final int maxStars;
  final int bestTimeSeconds;
  final Set<int> completedPieceCounts;
  final String? highestDifficultyKey;
  final Map<String, int> allDifficultyStars;
  final int completedDifficultyCount;
  final int totalPlayCount;
  final int minHintsUsed;

  // 时间维度
  final DateTime? lastSavedAt;
  final DateTime? lastCompletedAt;
  final DateTime? firstCompletedAt;
  final DateTime? firstPlayedAt;
  final DateTime? favoritedAt;

  // 状态与路由
  final bool isFavorite;
  final bool isOrphan;
  final String? contextId;
  final String? displaySubtitle;

  DateTime? get lastPlayedAt => lastSavedAt;
}

/// 统一拼图元数据与进度装配解析器
class UnifiedPuzzleResolver {
  const UnifiedPuzzleResolver(this.index);

  final UnifiedCatalogIndex index;

  /// 来源分类主题色
  static Color getSourceColor(String label) {
    switch (label) {
      case '主线':
        return const Color(0xFF4A90E2);
      case '每日':
        return const Color(0xFFFF9500);
      case '自制':
        return const Color(0xFF9C27B0);
      case '扩展包':
        return const Color(0xFF00B894);
      case '活动':
        return const Color(0xFFFF5252);
      default:
        return const Color(0xFFD4963C);
    }
  }

  /// 根据 canonicalId 与已批量加载的进度，同步装配卡片数据（支持源被删的孤儿卡兜底）
  UnifiedPuzzleCardData resolve({
    required String canonicalId,
    LevelProgress? progress,
    FavoriteEntry? favoriteEntry,
  }) {
    final entry = index.get(canonicalId);
    final p = progress ?? LevelProgress(canonicalId: canonicalId);
    final isFav =
        favoriteEntry != null || FavoriteStore.instance.isFavorite(canonicalId);

    if (entry != null) {
      return UnifiedPuzzleCardData(
        canonicalId: canonicalId,
        title: entry.title,
        imagePathOrUrl: entry.imagePathOrUrl,
        isLocalFile: entry.isLocalFile,
        sourceLabel: entry.sourceLabel,
        sourceColor: getSourceColor(entry.sourceLabel),
        sourceModule: entry.sourceModule,
        aspectRatio: entry.aspectRatio,
        author: entry.author,
        tags: entry.tags,
        progressPercent: p.progressPercent,
        isCompleted: p.isCompleted,
        hasActiveSnapshot: p.hasSnapshot,
        activeDifficultyKey: p.activeDifficultyKey,
        maxStars: p.maxStars,
        bestTimeSeconds: p.bestTimeSeconds,
        completedPieceCounts: p.completedPieceCounts.toSet(),
        allDifficultyStars: p.allDifficultyStars,
        completedDifficultyCount: p.completedDifficultyCount,
        totalPlayCount: p.totalPlayCount,
        minHintsUsed: p.records.values.isNotEmpty
            ? p.records.values
                  .map((r) => r.minHintsUsed)
                  .reduce((a, b) => a < 0 ? b : (b < 0 ? a : (a < b ? a : b)))
            : -1,
        lastSavedAt: p.lastSavedAt,
        lastCompletedAt: p.lastCompletedAt,
        firstCompletedAt: p.firstCompletedAt,
        firstPlayedAt: p.firstPlayedAt,
        favoritedAt: favoriteEntry?.favoritedAt,
        isFavorite: isFav,
        isOrphan: false,
        contextId: entry.contextId,
        displaySubtitle: entry.displaySubtitle,
      );
    }

    // 孤儿卡兜底（源已被删除或下架）
    final fallbackTitle = favoriteEntry?.titleSnapshot ?? canonicalId;
    final fallbackImage = favoriteEntry?.imageSnapshot ?? '';
    final fallbackLabel = favoriteEntry?.sourceLabelSnapshot ?? '已失效';
    final fallbackLocal = favoriteEntry?.isLocalFileSnapshot ?? false;
    final fallbackAspect = favoriteEntry?.aspectRatioLabel == 'portrait2x3'
        ? PuzzleAspectRatio.portrait2x3
        : (favoriteEntry?.aspectRatioLabel == 'landscape3x2'
              ? PuzzleAspectRatio.landscape3x2
              : PuzzleAspectRatio.square1x1);

    return UnifiedPuzzleCardData(
      canonicalId: canonicalId,
      title: fallbackTitle,
      imagePathOrUrl: fallbackImage,
      isLocalFile: fallbackLocal,
      sourceLabel: fallbackLabel,
      sourceColor: Colors.grey,
      sourceModule: 'unknown',
      aspectRatio: fallbackAspect,
      author: favoriteEntry?.author,
      tags: favoriteEntry?.tags ?? const [],
      progressPercent: p.progressPercent,
      isCompleted: p.isCompleted,
      hasActiveSnapshot: p.hasSnapshot,
      activeDifficultyKey: p.activeDifficultyKey,
      maxStars: p.maxStars,
      bestTimeSeconds: p.bestTimeSeconds,
      completedPieceCounts: p.completedPieceCounts.toSet(),
      allDifficultyStars: p.allDifficultyStars,
      completedDifficultyCount: p.completedDifficultyCount,
      totalPlayCount: p.totalPlayCount,
      lastSavedAt: p.lastSavedAt,
      lastCompletedAt: p.lastCompletedAt,
      firstCompletedAt: p.firstCompletedAt,
      firstPlayedAt: p.firstPlayedAt,
      favoritedAt: favoriteEntry?.favoritedAt,
      isFavorite: isFav,
      isOrphan: true,
      displaySubtitle: '关卡源已失效或下架',
    );
  }
}
