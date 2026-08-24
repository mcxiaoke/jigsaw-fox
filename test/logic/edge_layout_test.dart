import 'package:flutter_test/flutter_test.dart';
import 'package:jigsawpuzzle/logic/geometry/edge_curve.dart';
import 'package:jigsawpuzzle/logic/geometry/edge_layout.dart';
import 'package:jigsawpuzzle/logic/geometry/edge_type.dart';

void main() {
  group('EdgeLayout & PieceEdges Tests', () {
    test('Deterministic topology given the same seed', () {
      final layout1 = EdgeLayout(rows: 4, cols: 5, seed: 42);
      final layout2 = EdgeLayout(rows: 4, cols: 5, seed: 42);

      for (var r = 0; r < 4; r++) {
        for (var c = 0; c < 5; c++) {
          expect(layout1.edgesFor(r, c), equals(layout2.edgesFor(r, c)));
        }
      }
    });

    test('Outer borders are always flat', () {
      final layout = EdgeLayout(rows: 3, cols: 4, seed: 12345);

      for (var c = 0; c < 4; c++) {
        expect(layout.edgesFor(0, c).top.isFlat, isTrue);
        expect(layout.edgesFor(2, c).bottom.isFlat, isTrue);
      }

      for (var r = 0; r < 3; r++) {
        expect(layout.edgesFor(r, 0).left.isFlat, isTrue);
        expect(layout.edgesFor(r, 3).right.isFlat, isTrue);
      }
    });

    test('Adjacent internal edges are always complementary mirrors (tab <-> blank)', () {
      final layout = EdgeLayout(rows: 5, cols: 6, seed: 999);

      for (var r = 0; r < 5; r++) {
        for (var c = 0; c < 6; c++) {
          final current = layout.edgesFor(r, c);

          // Check right neighbor
          if (c + 1 < 6) {
            final rightNeighbor = layout.edgesFor(r, c + 1);
            expect(current.right.complementary(), equals(rightNeighbor.left),
                reason: 'Mismatch between piece ($r, $c) right and ($r, ${c + 1}) left');
          }

          // Check bottom neighbor
          if (r + 1 < 5) {
            final bottomNeighbor = layout.edgesFor(r + 1, c);
            expect(current.bottom.complementary(), equals(bottomNeighbor.top),
                reason: 'Mismatch between piece ($r, $c) bottom and (${r + 1}, $c) top');
          }
        }
      }
    });

    test('Corner and Border piece identification', () {
      final layout = EdgeLayout(rows: 3, cols: 3, seed: 101);

      // (0,0), (0,2), (2,0), (2,2) are corners
      expect(layout.edgesFor(0, 0).isCorner, isTrue);
      expect(layout.edgesFor(0, 2).isCorner, isTrue);
      expect(layout.edgesFor(2, 0).isCorner, isTrue);
      expect(layout.edgesFor(2, 2).isCorner, isTrue);

      // (1,1) is center piece (no flat edges)
      final center = layout.edgesFor(1, 1);
      expect(center.isBorder, isFalse);
      expect(center.isCorner, isFalse);
    });

    test('PieceEdges clockwise rotation', () {
      const edges = PieceEdges(
        top: EdgeCurveDescriptor(edgeType: EdgeType.flat),
        right: EdgeCurveDescriptor(edgeType: EdgeType.tab),
        bottom: EdgeCurveDescriptor(edgeType: EdgeType.blank),
        left: EdgeCurveDescriptor(edgeType: EdgeType.tab),
      );

      final rot1 = edges.rotateClockwise(1);
      expect(rot1.top.edgeType, EdgeType.tab); // Old left
      expect(rot1.right.edgeType, EdgeType.flat); // Old top
      expect(rot1.bottom.edgeType, EdgeType.tab); // Old right
      expect(rot1.left.edgeType, EdgeType.blank); // Old bottom

      final rot4 = edges.rotateClockwise(4);
      expect(rot4, equals(edges));
    });
  });
}
