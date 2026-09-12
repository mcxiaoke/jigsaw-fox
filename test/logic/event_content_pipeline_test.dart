// P1-4：测试有意触发失败路径以验证容错逻辑，统一豁免
// ignore_for_file: avoid_catches_without_on_clauses
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jigsawpuzzle/l10n/gen/strings.g.dart';
import 'package:jigsawpuzzle/logic/content/models/puzzle_event_item.dart';
import 'package:jigsawpuzzle/logic/content/pipelines/events_content_pipeline.dart';
import 'package:jigsawpuzzle/widgets/download_badge.dart';
import 'package:path/path.dart' as p;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempDir;
  late String cacheFilePath;
  late String eventsStorageBaseDir;
  late EventsContentPipeline pipeline;

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('jigsaw_event_test_');
    cacheFilePath = p.join(tempDir.path, 'events_cache.json');
    eventsStorageBaseDir = p.join(tempDir.path, 'events');
    pipeline = EventsContentPipeline(
      cacheFilePath: cacheFilePath,
      eventsStorageBaseDir: eventsStorageBaseDir,
    );
  });

  tearDown(() {
    try {
      if (tempDir.existsSync()) {
        tempDir.deleteSync(recursive: true);
      }
    } catch (_) {}
  });

  group('EventsContentPipeline Local Cache & Download Tests', () {
    test(
      'isEventDownloaded correctly identifies missing vs ready local files',
      () {
        const event = PuzzleEventItem(
          id: 'cyberpunk_2026',
          title: 'Cyberpunk 2026',
          status: 'active',
          type: 'zip',
          zipUrl: 'https://example.com/cyberpunk.zip',
          isLocalDownloaded: false,
        );

        // 1. 目录不存在 -> 未下载
        expect(pipeline.isEventDownloaded(event), isFalse);

        // 2. 目录存在但无图片 -> 未下载
        final eventDir = Directory(p.join(eventsStorageBaseDir, event.id));
        eventDir.createSync(recursive: true);
        expect(pipeline.isEventDownloaded(event), isFalse);

        // 3. 目录存在且有非图片文件（如临时文件） -> 未下载
        File(p.join(eventDir.path, 'notes.txt')).writeAsStringSync('notes');
        expect(pipeline.isEventDownloaded(event), isFalse);

        // 4. 目录存在有效图片文件 -> 已下载就绪
        File(
          p.join(eventDir.path, '01_level.webp'),
        ).writeAsBytesSync([0x52, 0x49, 0x46, 0x46]);
        expect(pipeline.isEventDownloaded(event), isTrue);

        // 5. 非 zip 类型的 array 活动 -> 始终视为就绪
        const arrayEvent = PuzzleEventItem(
          id: 'online_event',
          title: 'Online Event',
          status: 'active',
          type: 'array',
          levels: ['https://example.com/1.webp'],
        );
        expect(pipeline.isEventDownloaded(arrayEvent), isTrue);
      },
    );

    test(
      'ensureEventDownloaded skips download if local disk files exist',
      () async {
        const event = PuzzleEventItem(
          id: 'summer_fest',
          title: 'Summer Fest',
          status: 'active',
          type: 'zip',
          zipUrl: 'https://example.com/summer.zip',
          isLocalDownloaded: false,
        );

        // 模拟磁盘上已存在解压后的关卡图片
        final eventDir = Directory(p.join(eventsStorageBaseDir, event.id));
        eventDir.createSync(recursive: true);
        File(
          p.join(eventDir.path, 'level_1.jpg'),
        ).writeAsBytesSync([0xFF, 0xD8, 0xFF]);

        var updateNotified = 0;
        pipeline.updateNotifier.addListener(() {
          updateNotified++;
        });

        final ok = await pipeline.ensureEventDownloaded(event);
        expect(ok, isTrue);
        expect(pipeline.getDownloadProgress(event.id), 1.0);
        expect(updateNotified, greaterThan(0));
      },
    );
  });

  group('DownloadBadge Widget Tests', () {
    setUpAll(() {
      LocaleSettings.setLocale(AppLocale.zh);
    });

    testWidgets('Renders download button when Zip not downloaded', (
      tester,
    ) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: DownloadBadge(
              isDownloaded: false,
              isDownloading: false,
              downloadProgress: 0.0,
              isZipType: true,
              displayFileSize: '5.2 MB',
            ),
          ),
        ),
      );

      expect(find.text('5.2 MB'), findsOneWidget);
    });

    testWidgets('Renders progress percent when downloading', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: DownloadBadge(
              isDownloaded: false,
              isDownloading: true,
              downloadProgress: 0.45,
              isZipType: true,
              displayFileSize: '5.2 MB',
            ),
          ),
        ),
      );

      expect(find.text('45%'), findsOneWidget);
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
    });

    testWidgets('Renders downloaded badge when ready', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: DownloadBadge(
              isDownloaded: true,
              isDownloading: false,
              downloadProgress: 1.0,
              isZipType: true,
              displayFileSize: '5.2 MB',
            ),
          ),
        ),
      );

      expect(find.text(t.collections.badgeDownloaded), findsOneWidget);
    });

    testWidgets('Renders nothing for non-zip online items', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: DownloadBadge(
              isDownloaded: true,
              isDownloading: false,
              downloadProgress: 1.0,
              isZipType: false,
            ),
          ),
        ),
      );

      expect(find.byType(CircularProgressIndicator), findsNothing);
      expect(find.text(t.collections.badgeDownloaded), findsNothing);
    });
  });
}
