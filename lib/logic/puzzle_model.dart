import 'dart:math' as math;

/// Representation of a difficulty tier with UI metadata.
class DifficultyTier {
  const DifficultyTier({
    required this.difficulty,
    required this.tag,
    required this.estimatedMinutes,
    required this.secPerPiece,
    this.tierLevel = 'L1',
  });

  final PuzzleDifficulty difficulty;
  final String tag;
  final String estimatedMinutes;
  final double secPerPiece;
  final String tierLevel;
}

/// Standard aspect ratios supported by the game (v3.4: 1:1, 2:3, 3:2, 3:4, 4:3).
/// Ensures all base cells before jigsaw edge deformation are pure squares (pieceW == pieceH).
enum PuzzleAspectRatio {
  square1x1(
    '1:1 正方形',
    1,
    1,
    recommendedK: 6,
    multipliers: [5, 6, 8, 10, 12, 15, 20, 24],
  ),
  portrait2x3(
    '2:3 竖屏',
    2,
    3,
    recommendedK: 2,
    multipliers: [2, 3, 4, 5, 6, 8, 10],
  ),
  landscape3x2(
    '3:2 横屏',
    3,
    2,
    recommendedK: 2,
    multipliers: [2, 3, 4, 5, 6, 8, 10],
  ),
  portrait3x4('3:4 竖屏', 3, 4, recommendedK: 2, multipliers: [2, 3, 4, 5, 6, 7]),
  landscape4x3(
    '4:3 横屏',
    4,
    3,
    recommendedK: 2,
    multipliers: [2, 3, 4, 5, 6, 7],
  );

  const PuzzleAspectRatio(
    this.label,
    this.aspectCols,
    this.aspectRows, {
    required this.recommendedK,
    required this.multipliers,
  });

  final String label;
  final int aspectCols; // Base column multiplier
  final int aspectRows; // Base row multiplier
  final int recommendedK; // Recommended multiplier for beginner/casual start
  final List<int>
  multipliers; // Ladder multipliers under pure square piece constraint

  double get ratio => aspectCols / aspectRows;

  /// Calculates the area crop loss when cropping an image with [imageRatio] to [targetRatio].
  /// Formula: CropLoss(r, target) = 1 - min(r / target, target / r)
  static double cropLoss(double imageRatio, double targetRatio) {
    if (imageRatio <= 0 || targetRatio <= 0) return 1.0;
    return 1.0 - math.min(imageRatio / targetRatio, targetRatio / imageRatio);
  }

  /// Detects the closest standard aspect ratio using the minimum area crop loss algorithm.
  static PuzzleAspectRatio fromSize(double width, double height) {
    if (width <= 0 || height <= 0) return square1x1;
    final r = width / height;

    var closest = values.first;
    var minLoss = double.infinity;

    for (final candidate in values) {
      final loss = cropLoss(r, candidate.ratio);
      if (loss < minLoss) {
        minLoss = loss;
        closest = candidate;
      }
    }
    return closest;
  }

  /// Generates the list of regular square-piece difficulty tiers for this aspect ratio.
  List<DifficultyTier> get tiers {
    return multipliers.map((k) {
      final cols = aspectCols * k;
      final rows = aspectRows * k;
      final count = cols * rows;
      final diff = PuzzleDifficulty(
        rows: rows,
        cols: cols,
        label: '$cols × $rows ($count 块)',
        recommended: k == recommendedK,
      );
      return DifficultyTier(
        difficulty: diff,
        tag: diff.tierTag,
        estimatedMinutes: diff.estimatedMinutes,
        secPerPiece: diff.secPerPiece,
        tierLevel: diff.tierLevel,
      );
    }).toList();
  }
}

/// Puzzle grid difficulty level.
class PuzzleDifficulty {
  const PuzzleDifficulty({
    required this.label,
    required this.rows,
    required this.cols,
    this.recommended = false,
  });

  final String label;
  final int rows;
  final int cols;
  final bool recommended;

  int get pieceCount => rows * cols;

