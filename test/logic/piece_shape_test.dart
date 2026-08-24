import 'package:flutter_test/flutter_test.dart';
import 'package:jigsawpuzzle/logic/geometry/edge_curve.dart';
import 'package:jigsawpuzzle/logic/geometry/edge_layout.dart';
import 'package:jigsawpuzzle/logic/geometry/edge_type.dart';
import 'package:jigsawpuzzle/logic/geometry/piece_shape.dart';

void main() {
  group('PieceShape & Overhang Geometry Tests', () {
    test('Overhang matches tab edges and blank safety margins', () {
      const edges = PieceEdges(
        top: EdgeCurveDescriptor(edgeType: EdgeType.tab),
        right: EdgeCurveDescriptor(edgeType: EdgeType.blank),
        bottom: EdgeCurveDescriptor(edgeType: EdgeType.flat),
        left: EdgeCurveDescriptor(edgeType: EdgeType.tab),
      );

      final shape = PieceShape(
        edges: edges,
        width: 100.0,
        height: 80.0,
        tipRatio: 0.25,
      );

      expect(shape.overhang.top, 0.25);
      expect(shape.overhang.left, 0.25);
      expect(shape.overhang.right, 0.15); // blank safety margin
      expect(shape.overhang.bottom, 0.0); // flat outer border
    });

    test('fillRect coordinates matches Overhang specification', () {
      const edges = PieceEdges(
        top: EdgeCurveDescriptor(edgeType: EdgeType.tab),
        right: EdgeCurveDescriptor(edgeType: EdgeType.tab),
        bottom: EdgeCurveDescriptor(edgeType: EdgeType.blank),
        left: EdgeCurveDescriptor(edgeType: EdgeType.flat),
      );

      final shape = PieceShape(
        edges: edges,
        width: 100.0,
        height: 100.0,
        tipRatio: 0.2,
      );

      final fillRect = shape.fillRect;
      expect(fillRect.left, -0.0); // left is flat
      expect(fillRect.top, -20.0); // top is tab -> -0.2 * 100
      expect(fillRect.width, 120.0); // 100 * (1 + 0 + 0.2)
      expect(fillRect.height, 135.0); // 100 * (1 + 0.2 + 0.15)
    });

    test('srcRect maps 1:1 proportionally with fillRect', () {
      const edges = PieceEdges(
        top: EdgeCurveDescriptor(edgeType: EdgeType.blank),
        right: EdgeCurveDescriptor(edgeType: EdgeType.tab),
        bottom: EdgeCurveDescriptor(edgeType: EdgeType.tab),
        left: EdgeCurveDescriptor(edgeType: EdgeType.flat),
      );

      final shape = PieceShape(
        edges: edges,
        width: 100.0,
        height: 80.0,
        tipRatio: 0.2,
      );

      final src = shape.srcRect(
        row: 2,
        col: 3,
        srcWidthPerCol: 200.0,
        srcHeightPerRow: 160.0,
      );

      // col = 3, overhang.left = 0.0 (flat) -> left = 3 * 200 = 600
      expect(src.left, 600.0);
      // row = 2, overhang.top = 0.15 (blank) -> top = (2 - 0.15) * 160 = 1.85 * 160 = 296
      expect(src.top, 296.0);
      // width = (1 + 0 + 0.2) * 200 = 1.2 * 200 = 240
      expect(src.width, 240.0);
      // height = (1 + 0.15 + 0.2) * 160 = 1.35 * 160 = 216
      expect(src.height, 216.0);
    });

    test('Hit testing contains interior points', () {
      const edges = PieceEdges(
        top: EdgeCurveDescriptor(edgeType: EdgeType.tab),
        right: EdgeCurveDescriptor(edgeType: EdgeType.tab),
        bottom: EdgeCurveDescriptor(edgeType: EdgeType.blank),
        left: EdgeCurveDescriptor(edgeType: EdgeType.flat),
      );

      final shape = PieceShape(
        edges: edges,
        width: 100.0,
        height: 100.0,
      );

      // Center of base cell should always be inside
      expect(shape.containsLocalPoint(const Offset(50, 50), 0), isTrue);

      // Far away point outside bounding box should be false
      expect(shape.containsLocalPoint(const Offset(500, 500), 0), isFalse);
    });

    test('Quadratic bezier path is built', () {
      const edges = PieceEdges(
        top: EdgeCurveDescriptor(edgeType: EdgeType.tab),
        right: EdgeCurveDescriptor(edgeType: EdgeType.tab),
        bottom: EdgeCurveDescriptor(edgeType: EdgeType.blank),
        left: EdgeCurveDescriptor(edgeType: EdgeType.flat),
      );

      final shape = PieceShape(
        edges: edges,
        width: 100.0,
        height: 100.0,
      );

      expect(shape.path, isNotNull);
    });
  });
}
