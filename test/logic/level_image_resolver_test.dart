import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jigsawpuzzle/logic/cache/level_image_resolver.dart';
import 'package:jigsawpuzzle/logic/cache/thumbnail_dimension.dart';
import 'package:jigsawpuzzle/logic/content/models/puzzle_level_item.dart';
import 'package:jigsawpuzzle/logic/content/network/content_http_client.dart';
import 'package:path/path.dart' as p;

class FakeContentHttpClient extends ContentHttpClient {
  int downloadCallCount = 0;
  Duration delay = Duration.zero;
  bool shouldFail = false;

  @override
  Future<File> downloadFile(
    String url,
    String destinationPath, {
    Duration? timeout,
    void Function(int received, int total)? onProgress,
  }) async {
    downloadCallCount++;
    if (delay > Duration.zero) {
      await Future<void>.delayed(delay);
    }
    if (shouldFail) {
      throw Exception('Network download failed');
    }
    final file = File(destinationPath);
    await file.parent.create(recursive: true);
    await file.writeAsString('fake_image_content');
    return file;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory testSupportDir;
  late FakeContentHttpClient fakeHttpClient;

  setUp(() async {
    testSupportDir = Directory.systemTemp.createTempSync(
      'level_image_resolver_test_',
    );

    const channel = MethodChannel('plugins.flutter.io/path_provider');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (methodCall) async {
          return testSupportDir.path;
        });

    fakeHttpClient = FakeContentHttpClient();
    LevelImageResolver.instance.resetForTest(
      httpClientOverride: fakeHttpClient,
    );
  });

  tearDown(() async {
    LevelImageResolver.instance.resetForTest();
    try {
      if (testSupportDir.existsSync()) {
        testSupportDir.deleteSync(recursive: true);
      }
    } catch (_) {}
  });

  group('ThumbnailDimension Enum Tests', () {
    test('ThumbnailDimension defines correct pixels and defaults', () {
      expect(ThumbnailDimension.card.pixels, 360);
      expect(ThumbnailDimension.eventCover.pixels, 720);
      expect(kDefaultThumbnailDimension, ThumbnailDimension.card);
    });
  });

  group('LevelImageResolver Cold-Boot & Warmup Tests', () {
    test('warmup initializes network levels dir on disk', () async {
      final expectedDir = Directory(
        p.join(testSupportDir.path, 'levels', 'network'),
      );
      expect(expectedDir.existsSync(), isFalse);

      await LevelImageResolver.instance.warmup();

      expect(expectedDir.existsSync(), isTrue);
    });

    test('getUrlLocalPathIfAvailable returns null before warmup/init', () {
      final res = LevelImageResolver.instance.getUrlLocalPathIfAvailable(
        'https://example.com/test.jpg',
      );
      expect(res, isNull);
    });

    test(
      'getUrlLocalPathIfAvailable correctly identifies cache hit and miss',
      () async {
        await LevelImageResolver.instance.warmup();
        const testUrl = 'https://example.com/cats.jpg';

        expect(
          LevelImageResolver.instance.getUrlLocalPathIfAvailable(testUrl),
          isNull,
        );

        final networkDir = Directory(
          p.join(testSupportDir.path, 'levels', 'network'),
        );
        final dummyPath = p.join(networkDir.path, 'net_dummy.jpg');
        File(dummyPath).writeAsBytesSync([]);
        expect(File(dummyPath).existsSync(), isTrue);
        expect(File(dummyPath).lengthSync(), 0);

        final localPath = await LevelImageResolver.instance.resolveUrlLocalPath(
          testUrl,
        );
        expect(localPath, isNotEmpty);
        expect(File(localPath).existsSync(), isTrue);
        expect(File(localPath).lengthSync(), greaterThan(0));

        final syncHit = LevelImageResolver.instance.getUrlLocalPathIfAvailable(
          testUrl,
        );
        expect(syncHit, equals(localPath));
      },
    );

    test(
      'cleanLegacyThumbnailCache deletes legacy directory if present',
      () async {
        final legacyDir = Directory(
          p.join(testSupportDir.path, 'thumbnail_cache'),
        );
        legacyDir.createSync(recursive: true);
        final dummyFile = File(p.join(legacyDir.path, 'thumb_old.jpg'));
        dummyFile.writeAsStringSync('old');
        expect(legacyDir.existsSync(), isTrue);

        await LevelImageResolver.instance.cleanLegacyThumbnailCache();

        expect(legacyDir.existsSync(), isFalse);
      },
    );
  });

