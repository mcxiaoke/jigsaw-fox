import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:jigsawpuzzle/logic/cache/level_image_resolver.dart';
import 'package:jigsawpuzzle/logic/content/models/puzzle_level_item.dart';
import 'package:jigsawpuzzle/logic/content/network/content_http_client.dart';
import 'package:jigsawpuzzle/widgets/app_cached_image.dart';
import 'package:jigsawpuzzle/widgets/lazy_level_image.dart';
import 'package:path/path.dart' as p;

Uint8List createTestPng() {
  final image = img.Image(width: 10, height: 10);
  img.fill(image, color: img.ColorRgb8(200, 100, 50));
  return Uint8List.fromList(img.encodePng(image));
}

class FakeHttpClient extends ContentHttpClient {
  bool shouldFail = false;
  Duration delay = Duration.zero;

  @override
  Future<File> downloadFile(
    String url,
    String destinationPath, {
    Duration? timeout,
    void Function(int received, int total)? onProgress,
  }) async {
    if (delay > Duration.zero) {
      await Future<void>.delayed(delay);
    }
    if (shouldFail) {
      throw const HttpException('Simulated download failure');
    }
    final file = File(destinationPath);
    if (!file.parent.existsSync()) {
      file.parent.createSync(recursive: true);
    }
    file.writeAsBytesSync(createTestPng());
    return file;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory testSupportDir;
  late String networkLevelsDir;
  late FakeHttpClient fakeHttpClient;

  setUp(() {
    testSupportDir = Directory.systemTemp.createTempSync(
      'jigsaw_img_widget_test_',
    );
    networkLevelsDir = p.join(testSupportDir.path, 'levels', 'network');
    Directory(networkLevelsDir).createSync(recursive: true);

    fakeHttpClient = FakeHttpClient();
    LevelImageResolver.instance.resetForTest(
      networkLevelsDirOverride: networkLevelsDir,
      httpClientOverride: fakeHttpClient,
    );
  });

  tearDown(() {
    LevelImageResolver.instance.resetForTest();
    try {
      if (testSupportDir.existsSync()) {
        testSupportDir.deleteSync(recursive: true);
      }
    } catch (_) {}
  });

  group('AppCachedImage Widget Tests', () {
    testWidgets('Renders errorWidget when remote download fails', (
      tester,
    ) async {
      fakeHttpClient.shouldFail = true;
      const testUrl = 'https://example.com/failed_download.png';

      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: AppCachedImage(
              imagePathOrUrl: testUrl,
              errorWidget: Text('CustomError'),
            ),
          ),
        ),
      );

      // Advance frames to complete async _load()
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));

      expect(find.text('CustomError'), findsOneWidget);
    });

    testWidgets('Renders FileImage with ResizeImage for valid local file', (
      tester,
    ) async {
      final file = File(p.join(testSupportDir.path, 'test_local.png'));
      file.writeAsBytesSync(createTestPng());

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: AppCachedImage(
              imagePathOrUrl: file.path,
              targetDimension: ThumbnailDimension.eventCover,
              fadeInDuration: Duration.zero,
            ),
          ),
        ),
      );

      final imageFinder = find.byType(Image);
      expect(imageFinder, findsOneWidget);
      final imageWidget = tester.widget<Image>(imageFinder);
      expect(imageWidget.image, isA<ResizeImage>());
      final resize = imageWidget.image as ResizeImage;
      expect(resize.imageProvider, isA<FileImage>());
      expect(resize.width, 720);
    });

    testWidgets(
      'LazyLevelImage synchronous hit renders AppCachedImage directly',
      (tester) async {
        const url = 'https://example.com/level_cached.png';

        // Pre-land the file directly into network levels dir
        final localPath = await LevelImageResolver.instance.resolveUrlLocalPath(
          url,
        );
        expect(File(localPath).existsSync(), isTrue);
        expect(
          LevelImageResolver.instance.getUrlLocalPathIfAvailable(url),
          isNotNull,
        );

        const level = PuzzleLevelItem(
          id: 'main:101',
          url: url,
        );

        await tester.pumpWidget(
          const MaterialApp(
            home: Scaffold(
              body: LazyLevelImage(
                level: level,
                placeholder: Text('MyLazyPlaceholder'),
              ),
            ),
          ),
        );

        // Cold-boot sync hit: AppCachedImage is mounted immediately on 1st frame with resolved localPath!
        expect(find.byType(AppCachedImage), findsOneWidget);
        final cachedImage = tester.widget<AppCachedImage>(
          find.byType(AppCachedImage),
        );
        expect(cachedImage.imagePathOrUrl, equals(localPath));
      },
    );

    testWidgets(
      '_NetworkImageLoader discards completed download if URL changed before completion',
      (tester) async {
        fakeHttpClient.delay = const Duration(milliseconds: 100);

        const url1 = 'https://example.com/slow1.png';
        const url2 = 'https://example.com/slow2.png';

        await tester.pumpWidget(
          const MaterialApp(
            home: Scaffold(
              body: AppCachedImage(
                imagePathOrUrl: url1,
                placeholder: Text('Placeholder1'),
              ),
            ),
          ),
        );

        expect(find.text('Placeholder1'), findsOneWidget);

        // Advance 50ms while url1 is halfway through (100ms total)
        await tester.pump(const Duration(milliseconds: 50));

        // Change widget to url2 before url1 completes
        await tester.pumpWidget(
          const MaterialApp(
            home: Scaffold(
              body: AppCachedImage(
                imagePathOrUrl: url2,
                placeholder: Text('Placeholder2'),
              ),
            ),
          ),
        );

        expect(find.text('Placeholder2'), findsOneWidget);

        // Advance 60ms (total 110ms from start):
        // url1 completes at t=100ms, but url2 won't complete until t=150ms.
        await tester.pump(const Duration(milliseconds: 60));

        // Because url changed to url2, the completed url1 must NOT override with url1's image
        expect(find.text('Placeholder2'), findsOneWidget);

        // Now advance 60ms more (total 170ms from start, 120ms from url2 start)
        await tester.pump(const Duration(milliseconds: 60));
        await tester.pump();

        final path2 = LevelImageResolver.instance.getUrlLocalPathIfAvailable(
          url2,
        );
        expect(path2, isNotNull);
      },
    );
  });
}
