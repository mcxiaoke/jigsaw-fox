import '../../logic/puzzle_model.dart';

/// Represents a user-generated custom puzzle item (or preset sample).
class CustomPuzzleItem {
  const CustomPuzzleItem({
    required this.id,
    required this.title,
    required this.imagePathOrUrl,
    required this.isLocalFile,
    required this.difficulty,
    this.createdAt,
    this.isCompleted = false,
    this.progressPercent = 0,
    this.bestTimeSeconds = 0,
    this.savedSnapshotJson,
    this.completedPieceCounts = const [],
  });

  final String id;
  final String title;
  final String imagePathOrUrl;
  final bool isLocalFile;
  final PuzzleDifficulty difficulty;
  final DateTime? createdAt;
  final bool isCompleted;
  final int progressPercent;
  final int bestTimeSeconds;
  final String? savedSnapshotJson;
  final List<int> completedPieceCounts;

  CustomPuzzleItem copyWith({
    String? id,
    String? title,
    String? imagePathOrUrl,
    bool? isLocalFile,
    PuzzleDifficulty? difficulty,
    DateTime? createdAt,
    bool? isCompleted,
    int? progressPercent,
    int? bestTimeSeconds,
    String? savedSnapshotJson,
    List<int>? completedPieceCounts,
  }) {
    return CustomPuzzleItem(
      id: id ?? this.id,
      title: title ?? this.title,
      imagePathOrUrl: imagePathOrUrl ?? this.imagePathOrUrl,
      isLocalFile: isLocalFile ?? this.isLocalFile,
      difficulty: difficulty ?? this.difficulty,
      createdAt: createdAt ?? this.createdAt,
      isCompleted: isCompleted ?? this.isCompleted,
      progressPercent: progressPercent ?? this.progressPercent,
      bestTimeSeconds: bestTimeSeconds ?? this.bestTimeSeconds,
      savedSnapshotJson: savedSnapshotJson ?? this.savedSnapshotJson,
      completedPieceCounts: completedPieceCounts ?? this.completedPieceCounts,
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'title': title,
        'imagePathOrUrl': imagePathOrUrl,
        'isLocalFile': isLocalFile,
        'rows': difficulty.rows,
        'cols': difficulty.cols,
        'createdAt': createdAt?.toIso8601String(),
        'isCompleted': isCompleted || completedPieceCounts.isNotEmpty,
        'progressPercent': progressPercent,
        'bestTimeSeconds': bestTimeSeconds,
        'savedSnapshotJson': savedSnapshotJson,
        'completedPieceCounts': completedPieceCounts,
      };

  factory CustomPuzzleItem.fromJson(Map<String, dynamic> json) {
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

    return CustomPuzzleItem(
      id: json['id'] as String,
      title: json['title'] as String,
      imagePathOrUrl: json['imagePathOrUrl'] as String,
      isLocalFile: json['isLocalFile'] as bool? ?? false,
      difficulty: diff,
      createdAt: json['createdAt'] != null
          ? DateTime.tryParse(json['createdAt'] as String)
          : null,
      isCompleted: isCompletedVal || completedCounts.isNotEmpty,
      progressPercent: json['progressPercent'] as int? ?? 0,
      bestTimeSeconds: json['bestTimeSeconds'] as int? ?? 0,
      savedSnapshotJson: json['savedSnapshotJson'] as String?,
      completedPieceCounts: completedCounts,
    );
  }
}
