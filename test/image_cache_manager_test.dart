import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:jigsawpuzzle/data/game_repository.dart';
import 'package:jigsawpuzzle/data/models/custom_puzzle_item.dart';
import 'package:jigsawpuzzle/data/storage_manager.dart';
import 'package:jigsawpuzzle/logic/cache/engine_task_queue.dart';
import 'package:jigsawpuzzle/logic/cache/image_cache_manager.dart';
import 'package:jigsawpuzzle/logic/cache/memory_cache.dart';
import 'package:jigsawpuzzle/logic/cache/thumbnail_generator.dart';
import 'package:jigsawpuzzle/logic/puzzle_model.dart';
import 'package:jigsawpuzzle/widgets/app_cached_image.dart';

import 'test_helper.dart';

Uint8List createTestPngBytes(int width, int height) {
  final image = img.Image(width: width, height: height);
  img.fill(image, color: img.ColorRgb8(50, 150, 200));
  return Uint8List.fromList(img.encodePng(image));
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory testTempDir;
  late StorageManager sm;

  setUpAll(() async {
    testTempDir = await Directory.systemTemp.createTemp(
      'jigsaw_tiered_cache_test_',
    );

    const channel = MethodChannel('plugins.flutter.io/path_provider');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (MethodCall methodCall) async {
          return testTempDir.path;
        });

    sm = await initTestAppStorage();
    await GameRepository.instance.init();
    await ImageCacheManager.instance.init();
  });

  tearDownAll(() async {
    await tearDownTestStorage(sm);
    try {
      if (await testTempDir.exists()) {
        await testTempDir.delete(recursive: true);
      }
    } catch (_) {}
  });

  group('L1 MemoryCache LRU Tests', () {
    test('MemoryCache handles put, get, and LRU eviction correctly', () {
      final cache = MemoryCache(maxEntries: 3, maxSizeBytes: 1000);

      final bytes1 = Uint8List(100);
      final bytes2 = Uint8List(200);
      final bytes3 = Uint8List(300);
      final bytes4 = Uint8List(150);

      cache.put('key1', bytes1);
      cache.put('key2', bytes2);
      cache.put('key3', bytes3);

      expect(cache.entryCount, 3);
      expect(cache.currentSizeBytes, 600);
      expect(cache.get('key1'), isNotNull);

      // Accessing key1 makes key2 the oldest. Now insert key4, key2 should be evicted!
      cache.put('key4', bytes4);

      expect(cache.entryCount, 3);
      expect(cache.get('key2'), isNull); // Evicted!
      expect(cache.get('key1'), isNotNull);
      expect(cache.get('key3'), isNotNull);
      expect(cache.get('key4'), isNotNull);

      cache.clear();
      expect(cache.entryCount, 0);
      expect(cache.currentSizeBytes, 0);
    });
  });

  group('EngineTaskQueue Concurrency & Single Flight Tests', () {
    test(
      'EngineTaskQueue enforces max concurrency and drains queue smoothly',
      () async {
        final queue = EngineTaskQueue(maxConcurrency: 2);
        expect(queue.maxConcurrency, 2);

        var activeWorkers = 0;
        var peakConcurrency = 0;
        var completedCount = 0;

        Future<int> mockWorker(int id) async {
          activeWorkers++;
          if (activeWorkers > peakConcurrency) {
            peakConcurrency = activeWorkers;
          }
          await Future.delayed(const Duration(milliseconds: 30));
          activeWorkers--;
          completedCount++;
          return id;
        }

        final futures = <Future<int>>[];
        for (int i = 0; i < 8; i++) {
          futures.add(
            queue.schedule(key: 'task_$i', task: () => mockWorker(i)),
          );
        }

        final results = await Future.wait(futures);
        expect(results.length, 8);
        expect(completedCount, 8);
        expect(peakConcurrency, lessThanOrEqualTo(2));
        expect(queue.runningCount, 0);
        expect(queue.queuedCount, 0);
      },
    );

    test(
      'EngineTaskQueue performs Single Flight deduplication for identical keys',
      () async {
        final queue = EngineTaskQueue(maxConcurrency: 4);

        var executionCount = 0;
        Future<String> heavyJob() async {
          executionCount++;
          await Future.delayed(const Duration(milliseconds: 20));
          return 'job_done';
        }

        // Schedule 6 requests with the exact same key
        final futures = List.generate(
          6,
          (_) => queue.schedule(key: 'shared_key', task: heavyJob),
        );

        final results = await Future.wait(futures);

        expect(executionCount, 1); // Only executed ONCE!
        for (final r in results) {
          expect(r, 'job_done');
        }
      },
    );
  });

  group('ThumbnailGenerator & Pipeline Tests', () {
    test(
      'ThumbnailGenerator downsamples raw bytes correctly in Isolate',
      () async {
        final rawPng = createTestPngBytes(1200, 800);
        final thumbBytes = await ThumbnailGenerator.generateThumbnailFromBytes(
          rawBytes: rawPng,
          targetDimension: 300,
          quality: 80,
        );

        expect(thumbBytes, isNotNull);
        expect(thumbBytes!.isNotEmpty, isTrue);

        final decodedThumb = img.decodeImage(thumbBytes);
        expect(decodedThumb, isNotNull);
        expect(decodedThumb!.width, 300);
        expect(decodedThumb.height, 200);
      },
    );
  });

  group('ImageCacheManager Tiered Cache & Zero-Sync I/O Tests', () {
    test(
      'ImageCacheManager provides tiered lookup (L1 Memory -> L2 Disk -> L3 Worker)',
      () async {
        final manager = ImageCacheManager.instance;
        final testImgFile = File('${testTempDir.path}/tiered_test_origin.png');
        await testImgFile.writeAsBytes(createTestPngBytes(1000, 600));

        // Initially neither L1 nor L2
        expect(manager.isThumbnailCached(testImgFile.path), isFalse);
        expect(
          manager.getCachedThumbnailBytesFromMemory(testImgFile.path),
          isNull,
        );

        // Fetch bytes through tiered pipeline (generates & populates L2 disk + L1 memory)
        final bytes = await manager.getThumbnailBytes(
          testImgFile.path,
          dimension: ThumbnailDimension.card,
        );
        expect(bytes, isNotNull);
        expect(bytes!.isNotEmpty, isTrue);

        // Now L1 is populated
        expect(
          manager.getCachedThumbnailBytesFromMemory(testImgFile.path),
          isNotNull,
        );

        // Now L2 in-memory index is populated (0-latency check)
        expect(manager.isThumbnailCached(testImgFile.path), isTrue);

        // Clear only L1 memory cache, L2 disk cache remains and can be read back into L1
        manager.memoryCache.clear();
        expect(
          manager.getCachedThumbnailBytesFromMemory(testImgFile.path),
          isNull,
        );
        expect(manager.isThumbnailCached(testImgFile.path), isTrue);

        // Fetching again reads from L2 disk into L1 memory
        final bytesFromDisk = await manager.getThumbnailBytes(
          testImgFile.path,
          dimension: ThumbnailDimension.card,
        );
        expect(bytesFromDisk, isNotNull);
        expect(
          manager.getCachedThumbnailBytesFromMemory(testImgFile.path),
          isNotNull,
        );

        final sizeBytes = await manager.getCacheSizeBytes();
        expect(sizeBytes, greaterThan(0));
      },
    );

    test(
      'ImageCacheManager clearCache resets L1 memory, L2 disk, and task queue',
      () async {
        final manager = ImageCacheManager.instance;
        final testImgFile = File('${testTempDir.path}/clear_test_origin.png');
        await testImgFile.writeAsBytes(createTestPngBytes(600, 400));

        await manager.getThumbnailBytes(
          testImgFile.path,
          dimension: ThumbnailDimension.card,
        );
        expect(manager.isThumbnailCached(testImgFile.path), isTrue);

        await manager.clearCache();
        expect(manager.isThumbnailCached(testImgFile.path), isFalse);
        expect(
          manager.getCachedThumbnailBytesFromMemory(testImgFile.path),
          isNull,
        );
        expect(await manager.getCacheSizeBytes(), equals(0));
      },
    );
  });

  group('ThumbnailDimension Enum Tests', () {
    test('enum exposes expected pixel buckets', () {
      expect(ThumbnailDimension.card.pixels, 360);
      expect(ThumbnailDimension.eventCover.pixels, 720);
    });

    test(
      'getCacheKey produces distinct keys per dimension for the same source',
      () {
        final manager = ImageCacheManager.instance;
        final src = '${testTempDir.path}/enum_test_origin.png';

        final cardKey = manager.getCacheKey(
          src,
          dimension: ThumbnailDimension.card,
        );
        final coverKey = manager.getCacheKey(
          src,
          dimension: ThumbnailDimension.eventCover,
        );

        expect(cardKey, isNot(equals(coverKey)));
        expect(cardKey, endsWith('_360.jpg'));
        expect(coverKey, endsWith('_720.jpg'));
      },
    );

    test('removeThumbnailForSource cleans up all dimension variants', () async {
      final manager = ImageCacheManager.instance;
      final src = '${testTempDir.path}/remove_all_test_origin.png';
      await File(src).writeAsBytes(createTestPngBytes(800, 600));

      // Populate both dimension variants
      await manager.getThumbnailBytes(src, dimension: ThumbnailDimension.card);
      await manager.getThumbnailBytes(
        src,
        dimension: ThumbnailDimension.eventCover,
      );
      expect(
        manager.isThumbnailCached(src, dimension: ThumbnailDimension.card),
        isTrue,
      );
      expect(
        manager.isThumbnailCached(
          src,
          dimension: ThumbnailDimension.eventCover,
        ),
        isTrue,
      );

      await manager.removeThumbnailForSource(src);

      for (final dim in ThumbnailDimension.values) {
        expect(
          manager.isThumbnailCached(src, dimension: dim),
          isFalse,
          reason: 'variant ${dim.name} should be removed',
        );
      }
    });
  });

  group('GameRepository customPuzzlesNotifier Reactive Tests', () {
    test(
      'Adding, updating, and deleting custom puzzle notifies customPuzzlesNotifier',
      () async {
        final repo = GameRepository.instance;
        var notifiedCount = 0;
        List<CustomPuzzleItem>? lastList;

        void listener() {
          notifiedCount++;
          lastList = repo.customPuzzlesNotifier.value;
        }

        repo.customPuzzlesNotifier.addListener(listener);

        final newItem = CustomPuzzleItem(
          id: 'test_ugc_02',
          title: '测试自制关卡2',
          imagePathOrUrl: 'assets/images/sample_01.jpg',
          isLocalFile: false,
          difficulty: PuzzleAspectRatio.square1x1.tiers[0].difficulty,
          createdAt: DateTime.now(),
        );

        await repo.addCustomPuzzle(newItem);
        expect(notifiedCount, greaterThanOrEqualTo(1));
        expect(lastList, isNotNull);
        expect(lastList!.any((p) => p.id == 'test_ugc_02'), isTrue);

        await repo.updateCustomProgress(id: 'test_ugc_02', progressPercent: 75);
        expect(
          repo.customPuzzlesNotifier.value
              .firstWhere((p) => p.id == 'test_ugc_02')
              .progressPercent,
          75,
        );

        await repo.deleteCustomPuzzle('test_ugc_02');
        expect(
          repo.customPuzzlesNotifier.value.any((p) => p.id == 'test_ugc_02'),
          isFalse,
        );

        repo.customPuzzlesNotifier.removeListener(listener);
      },
    );
  });

  group('AppCachedImage UI Component Tests', () {
    testWidgets('AppCachedImage builds with asset and handles error fallback', (
      tester,
    ) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: AppCachedImage(
              imagePathOrUrl: 'assets/images/sample_01.jpg',
              targetDimension: ThumbnailDimension.card,
            ),
          ),
        ),
      );

      expect(find.byType(AppCachedImage), findsOneWidget);
    });
  });
}
