import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:jigsawpuzzle/logic/content/content_manager.dart';
import 'package:jigsawpuzzle/logic/content/models/canonical_id.dart';
import 'package:jigsawpuzzle/logic/content/pipelines/daily_content_pipeline.dart';
import 'package:path/path.dart' as p;

void main() {
  const testServerBase = 'http://192.168.1.118/data/www/game/test';
  late Directory sandboxDir;
  late String supportDir;
  late String documentsDir;

  setUp(() {
    sandboxDir = Directory(
      p.join(Directory.current.path, 'temp', 'test_content_sandbox'),
    );
    if (sandboxDir.existsSync()) {
      sandboxDir.deleteSync(recursive: true);
    }
    sandboxDir.createSync(recursive: true);

    supportDir = p.join(sandboxDir.path, 'support');
    documentsDir = p.join(sandboxDir.path, 'documents');
    Directory(supportDir).createSync(recursive: true);
    Directory(documentsDir).createSync(recursive: true);
  });

  tearDown(() {
    if (sandboxDir.existsSync()) {
      try {
        sandboxDir.deleteSync(recursive: true);
      } catch (_) {}
    }
  });

  group('CanonicalId Specification Tests', () {
    test('Correctly formats canonical IDs across modules', () {
      expect(CanonicalId.forMain(101), equals('main:101'));
      expect(CanonicalId.forDaily('20260827'), equals('daily:20260827'));
      expect(CanonicalId.forDaily('20260827.webp'), equals('daily:20260827'));
      expect(
        CanonicalId.forEvent('cyberpunk_2026', '01_rain.jpg'),
        equals('event:cyberpunk_2026:01_rain'),
      );
      expect(
        CanonicalId.forPack('world_art', 'mona_lisa.png'),
        equals('pack:world_art:mona_lisa'),
      );
      expect(
        CanonicalId.forUgc('1787548651000.jpg'),
        equals('ugc:1787548651000'),
      );
    });

    test('Parses canonical ID into structured info', () {
      final info1 = CanonicalId.parse('main:101');
      expect(info1.module, equals('main'));
      expect(info1.name, equals('101'));

      final info2 = CanonicalId.parse('event:summer_2026:01_cover');
      expect(info2.module, equals('event'));
      expect(info2.context, equals('summer_2026'));
      expect(info2.name, equals('01_cover'));
    });
  });

  group('ContentManager End-to-End Tests with Real Test Server', () {
    test('1. Full sync, Main levels and Multi-tag filtering', () async {
      final manager = ContentManager(
        bootstrapUrls: ['$testServerBase/manifest.json'],
        appSupportDir: supportDir,
        appDocumentsDir: documentsDir,
      );

      // 初始化 (首次无缓存)
      await manager.initialize();
      expect(manager.getMainLevels().isEmpty, isTrue);

      // 全量同步
      await manager.syncAll(overrideToday: DateTime(2026, 8, 27));

      // 验证 Root Manifest
      expect(manager.currentManifest, isNotNull);
      expect(manager.currentManifest?.mainModule.version, equals(120));

      // 验证首页关卡
      final mainLevels = manager.getMainLevels();
      expect(mainLevels.length, equals(20));
      expect(mainLevels.first.id, equals('main:101'));
      expect(mainLevels.last.id, equals('main:120'));

      // 验证标签列表
      final tags = manager.getMainTags();
      expect(tags.contains('all'), isTrue);
      expect(tags.contains('animal'), isTrue);
      expect(tags.contains('bird'), isTrue);
      expect(tags.contains('panda'), isTrue);

      // 验证多标签过滤
      final animalLevels = manager.filterMainByTag('animal');
      expect(animalLevels.isNotEmpty, isTrue);

      final birdLevels = manager.filterMainByTag('bird');
      expect(birdLevels.isNotEmpty, isTrue);

      final allFiltered = manager.filterMainByTag('all');
      expect(allFiltered.length, equals(20));

      // 验证按需下载单张关卡图片
      final level101 = mainLevels.first;
      expect(level101.isLocalFile, isFalse);

      final downloadedLevel101 = await manager.ensureMainLevelDownloaded(
        level101,
      );
      expect(downloadedLevel101.isLocalFile, isTrue);
      expect(File(downloadedLevel101.imagePathOrUrl).existsSync(), isTrue);
    });

    test(
      '2. Daily Challenge monthly Zip download and Time-lock validation',
      () async {
        final manager = ContentManager(
          bootstrapUrls: ['$testServerBase/manifest.json'],
          appSupportDir: supportDir,
          appDocumentsDir: documentsDir,
        );

        final testToday = DateTime(2026, 8, 27);
        await manager.syncAll(overrideToday: testToday);

        // 验证 8 月份每日关卡 (共 31 天)
        final augustLevels = manager.getDailyLevelsForMonth(
          '202608',
          overrideToday: testToday,
        );
        expect(augustLevels.length, equals(31));

        // 验证过去和今天的日期：未加锁 (isTimeLocked == false)
        final levelAug01 = augustLevels.firstWhere(
          (l) => l.dailyDate == '20260801',
        );
        expect(levelAug01.isTimeLocked, isFalse);
        expect(levelAug01.id, equals('daily:20260801'));

        final levelAug27 = augustLevels.firstWhere(
          (l) => l.dailyDate == '20260827',
        );
        expect(levelAug27.isTimeLocked, isFalse);

        // 验证未来日期：加锁 (isTimeLocked == true)
        final levelAug28 = augustLevels.firstWhere(
          (l) => l.dailyDate == '20260828',
        );
        expect(levelAug28.isTimeLocked, isTrue);

        final levelAug31 = augustLevels.firstWhere(
          (l) => l.dailyDate == '20260831',
        );
        expect(levelAug31.isTimeLocked, isTrue);

        // 验证今日关卡快捷获取
        final todayLevel = manager.getTodayDailyLevel(overrideToday: testToday);
        expect(todayLevel, isNotNull);
        expect(todayLevel?.dailyDate, equals('20260827'));
        expect(todayLevel?.isTimeLocked, isFalse);
      },
    );

    test(
      '3. Events Zip and Array modes, and Auto-GC for disabled events',
      () async {
        // 预设：在本地创建一个属于 disabled 活动的沙盒目录
        final disabledEventDir = Directory(
          p.join(documentsDir, 'events', 'expired_cleanup_test'),
        );
        disabledEventDir.createSync(recursive: true);
        File(
          p.join(disabledEventDir.path, 'garbage.tmp'),
        ).writeAsStringSync('old cache');
        expect(disabledEventDir.existsSync(), isTrue);

        final manager = ContentManager(
          bootstrapUrls: ['$testServerBase/manifest.json'],
          appSupportDir: supportDir,
          appDocumentsDir: documentsDir,
        );

        await manager.syncAll();

        // 验证可见活动 (disabled 状态的活动必须被自动过滤隐藏)
        final visibleEvents = manager.getVisibleEvents();
        expect(
          visibleEvents.any((e) => e.id == 'expired_cleanup_test'),
          isFalse,
        );
        expect(visibleEvents.any((e) => e.id == 'cyberpunk_2026'), isTrue);
        expect(visibleEvents.any((e) => e.id == 'cute_animals_party'), isTrue);

        // 验证 Auto-GC 磁盘清理：disabled 活动的目录必须被彻底物理删除
        expect(disabledEventDir.existsSync(), isFalse);

        // 验证 Zip 模式活动下载与关卡映射
        final cyberpunkEvent = visibleEvents.firstWhere(
          (e) => e.id == 'cyberpunk_2026',
        );
        expect(cyberpunkEvent.isZipType, isTrue);

        final zipReady = await manager.ensureEventDownloaded(cyberpunkEvent);
        expect(zipReady, isTrue);

        final cyberpunkLevels = manager.getEventLevels(cyberpunkEvent);
        expect(cyberpunkLevels.length, equals(6));
        expect(cyberpunkLevels.first.id, equals('event:cyberpunk_2026:01'));
        expect(File(cyberpunkLevels.first.imagePathOrUrl).existsSync(), isTrue);

        // 验证 Array 模式活动关卡映射
        final animalEvent = visibleEvents.firstWhere(
          (e) => e.id == 'cute_animals_party',
        );
        expect(animalEvent.isArrayType, isTrue);

        final animalLevels = manager.getEventLevels(animalEvent);
        expect(animalLevels.length, equals(5));
        expect(animalLevels.first.id, equals('event:cute_animals_party:101'));
      },
    );

    test(
      '4. Robustness: Fallback to backup bootstrap URL on primary failure',
      () async {
        final manager = ContentManager(
          bootstrapUrls: [
            'http://192.168.1.118/data/www/game/test/non_existent_404.json', // 故意失败的主 URL
            '$testServerBase/manifest.json', // 正常的备用 URL
          ],
          appSupportDir: supportDir,
          appDocumentsDir: documentsDir,
        );

        final manifest = await manager.manifestRouter.resolveManifest();
        expect(manifest.mainModule.version, equals(120));
      },
    );

    test(
      '5. Robustness: Offline cache restoration when totally disconnected',
      () async {
        // 步骤 1：先在线同步一次，产生本地缓存
        final onlineManager = ContentManager(
          bootstrapUrls: ['$testServerBase/manifest.json'],
          appSupportDir: supportDir,
          appDocumentsDir: documentsDir,
        );
        await onlineManager.syncAll();
        expect(onlineManager.getMainLevels().length, equals(20));

        // 步骤 2：创建全新的 Manager，提供完全无法连接的假 URL (模拟彻底断网)
        final offlineManager = ContentManager(
          bootstrapUrls: ['http://127.0.0.1:9999/dead_url.json'],
          appSupportDir: supportDir,
          appDocumentsDir: documentsDir,
        );

        // 初始化自愈：从本地缓存恢复
        await offlineManager.initialize();
        expect(offlineManager.currentManifest, isNotNull);
        expect(offlineManager.currentManifest?.mainModule.version, equals(120));
        expect(offlineManager.getMainLevels().length, equals(20));
        expect(offlineManager.getMainTags().contains('animal'), isTrue);
      },
    );

    test(
      '6. Daily Challenge: Tolerates dirty overflow dates and truncated image counts',
      () async {
        final dailyPipeline = DailyContentPipeline(
          dailyStorageBaseDir: p.join(documentsDir, 'daily'),
        );

        // 模拟本地 2026 年 2 月份 (平年共 28 天)，但错误放入了 29、30、31 号的脏文件
        final febDir = Directory(p.join(documentsDir, 'daily', '202602'));
        febDir.createSync(recursive: true);
        for (var d = 1; d <= 31; d++) {
          File(
            p.join(febDir.path, '202602${d.toString().padLeft(2, '0')}.jpg'),
          ).writeAsStringSync('fake image');
        }

        // 获取 2 月份关卡，应该严格自动过滤掉 29, 30, 31 号，只保留 28 天
        final febLevels = dailyPipeline.getLevelsForMonth(
          '202602',
          overrideToday: DateTime(2026, 3, 1),
        );
        expect(febLevels.length, equals(28));
        expect(febLevels.last.dailyDate, equals('20260228'));

        // 模拟某月份只提供了 25 张图片 (2026-09 只提供 01~25)
        final sepDir = Directory(p.join(documentsDir, 'daily', '202609'));
        sepDir.createSync(recursive: true);
        for (var d = 1; d <= 25; d++) {
          File(
            p.join(sepDir.path, '202609${d.toString().padLeft(2, '0')}.jpg'),
          ).writeAsStringSync('fake image');
        }

        // 获取 9 月份关卡，自适应展示 25 个关卡
        final sepLevels = dailyPipeline.getLevelsForMonth(
          '202609',
          overrideToday: DateTime(2026, 10, 1),
        );
        expect(sepLevels.length, equals(25));
        expect(sepLevels.last.dailyDate, equals('20260925'));
      },
    );
  });
}
