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

/// Standard aspect ratios supported by the game (v3.3.1: 1:1, 2:3, 3:2).
/// Ensures all base cells before jigsaw edge deformation are pure squares (pieceW == pieceH).
enum PuzzleAspectRatio {
  square1x1('1:1 正方形', 1, 1),
  portrait2x3('2:3 竖屏', 2, 3),
  landscape3x2('3:2 横屏', 3, 2);

  const PuzzleAspectRatio(this.label, this.aspectCols, this.aspectRows);

  final String label;
  final int aspectCols; // Base column multiplier
  final int aspectRows; // Base row multiplier

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

    var closest = square1x1;
    var minLoss = cropLoss(r, square1x1.ratio);

    for (final candidate in values) {
      final loss = cropLoss(r, candidate.ratio);
      if (loss < minLoss) {
        minLoss = loss;
        closest = candidate;
      }
    }
    return closest;
  }

  /// Generates the list of regular square-piece difficulty tiers for this aspect ratio (7 tiers).
  List<DifficultyTier> get tiers {
    switch (this) {
      case PuzzleAspectRatio.square1x1:
        return const [
          DifficultyTier(
            difficulty: PuzzleDifficulty(label: '5 × 5 (25 块)', rows: 5, cols: 5),
            tag: '新手 Easy',
            estimatedMinutes: '1~3分钟',
            secPerPiece: 3.0,
            tierLevel: 'L1',
          ),
          DifficultyTier(
            difficulty: PuzzleDifficulty(label: '6 × 6 (36 块)', rows: 6, cols: 6, recommended: true),
            tag: '入门+ (过渡)',
            estimatedMinutes: '2~4分钟',
            secPerPiece: 3.5,
            tierLevel: 'L1.5',
          ),
          DifficultyTier(
            difficulty: PuzzleDifficulty(label: '8 × 8 (64 块)', rows: 8, cols: 8),
            tag: '简单 Beginner',
            estimatedMinutes: '5~8分钟',
            secPerPiece: 5.0,
            tierLevel: 'L2',
          ),
          DifficultyTier(
            difficulty: PuzzleDifficulty(label: '10 × 10 (100 块)', rows: 10, cols: 10),
            tag: '普通 Medium',
            estimatedMinutes: '12~18分钟',
            secPerPiece: 8.0,
            tierLevel: 'L3',
          ),
          DifficultyTier(
            difficulty: PuzzleDifficulty(label: '12 × 12 (144 块)', rows: 12, cols: 12),
            tag: '进阶 Hard',
            estimatedMinutes: '25~35分钟',
            secPerPiece: 12.0,
            tierLevel: 'L4',
          ),
          DifficultyTier(
            difficulty: PuzzleDifficulty(label: '15 × 15 (225 块)', rows: 15, cols: 15),
            tag: '困难 Expert',
            estimatedMinutes: '50~75分钟',
            secPerPiece: 18.0,
            tierLevel: 'L5',
          ),
          DifficultyTier(
            difficulty: PuzzleDifficulty(label: '20 × 20 (400 块)', rows: 20, cols: 20),
            tag: '大师 Master',
            estimatedMinutes: '1.5~3小时',
            secPerPiece: 25.0,
            tierLevel: 'L6',
          ),
        ];

      case PuzzleAspectRatio.portrait2x3:
        return const [
          DifficultyTier(
            difficulty: PuzzleDifficulty(label: '4 × 6 (24 块)', rows: 6, cols: 4, recommended: true),
            tag: '新手 Easy',
            estimatedMinutes: '1~3分钟',
            secPerPiece: 3.0,
            tierLevel: 'L1',
          ),
          DifficultyTier(
            difficulty: PuzzleDifficulty(label: '6 × 9 (54 块)', rows: 9, cols: 6),
            tag: '简单 Beginner',
            estimatedMinutes: '5~8分钟',
            secPerPiece: 5.0,
            tierLevel: 'L2',
          ),
          DifficultyTier(
            difficulty: PuzzleDifficulty(label: '8 × 12 (96 块)', rows: 12, cols: 8),
            tag: '普通 Medium',
            estimatedMinutes: '12~18分钟',
            secPerPiece: 8.0,
            tierLevel: 'L3',
          ),
          DifficultyTier(
            difficulty: PuzzleDifficulty(label: '10 × 15 (150 块)', rows: 15, cols: 10),
            tag: '进阶 Hard',
            estimatedMinutes: '25~35分钟',
            secPerPiece: 12.0,
            tierLevel: 'L4',
          ),
          DifficultyTier(
            difficulty: PuzzleDifficulty(label: '12 × 18 (216 块)', rows: 18, cols: 12),
            tag: '困难 Expert',
            estimatedMinutes: '50~75分钟',
            secPerPiece: 18.0,
            tierLevel: 'L5',
          ),
          DifficultyTier(
            difficulty: PuzzleDifficulty(label: '16 × 24 (384 块)', rows: 24, cols: 16),
            tag: '大师 Master',
            estimatedMinutes: '1.5~3小时',
            secPerPiece: 25.0,
            tierLevel: 'L6',
          ),
        ];

      case PuzzleAspectRatio.landscape3x2:
        return const [
          DifficultyTier(
            difficulty: PuzzleDifficulty(label: '6 × 4 (24 块)', rows: 4, cols: 6, recommended: true),
            tag: '新手 Easy',
            estimatedMinutes: '1~3分钟',
            secPerPiece: 3.0,
            tierLevel: 'L1',
          ),
          DifficultyTier(
            difficulty: PuzzleDifficulty(label: '9 × 6 (54 块)', rows: 6, cols: 9),
            tag: '简单 Beginner',
            estimatedMinutes: '5~8分钟',
            secPerPiece: 5.0,
            tierLevel: 'L2',
          ),
          DifficultyTier(
            difficulty: PuzzleDifficulty(label: '12 × 8 (96 块)', rows: 8, cols: 12),
            tag: '普通 Medium',
            estimatedMinutes: '12~18分钟',
            secPerPiece: 8.0,
            tierLevel: 'L3',
          ),
          DifficultyTier(
            difficulty: PuzzleDifficulty(label: '15 × 10 (150 块)', rows: 10, cols: 15),
            tag: '进阶 Hard',
            estimatedMinutes: '25~35分钟',
            secPerPiece: 12.0,
            tierLevel: 'L4',
          ),
          DifficultyTier(
            difficulty: PuzzleDifficulty(label: '18 × 12 (216 块)', rows: 12, cols: 18),
            tag: '困难 Expert',
            estimatedMinutes: '50~75分钟',
            secPerPiece: 18.0,
            tierLevel: 'L5',
          ),
          DifficultyTier(
            difficulty: PuzzleDifficulty(label: '24 × 16 (384 块)', rows: 16, cols: 24),
            tag: '大师 Master',
            estimatedMinutes: '1.5~3小时',
            secPerPiece: 25.0,
            tierLevel: 'L6',
          ),
        ];
    }
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

  /// Returns the corresponding non-linear secPerPiece benchmark for star rating.
  double get secPerPiece {
    switch (pieceCount) {
      case 24:
      case 25:
        return 3.0; // L1
      case 36:
        return 3.5; // L1.5
      case 54:
      case 64:
        return 5.0; // L2
      case 96:
      case 100:
        return 8.0; // L3
      case 144:
      case 150:
        return 12.0; // L4
      case 216:
      case 225:
        return 18.0; // L5
      case 384:
      case 400:
        return 25.0; // L6
      default:
        if (pieceCount <= 30) return 3.0;
        if (pieceCount <= 45) return 3.5;
        if (pieceCount <= 80) return 5.0;
        if (pieceCount <= 120) return 8.0;
        if (pieceCount <= 180) return 12.0;
        if (pieceCount <= 300) return 18.0;
        return 25.0;
    }
  }

  /// Difficulty tier label (L1 ~ L6).
  String get tierLevel {
    switch (pieceCount) {
      case 24:
      case 25:
        return 'L1';
      case 36:
        return 'L1.5';
      case 54:
      case 64:
        return 'L2';
      case 96:
      case 100:
        return 'L3';
      case 144:
      case 150:
        return 'L4';
      case 216:
      case 225:
        return 'L5';
      case 384:
      case 400:
        return 'L6';
      default:
        return 'Custom';
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

  static const List<PuzzleDifficulty> presets = [
    PuzzleDifficulty(label: '4 × 6 (24 块)', rows: 6, cols: 4, recommended: true),
    PuzzleDifficulty(label: '6 × 4 (24 块)', rows: 4, cols: 6, recommended: true),
    PuzzleDifficulty(label: '5 × 5 (25 块)', rows: 5, cols: 5),
    PuzzleDifficulty(label: '6 × 6 (36 块)', rows: 6, cols: 6, recommended: true),
    PuzzleDifficulty(label: '6 × 9 (54 块)', rows: 9, cols: 6),
    PuzzleDifficulty(label: '9 × 6 (54 块)', rows: 6, cols: 9),
    PuzzleDifficulty(label: '8 × 8 (64 块)', rows: 8, cols: 8),
    PuzzleDifficulty(label: '8 × 12 (96 块)', rows: 12, cols: 8),
    PuzzleDifficulty(label: '12 × 8 (96 块)', rows: 8, cols: 12),
    PuzzleDifficulty(label: '10 × 10 (100 块)', rows: 10, cols: 10),
    PuzzleDifficulty(label: '12 × 12 (144 块)', rows: 12, cols: 12),
    PuzzleDifficulty(label: '10 × 15 (150 块)', rows: 15, cols: 10),
    PuzzleDifficulty(label: '15 × 10 (150 块)', rows: 10, cols: 15),
    PuzzleDifficulty(label: '12 × 18 (216 块)', rows: 18, cols: 12),
    PuzzleDifficulty(label: '18 × 12 (216 块)', rows: 12, cols: 18),
    PuzzleDifficulty(label: '15 × 15 (225 块)', rows: 15, cols: 15),
    PuzzleDifficulty(label: '16 × 24 (384 块)', rows: 24, cols: 16),
    PuzzleDifficulty(label: '24 × 16 (384 块)', rows: 16, cols: 24),
    PuzzleDifficulty(label: '20 × 20 (400 块)', rows: 20, cols: 20),
  ];

  @override
  String toString() => label;
}
