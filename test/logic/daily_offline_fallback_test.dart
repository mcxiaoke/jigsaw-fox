// P1-4：测试有意触发失败路径以验证容错逻辑，统一豁免
// ignore_for_file: avoid_catches_without_on_clauses
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:jigsawpuzzle/logic/content/models/canonical_id.dart';
import 'package:jigsawpuzzle/logic/content/models/puzzle_level_item.dart';
import 'package:jigsawpuzzle/logic/content/pipelines/daily_content_pipeline.dart';
import 'package:path/path.dart' as p;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempDailyDir;
  late DailyContentPipeline pipeline;

  setUp(() {
    tempDailyDir = Directory.systemTemp.createTempSync('daily_fallback_test_');
    pipeline = DailyContentPipeline(dailyStorageBaseDir: tempDailyDir.path);
  });

  tearDown(() {
    try {
      if (tempDailyDir.existsSync()) {
        tempDailyDir.deleteSync(recursive: true);
      }
    } catch (_) {}
  });

  File createMockDailyFile(String yyyyMm, String yyyyMmDd) {
    final monthDir = Directory(p.join(tempDailyDir.path, yyyyMm));
    if (!monthDir.existsSync()) {
      monthDir.createSync(recursive: true);
    }
    final file = File(p.join(monthDir.path, '$yyyyMmDd.webp'));
    file.writeAsBytesSync([1, 2, 3, 4]);
    return file;
  }

  group('DailyContentPipeline Local History Levels Discovery', () {
    test(
      'Discovers ready months and levels in both YYYYMM and YYYY-MM formatted directories',
      () {
        createMockDailyFile('202608', '20260801');
        createMockDailyFile('202608', '20260802');
        createMockDailyFile('2026-09', '20260901');

        // 空目录残留，不应该被视作 ready 月份
        Directory(p.join(tempDailyDir.path, '202607')).createSync();

        // 仅有非法命名的文件，也不应该被视作 ready 月份
        final invalidDir = Directory(p.join(tempDailyDir.path, '202606'))
          ..createSync();
        File(p.join(invalidDir.path, 'invalid.txt')).writeAsStringSync('dummy');

        final readyMonths = pipeline.getLocalReadyMonths();
        expect(readyMonths, ['202609', '202608']);

        final history = pipeline.getAllLocalHistoryLevels();
        expect(history.length, 3);
        expect(history.map((e) => e.dailyDate).toList(), [
          '20260801',
          '20260802',
          '20260901',
        ]);
      },
    );

    test('Ignores invalid dates like February 30th', () {
      createMockDailyFile('202602', '20260228');
      createMockDailyFile('202602', '20260230'); // 非法日期

      final levels = pipeline.getLevelsForMonth('202602');
      expect(levels.length, 1);
      expect(levels.first.dailyDate, '20260228');
    });

    test(
      'getOfficialTodayLevel strictly returns today level or null without fallback',
      () {
        final today = DateTime(2026, 9, 11);
        expect(pipeline.getOfficialTodayLevel(overrideToday: today), isNull);

        final file = createMockDailyFile('202609', '20260911');
        final official = pipeline.getOfficialTodayLevel(overrideToday: today);
        expect(official, isNotNull);
        expect(official!.localPath, file.path);
        expect(official.dailyDate, '20260911');
      },
    );
  });

  group('DailyContentPipeline Daily Banner Level (Offline Fallback)', () {
    test('Scenario 1: Returns official today level when present locally', () {
      final today = DateTime(2026, 9, 11);
      final file = createMockDailyFile('202609', '20260911');

      final level = pipeline.getDailyBannerLevel(overrideToday: today);
      expect(level, isNotNull);
      expect(level!.id, CanonicalId.forDaily('20260911'));
      expect(level.dailyDate, '20260911');
      expect(level.localPath, file.path);
      expect(level.isTimeLocked, isFalse);
    });

    test(
      'Scenario 2: Offline for multiple days, falls back to local history deterministically',
      () {
        // 离线环境：今天是 2026-10-15，当月 2026-10 未联网下载，本地仅有 8月与 9月的历史关卡
        final today = DateTime(2026, 10, 15);
        final f1 = createMockDailyFile('202608', '20260810');
        final f2 = createMockDailyFile('202608', '20260820');
        final f3 = createMockDailyFile('202609', '20260905');

        final level1 = pipeline.getDailyBannerLevel(overrideToday: today);
        expect(level1, isNotNull);
        // ID 必须规范化为当天的 daily:YYYYMMDD，保证打卡 streak 正常累积
        expect(level1!.id, CanonicalId.forDaily('20261015'));
        expect(level1.dailyDate, '20261015');
        expect(level1.isLocalFile, isTrue);
        expect(level1.sourceModule, CanonicalId.prefixDaily);
        // 本地图片必须真实存在
        expect(File(level1.localPath!).existsSync(), isTrue);
        expect([f1.path, f2.path, f3.path], contains(level1.localPath));

        // 确定性验证：同日多次请求必须返回完全同一张图片
        final level2 = pipeline.getDailyBannerLevel(overrideToday: today);
        expect(level2!.localPath, level1.localPath);
        expect(level2.id, level1.id);
      },
    );

    test(
      'Scenario 3: Offline with no daily history, falls back to available main levels',
      () {
        final today = DateTime(2026, 10, 15);
        // 本地无任何 daily 关卡
        expect(pipeline.getAllLocalHistoryLevels(), isEmpty);

        final dummyMainImg = File(p.join(tempDailyDir.path, 'main_01.jpg'))
          ..writeAsBytesSync([5, 6, 7]);
        final fallbackLevels = [
          PuzzleLevelItem(
            id: 'main:nature:01',
            localPath: dummyMainImg.path,
            isLocalFile: true,
            order: 1,
          ),
        ];

        final level = pipeline.getDailyBannerLevel(
          overrideToday: today,
          fallbackLocalLevels: fallbackLevels,
        );

        expect(level, isNotNull);
        expect(level!.id, CanonicalId.forDaily('20261015'));
        expect(level.dailyDate, '20261015');
        expect(level.localPath, dummyMainImg.path);
        expect(level.sourceModule, CanonicalId.prefixDaily);
      },
    );

    test(
      'Scenario 4: Completely offline with zero local data returns null (NEVER assetSamples)',
      () {
        final today = DateTime(2026, 10, 15);
        // 没有任何本地历史关卡，也没有备选关卡
        final level = pipeline.getDailyBannerLevel(overrideToday: today);
        expect(level, isNull);
      },
    );
  });
}
