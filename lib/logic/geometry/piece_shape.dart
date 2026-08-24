import 'dart:math';
import 'dart:ui' show Offset, Path, Rect;

import 'edge_layout.dart';

/// Represents edge overhang ratios for 4 sides of a puzzle piece.
class Overhang {
  const Overhang({
    this.left = 0.0,
    this.top = 0.0,
    this.right = 0.0,
    this.bottom = 0.0,
  });

  final double left;
  final double top;
  final double right;
  final double bottom;

  static const double standardTabRatio = 0.35;
  static const double standardBlankRatio = 0.15;

  factory Overhang.fromEdges(PieceEdges edges, {double? tip}) {
    double ratioFor(dynamic edge) {
      if (edge.isFlat) return 0.0;
      if (edge.isTab) return tip ?? standardTabRatio;
      return standardBlankRatio;
    }

    return Overhang(
      top: ratioFor(edges.top),
      right: ratioFor(edges.right),
      bottom: ratioFor(edges.bottom),
      left: ratioFor(edges.left),
    );
  }

  @override
  String toString() =>
      'Overhang(L:${left.toStringAsFixed(2)}, T:${top.toStringAsFixed(2)}, R:${right.toStringAsFixed(2)}, B:${bottom.toStringAsFixed(2)})';
}

/// Generates and caches the geometric quadratic bezier path, bounding box, and texture rectangles for an individual jigsaw piece.
class PieceShape {
  PieceShape({
    required this.edges,
    required this.width,
    required this.height,
    double? tipRatio,
  }) : overhang = Overhang.fromEdges(edges, tip: tipRatio) {
    path = _buildPath();
  }

  final PieceEdges edges;
  final double width;
  final double height;
  final Overhang overhang;

  late final Path path;

  /// Bounding rectangle in the piece local coordinate system (origin at base cell top-left).
  Rect get fillRect => Rect.fromLTWH(
        -overhang.left * width,
        -overhang.top * height,
        (1.0 + overhang.left + overhang.right) * width,
        (1.0 + overhang.top + overhang.bottom) * height,
      );

  /// Source sampling rectangle from the original image (in pixel coordinates).
  Rect srcRect({
    required int row,
    required int col,
    required double srcWidthPerCol,
    required double srcHeightPerRow,
  }) {
    return Rect.fromLTWH(
      (col - overhang.left) * srcWidthPerCol,
      (row - overhang.top) * srcHeightPerRow,
      (1.0 + overhang.left + overhang.right) * srcWidthPerCol,
      (1.0 + overhang.top + overhang.bottom) * srcHeightPerRow,
    );
  }

  /// Builds a clockwise closed quadratic bezier path with origin (0, 0) at the base cell's top-left.
  Path _buildPath() {
    final p = Path();
    p.moveTo(0, 0);

    // 1. Top edge: (0, 0) -> (width, 0), normal is (0, -1) pointing up (outward)
    edges.top.appendToPath(
      p,
      start: const Offset(0, 0),
      end: Offset(width, 0),
      normal: const Offset(0, -1),
      reverse: false,
    );

    // 2. Right edge: (width, 0) -> (width, height), normal is (1, 0) pointing right (outward)
    edges.right.appendToPath(
      p,
      start: Offset(width, 0),
      end: Offset(width, height),
      normal: const Offset(1, 0),
      reverse: false,
    );

    // 3. Bottom edge: canonical is (0, height) -> (width, height), normal is (0, 1) down.
    // Trace backward from (width, height) to (0, height).
    edges.bottom.appendToPath(
      p,
      start: Offset(0, height),
      end: Offset(width, height),
      normal: const Offset(0, 1),
      reverse: true,
    );

    // 4. Left edge: canonical is (0, 0) -> (0, height), normal is (-1, 0) left.
    // Trace backward from (0, height) to (0, 0).
    edges.left.appendToPath(
      p,
      start: const Offset(0, 0),
      end: Offset(0, height),
      normal: const Offset(-1, 0),
      reverse: true,
    );

    p.close();
    return p;
  }

  /// Performs inverse hit test on the shape under rotation [rot] (0, 1, 2, 3).
  bool containsLocalPoint(Offset localPoint, int rot) {
    if (rot % 4 == 0) {
      return path.contains(localPoint);
    }
    // Rotate local point backwards around base cell center (width/2, height/2)
    final cx = width / 2.0;
    final cy = height / 2.0;
    final dx = localPoint.dx - cx;
    final dy = localPoint.dy - cy;

    final angle = -(rot % 4) * (pi / 2.0);
    final cosA = cos(angle);
    final sinA = sin(angle);

    final origX = cx + dx * cosA - dy * sinA;
    final origY = cy + dx * sinA + dy * cosA;

    return path.contains(Offset(origX, origY));
  }
}
