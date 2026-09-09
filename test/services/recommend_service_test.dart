import 'package:flutter_test/flutter_test.dart';
import 'package:jigsawpuzzle/logic/puzzle_model.dart';
import 'package:jigsawpuzzle/services/recommend_service.dart';

void main() {
  group('RecommendRule.computeRecommendedTierIndex', () {
    List<int> zeroed() => List<int>.filled(RecommendRule.tierLevels.length, 0);

    test('无任何完成记录 → 默认推荐 2 档（L2，起点）', () {
      expect(RecommendRule.computeRecommendedTierIndex(zeroed()), 2);
    });

    test('L2 完成 4 张未达阈值 → 仍推荐 2 档', () {
      final done = zeroed()..[2] = 4;
      expect(RecommendRule.computeRecommendedTierIndex(done), 2);
    });

    test('L2 完成 5 张 → 推荐升 3 档', () {
      final done = zeroed()..[2] = 5;
      expect(RecommendRule.computeRecommendedTierIndex(done), 3);
    });

    test('L2 达标且 L3 完成 9 张未达标 → 推荐 3 档', () {
      final done = zeroed()
        ..[2] = 5
        ..[3] = 9;
      expect(RecommendRule.computeRecommendedTierIndex(done), 3);
    });

    test('L3 完成 10 张（即使 L2 未达标）→ 推荐 4 档，只上推不下降', () {
      final done = zeroed()..[3] = 10;
      expect(RecommendRule.computeRecommendedTierIndex(done), 4);
    });

    test('跨档累计：L2=0、L3=5、L4=6 → L3 及以上累计 11 → 推荐 4 档', () {
      // 熟练用户一开始就玩高难，不会因“没刷低档”被卡在默认档
      final done = zeroed()
        ..[3] = 5
        ..[4] = 6;
      expect(RecommendRule.computeRecommendedTierIndex(done), 4);
    });

    test('L4 及以上累计 10 张 → 推荐 5 档（跳级玩家按实力上探）', () {
      final done = zeroed()..[4] = 10;
      expect(RecommendRule.computeRecommendedTierIndex(done), 5);
    });

    test('L3=9 未达 10（L2=0）→ L2+ 累计 9≥5 → 推荐 3 档（继续攻坚 L3）', () {
      final done = zeroed()..[3] = 9;
      expect(RecommendRule.computeRecommendedTierIndex(done), 3);
    });

    test('全档位海量完成 → 封顶 5 档，永不推荐 6/7 档', () {
      final done = List<int>.filled(8, 100);
      expect(RecommendRule.computeRecommendedTierIndex(done), 5);
    });

    test('只玩 L6/L7 高难 → 计入 L4+ 累计 → 封顶推荐 5 档', () {
      final done = zeroed()
        ..[6] = 100
        ..[7] = 100;
      expect(RecommendRule.computeRecommendedTierIndex(done), 5);
    });

    test('done 列表过短（防御）→ 仍返回默认 2', () {
      expect(RecommendRule.computeRecommendedTierIndex(const [0, 0]), 2);
    });
  });

  group('RecommendRule.tierIndexOfKey', () {
    test('8x8 (64) → 2 (L2)', () {
      expect(RecommendRule.tierIndexOfKey('8x8'), 2);
    });
    test('6x6 (36) → 1 (L1.5)', () {
      expect(RecommendRule.tierIndexOfKey('6x6'), 1);
    });
    test('5x5 (25) → 0 (L1)', () {
      expect(RecommendRule.tierIndexOfKey('5x5'), 0);
    });
    test('10x10 (100) → 3 (L3)', () {
      expect(RecommendRule.tierIndexOfKey('10x10'), 3);
    });
    test('12x12 (144) → 4 (L4)', () {
      expect(RecommendRule.tierIndexOfKey('12x12'), 4);
    });
    test('15x15 (225) → 5 (L5)', () {
      expect(RecommendRule.tierIndexOfKey('15x15'), 5);
    });
    test('24x24 (576) → 7 (L7)', () {
      expect(RecommendRule.tierIndexOfKey('24x24'), 7);
    });
    test('竖版 6x9 (54) → 2 (L2)', () {
      expect(RecommendRule.tierIndexOfKey('6x9'), 2);
    });
    test('非法 key → -1（不计入统计）', () {
      expect(RecommendRule.tierIndexOfKey('abc'), -1);
      expect(RecommendRule.tierIndexOfKey('8x'), -1);
      expect(RecommendRule.tierIndexOfKey('x8'), -1);
      expect(RecommendRule.tierIndexOfKey('0x8'), -1);
      expect(RecommendRule.tierIndexOfKey(''), -1);
    });
  });

  group('RecommendRule.levelOf', () {
    test('档位序 → tierLevel 字符串', () {
      expect(RecommendRule.levelOf(0), 'L1');
      expect(RecommendRule.levelOf(1), 'L1.5');
      expect(RecommendRule.levelOf(2), 'L2');
      expect(RecommendRule.levelOf(5), 'L5');
      expect(RecommendRule.levelOf(7), 'L7');
    });
    test('越界 → 回退默认 L2', () {
      expect(RecommendRule.levelOf(-1), 'L2');
      expect(RecommendRule.levelOf(8), 'L2');
    });
  });

  group('RecommendService.difficultyForAspect（未计算时默认 2 档）', () {
    final svc = RecommendService.instance;

    test('全局默认推荐档为 2（L2）', () {
      expect(svc.recommendedTierIndex, RecommendRule.defaultTierIndex);
      expect(svc.recommendedTierLevel, 'L2');
    });

    test('square 1:1 → 精确命中 L2 档 8x8/64', () {
      final d = svc.difficultyForAspect(PuzzleAspectRatio.square1x1);
      expect(d.tierLevel, 'L2');
      expect(d.pieceCount, 64);
      expect(d.rows, 8);
      expect(d.cols, 8);
    });

    test('各比例都精确命中 L2 档（不存在就近映射问题）', () {
      for (final aspect in PuzzleAspectRatio.values) {
        final d = svc.difficultyForAspect(aspect);
        expect(d.tierLevel, 'L2',
            reason: '${aspect.name} 应存在 L2 档');
        expect(d.pieceCount, greaterThan(0));
      }
    });
  });
}
