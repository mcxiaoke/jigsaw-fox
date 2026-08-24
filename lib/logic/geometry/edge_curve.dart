import 'dart:math';
import 'dart:ui' show Offset, Path;

import 'edge_type.dart';

/// 4 Classic preset tab shapes identical to Jigsaw Explorer.
enum EdgeShapeType {
  /// Symmetrical, smooth round ball tab (classic standard).
  ball,

  /// Sturdy, wider and shorter tab.
  stub,

  /// Playful skewed sock-shaped tab with asymmetric head.
  sock,

  /// Slender finger-shaped tab with gentle slope.
  finger,
}

/// A 2D point in normalized edge coordinate space:
/// `along`: [0, 1] along the edge from start (0.0) to end (1.0).
/// `from`: perpendicular offset (+outward tab, -inward blank).
class CurvePoint {
  const CurvePoint(this.along, this.from);
  final double along;
  final double from;
}

/// Jigsaw Explorer 12-point quadratic bezier shape matrices (6 quadratic segments each).
class JigexCurves {
  static const List<CurvePoint> ball = [
    CurvePoint(0.0643939393939394, -0.00378787878787879),
    CurvePoint(0.162878787878788, -0.0265151515151515),
    CurvePoint(0.534090909090909, -0.0984848484848485),
    CurvePoint(0.431818181818182, 0.0568181818181818),
    CurvePoint(0.265151515151515, 0.287878787878788),
    CurvePoint(0.500000000000000, 0.295454545454545),
    CurvePoint(0.715909090909091, 0.287878787878788),
    CurvePoint(0.575757575757576, 0.0568181818181818),
    CurvePoint(0.515151515151515, -0.0795454545454545),
    CurvePoint(0.761363636363636, -0.0189393939393939),
    CurvePoint(0.905303030303030, 0.0113636363636364),
    CurvePoint(1.000000000000000, 0.0000000000000000),
  ];

  static const List<CurvePoint> stub = [
    CurvePoint(0.0946969696969697, 0.00757575757575758),
    CurvePoint(0.219696969696970, -0.0492424242424242),
    CurvePoint(0.397727272727101, -0.117424242424242),
    CurvePoint(0.378787878787097, 0.0189393939393114),
    CurvePoint(0.363636363636116, 0.234848484848119),
    CurvePoint(0.617424242424111, 0.151515151515102),
    CurvePoint(0.708333333333032, 0.109848484848083),
    CurvePoint(0.617424242424097, -0.01515151515151),
    CurvePoint(0.518939393939082, -0.181818181818111),
    CurvePoint(0.837121212121097, -0.0303030303030032),
    CurvePoint(0.909090909090105, 0.0037878787878711),
    CurvePoint(1.000000000000000, 0.0000000000000000),
  ];

  static const List<CurvePoint> sock = [
    CurvePoint(0.0946969696969697, 0.0113636363636364),
    CurvePoint(0.227272727272727, -0.0303030303030303),
    CurvePoint(0.537878787878788, -0.117424242424242),
    CurvePoint(0.382575757575758, 0.132575757575758),
    CurvePoint(0.284090909090909, 0.344696969696970),
    CurvePoint(0.541666666666667, 0.268939393939394),
    CurvePoint(0.681818181818182, 0.208333333333333),
    CurvePoint(0.575757575757576, 0.0568181818181818),
    CurvePoint(0.515151515151515, -0.0795454545454545),
    CurvePoint(0.761363636363636, -0.0189393939393939),
    CurvePoint(0.905303030303030, 0.0113636363636364),
    CurvePoint(1.000000000000000, 0.0000000000000000),
  ];

  static const List<CurvePoint> finger = [
    CurvePoint(0.0492424242424242, 0.0000000000000000),
    CurvePoint(0.159090909090909, -0.0227272727272727),
    CurvePoint(0.545454545454545, -0.0681818181818182),
    CurvePoint(0.412878787878788, 0.1250000000000000),
    CurvePoint(0.253787878787879, 0.344696969696970),
    CurvePoint(0.473484848484849, 0.272727272727273),
    CurvePoint(0.553030303030303, 0.238636363636364),
    CurvePoint(0.549242424242424, 0.121212121212121),
    CurvePoint(0.500000000000000, -0.109848484848485),
    CurvePoint(0.761363636363636, -0.0189393939393939),
    CurvePoint(0.905303030303030, 0.0113636363636364),
    CurvePoint(1.000000000000000, 0.0000000000000000),
  ];

  static List<CurvePoint> getPoints(EdgeShapeType shape) {
    switch (shape) {
      case EdgeShapeType.ball:
        return ball;
      case EdgeShapeType.stub:
        return stub;
      case EdgeShapeType.sock:
        return sock;
      case EdgeShapeType.finger:
        return finger;
    }
  }
}

/// Mathematical descriptor for a smooth jigsaw edge curve based on Jigsaw Explorer curves.
class EdgeCurveDescriptor {
  const EdgeCurveDescriptor({
    required this.edgeType,
    this.shapeType = EdgeShapeType.ball,
    this.bend = true,
    this.depthScale = 0.95,
  });

