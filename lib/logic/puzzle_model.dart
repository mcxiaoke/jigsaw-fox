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

  static const List<PuzzleDifficulty> presets = [
    PuzzleDifficulty(label: '3 × 3 (9 块)', rows: 3, cols: 3),
    PuzzleDifficulty(label: '3 × 4 (12 块)', rows: 3, cols: 4),
    PuzzleDifficulty(label: '4 × 4 (16 块)', rows: 4, cols: 4, recommended: true),
    PuzzleDifficulty(label: '4 × 6 (24 块)', rows: 4, cols: 6),
    PuzzleDifficulty(label: '5 × 5 (25 块)', rows: 5, cols: 5),
    PuzzleDifficulty(label: '6 × 6 (36 块)', rows: 6, cols: 6),
    PuzzleDifficulty(label: '6 × 8 (48 块)', rows: 6, cols: 8),
    PuzzleDifficulty(label: '8 × 8 (64 块)', rows: 8, cols: 8),
    PuzzleDifficulty(label: '10 × 10 (100 块)', rows: 10, cols: 10),
    PuzzleDifficulty(label: '12 × 16 (192 块)', rows: 12, cols: 16),
    PuzzleDifficulty(label: '15 × 20 (300 块)', rows: 15, cols: 20),
    PuzzleDifficulty(label: '20 × 20 (400 块)', rows: 20, cols: 20),
  ];

  @override
  String toString() => label;
}
