/// Representation of a difficulty tier with UI metadata.
class DifficultyTier {
  const DifficultyTier({
    required this.difficulty,
    required this.tag,
    required this.estimatedMinutes,
  });

  final PuzzleDifficulty difficulty;
  final String tag;
  final String estimatedMinutes;
}

/// Standard aspect ratios supported by the game.
/// Ensures all base cells before jigsaw edge deformation are pure squares (pieceW == pieceH).
enum PuzzleAspectRatio {
  square1x1('1:1 正方形', 1, 1),
  portrait2x3('2:3 竖屏', 2, 3),
  landscape3x2('3:2 横屏', 3, 2),
  portrait3x4('3:4 竖屏', 3, 4),
  landscape4x3('4:3 横屏', 4, 3);

  const PuzzleAspectRatio(this.label, this.aspectCols, this.aspectRows);

  final String label;
  final int aspectCols; // Base column multiplier
  final int aspectRows; // Base row multiplier

  double get ratio => aspectCols / aspectRows;

  /// Detects the closest standard aspect ratio from image pixel dimensions.
  static PuzzleAspectRatio fromSize(double width, double height) {
    if (width <= 0 || height <= 0) return square1x1;
    final r = width / height;

    var closest = square1x1;
    var minDiff = (r - square1x1.ratio).abs();

    for (final candidate in values) {
      final diff = (r - candidate.ratio).abs();
      if (diff < minDiff) {
        minDiff = diff;
        closest = candidate;
      }
    }
    return closest;
  }

