// Unit tests for small zip auto-download (<20MB) with in-flight avoidance
// ignore_for_file: avoid_catches_without_on_clauses
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jigsawpuzzle/logic/cache/level_image_resolver.dart';
import 'package:jigsawpuzzle/logic/content/content_manager.dart';
import 'package:jigsawpuzzle/logic/content/network/content_http_client.dart';
import 'package:path/path.dart' as p;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempDir;
  late String supportDir;

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('jigsaw_autodownload_test_');
    supportDir = p.join(tempDir.path, 'support');
    Directory(supportDir).createSync(recursive: true);
    LevelImageResolver.instance.resetForTest();
  });

  tearDown(() {
    try {
      if (tempDir.existsSync()) {
        tempDir.deleteSync(recursive: true);
      }
    } catch (_) {}
  });

  group('AutoDownload Small Packs (<20MB) Tests', () {
    test('kAutoDownloadMaxSizeBytes is exactly 20MB', () {
      expect(
        ContentManager.kAutoDownloadMaxSizeBytes,
        equals(20 * 1024 * 1024),
      );
    });

    test(
      'Filters eligible events and collections under 20MB correctly',
      () async {
        // 1. 准备活动缓存数据
        final eventsData = [
          {
            'id': 'event_small',
            'title': 'Small Event',
            'status': 'active',
            'type': 'zip',
            'zipUrl': 'https://example.com/small.zip',
            'fileSizeBytes': 5 * 1024 * 1024, // 5MB -> 应该自动下载
          },
          {
            'id': 'event_too_large',
            'title': 'Large Event',
            'status': 'active',
            'type': 'zip',
            'zipUrl': 'https://example.com/large.zip',
            'fileSizeBytes': 25 * 1024 * 1024, // 25MB -> 排除
          },
          {
            'id': 'event_zero_size',
            'title': 'Zero Size Event',
            'status': 'active',
            'type': 'zip',
            'zipUrl': 'https://example.com/zero.zip',
            'fileSizeBytes': 0, // 0 -> 排除（大小未知）
          },
          {
            'id': 'event_delisted',
            'title': 'Delisted Event',
            'status': 'active',
            'type': 'zip',
            'zipUrl': 'https://example.com/delisted.zip',
            'fileSizeBytes': 2 * 1024 * 1024,
            'isDelisted': true, // 已下架 -> 排除
          },
          {
            'id': 'event_disabled',
            'title': 'Disabled Event',
            'status': 'disabled',
            'type': 'zip',
            'zipUrl': 'https://example.com/disabled.zip',
            'fileSizeBytes': 2 * 1024 * 1024, // disabled -> 排除
          },
          {
            'id': 'event_already_downloaded',
            'title': 'Downloaded Event',
            'status': 'active',
            'type': 'zip',
            'zipUrl': 'https://example.com/downloaded.zip',
            'fileSizeBytes': 3 * 1024 * 1024,
            'isLocalDownloaded': true, // 已下载 -> 排除
          },
        ];

        final eventsCacheFile = File(p.join(supportDir, 'events_cache.json'));
        eventsCacheFile.writeAsStringSync(jsonEncode(eventsData));

        // 模拟本地已存在资源的已下载活动
        final alreadyDownloadedDir = Directory(
          p.join(supportDir, 'levels', 'events', 'event_already_downloaded'),
        )..createSync(recursive: true);
        File(
          p.join(alreadyDownloadedDir.path, 'level_1.webp'),
        ).writeAsBytesSync([1, 2, 3]);

        // 2. 准备图集缓存数据
        final collectionsData = [
          {
            'id': 'col_small',
            'title': 'Small Col',
            'status': 'active',
            'type': 'zip',
            'zipUrl': 'https://example.com/col_small.zip',
            'fileSizeBytes': 15 * 1024 * 1024, // 15MB -> 应该自动下载
          },
          {
            'id': 'col_too_large',
            'title': 'Large Col',
            'status': 'active',
            'type': 'zip',
            'zipUrl': 'https://example.com/col_large.zip',
            'fileSizeBytes': 21 * 1024 * 1024, // 21MB -> 排除
          },
        ];

        final collectionsCacheFile = File(
          p.join(supportDir, 'collections_cache.json'),
        );
        collectionsCacheFile.writeAsStringSync(jsonEncode(collectionsData));

        // 3. 构建 ContentManager 并注入假 ContentHttpClient
        final fakeClient = _FakeDownloadHttpClient(
          zipBytes: _createMockZipBytes(),
        );
        final manager = ContentManager(
          bootstrapUrls: ['https://example.com/manifest.json'],
          appSupportDir: supportDir,
          httpClient: fakeClient,
        );
        await manager.initialize();

        expect(
          manager.getVisibleEvents().length,
          equals(5),
        ); // disabled 过滤后 5 个
        expect(manager.getVisibleCollections().length, equals(2));

        // 4. 执行自动下载
        await manager.runAutoDownloadSmallPacksForTest(
          maxWaitInFlight: Duration.zero,
        );

        // 5. 核心断言：验证只有 eligible 的 2 个包进入了下载队列，其余被排除
        expect(
          fakeClient.requestedUrls,
          equals([
            'https://example.com/small.zip',
            'https://example.com/col_small.zip',
          ]),
        );
        expect(
          fakeClient.requestedUrls.contains('https://example.com/large.zip'),
          isFalse,
        );
        expect(
          fakeClient.requestedUrls.contains('https://example.com/zero.zip'),
          isFalse,
        );
        expect(
          fakeClient.requestedUrls.contains('https://example.com/delisted.zip'),
          isFalse,
        );
        expect(
          fakeClient.requestedUrls.contains('https://example.com/disabled.zip'),
          isFalse,
        );
        expect(
          fakeClient.requestedUrls.contains(
            'https://example.com/downloaded.zip',
          ),
          isFalse,
        );
        expect(
          fakeClient.requestedUrls.contains(
            'https://example.com/col_large.zip',
          ),
          isFalse,
        );

        // 6. 正向验证：合规的 2 个包成功下载并解压标记为已就绪
        final eventSmall = manager.getVisibleEvents().firstWhere(
          (e) => e.id == 'event_small',
        );
        expect(manager.eventsPipeline.isEventDownloaded(eventSmall), isTrue);

        final colSmall = manager.getVisibleCollections().firstWhere(
          (c) => c.id == 'col_small',
        );
        expect(
          manager.collectionsPipeline.isCollectionDownloaded(colSmall),
          isTrue,
        );

        // 7. 负向验证：被排除的项依然未就绪
        final eventTooLarge = manager.getVisibleEvents().firstWhere(
          (e) => e.id == 'event_too_large',
        );
        expect(
          manager.eventsPipeline.isEventDownloaded(eventTooLarge),
          isFalse,
        );

        final colTooLarge = manager.getVisibleCollections().firstWhere(
          (c) => c.id == 'col_too_large',
        );
        expect(
          manager.collectionsPipeline.isCollectionDownloaded(colTooLarge),
          isFalse,
        );

        // 验证未抛出未捕获异常，任务顺利结束
        expect(manager.isAutoDownloading, isFalse);
      },
    );

    test(
      'Waits for foreground in-flight downloads to clear before proceeding',
      () async {
        final fakeClient = _FakeDownloadHttpClient(
          zipBytes: _createMockZipBytes(),
        );
        final manager = ContentManager(
          bootstrapUrls: ['https://example.com/manifest.json'],
          appSupportDir: supportDir,
          httpClient: fakeClient,
        );
        await manager.initialize();

        // 模拟前台 LevelImageResolver 正在下载图片
        final completer = Completer<String>();
        LevelImageResolver.instance.inFlightForTest['mock_cover.jpg'] =
            completer.future;

        expect(manager.hasForegroundInFlight, isTrue);

        var downloadFinished = false;
        final future = manager
            .runAutoDownloadSmallPacksForTest(
              maxWaitInFlight: const Duration(seconds: 3),
            )
            .then((_) {
              downloadFinished = true;
            });

        // 稍等 100ms，任务应该仍在等待 in-flight 清理
        await Future<void>.delayed(const Duration(milliseconds: 100));
        expect(downloadFinished, isFalse);
        expect(manager.isAutoDownloading, isTrue);

        // 前台图片下载完成
        completer.complete('done');
        LevelImageResolver.instance.inFlightForTest.clear();
        expect(manager.hasForegroundInFlight, isFalse);

        // 等待自动下载完成
        await future;
        expect(downloadFinished, isTrue);
        expect(manager.isAutoDownloading, isFalse);
      },
    );

    test(
      'Re-entrant triggers are safely ignored while download is running',
      () async {
        final fakeClient = _FakeDownloadHttpClient(
          zipBytes: _createMockZipBytes(),
        );
        final manager = ContentManager(
          bootstrapUrls: ['https://example.com/manifest.json'],
          appSupportDir: supportDir,
          httpClient: fakeClient,
        );
        await manager.initialize();

        // 模拟长耗时等待
        final completer = Completer<String>();
        LevelImageResolver.instance.inFlightForTest['mock_wait.jpg'] =
            completer.future;

        unawaited(
          manager.runAutoDownloadSmallPacksForTest(),
        );

        await Future<void>.delayed(const Duration(milliseconds: 50));
        expect(manager.isAutoDownloading, isTrue);

        // 再次触发应该直接跳过（防重入）
        manager.triggerAutoDownloadSmallPacks();
        expect(manager.isAutoDownloading, isTrue);

        // 清理
        completer.complete('done');
        LevelImageResolver.instance.inFlightForTest.clear();
        await Future<void>.delayed(const Duration(milliseconds: 100));
      },
    );
  });
}

