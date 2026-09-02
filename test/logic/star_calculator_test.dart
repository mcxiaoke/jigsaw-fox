import 'package:flutter_test/flutter_test.dart';
import 'package:jigsawpuzzle/logic/puzzle_model.dart';
import 'package:jigsawpuzzle/logic/star_calculator.dart';

void main() {
  group('StarCalculator Unit Tests', () {
    test('hintAllowance scales with piece count and clamps within [2, 6]', () {
      expect(StarCalculator.hintAllowance(24), equals(2));
      expect(StarCalculator.hintAllowance(25), equals(2));
      expect(StarCalculator.hintAllowance(36), equals(2));
      expect(StarCalculator.hintAllowance(54), equals(2));
      expect(StarCalculator.hintAllowance(64), equals(2));
      expect(StarCalculator.hintAllowance(96), equals(2));
      expect(StarCalculator.hintAllowance(100), equals(2));
      expect(StarCalculator.hintAllowance(144), equals(3));
      expect(StarCalculator.hintAllowance(150), equals(3));
      expect(StarCalculator.hintAllowance(216), equals(5));
      expect(StarCalculator.hintAllowance(225), equals(5));
      expect(StarCalculator.hintAllowance(384), equals(6));
      expect(StarCalculator.hintAllowance(400), equals(6));
      expect(StarCalculator.hintAllowance(1000), equals(6)); // Clamped to 6
    });

    test('L1 25-piece star ratings with exact thresholds', () {
      const pieces = 25;
      const secPerPiece = 3.0; // Base = 75s, 70% = 52.5s (52500ms)

      // 3 stars: Time <= 70% Base, 0 hints
      expect(
        StarCalculator.calcStars(
          actualPieces: pieces,
          secPerPiece: secPerPiece,
          hints: 0,
          seconds: 52, // 52000ms <= 52500ms -> Time 3
        ),
        equals(3),
      );

      // 2 stars: Time > 70% Base, <= 100% Base, 0 hints
      expect(
        StarCalculator.calcStars(
          actualPieces: pieces,
          secPerPiece: secPerPiece,
          hints: 0,
          seconds: 53, // 53000ms > 52500ms -> Time 2
        ),
        equals(2),
      );

      // 2 stars: Exactly at Base 75s
      expect(
        StarCalculator.calcStars(
          actualPieces: pieces,
          secPerPiece: secPerPiece,
          hints: 0,
          seconds: 75,
        ),
        equals(2),
      );

      // 1 star: Exceeds Base seconds
      expect(
        StarCalculator.calcStars(
          actualPieces: pieces,
          secPerPiece: secPerPiece,
          hints: 0,
          seconds: 76,
        ),
        equals(1),
      );

      // 2 stars: Fast (Time 3) but used 1 hint (Hint 2, within allowance 2)
      expect(
        StarCalculator.calcStars(
          actualPieces: pieces,
          secPerPiece: secPerPiece,
          hints: 1,
          seconds: 40,
        ),
        equals(2),
      );

      // 2 stars: Fast (Time 3) and used 2 hints (Hint 2, exact allowance)
      expect(
        StarCalculator.calcStars(
          actualPieces: pieces,
          secPerPiece: secPerPiece,
          hints: 2,
          seconds: 40,
        ),
        equals(2),
      );

      // 1 star: Fast (Time 3) but exceeded hint allowance (3 hints -> Hint 1)
      expect(
        StarCalculator.calcStars(
          actualPieces: pieces,
          secPerPiece: secPerPiece,
          hints: 3,
          seconds: 40,
        ),
        equals(1),
      );

      // 1 star baseline guarantee (never 0)
      expect(
        StarCalculator.calcStars(
          actualPieces: pieces,
          secPerPiece: secPerPiece,
          hints: 99,
          seconds: 9999,
        ),
        equals(1),
      );
    });

    test('L6 400-piece star ratings with clamped allowance', () {
      const pieces = 400;
      const secPerPiece = 25.0; // Base = 10000s, 70% = 7000s

      // 3 stars: 0 hints, <= 7000s
      expect(
        StarCalculator.calcStars(
          actualPieces: pieces,
          secPerPiece: secPerPiece,
          hints: 0,
          seconds: 7000,
        ),
        equals(3),
      );

      // 2 stars: 0 hints, 7001s
      expect(
        StarCalculator.calcStars(
          actualPieces: pieces,
          secPerPiece: secPerPiece,
          hints: 0,
          seconds: 7001,
        ),
        equals(2),
      );

      // 2 stars: 6 hints (allowance = 6), fast time
      expect(
        StarCalculator.calcStars(
          actualPieces: pieces,
          secPerPiece: secPerPiece,
          hints: 6,
          seconds: 5000,
        ),
        equals(2),
      );

      // 1 star: 7 hints (exceeds allowance = 6)
      expect(
        StarCalculator.calcStars(
          actualPieces: pieces,
          secPerPiece: secPerPiece,
          hints: 7,
          seconds: 5000,
        ),
        equals(1),
      );
    });

    test('PuzzleDifficulty provides correct secPerPiece and tierLevel', () {
      for (final diff in PuzzleDifficulty.presets) {
        expect(diff.secPerPiece, greaterThan(0.0));
        expect(diff.tierLevel.startsWith('L'), isTrue);
      }
    });

    test('PuzzleAspectRatio crop loss formula and aspect detection', () {
      // 1:1 image to 1:1 ratio -> loss 0
      expect(PuzzleAspectRatio.cropLoss(1.0, 1.0), closeTo(0.0, 0.001));

      // 4:3 (1.333) to 3:2 (1.5) -> loss = 1 - 1.3333/1.5 = 11.1%
      expect(PuzzleAspectRatio.cropLoss(4 / 3, 3 / 2), closeTo(0.111, 0.005));

      // 3:4 (0.75) to 2:3 (0.667) -> loss = 1 - 0.6667/0.75 = 11.1%
      expect(PuzzleAspectRatio.cropLoss(3 / 4, 2 / 3), closeTo(0.111, 0.005));

      // fromSize test: 4:3 image chooses 3:2 (11.1% loss) over 1:1 (25% loss)
      expect(
        PuzzleAspectRatio.fromSize(4032, 3024),
        equals(PuzzleAspectRatio.landscape3x2),
      );
      // 3:4 vertical image chooses 2:3 (11.1% loss)
      expect(
        PuzzleAspectRatio.fromSize(3024, 4032),
        equals(PuzzleAspectRatio.portrait2x3),
      );
      // 1:1 image chooses 1:1
      expect(
        PuzzleAspectRatio.fromSize(1000, 1000),
        equals(PuzzleAspectRatio.square1x1),
      );
    });
  });
}