  final EdgeType edgeType;
  final EdgeShapeType shapeType;
  final bool bend;
  final double depthScale;

  static const EdgeCurveDescriptor flat = EdgeCurveDescriptor(
    edgeType: EdgeType.flat,
  );

  bool get isFlat => edgeType == EdgeType.flat;
  bool get isTab => edgeType == EdgeType.tab;
  bool get isBlank => edgeType == EdgeType.blank;

  /// Creates a complementary descriptor for the adjacent piece sharing this edge.
  EdgeCurveDescriptor complementary() {
    if (isFlat) return flat;
    return EdgeCurveDescriptor(
      edgeType: isTab ? EdgeType.blank : EdgeType.tab,
      shapeType: shapeType,
      bend: bend, // Note: Shared physical edge has identical bend in space
      depthScale: depthScale,
    );
  }

  /// Appends this smooth curve defined in canonical edge direction (from [start] to [end]) onto [path].
  /// [normal] is the directed outward unit normal vector.
  /// If [reverse] is true, traces the curve backwards from [end] back to [start].
  void appendToPath(
    Path path, {
    required Offset start,
    required Offset end,
    required Offset normal,
    bool reverse = false,
  }) {
    if (isFlat) {
      if (reverse) {
        path.lineTo(start.dx, start.dy);
      } else {
        path.lineTo(end.dx, end.dy);
      }
      return;
    }

    final tangent = end - start;
    final length = tangent.distance;
    if (length <= 0) return;

    final u = tangent / length; // Unit tangent along canonical direction
    final sign = isTab ? 1.0 : -1.0;
    final directedNormal = normal * sign;

    final rawPts = JigexCurves.getPoints(shapeType);

    // Compute 6 segments: each with a control point and an anchor point
    final controls = <Offset>[];
    final anchors = <Offset>[];

    if (bend) {
      // Normal forward order: (0.0 -> 1.0)
      for (var s = 0; s < 6; s++) {
        final ctrlPt = rawPts[s * 2];
        final anchorPt = rawPts[s * 2 + 1];

        final cp = start +
            u * (ctrlPt.along * length) +
            directedNormal * (ctrlPt.from * length * depthScale);
        final p = start +
            u * (anchorPt.along * length) +
            directedNormal * (anchorPt.from * length * depthScale);

        controls.add(cp);
        anchors.add(p);
      }
    } else {
      // Symmetrical horizontal mirror across along=0.5: still going from 0.0 to 1.0
      // Segment 0: ctrl = 1 - P10, anchor = 1 - P9
      // Segment 1: ctrl = 1 - P8,  anchor = 1 - P7
      // Segment 2: ctrl = 1 - P6,  anchor = 1 - P5
      // Segment 3: ctrl = 1 - P4,  anchor = 1 - P3
      // Segment 4: ctrl = 1 - P2,  anchor = 1 - P1
      // Segment 5: ctrl = 1 - P0,  anchor = (1.0, 0.0)
      for (var s = 0; s < 6; s++) {
        final rawCtrlIdx = 10 - s * 2;
        final ctrlPt = rawPts[rawCtrlIdx];
        final cpAlong = 1.0 - ctrlPt.along;

        final anchorAlong = (s == 5) ? 1.0 : 1.0 - rawPts[8 - s * 2 + 1].along;
        final anchorFrom = (s == 5) ? 0.0 : rawPts[8 - s * 2 + 1].from;

        final cp = start +
            u * (cpAlong * length) +
            directedNormal * (ctrlPt.from * length * depthScale);
        final p = start +
            u * (anchorAlong * length) +
            directedNormal * (anchorFrom * length * depthScale);

        controls.add(cp);
        anchors.add(p);
      }
    }

    if (!reverse) {
      // Forward: start -> A0 -> A1 -> A2 -> A3 -> A4 -> A5 (end)
      for (var s = 0; s < 6; s++) {
        path.quadraticBezierTo(
          controls[s].dx,
          controls[s].dy,
          anchors[s].dx,
          anchors[s].dy,
        );
      }
    } else {
      // Backward: from end (A5) -> A4 -> A3 -> A2 -> A1 -> A0 -> start
      for (var s = 5; s >= 0; s--) {
        final target = (s == 0) ? start : anchors[s - 1];
        path.quadraticBezierTo(
          controls[s].dx,
          controls[s].dy,
          target.dx,
          target.dy,
        );
      }
    }
  }

  /// Calculates max outward protrusion ratio in [0, 1].
  double get maxOverhangRatio {
    if (isFlat || isBlank) return 0.0;
    return max(0.22, 0.35 * depthScale);
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is EdgeCurveDescriptor &&
          runtimeType == other.runtimeType &&
          edgeType == other.edgeType &&
          shapeType == other.shapeType &&
          bend == other.bend &&
          depthScale == other.depthScale;

  @override
  int get hashCode => Object.hash(edgeType, shapeType, bend, depthScale);
}
