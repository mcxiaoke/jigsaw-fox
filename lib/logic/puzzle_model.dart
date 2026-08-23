class PuzzleDifficulty {
  const PuzzleDifficulty(this.label, this.rows, this.cols);
  final String label;
  final int rows;
  final int cols;
  int get pieceCount => rows * cols;

  static const values = [
    PuzzleDifficulty('3 × 3', 3, 3),
    PuzzleDifficulty('4 × 4', 4, 4),
    PuzzleDifficulty('5 × 5', 5, 5),
    PuzzleDifficulty('6 × 6', 6, 6),
  ];

  @override
  String toString() => label;
}

/// One puzzle piece, identified by its grid position.
class PieceData {
  PieceData({required this.row, required this.col})
      : currentRow = row,
        currentCol = col;

  final int row;
  final int col;
  int currentRow;
  int currentCol;

  bool get isAtTarget => currentRow == row && currentCol == col;
}
