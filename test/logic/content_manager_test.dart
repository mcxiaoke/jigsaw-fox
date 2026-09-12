import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:jigsawpuzzle/logic/content/content_manager.dart';
import 'package:jigsawpuzzle/logic/content/models/canonical_id.dart';
import 'package:jigsawpuzzle/logic/content/network/content_http_client.dart';
import 'package:jigsawpuzzle/logic/content/pipelines/daily_content_pipeline.dart';
import 'package:path/path.dart' as p;

/// 内容测试服务器基址覆盖项。
///
/// 默认基址指向作者本机的局域网服务器（192.168.1.118），该地址仅在特定网络
/// 环境可达，换机或 CI 上必然失败。需要运行依赖真实服务器的用例时显式指定：
///
/// ```bash
/// flutter test --dart-define=JIGSAW_TEST_SERVER=http://your-host/test2
/// ```
const String jigsawTestServerOverride = String.fromEnvironment(
  'JIGSAW_TEST_SERVER',
);

/// 依赖真实内容服务器的用例的统一跳过条件（见 [jigsawTestServerOverride]）。
///
/// 未显式提供服务器时这些用例会被跳过，而不是在 CI 上产生假失败。
String? get skipUnlessTestServer => jigsawTestServerOverride.isEmpty
    ? '需要真实内容服务器：用 --dart-define=JIGSAW_TEST_SERVER=<base> 启用'
    : null;

