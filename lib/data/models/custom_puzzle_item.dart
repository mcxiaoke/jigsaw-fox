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
    this.sourceType = 'gallery',
    this.sourcePlatform = '本地相册',
    this.sourceUrl,
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

  /// Source type: 'gallery' (相册导入), 'online' (网络图库), 'preset' (官方预置)
  final String sourceType;

  /// Specific platform name
  final String sourcePlatform;

  /// Original image URL or local source path
  final String? sourceUrl;

  /// 规范合规的来源显示：仅输出 '相册' 或 '网络' (杜绝具体第三方网站名称防侵权)
  String get displaySource {
    if (sourceType == 'gallery' ||
        sourceType == 'local' ||
        sourcePlatform == '相册' ||
        sourcePlatform == '本地相册') {
      return '相册';
    }
    return '网络';
  }

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
    bool clearSnapshot = false,
    List<int>? completedPieceCounts,
    String? sourceType,
    String? sourcePlatform,
    String? sourceUrl,
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
      savedSnapshotJson: clearSnapshot
          ? null
          : (savedSnapshotJson ?? this.savedSnapshotJson),
      completedPieceCounts: completedPieceCounts ?? this.completedPieceCounts,
      sourceType: sourceType ?? this.sourceType,
      sourcePlatform: sourcePlatform ?? this.sourcePlatform,
      sourceUrl: sourceUrl ?? this.sourceUrl,
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
    'sourceType': sourceType,
    'sourcePlatform': sourcePlatform,
    'sourceUrl': sourceUrl,
  };

  /// 元数据专用序列化（设计 §5.2）：custom:{id} 只存元数据，
  /// 进度字段 isCompleted/progressPercent/bestTimeSeconds/
  /// completedPieceCounts/savedSnapshotJson 全部委托 game-progress-v1 的
  /// ugc:{id}，不在此落盘——否则会产生双路副本，且残留的旧进度字段会
  /// 在水合前被 fromJson 错误还原。
  Map<String, dynamic> toMetadataJson() => {
    'id': id,
    'title': title,
    'imagePathOrUrl': imagePathOrUrl,
    'isLocalFile': isLocalFile,
    'rows': difficulty.rows,
    'cols': difficulty.cols,
    if (createdAt != null) 'createdAt': createdAt!.toIso8601String(),
    'sourceType': sourceType,
    'sourcePlatform': sourcePlatform,
    if (sourceUrl != null) 'sourceUrl': sourceUrl,
  };

  factory CustomPuzzleItem.fromJson(Map<String, dynamic> json) {
    final rows = json['rows'] as int? ?? 4;
    final cols = json['cols'] as int? ?? 4;
    final diff = PuzzleDifficulty.presets.firstWhere(
      (d) => d.rows == rows && d.cols == cols,
      orElse: () => PuzzleDifficulty(
        label: '$cols × $rows (${rows * cols} 块)',
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

    final imagePathOrUrl = json['imagePathOrUrl'] as String? ?? '';
    final isLocal = json['isLocalFile'] as bool? ?? false;

    // Backward-compatible source fallback
    String derivedSourceType = json['sourceType'] as String? ?? '';
    String derivedSourcePlatform = json['sourcePlatform'] as String? ?? '';
    if (derivedSourceType.isEmpty) {
      if (imagePathOrUrl.startsWith('assets/')) {
        derivedSourceType = 'preset';
        derivedSourcePlatform = '官方预置';
      } else {
        derivedSourceType = 'gallery';
        derivedSourcePlatform = '本地相册';
      }
    }
    if (derivedSourcePlatform.isEmpty) {
      derivedSourcePlatform = derivedSourceType == 'preset'
          ? '官方预置'
          : (derivedSourceType == 'online' ? '网络图库' : '本地相册');
    }

    return CustomPuzzleItem(
      id: json['id'] as String,
      title: json['title'] as String,
      imagePathOrUrl: imagePathOrUrl,
      isLocalFile: isLocal,
      difficulty: diff,
      createdAt: json['createdAt'] != null
          ? DateTime.tryParse(json['createdAt'] as String)
          : null,
      isCompleted: isCompletedVal || completedCounts.isNotEmpty,
      progressPercent: json['progressPercent'] as int? ?? 0,
      bestTimeSeconds: json['bestTimeSeconds'] as int? ?? 0,
      savedSnapshotJson: json['savedSnapshotJson'] as String?,
      completedPieceCounts: completedCounts,
      sourceType: derivedSourceType,
      sourcePlatform: derivedSourcePlatform,
      sourceUrl: json['sourceUrl'] as String?,
    );
  }
}