  group('LevelImageResolver Single-Flight Deduplication Tests', () {
    test(
      'Concurrent resolveUrlLocalPath requests for same URL trigger only 1 download',
      () async {
        await LevelImageResolver.instance.warmup();
        fakeHttpClient.delay = const Duration(milliseconds: 50);

        const url = 'https://example.com/banner.png?timestamp=12345';

        final futures = List.generate(
          5,
          (_) => LevelImageResolver.instance.resolveUrlLocalPath(url),
        );
        await Future<void>.delayed(Duration.zero);
        expect(LevelImageResolver.instance.inFlightForTest.length, 1);

        final results = await Future.wait(futures);

        for (final res in results) {
          expect(res, equals(results.first));
          expect(res.endsWith('.png'), isTrue);
        }

        expect(fakeHttpClient.downloadCallCount, 1);
        expect(LevelImageResolver.instance.inFlightForTest.isEmpty, isTrue);

        final secondRes = await LevelImageResolver.instance.resolveUrlLocalPath(
          url,
        );
        expect(secondRes, equals(results.first));
        expect(fakeHttpClient.downloadCallCount, 1);
      },
    );

    test('Single-flight cleans up on failure allowing retry', () async {
      await LevelImageResolver.instance.warmup();
      fakeHttpClient.shouldFail = true;

      const url = 'https://example.com/failed.jpg';

      final result1 = await LevelImageResolver.instance.resolveUrlLocalPath(
        url,
      );
      expect(result1, isEmpty);
      expect(LevelImageResolver.instance.inFlightForTest.isEmpty, isTrue);

      fakeHttpClient.shouldFail = false;
      final result2 = await LevelImageResolver.instance.resolveUrlLocalPath(
        url,
      );
      expect(result2, isNotEmpty);
      expect(File(result2).existsSync(), isTrue);
      expect(fakeHttpClient.downloadCallCount, 2);
    });
  });

  group('LevelImageResolver resolveLevelLocalPath Tests', () {
    test('Asset levels return path immediately', () async {
      const level = PuzzleLevelItem(
        id: 'main:001',
        url: 'assets/levels/main_001.jpg',
      );

      final path = await LevelImageResolver.instance.resolveLevelLocalPath(
        level,
      );
      expect(path, 'assets/levels/main_001.jpg');
      expect(fakeHttpClient.downloadCallCount, 0);
    });

    test('Existing local file returns path directly', () async {
      final localFile = File(p.join(testSupportDir.path, 'custom_pic.jpg'));
      await localFile.writeAsBytes(Uint8List.fromList([1, 2, 3]));

      final level = PuzzleLevelItem(
        id: 'custom:001',
        localPath: localFile.path,
      );

      final path = await LevelImageResolver.instance.resolveLevelLocalPath(
        level,
      );
      expect(path, localFile.path);
      expect(fakeHttpClient.downloadCallCount, 0);
    });

    test(
      'Network level delegates to single-flight and lands in network directory',
      () async {
        await LevelImageResolver.instance.warmup();

        const level = PuzzleLevelItem(
          id: 'remote:100',
          url: 'https://cdn.example.com/levels/100.jpg',
        );

        final path = await LevelImageResolver.instance.resolveLevelLocalPath(
          level,
        );
        expect(path, isNotEmpty);
        expect(path.startsWith('http'), isFalse);
        expect(File(path).existsSync(), isTrue);
        expect(fakeHttpClient.downloadCallCount, 1);
      },
    );
  });
}
