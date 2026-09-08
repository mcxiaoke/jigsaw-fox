import 'package:flutter_test/flutter_test.dart';
import 'package:jigsawpuzzle/data/models/custom_puzzle_item.dart';
import 'package:jigsawpuzzle/logic/puzzle_model.dart';

void main() {
  group('CustomPuzzleItem Title & Sanitization Tests', () {
    test('Default constructor sets title to empty string', () {
      const item = CustomPuzzleItem(
        id: 'ugc_test',
        imagePathOrUrl: '/path/to/img.png',
        isLocalFile: true,
        difficulty: PuzzleDifficulty(label: '4 × 4', rows: 4, cols: 4),
      );
      expect(item.title, isEmpty);
    });

    test('isFakeTitle detects generated fake titles', () {
      expect(CustomPuzzleItem.isFakeTitle('我的自制拼图'), isTrue);
      expect(CustomPuzzleItem.isFakeTitle('自制拼图'), isTrue);
      expect(CustomPuzzleItem.isFakeTitle('巴黎埃菲尔铁塔晨曦'), isTrue);
      expect(CustomPuzzleItem.isFakeTitle('午后阳光与香浓拿铁'), isTrue);
      expect(CustomPuzzleItem.isFakeTitle('草地上奔跑的小柴犬'), isTrue);
      expect(CustomPuzzleItem.isFakeTitle(''), isTrue);
      expect(CustomPuzzleItem.isFakeTitle('   '), isTrue);
      expect(CustomPuzzleItem.isFakeTitle(null), isTrue);

      expect(CustomPuzzleItem.isFakeTitle('真实风景照'), isFalse);
    });

    test('fromJson sanitizes legacy fake titles into empty string', () {
      final jsonWithFake = {
        'id': 'ugc_123',
        'title': '我的自制拼图',
        'imagePathOrUrl': 'assets/bg/sample.png',
        'isLocalFile': false,
        'rows': 4,
        'cols': 4,
      };

      final item = CustomPuzzleItem.fromJson(jsonWithFake);
      expect(item.title, isEmpty);
    });

    test('fromJson preserves non-fake custom titles if any', () {
      final jsonCustom = {
        'id': 'ugc_456',
        'title': '家庭合影',
        'imagePathOrUrl': 'assets/bg/family.png',
        'isLocalFile': false,
        'rows': 4,
        'cols': 4,
      };

      final item = CustomPuzzleItem.fromJson(jsonCustom);
      expect(item.title, equals('家庭合影'));
    });
  });
}