  /// Generates the list of regular square-piece difficulty tiers for this aspect ratio.
  List<DifficultyTier> get tiers {
    switch (this) {
      case PuzzleAspectRatio.square1x1:
        return const [
          DifficultyTier(
            difficulty: PuzzleDifficulty(label: '4 × 4 (16 块)', rows: 4, cols: 4, recommended: true),
            tag: '新手入门',
            estimatedMinutes: '2~4分钟',
          ),
          DifficultyTier(
            difficulty: PuzzleDifficulty(label: '5 × 5 (25 块)', rows: 5, cols: 5),
            tag: '轻松休闲',
            estimatedMinutes: '4~6分钟',
          ),
          DifficultyTier(
            difficulty: PuzzleDifficulty(label: '6 × 6 (36 块)', rows: 6, cols: 6),
            tag: '经典标准',
            estimatedMinutes: '6~10分钟',
          ),
          DifficultyTier(
            difficulty: PuzzleDifficulty(label: '8 × 8 (64 块)', rows: 8, cols: 8),
            tag: '趣味进阶',
            estimatedMinutes: '15~22分钟',
          ),
          DifficultyTier(
            difficulty: PuzzleDifficulty(label: '10 × 10 (100 块)', rows: 10, cols: 10),
            tag: '探索挑战',
            estimatedMinutes: '25~35分钟',
          ),
          DifficultyTier(
            difficulty: PuzzleDifficulty(label: '12 × 12 (144 块)', rows: 12, cols: 12),
            tag: '大师挑战',
            estimatedMinutes: '40~55分钟',
          ),
          DifficultyTier(
            difficulty: PuzzleDifficulty(label: '15 × 15 (225 块)', rows: 15, cols: 15),
            tag: '宗师试炼',
            estimatedMinutes: '1.5小时+',
          ),
        ];

      case PuzzleAspectRatio.portrait3x4:
        return const [
          DifficultyTier(
            difficulty: PuzzleDifficulty(label: '6 × 8 (48 块)', rows: 8, cols: 6, recommended: true),
            tag: '经典标准',
            estimatedMinutes: '8~12分钟',
          ),
          DifficultyTier(
            difficulty: PuzzleDifficulty(label: '9 × 12 (108 块)', rows: 12, cols: 9),
            tag: '探索进阶',
            estimatedMinutes: '20~30分钟',
          ),
          DifficultyTier(
            difficulty: PuzzleDifficulty(label: '12 × 16 (192 块)', rows: 16, cols: 12),
            tag: '大师挑战',
            estimatedMinutes: '45~60分钟',
          ),
          DifficultyTier(
            difficulty: PuzzleDifficulty(label: '15 × 20 (300 块)', rows: 20, cols: 15),
            tag: '宗师试炼',
            estimatedMinutes: '1.5小时+',
          ),
        ];

      case PuzzleAspectRatio.landscape4x3:
        return const [
          DifficultyTier(
            difficulty: PuzzleDifficulty(label: '8 × 6 (48 块)', rows: 6, cols: 8, recommended: true),
            tag: '经典标准',
            estimatedMinutes: '8~12分钟',
          ),
          DifficultyTier(
            difficulty: PuzzleDifficulty(label: '12 × 9 (108 块)', rows: 9, cols: 12),
            tag: '探索进阶',
            estimatedMinutes: '20~30分钟',
          ),
          DifficultyTier(
            difficulty: PuzzleDifficulty(label: '16 × 12 (192 块)', rows: 12, cols: 16),
            tag: '大师挑战',
            estimatedMinutes: '45~60分钟',
          ),
          DifficultyTier(
            difficulty: PuzzleDifficulty(label: '20 × 15 (300 块)', rows: 15, cols: 20),
            tag: '宗师试炼',
            estimatedMinutes: '1.5小时+',
          ),
        ];

      case PuzzleAspectRatio.portrait2x3:
        return const [
          DifficultyTier(
            difficulty: PuzzleDifficulty(label: '4 × 6 (24 块)', rows: 6, cols: 4, recommended: true),
            tag: '经典标准',
            estimatedMinutes: '4~6分钟',
          ),
          DifficultyTier(
            difficulty: PuzzleDifficulty(label: '6 × 9 (54 块)', rows: 9, cols: 6),
            tag: '趣味进阶',
            estimatedMinutes: '10~15分钟',
          ),
          DifficultyTier(
            difficulty: PuzzleDifficulty(label: '8 × 12 (96 块)', rows: 12, cols: 8),
            tag: '探索挑战',
            estimatedMinutes: '20~30分钟',
          ),
          DifficultyTier(
            difficulty: PuzzleDifficulty(label: '10 × 15 (150 块)', rows: 15, cols: 10),
            tag: '大师挑战',
            estimatedMinutes: '40~55分钟',
          ),
          DifficultyTier(
            difficulty: PuzzleDifficulty(label: '12 × 18 (216 块)', rows: 18, cols: 12),
            tag: '宗师试炼',
            estimatedMinutes: '1小时+',
          ),
        ];

      case PuzzleAspectRatio.landscape3x2:
        return const [
          DifficultyTier(
            difficulty: PuzzleDifficulty(label: '6 × 4 (24 块)', rows: 4, cols: 6, recommended: true),
            tag: '经典标准',
            estimatedMinutes: '4~6分钟',
          ),
          DifficultyTier(
            difficulty: PuzzleDifficulty(label: '9 × 6 (54 块)', rows: 6, cols: 9),
            tag: '趣味进阶',
            estimatedMinutes: '10~15分钟',
          ),
          DifficultyTier(
            difficulty: PuzzleDifficulty(label: '12 × 8 (96 块)', rows: 8, cols: 12),
            tag: '探索挑战',
            estimatedMinutes: '20~30分钟',
          ),
          DifficultyTier(
            difficulty: PuzzleDifficulty(label: '15 × 10 (150 块)', rows: 10, cols: 15),
            tag: '大师挑战',
            estimatedMinutes: '40~55分钟',
          ),
          DifficultyTier(
            difficulty: PuzzleDifficulty(label: '18 × 12 (216 块)', rows: 12, cols: 18),
            tag: '宗师试炼',
            estimatedMinutes: '1小时+',
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
    PuzzleDifficulty(label: '4 × 4 (16 块)', rows: 4, cols: 4, recommended: true),
    PuzzleDifficulty(label: '4 × 6 (24 块)', rows: 6, cols: 4),
    PuzzleDifficulty(label: '6 × 4 (24 块)', rows: 4, cols: 6),
    PuzzleDifficulty(label: '5 × 5 (25 块)', rows: 5, cols: 5),
    PuzzleDifficulty(label: '6 × 6 (36 块)', rows: 6, cols: 6),
    PuzzleDifficulty(label: '6 × 8 (48 块)', rows: 8, cols: 6),
    PuzzleDifficulty(label: '8 × 6 (48 块)', rows: 6, cols: 8),
    PuzzleDifficulty(label: '6 × 9 (54 块)', rows: 9, cols: 6),
    PuzzleDifficulty(label: '9 × 6 (54 块)', rows: 6, cols: 9),
    PuzzleDifficulty(label: '8 × 8 (64 块)', rows: 8, cols: 8),
    PuzzleDifficulty(label: '8 × 12 (96 块)', rows: 12, cols: 8),
    PuzzleDifficulty(label: '12 × 8 (96 块)', rows: 8, cols: 12),
    PuzzleDifficulty(label: '10 × 10 (100 块)', rows: 10, cols: 10),
    PuzzleDifficulty(label: '9 × 12 (108 块)', rows: 12, cols: 9),
    PuzzleDifficulty(label: '12 × 9 (108 块)', rows: 9, cols: 12),
    PuzzleDifficulty(label: '12 × 12 (144 块)', rows: 12, cols: 12),
    PuzzleDifficulty(label: '10 × 15 (150 块)', rows: 15, cols: 10),
    PuzzleDifficulty(label: '15 × 10 (150 块)', rows: 10, cols: 15),
    PuzzleDifficulty(label: '12 × 16 (192 块)', rows: 16, cols: 12),
    PuzzleDifficulty(label: '16 × 12 (192 块)', rows: 12, cols: 16),
    PuzzleDifficulty(label: '12 × 18 (216 块)', rows: 18, cols: 12),
    PuzzleDifficulty(label: '18 × 12 (216 块)', rows: 12, cols: 18),
    PuzzleDifficulty(label: '15 × 15 (225 块)', rows: 15, cols: 15),
    PuzzleDifficulty(label: '15 × 20 (300 块)', rows: 20, cols: 15),
    PuzzleDifficulty(label: '20 × 15 (300 块)', rows: 15, cols: 20),
  ];

  @override
  String toString() => label;
}
