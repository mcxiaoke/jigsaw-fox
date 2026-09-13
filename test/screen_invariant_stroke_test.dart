import 'package:flutter_test/flutter_test.dart';
import 'package:jigsawpuzzle/game/puzzle_piece_component.dart';

/// 屏幕恒定逆缩放契约测试。
///
/// 【背景】碎片组件渲染在未缩放的局部坐标系中，Flame 在调用 `render` 前会施加
/// `canvas.scale(scale.x, scale.y)`。因此局部线宽映射到屏幕的可见宽度为
/// `localWidth × scale`。为避免高倍放大后线条被成倍放大，渲染改用
/// `localWidth = screenValue / max(scale, 1.0)` 做逆缩放。
///
/// 本测试固化 [PuzzlePieceComponent.screenInvariantValue] 的两条契约：
///   1. `scale > 1`  时 `local × scale == screenValue`（屏幕宽度恒定）；
///   2. `scale <= 1` 时 `local == screenValue`（低倍场景退化为原行为，改动面收敛到放大方向）。
void main() {
  group('screenInvariantValue 屏幕恒定契约', () {
    test('scale > 1 时屏幕宽度恒等于目标值', () {
      const baselines = <double>[1.2, 0.8, 2.5];
      const scales = <double>[1.5, 2.0, 2.4, 2.88, 3.6, 5.0];

      for (final baseline in baselines) {
        for (final s in scales) {
          final local = PuzzlePieceComponent.screenInvariantValue(baseline, s);
          expect(
            local * s,
            closeTo(baseline, 1e-9),
            reason: 'baseline=$baseline scale=$s 时屏幕宽度应恒为 $baseline',
          );
        }
      }
    });

    test('scale <= 1 时局部值等于目标值（不改动低倍行为）', () {
      const baselines = <double>[1.2, 0.8, 2.5];
      const scales = <double>[0.16, 0.21, 0.43, 0.8, 1.0];

      for (final baseline in baselines) {
        for (final s in scales) {
          final local = PuzzlePieceComponent.screenInvariantValue(baseline, s);
          expect(
            local,
            closeTo(baseline, 1e-9),
            reason: 'baseline=$baseline scale=$s 时局部值应等于基线',
          );
        }
      }
    });

    test('scale == 1.0 是两条契约的连续交界（无跳变）', () {
      const baseline = 1.2;
      final justBelow = PuzzlePieceComponent.screenInvariantValue(
        baseline,
        0.9999,
      );
      final at = PuzzlePieceComponent.screenInvariantValue(baseline, 1.0);
      final justAbove = PuzzlePieceComponent.screenInvariantValue(
        baseline,
        1.0001,
      );

      expect(justBelow, closeTo(at, 1e-3));
      expect(at, closeTo(justAbove, 1e-3));
    });

    test('极端缩小不会造成局部线宽暴增（回归 gm 2.1 风险）', () {
      // 托盘态 _trayPieceScale 可低至 0.16（2x2 且棋盘较宽时）
      const local = 0.8;
      expect(
        PuzzlePieceComponent.screenInvariantValue(local, 0.16),
        local,
        reason: '缩小场景必须退化为原值，绝不能放大到 1/0.16 = 6.25 倍',
      );
    });

    test('非法 scale（0 或负数）退化为基线，不产生除零', () {
      for (final bad in <double>[0.0, -1.0, -0.5]) {
        expect(
          PuzzlePieceComponent.screenInvariantValue(1.2, bad),
          1.2,
          reason: 'scale=$bad 应截顶到 1.0，避免除零或负线宽',
        );
      }
    });
  });
}
