import 'dart:math';

import 'edge_curve.dart';
import 'edge_type.dart';

/// Quad edges of a single puzzle piece with rich parameterized bezier curves.
class PieceEdges {
  const PieceEdges({
    required this.top,
    required this.right,
    required this.bottom,
    required this.left,
  });

  final EdgeCurveDescriptor top;
  final EdgeCurveDescriptor right;
  final EdgeCurveDescriptor bottom;
  final EdgeCurveDescriptor left;

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
      'PieceEdges(T:${top.edgeType.name}, R:${right.edgeType.name}, B:${bottom.edgeType.name}, L:${left.edgeType.name})';
}

/// Deterministic edge topology layout generated from rows, cols and random seed.
/// Generates continuous, smooth, interlocking quadratic bezier curves across the entire board.
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

  // _h[r][c] stores the horizontal edge descriptor between row r and row r+1 at col c
  // (from the perspective of the upper piece looking downward at bottom edge)
  late final List<List<EdgeCurveDescriptor>> _h;

  // _v[r][c] stores the vertical edge descriptor between col c and col c+1 at row r
  // (from the perspective of the left piece looking rightward at right edge)
  late final List<List<EdgeCurveDescriptor>> _v;

  void _generate() {
    final rng = Random(seed);

    // 1. Generate Horizontal Edges: (rows - 1) lines, each of cols segments
    _h = List.generate(rows - 1, (r) {
      final rowEdges = <EdgeCurveDescriptor>[];
      for (var c = 0; c < cols; c++) {
        final isTab = rng.nextBool();
        final shapeIndex = rng.nextInt(EdgeShapeType.values.length);
        final shapeType = EdgeShapeType.values[shapeIndex];
        final bend = rng.nextBool();

        rowEdges.add(
          EdgeCurveDescriptor(
            edgeType: isTab ? EdgeType.tab : EdgeType.blank,
            shapeType: shapeType,
            bend: bend,
          ),
        );
      }
      return rowEdges;
    });

    // 2. Generate Vertical Edges: (cols - 1) lines, each of rows segments
    _v = List.generate(rows, (r) => List<EdgeCurveDescriptor>.filled(cols - 1, EdgeCurveDescriptor.flat));

    for (var c = 0; c < cols - 1; c++) {
      for (var r = 0; r < rows; r++) {
        final isTab = rng.nextBool();
        final shapeIndex = rng.nextInt(EdgeShapeType.values.length);
        final shapeType = EdgeShapeType.values[shapeIndex];
        final bend = rng.nextBool();

        _v[r][c] = EdgeCurveDescriptor(
          edgeType: isTab ? EdgeType.tab : EdgeType.blank,
          shapeType: shapeType,
          bend: bend,
        );
      }
    }
  }

  /// Derives four edge curves for a piece at row [r] and col [c].
  PieceEdges edgesFor(int r, int c) {
    assert(r >= 0 && r < rows, 'row out of bounds');
    assert(c >= 0 && c < cols, 'col out of bounds');

    // Top edge: border if r == 0, else complementary of upper piece's bottom edge
    final top = r == 0 ? EdgeCurveDescriptor.flat : _h[r - 1][c].complementary();

    // Bottom edge: border if r == rows - 1, else direct _h[r][c]
    final bottom = r == rows - 1 ? EdgeCurveDescriptor.flat : _h[r][c];

    // Left edge: border if c == 0, else complementary of left piece's right edge
    final left = c == 0 ? EdgeCurveDescriptor.flat : _v[r][c - 1].complementary();

    // Right edge: border if c == cols - 1, else direct _v[r][c]
    final right = c == cols - 1 ? EdgeCurveDescriptor.flat : _v[r][c];

    return PieceEdges(top: top, right: right, bottom: bottom, left: left);
  }
}
