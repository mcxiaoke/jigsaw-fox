import 'package:flutter_test/flutter_test.dart';
import 'package:jigsawpuzzle/logic/puzzle_model.dart';

void main() {
  test('difficulty preset configuration', () {
    expect(PuzzleDifficulty.presets.first.pieceCount, 9);
    expect(PuzzleDifficulty.presets.last.pieceCount, 48);
  });
}