class _FakeDownloadHttpClient extends ContentHttpClient {
  _FakeDownloadHttpClient({required this.zipBytes});

  final List<int> zipBytes;
  final List<String> requestedUrls = [];

  @override
  Future<File> downloadFileWithMirrors(
    List<String> urls,
    String destinationPath, {
    Duration? timeout,
    void Function(int received, int total)? onProgress,
  }) async {
    requestedUrls.addAll(urls);
    final file = File(destinationPath);
    if (!file.parent.existsSync()) {
      file.parent.createSync(recursive: true);
    }
    await file.writeAsBytes(zipBytes, flush: true);
    onProgress?.call(zipBytes.length, zipBytes.length);
    return file;
  }

  @override
  Future<File> downloadFile(
    String url,
    String destinationPath, {
    Duration? timeout,
    void Function(int received, int total)? onProgress,
  }) async {
    requestedUrls.add(url);
    final file = File(destinationPath);
    if (!file.parent.existsSync()) {
      file.parent.createSync(recursive: true);
    }
    await file.writeAsBytes(zipBytes, flush: true);
    onProgress?.call(zipBytes.length, zipBytes.length);
    return file;
  }
}

List<int> _createMockZipBytes() {
  final archive = Archive();
  final dummyImageContent = utf8.encode('fake_image_content');
  archive.addFile(
    ArchiveFile('test_image.webp', dummyImageContent.length, dummyImageContent),
  );
  return ZipEncoder().encode(archive);
}