void main() {
  final testServerBase = jigsawTestServerOverride.isNotEmpty
      ? jigsawTestServerOverride
      : 'http://127.0.0.1:8080/test2';
  late Directory sandboxDir;
  late String supportDir;

  setUp(() {
    sandboxDir = Directory(
      p.join(Directory.current.path, 'temp', 'test_content_sandbox'),
    );
    if (sandboxDir.existsSync()) {
      sandboxDir.deleteSync(recursive: true);
    }
    sandboxDir.createSync(recursive: true);

    supportDir = p.join(sandboxDir.path, 'support');
    Directory(supportDir).createSync(recursive: true);
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

  group(
    'ContentManager End-to-End Tests with Real Test Server',
    () {
      test('1. Full sync, Main levels and Multi-tag filtering', () async {
        final manager = ContentManager(
          bootstrapUrls: ['$testServerBase/manifest.json'],
          appSupportDir: supportDir,
        );

        // 初始化 (首次无缓存)
        await manager.initialize();
        expect(manager.getMainLevels().isEmpty, isTrue);

        // 全量同步
        await manager.syncAll(overrideToday: DateTime(2026, 8, 27));

        // 验证 Root Manifest
        expect(manager.currentManifest, isNotNull);
        expect(manager.currentManifest?.mainModule.version, equals(103));

        // 验证首页关卡
        final mainLevels = manager.getMainLevels();
        expect(mainLevels.length, equals(20));
        expect(mainLevels.first.id, equals('main:101'));
        expect(mainLevels.last.id, equals('main:120'));

        // 验证标签列表 (对齐 data/taxonomy.json 规范)
        final tags = manager.getMainTags();
        expect(tags.contains('all'), isTrue);
        expect(tags.contains('Animals'), isTrue);
        expect(tags.contains('Nature'), isTrue);
        expect(tags.contains('Landscapes'), isTrue);
        expect(tags.contains('Structures'), isTrue);

        // 验证多标签过滤
        final animalLevels = manager.filterMainByTag('Animals');
        expect(animalLevels.isNotEmpty, isTrue);

        final natureLevels = manager.filterMainByTag('Nature');
        expect(natureLevels.isNotEmpty, isTrue);

        final allFiltered = manager.filterMainByTag('all');
        expect(allFiltered.length, equals(20));

        // 验证按需下载单张关卡图片
        final level101 = mainLevels.first;
        expect(level101.isLocalFile, isFalse);

        final downloadedLevel101 = await manager.ensureMainLevelDownloaded(
          level101,
        );
        expect(downloadedLevel101.isLocalFile, isTrue);
        expect(downloadedLevel101.localPath, isNotNull);
        expect(File(downloadedLevel101.localPath!).existsSync(), isTrue);
      });

      test(
        '2. Daily Challenge monthly Zip download and Time-lock validation',
        () async {
          final manager = ContentManager(
            bootstrapUrls: ['$testServerBase/manifest.json'],
            appSupportDir: supportDir,
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
          final todayLevel = manager.getTodayDailyLevel(
            overrideToday: testToday,
          );
          expect(todayLevel, isNotNull);
          expect(todayLevel?.dailyDate, equals('20260827'));
          expect(todayLevel?.isTimeLocked, isFalse);
        },
      );

      test(
        '3. Events Zip and Array modes, and no auto-delete for disabled events',
        () async {
          // 预设：在本地创建一个属于 disabled 活动的沙盒目录
          final disabledEventDir = Directory(
            p.join(supportDir, 'levels', 'events', 'expired_cleanup_test'),
          );
          disabledEventDir.createSync(recursive: true);
          File(
            p.join(disabledEventDir.path, 'garbage.tmp'),
          ).writeAsStringSync('old cache');
          expect(disabledEventDir.existsSync(), isTrue);

          final manager = ContentManager(
            bootstrapUrls: ['$testServerBase/manifest.json'],
            appSupportDir: supportDir,
          );

          await manager.syncAll();

          // 验证可见活动 (disabled 状态的活动必须被自动过滤隐藏)
          final visibleEvents = manager.getVisibleEvents();
          expect(
            visibleEvents.any((e) => e.id == 'expired_cleanup_test'),
            isFalse,
          );
          expect(visibleEvents.any((e) => e.id == 'cyberpunk_2026'), isTrue);
          expect(
            visibleEvents.any((e) => e.id == 'cute_animals_party'),
            isTrue,
          );

          // P0-2（红线 R1）：disabled 活动的本地目录不得被自动删除。
          expect(disabledEventDir.existsSync(), isTrue);

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
          expect(cyberpunkLevels.first.localPath, isNotNull);
          expect(File(cyberpunkLevels.first.localPath!).existsSync(), isTrue);

          // 验证 Array 模式活动关卡映射
          final animalEvent = visibleEvents.firstWhere(
            (e) => e.id == 'cute_animals_party',
          );
          expect(animalEvent.isArrayType, isTrue);

          final animalLevels = manager.getEventLevels(animalEvent);
          expect(animalLevels.length, equals(5));
          expect(
            animalLevels.first.id,
            equals('event:cute_animals_party:0101'),
          );
        },
      );

      test(
        '4. Robustness: Fallback to backup bootstrap URL on primary failure',
        () async {
          final manager = ContentManager(
            bootstrapUrls: [
              // 故意失败的主 URL：本地未监听端口，连接立即被拒，无需依赖局域网
              'http://127.0.0.1:9999/non_existent_404.json',
              '$testServerBase/manifest.json', // 正常的备用 URL
            ],
            appSupportDir: supportDir,
          );

          final manifest = await manager.manifestRouter.resolveManifest();
          expect(manifest.mainModule.version, equals(103));
        },
      );

      test(
        '5. Robustness: Offline cache restoration when totally disconnected',
        () async {
          // 步骤 1：先在线同步一次，产生本地缓存
          final onlineManager = ContentManager(
            bootstrapUrls: ['$testServerBase/manifest.json'],
            appSupportDir: supportDir,
          );
          await onlineManager.syncAll();
          expect(onlineManager.getMainLevels().length, equals(20));

          // 步骤 2：创建全新的 Manager，提供完全无法连接的假 URL (模拟彻底断网)
          final offlineManager = ContentManager(
            bootstrapUrls: ['http://127.0.0.1:9999/dead_url.json'],
            appSupportDir: supportDir,
          );

          // 初始化自愈：从本地缓存恢复
          await offlineManager.initialize();
          expect(offlineManager.currentManifest, isNotNull);
          expect(
            offlineManager.currentManifest?.mainModule.version,
            equals(103),
          );
          expect(offlineManager.getMainLevels().length, equals(20));
          expect(offlineManager.getMainTags().contains('Animals'), isTrue);
        },
      );

      test(
        '6. Daily Challenge: Tolerates dirty overflow dates and truncated image counts',
        () async {
          final dailyPipeline = DailyContentPipeline(
            dailyStorageBaseDir: p.join(supportDir, 'levels', 'daily'),
          );

          // 模拟本地 2026 年 2 月份 (平年共 28 天)，但错误放入了 29、30、31 号的脏文件
          final febDir = Directory(
            p.join(supportDir, 'levels', 'daily', '202602'),
          );
          febDir.createSync(recursive: true);
          for (var d = 1; d <= 31; d++) {
            File(
              p.join(febDir.path, '202602${d.toString().padLeft(2, '0')}.jpg'),
            ).writeAsStringSync('fake image');
          }

          // 获取 2 月份关卡，应该严格自动过滤掉 29, 30, 31 号，只保留 28 天
          final febLevels = dailyPipeline.getLevelsForMonth(
            '202602',
            overrideToday: DateTime(2026, 3),
          );
          expect(febLevels.length, equals(28));
          expect(febLevels.last.dailyDate, equals('20260228'));

          // 模拟某月份只提供了 25 张图片 (2026-09 只提供 01~25)
          final sepDir = Directory(
            p.join(supportDir, 'levels', 'daily', '202609'),
          );
          sepDir.createSync(recursive: true);
          for (var d = 1; d <= 25; d++) {
            File(
              p.join(sepDir.path, '202609${d.toString().padLeft(2, '0')}.jpg'),
            ).writeAsStringSync('fake image');
          }

          // 获取 9 月份关卡，自适应展示 25 个关卡
          final sepLevels = dailyPipeline.getLevelsForMonth(
            '202609',
            overrideToday: DateTime(2026, 10),
          );
          expect(sepLevels.length, equals(25));
          expect(sepLevels.last.dailyDate, equals('20260925'));
        },
      );
    },
    skip: skipUnlessTestServer,
  );

  group('RFC 3986 URL Resolution Tests', () {
    test('Correctly resolves relative and absolute URLs', () {
      const baseManifest = 'http://127.0.0.1:8080/test2/manifest.json';

      // 1. 同级相对路径
      expect(
        ContentHttpClient.resolveUrl(baseManifest, 'main/index.json'),
        equals('http://127.0.0.1:8080/test2/main/index.json'),
      );

      // 2. 模块内批次相对路径
      const baseMainIndex = 'http://127.0.0.1:8080/test2/main/index.json';
      expect(
        ContentHttpClient.resolveUrl(baseMainIndex, 'batches/batch_001.json'),
        equals(
          'http://127.0.0.1:8080/test2/main/batches/batch_001.json',
        ),
      );

      // 3. 批次内部相对上级图片导航 (../images/0101.webp)
      const baseBatch =
          'http://127.0.0.1:8080/test2/main/batches/batch_001.json';
      expect(
        ContentHttpClient.resolveUrl(baseBatch, '../images/0101.webp'),
        equals(
          'http://127.0.0.1:8080/test2/main/images/0101.webp',
        ),
      );

      // 4. 绝对路径保持原样
      expect(
        ContentHttpClient.resolveUrl(
          baseManifest,
          'https://cdn2.other.com/extra.json',
        ),
        equals('https://cdn2.other.com/extra.json'),
      );
    });
  });

  group(
    'Universal v2.3.0 Deterministic Content Tests with test2 Server',
    () {
      final test2ServerBase = jigsawTestServerOverride.isNotEmpty
          ? jigsawTestServerOverride
          : 'http://127.0.0.1:8080/test2';

      test(
        '1. Full sync with test2, batch difference and explicit ID contract',
        () async {
          final manager = ContentManager(
            bootstrapUrls: ['$test2ServerBase/manifest.json'],
            appSupportDir: supportDir,
          );

          await manager.syncAll();

          // 验证 Manifest 版本与 BaseURI
          expect(manager.currentManifest, isNotNull);
          expect(manager.currentManifest?.schemaVersion, equals(4));
          expect(
            manager.currentManifest?.baseUri,
            equals('$test2ServerBase/manifest.json'),
          );

          // 验证 Main 关卡加载
          final levels = manager.getMainLevels();
          expect(
            levels.length,
            equals(20),
            reason: 'Total levels should be exactly 20 (no twin levels)',
          );

          // 验证所有关卡 ID 均严格遵循 main:XXX 格式，不含 url 噪音
          for (final l in levels) {
            expect(
              RegExp(r'^main:\d+$').hasMatch(l.id),
              isTrue,
              reason: 'ID ${l.id} must be main:order',
            );
          }

          // 核心验证：P0-3 修图补丁覆盖 (第 105 关)
          final level105 = levels.firstWhere((l) => l.order == 105);
          expect(
            level105.id,
            equals('main:105'),
            reason: 'Explicit ID must be preserved from batch_003',
          );
          expect(
            level105.url.endsWith('0105-r2.webp'),
            isTrue,
            reason: 'URL must point to patched image 0105-r2.webp',
          );
          expect(
            level105.tags.contains('retouched'),
            isTrue,
            reason: 'Tags must include patch tag',
          );
          expect(level105.hash, isNotNull, reason: 'Hash must be populated');

          // 验证不存在重复的 105 关
          final count105 = levels.where((l) => l.order == 105).length;
          expect(
            count105,
            equals(1),
            reason: 'There must NOT be duplicate/twin levels for order 105',
          );

          // 验证 Daily 模块从 daily/index.json 成功同步当月 ZIP
          final dailyLevels = manager.getDailyLevelsForMonth(
            '202609',
            overrideToday: DateTime(2026, 9, 5),
          );
          expect(dailyLevels.length, equals(30));

          // 验证 Events 与 Collections
          expect(manager.eventsPipeline.visibleEvents.length, equals(5));
          expect(
            manager.collectionsPipeline.visibleCollections.length,
            equals(4),
          );
        },
      );

      test(
        '2. Cold start cache restoration does NOT drift Canonical ID (Anti-Drift Proof)',
        () async {
          // 步骤 1：在线同步一次产生本地缓存并下载图片
          final onlineManager = ContentManager(
            bootstrapUrls: ['$test2ServerBase/manifest.json'],
            appSupportDir: supportDir,
          );
          await onlineManager.syncAll();
          final level101 = onlineManager.getMainLevels().firstWhere(
            (l) => l.order == 101,
          );

          // 下载关卡 101 图片到本地，将其路径改为本地绝对路径
          final downloaded101 = await onlineManager.ensureMainLevelDownloaded(
            level101,
          );
          expect(downloaded101.isLocalFile, isTrue);
          expect(downloaded101.localPath, isNotNull);
          expect(File(downloaded101.localPath!).existsSync(), isTrue);

          // 触发持久化
          await onlineManager.mainPipeline.syncWithRemote(
            remoteUrl: '$test2ServerBase/main/index.json',
            remoteVersion: 103,
          );

          // 步骤 2：创建全新的离线 Manager (模拟应用冷启动并断网)
          final offlineManager = ContentManager(
            bootstrapUrls: ['http://127.0.0.1:9999/dead_url.json'],
            appSupportDir: supportDir,
          );
          await offlineManager.initialize();

          // 核心验证：冷启动后，ID 绝对不能漂移成 main:main_101
          final restoredLevels = offlineManager.getMainLevels();
          expect(restoredLevels.length, equals(20));

          for (final l in restoredLevels) {
            expect(
              l.id.contains('main_'),
              isFalse,
              reason:
                  'ID ${l.id} drifted into double prefix! Must strictly be main:<order>',
            );
            expect(
              l.id.contains('-r2'),
              isFalse,
              reason:
                  'ID ${l.id} leaked revision suffix! Must strictly be main:<order>',
            );
          }

          final restored101 = restoredLevels.firstWhere((l) => l.order == 101);
          expect(restored101.id, equals('main:101'));
          expect(restored101.isLocalFile, isTrue);

          final restored105 = restoredLevels.firstWhere((l) => l.order == 105);
          expect(restored105.id, equals('main:105'));
        },
      );
    },
    skip: skipUnlessTestServer,
  );

  group('Daily Index Cache and Availability Tests', () {
    test(
      'Restores availableDailyMonths from local cache and guards unavailable months',
      () async {
        final cacheFile = File(p.join(supportDir, 'daily_index_cache.json'));
        await cacheFile.writeAsString('''
{
  "zipUrls": {
    "202609": "https://example.com/daily/zips/202609.zip",
    "202608": "https://example.com/daily/zips/202608.zip"
  },
  "mirrorUrls": {
    "202609": ["https://mirror.example.com/202609.zip"]
  }
}
''');

        final manager = ContentManager(
          bootstrapUrls: ['http://127.0.0.1:9999/manifest.json'],
          appSupportDir: supportDir,
        );

        await manager.initialize(offlineOnly: true);

        // 验证从本地缓存恢复了 202609 和 202608
        expect(manager.availableDailyMonths, containsAll(['202609', '202608']));
        expect(manager.isDailyMonthAvailable('202609'), isTrue);
        expect(manager.isDailyMonthAvailable('202608'), isTrue);

        // 关键验证：未声明的 202607 为不可用
        expect(manager.isDailyMonthAvailable('202607'), isFalse);

        // 验证未声明月份不会进入 pipeline 下载流程，直接返回 false
        final ready = await manager.ensureDailyMonthReady('202607');
        expect(ready, isFalse);
      },
    );
  });
}
