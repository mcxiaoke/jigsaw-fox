import '../../logic/puzzle_model.dart';

/// Represents a daily challenge item.
class DailyChallengeItem {
  const DailyChallengeItem({
    required this.id,
    required this.date,
    required this.dayNumber,
    required this.title,
    required this.author,
    required this.assetPath,
    required this.difficulty,
    this.isCompleted = false,
    this.progressPercent = 0,
    this.bestTimeSeconds = 0,
    this.savedSnapshotJson,
    this.completedPieceCounts = const [],
  });

  final String id;
  final String date; // YYYY-MM-DD
  final int dayNumber; // 1 ~ 31
  final String title;
  final String author;
  final String assetPath;
  final PuzzleDifficulty difficulty;
  final bool isCompleted;
  final int progressPercent;
  final int bestTimeSeconds;
  final String? savedSnapshotJson;
  final List<int> completedPieceCounts;

  DailyChallengeItem copyWith({
    String? id,
    String? date,
    int? dayNumber,
    String? title,
    String? author,
    String? assetPath,
    PuzzleDifficulty? difficulty,
    bool? isCompleted,
    int? progressPercent,
    int? bestTimeSeconds,
    String? savedSnapshotJson,
    bool clearSnapshot = false,
    List<int>? completedPieceCounts,
  }) {
    return DailyChallengeItem(
      id: id ?? this.id,
      date: date ?? this.date,
      dayNumber: dayNumber ?? this.dayNumber,
      title: title ?? this.title,
      author: author ?? this.author,
      assetPath: assetPath ?? this.assetPath,
      difficulty: difficulty ?? this.difficulty,
      isCompleted: isCompleted ?? this.isCompleted,
      progressPercent: progressPercent ?? this.progressPercent,
      bestTimeSeconds: bestTimeSeconds ?? this.bestTimeSeconds,
      savedSnapshotJson: clearSnapshot
          ? null
          : (savedSnapshotJson ?? this.savedSnapshotJson),
      completedPieceCounts: completedPieceCounts ?? this.completedPieceCounts,
    );
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'date': date,
    'dayNumber': dayNumber,
    'title': title,
    'author': author,
    'assetPath': assetPath,
    'rows': difficulty.rows,
    'cols': difficulty.cols,
    'isCompleted': isCompleted || completedPieceCounts.isNotEmpty,
    'progressPercent': progressPercent,
    'bestTimeSeconds': bestTimeSeconds,
    'savedSnapshotJson': savedSnapshotJson,
    'completedPieceCounts': completedPieceCounts,
  };

  factory DailyChallengeItem.fromJson(Map<String, dynamic> json) {
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
    final completedCounts =
        rawCompletedCounts ?? (isCompletedVal ? [diff.pieceCount] : <int>[]);

    return DailyChallengeItem(
      id: json['id'] as String,
      date: json['date'] as String,
      dayNumber: json['dayNumber'] as int,
      title: json['title'] as String,
      author: json['author'] as String? ?? 'Artist',
      assetPath: json['assetPath'] as String,
      difficulty: diff,
      isCompleted: isCompletedVal || completedCounts.isNotEmpty,
      progressPercent: json['progressPercent'] as int? ?? 0,
      bestTimeSeconds: json['bestTimeSeconds'] as int? ?? 0,
      savedSnapshotJson: json['savedSnapshotJson'] as String?,
      completedPieceCounts: completedCounts,
    );
  }
}
