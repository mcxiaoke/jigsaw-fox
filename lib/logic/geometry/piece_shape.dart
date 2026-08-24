import 'dart:math';
import 'dart:ui' show Offset, Path, Rect;

import 'edge_layout.dart';
import 'edge_type.dart';

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

  static const double standardTipRatio = 0.25;

  factory Overhang.fromEdges(PieceEdges edges, {double tip = standardTipRatio}) {
    return Overhang(
      top: edges.top.isTab ? tip : 0.0,
      right: edges.right.isTab ? tip : 0.0,
      bottom: edges.bottom.isTab ? tip : 0.0,
      left: edges.left.isTab ? tip : 0.0,
    );
  }

  @override
  String toString() =>
      'Overhang(L:$left, T:$top, R:$right, B:$bottom)';
}

/// Generates and caches the geometric bezier path, bounding box and texture rectangles
/// for an individual jigsaw puzzle piece.
class PieceShape {
  PieceShape({
    required this.edges,
    required this.width,
    required this.height,
    double tipRatio = Overhang.standardTipRatio,
  })  : overhang = Overhang.fromEdges(edges, tip: tipRatio),
        _tipRatio = tipRatio {
    path = _buildPath();
  }

  final PieceEdges edges;
  final double width;
  final double height;
  final Overhang overhang;
  final double _tipRatio;

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

  /// Builds a clockwise closed bezier path with origin (0, 0) at the base cell's top-left.
  Path _buildPath() {
    final p = Path();
    p.moveTo(0, 0);

    // Top edge: (0, 0) -> (width, 0), normal is (0, -1) pointing up (outward)
    _addEdge(
      p,
      start: const Offset(0, 0),
      end: Offset(width, 0),
      edgeType: edges.top,
      normal: const Offset(0, -1),
      tabDepth: height * _tipRatio,
    );

    // Right edge: (width, 0) -> (width, height), normal is (1, 0) pointing right (outward)
    _addEdge(
      p,
      start: Offset(width, 0),
      end: Offset(width, height),
      edgeType: edges.right,
      normal: const Offset(1, 0),
      tabDepth: width * _tipRatio,
    );

    // Bottom edge: (width, height) -> (0, height), normal is (0, 1) pointing down (outward)
    _addEdge(
      p,
      start: Offset(width, height),
      end: Offset(0, height),
      edgeType: edges.bottom,
      normal: const Offset(0, 1),
      tabDepth: height * _tipRatio,
    );

    // Left edge: (0, height) -> (0, 0), normal is (-1, 0) pointing left (outward)
    _addEdge(
      p,
      start: Offset(0, height),
      end: const Offset(0, 0),
      edgeType: edges.left,
      normal: const Offset(-1, 0),
      tabDepth: width * _tipRatio,
    );

    p.close();
    return p;
  }

  /// Appends a single edge segment from [start] to [end].
  /// [normal] is a unit normal vector pointing OUTWARD in clockwise order.
  static void _addEdge(
    Path path, {
    required Offset start,
    required Offset end,
    required EdgeType edgeType,
    required Offset normal,
    required double tabDepth,
  }) {
    if (edgeType.isFlat) {
      path.lineTo(end.dx, end.dy);
      return;
    }

    final tangent = end - start;
    final length = tangent.distance;
    if (length == 0) return;

    final u = tangent / length; // Unit tangent along edge
    final sign = edgeType.isTab ? 1.0 : -1.0;
    final n = normal * sign; // Directed outward normal vector
    final d = tabDepth;

    // Symmetrical, perfectly smooth circular interlocking jigsaw tab
    // 1. From start to left neck (p1)
    final p1 = start + u * (length * 0.36) - n * (d * 0.06);
    final cp1 = start + u * (length * 0.22);
    final cp2 = start + u * (length * 0.32) - n * (d * 0.04);
    path.cubicTo(cp1.dx, cp1.dy, cp2.dx, cp2.dy, p1.dx, p1.dy);

    // 2. From left neck (p1) out to bulb left cheek (p2)
    final p2 = start + u * (length * 0.44) + n * (d * 0.98);
    final cp3 = start + u * (length * 0.38) + n * (d * 0.35);
    final cp4 = start + u * (length * 0.39) + n * (d * 0.92);
    path.cubicTo(cp3.dx, cp3.dy, cp4.dx, cp4.dy, p2.dx, p2.dy);

    // 3. Bulb crown: from left cheek (p2) across apex to right cheek (p3)
    final p3 = start + u * (length * 0.56) + n * (d * 0.98);
    final cp5 = start + u * (length * 0.48) + n * (d * 1.04);
    final cp6 = start + u * (length * 0.52) + n * (d * 1.04);
    path.cubicTo(cp5.dx, cp5.dy, cp6.dx, cp6.dy, p3.dx, p3.dy);

    // 4. From right cheek (p3) down to right neck (p4)
    final p4 = start + u * (length * 0.64) - n * (d * 0.06);
    final cp7 = start + u * (length * 0.61) + n * (d * 0.92);
    final cp8 = start + u * (length * 0.62) + n * (d * 0.35);
    path.cubicTo(cp7.dx, cp7.dy, cp8.dx, cp8.dy, p4.dx, p4.dy);

    // 5. From right neck (p4) to end
    final cp9 = start + u * (length * 0.68) - n * (d * 0.04);
    final cp10 = start + u * (length * 0.78);
    path.cubicTo(cp9.dx, cp9.dy, cp10.dx, cp10.dy, end.dx, end.dy);
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
