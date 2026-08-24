import '../../logic/puzzle_model.dart';

/// Represents a level item in the 100-level main gallery.
class LevelItem {
  const LevelItem({
    required this.id,
    required this.index,
    required this.title,
    required this.assetPath,
    required this.difficulty,
    this.isUnlocked = false,
    this.isCompleted = false,
    this.progressPercent = 0,
    this.stars = 0,
    this.bestTimeSeconds = 0,
    this.savedSnapshotJson,
    this.completedPieceCounts = const [],
  });

  final String id;
  final int index;
  final String title;
  final String assetPath;
  final PuzzleDifficulty difficulty;
  final bool isUnlocked;
  final bool isCompleted;
  final int progressPercent; // 0 ~ 100
  final int stars; // 0 ~ 3
  final int bestTimeSeconds;
  final String? savedSnapshotJson;
  final List<int> completedPieceCounts;

  LevelItem copyWith({
    String? id,
    int? index,
    String? title,
    String? assetPath,
    PuzzleDifficulty? difficulty,
    bool? isUnlocked,
    bool? isCompleted,
    int? progressPercent,
    int? stars,
    int? bestTimeSeconds,
    String? savedSnapshotJson,
    List<int>? completedPieceCounts,
  }) {
    return LevelItem(
      id: id ?? this.id,
      index: index ?? this.index,
      title: title ?? this.title,
      assetPath: assetPath ?? this.assetPath,
      difficulty: difficulty ?? this.difficulty,
      isUnlocked: isUnlocked ?? this.isUnlocked,
      isCompleted: isCompleted ?? this.isCompleted,
      progressPercent: progressPercent ?? this.progressPercent,
      stars: stars ?? this.stars,
      bestTimeSeconds: bestTimeSeconds ?? this.bestTimeSeconds,
      savedSnapshotJson: savedSnapshotJson ?? this.savedSnapshotJson,
      completedPieceCounts: completedPieceCounts ?? this.completedPieceCounts,
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'index': index,
        'title': title,
        'assetPath': assetPath,
        'rows': difficulty.rows,
        'cols': difficulty.cols,
        'isUnlocked': isUnlocked,
        'isCompleted': isCompleted || completedPieceCounts.isNotEmpty,
        'progressPercent': progressPercent,
        'stars': stars,
        'bestTimeSeconds': bestTimeSeconds,
        'savedSnapshotJson': savedSnapshotJson,
        'completedPieceCounts': completedPieceCounts,
      };

  factory LevelItem.fromJson(Map<String, dynamic> json) {
    final rows = json['rows'] as int? ?? 4;
    final cols = json['cols'] as int? ?? 4;
    final diff = PuzzleDifficulty.presets.firstWhere(
      (d) => d.rows == rows && d.cols == cols,
      orElse: () => PuzzleDifficulty(
        label: '$rows × $cols (${rows * cols} 块)',
        rows: rows,
        cols: cols,
      ),
    );

    final rawCompletedCounts = (json['completedPieceCounts'] as List<dynamic>?)
        ?.map((e) => e as int)
        .toList();
    final isCompletedVal = json['isCompleted'] as bool? ?? false;
    final completedCounts = rawCompletedCounts ??
        (isCompletedVal ? [diff.pieceCount] : <int>[]);

    return LevelItem(
      id: json['id'] as String,
      index: json['index'] as int,
      title: json['title'] as String? ?? 'Level ${json['index']}',
      assetPath: json['assetPath'] as String,
      difficulty: diff,
      isUnlocked: json['isUnlocked'] as bool? ?? false,
      isCompleted: isCompletedVal || completedCounts.isNotEmpty,
      progressPercent: json['progressPercent'] as int? ?? 0,
      stars: json['stars'] as int? ?? 0,
      bestTimeSeconds: json['bestTimeSeconds'] as int? ?? 0,
      savedSnapshotJson: json['savedSnapshotJson'] as String?,
      completedPieceCounts: completedCounts,
    );
  }
}
