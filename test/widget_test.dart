import 'package:flutter_test/flutter_test.dart';
import 'package:jigsawpuzzle/logic/puzzle_model.dart';

void main() {
  test('difficulty piece count', () {
    expect(PuzzleDifficulty.values[0].pieceCount, 9);
    expect(PuzzleDifficulty.values.last.pieceCount, 36);
  });
}
