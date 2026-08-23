import 'package:flutter_test/flutter_test.dart';
import 'package:jigsawpuzzle/logic/geometry/edge_layout.dart';
import 'package:jigsawpuzzle/logic/geometry/edge_type.dart';
import 'package:jigsawpuzzle/logic/geometry/piece_shape.dart';

void main() {
  group('PieceShape & Overhang Geometry Tests', () {
    test('Overhang matches tab edges only', () {
      const edges = PieceEdges(
        top: EdgeType.tab,
        right: EdgeType.blank,
        bottom: EdgeType.flat,
        left: EdgeType.tab,
      );

      final shape = PieceShape(
        edges: edges,
        width: 100.0,
        height: 80.0,
        tipRatio: 0.25,
      );

      expect(shape.overhang.top, 0.25);
      expect(shape.overhang.left, 0.25);
      expect(shape.overhang.right, 0.0);
      expect(shape.overhang.bottom, 0.0);
    });

    test('fillRect coordinates matches Overhang specification', () {
      const edges = PieceEdges(
        top: EdgeType.tab,
        right: EdgeType.tab,
        bottom: EdgeType.blank,
        left: EdgeType.flat,
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
      expect(fillRect.width, 120.0); // 100 + 0 + 20
      expect(fillRect.height, 120.0); // 100 + 20 + 0
    });

    test('srcRect maps 1:1 proportionally with fillRect', () {
      const edges = PieceEdges(
        top: EdgeType.blank,
        right: EdgeType.tab,
        bottom: EdgeType.tab,
        left: EdgeType.tab,
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

      // col = 3, overhang.left = 0.2 -> left = (3 - 0.2) * 200 = 2.8 * 200 = 560
      expect(src.left, 560.0);
      // row = 2, overhang.top = 0.0 (blank) -> top = 2 * 160 = 320
      expect(src.top, 320.0);
      // width = (1 + 0.2 + 0.2) * 200 = 1.4 * 200 = 280
      expect(src.width, 280.0);
      // height = (1 + 0 + 0.2) * 160 = 1.2 * 160 = 192
      expect(src.height, 192.0);
    });

    test('Hit testing contains interior points', () {
      const edges = PieceEdges(
        top: EdgeType.tab,
        right: EdgeType.tab,
        bottom: EdgeType.blank,
        left: EdgeType.flat,
      );

      final shape = PieceShape(
        edges: edges,
        width: 100.0,
        height: 100.0,
      );

      // Center of base cell should always be inside
      expect(shape.containsLocalPoint(const Offset(50, 50), 0), isTrue);

      // Far away point outside bounding box should be false
      expect(shape.containsLocalPoint(const Offset(-100, -100), 0), isFalse);
    });
  });
}