  /// Difficulty tier level (L1 ~ L7).
  String get tierLevel {
    if (pieceCount <= 30) return 'L1';
    if (pieceCount <= 40) return 'L1.5';
    if (pieceCount <= 75) return 'L2';
    if (pieceCount <= 125) return 'L3';
    if (pieceCount <= 200) return 'L4';
    if (pieceCount <= 320) return 'L5';
    if (pieceCount <= 450) return 'L6';
    return 'L7';
  }

  /// Difficulty tier tag label.
  String get tierTag {
    switch (tierLevel) {
      case 'L1':
        return '新手 Easy';
      case 'L1.5':
        return '入门+ (过渡)';
      case 'L2':
        return '简单 Beginner';
      case 'L3':
        return '普通 Medium';
      case 'L4':
        return '进阶 Hard';
      case 'L5':
        return '困难 Expert';
      case 'L6':
        return '大师 Master';
      case 'L7':
        return '宗师 Grandmaster';
      default:
        return '普通 Medium';
    }
  }

  /// Difficulty tier index (0 ~ 7).
  int get tierIndex {
    switch (tierLevel) {
      case 'L1':
        return 0;
      case 'L1.5':
        return 1;
      case 'L2':
        return 2;
      case 'L3':
        return 3;
      case 'L4':
        return 4;
      case 'L5':
        return 5;
      case 'L6':
        return 6;
      case 'L7':
        return 7;
      default:
        return 2;
    }
  }

  /// Estimated completion time text (matches existing baselines).
  String get estimatedMinutes {
    switch (tierLevel) {
      case 'L1':
        return '1~3分钟';
      case 'L1.5':
        return '2~4分钟';
      case 'L2':
        return '5~8分钟';
      case 'L3':
        return '12~18分钟';
      case 'L4':
        return '25~35分钟';
      case 'L5':
        return '50~75分钟';
      case 'L6':
        return '1.5~3小时';
      case 'L7':
        return '3~5小时';
      default:
        return '10~20分钟';
    }
  }

  /// Returns the corresponding non-linear secPerPiece benchmark for star rating.
  double get secPerPiece {
    switch (tierLevel) {
      case 'L1':
        return 3.0;
      case 'L1.5':
        return 3.5;
      case 'L2':
        return 5.0;
      case 'L3':
        return 8.0;
      case 'L4':
        return 12.0;
      case 'L5':
        return 18.0;
      case 'L6':
        return 25.0;
      case 'L7':
        return 28.0;
      default:
        return 8.0;
    }
  }

  /// Returns an orientation-adaptive difficulty that matches the image's aspect ratio,
  /// ensuring cut puzzle pieces are always square.
  PuzzleDifficulty adaptiveForSize(double width, double height) {
    if (width <= 0 || height <= 0) return this;
    final aspect = PuzzleAspectRatio.fromSize(width, height);
    final tiers = aspect.tiers;
    // Find closest tier in piece count
    var best = tiers.first.difficulty;
    var minDiff = (best.pieceCount - pieceCount).abs();
    for (final t in tiers) {
      final diff = (t.difficulty.pieceCount - pieceCount).abs();
      if (diff < minDiff) {
        minDiff = diff;
        best = t.difficulty;
      }
    }
    return best;
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is PuzzleDifficulty &&
          runtimeType == other.runtimeType &&
          rows == other.rows &&
          cols == other.cols;

  @override
  int get hashCode => Object.hash(rows, cols);

  @override
  String toString() => label;

  /// Global static preset difficulty list (sorted ascending by pieceCount, then cols, then rows).
  static final List<PuzzleDifficulty> presets = _buildPresets();

  static List<PuzzleDifficulty> _buildPresets() {
    final list = <PuzzleDifficulty>[];
    for (final aspect in PuzzleAspectRatio.values) {
      for (final t in aspect.tiers) {
        if (!list.contains(t.difficulty)) {
          list.add(t.difficulty);
        }
      }
    }
    list.sort((a, b) {
      final cmp = a.pieceCount.compareTo(b.pieceCount);
      if (cmp != 0) return cmp;
      final c2 = a.cols.compareTo(b.cols);
      return c2 != 0 ? c2 : a.rows.compareTo(b.rows);
    });
    return List.unmodifiable(list);
  }
}
