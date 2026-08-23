import 'dart:math';
import 'edge_type.dart';

/// Quad edges of a single puzzle piece.
class PieceEdges {
  const PieceEdges({
    required this.top,
    required this.right,
    required this.bottom,
    required this.left,
  });

  final EdgeType top;
  final EdgeType right;
  final EdgeType bottom;
  final EdgeType left;

  /// Returns true if any of the edges is a flat outer border.
  bool get isBorder =>
      top.isFlat || right.isFlat || bottom.isFlat || left.isFlat;

  /// Returns true if this piece is a corner piece (2 flat edges).
  bool get isCorner =>
      [top, right, bottom, left].where((e) => e.isFlat).length == 2;

  /// Returns rotated edges clockwise by [steps] * 90 degrees.
  PieceEdges rotateClockwise([int steps = 1]) {
    final s = steps % 4;
    if (s == 0) return this;
    if (s == 1) {
      return PieceEdges(top: left, right: top, bottom: right, left: bottom);
    }
    if (s == 2) {
      return PieceEdges(top: bottom, right: left, bottom: top, left: right);
    }
    return PieceEdges(top: right, right: bottom, bottom: left, left: top);
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is PieceEdges &&
          runtimeType == other.runtimeType &&
          top == other.top &&
          right == other.right &&
          bottom == other.bottom &&
          left == other.left;

  @override
  int get hashCode => Object.hash(top, right, bottom, left);

  @override
  String toString() =>
      'PieceEdges(T:${top.name}, R:${right.name}, B:${bottom.name}, L:${left.name})';
}

/// Deterministic edge topology layout generated from rows, cols and random seed.
class EdgeLayout {
  EdgeLayout({
    required this.rows,
    required this.cols,
    required this.seed,
  })  : assert(rows >= 2, 'rows must be at least 2'),
        assert(cols >= 2, 'cols must be at least 2') {
    _generate();
  }

  final int rows;
  final int cols;
  final int seed;

  // _h[r][c] stores edge direction between row r and row r+1 at col c (+1 or -1)
  late final List<List<int>> _h;

  // _v[r][c] stores edge direction between col c and col c+1 at row r (+1 or -1)
  late final List<List<int>> _v;

  void _generate() {
    final rng = Random(seed);
    _h = List.generate(
      rows - 1,
      (_) => List.generate(cols, (_) => rng.nextBool() ? 1 : -1),
    );
    _v = List.generate(
      rows,
      (_) => List.generate(cols - 1, (_) => rng.nextBool() ? 1 : -1),
    );
  }

  /// Derives four edge types for a piece at row [r] and col [c].
  PieceEdges edgesFor(int r, int c) {
    assert(r >= 0 && r < rows, 'row out of bounds');
    assert(c >= 0 && c < cols, 'col out of bounds');

    final top = r == 0
        ? EdgeType.flat
        : (_h[r - 1][c] == 1 ? EdgeType.blank : EdgeType.tab);

    final bottom = r == rows - 1
        ? EdgeType.flat
        : (_h[r][c] == 1 ? EdgeType.tab : EdgeType.blank);

    final left = c == 0
        ? EdgeType.flat
        : (_v[r][c - 1] == 1 ? EdgeType.blank : EdgeType.tab);

    final right = c == cols - 1
        ? EdgeType.flat
        : (_v[r][c] == 1 ? EdgeType.tab : EdgeType.blank);

    return PieceEdges(top: top, right: right, bottom: bottom, left: left);
  }
}
