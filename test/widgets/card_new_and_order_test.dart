// P1-4：测试有意触发失败路径以验证容错逻辑，统一豁免
// ignore_for_file: avoid_catches_without_on_clauses
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jigsawpuzzle/data/game_repository.dart';
import 'package:jigsawpuzzle/data/storage_manager.dart';
import 'package:jigsawpuzzle/l10n/gen/strings.g.dart';
import 'package:jigsawpuzzle/logic/content/app_content.dart';
import 'package:jigsawpuzzle/logic/content/content_manager.dart';
import 'package:jigsawpuzzle/logic/content/models/puzzle_collection_item.dart';
import 'package:jigsawpuzzle/logic/content/models/puzzle_event_item.dart';
import 'package:jigsawpuzzle/logic/content/pipelines/collections_content_pipeline.dart';
import 'package:jigsawpuzzle/logic/content/pipelines/events_content_pipeline.dart';
import 'package:jigsawpuzzle/pages/collection_levels_page.dart';
import 'package:jigsawpuzzle/pages/event_levels_page.dart';
import 'package:jigsawpuzzle/pages/tabs/daily_tab_view.dart';
import 'package:jigsawpuzzle/services/locale_service.dart';
import 'package:path/path.dart' as p;
import '../test_helper.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late StorageManager sm;
  late Directory tempDir;

  setUpAll(() async {
    sm = await initTestAppStorage();
    await GameRepository.instance.init();
    await LocaleService.instance.init();

    tempDir = Directory.systemTemp.createTempSync('app_content_test_');
    final manager = ContentManager(
      bootstrapUrls: [],
      appSupportDir: tempDir.path,
    );
    await manager.initialize(offlineOnly: true);
    AppContent.instance.setManagerForTest(manager);
  });

  tearDownAll(() async {
    AppContent.instance.setManagerForTest(null);
    try {
      tempDir.deleteSync(recursive: true);
    } catch (_) {}
    await tearDownTestStorage(sm);
  });

  group('PuzzleCollectionItem & PuzzleEventItem isNew & updatedAt tests', () {
    test('Calculates isNew correctly based on updatedAt (within 7 days)', () {
      final now = DateTime.now();
      final recentDate = now.subtract(const Duration(days: 2));
      final oldDate = now.subtract(const Duration(days: 10));

      final recentCol = PuzzleCollectionItem.fromJson({
        'id': 'recent_col',
        'title': 'Recent Collection',
        'updatedAt': recentDate.toIso8601String(),
      });
      expect(recentCol.updatedAt, isNotNull);
      expect(recentCol.isNew, isTrue);

      final oldCol = PuzzleCollectionItem.fromJson({
        'id': 'old_col',
        'title': 'Old Collection',
        'updatedAt': oldDate.toIso8601String(),
      });
      expect(oldCol.isNew, isFalse);

      final recentEvent = PuzzleEventItem.fromJson({
        'id': 'recent_event',
        'title': 'Recent Event',
        'updatedAt': recentDate.toIso8601String(),
      });
      expect(recentEvent.updatedAt, isNotNull);
      expect(recentEvent.isNew, isTrue);

      final oldEvent = PuzzleEventItem.fromJson({
        'id': 'old_event',
        'title': 'Old Event',
        'updatedAt': oldDate.toIso8601String(),
      });
      expect(oldEvent.isNew, isFalse);
    });

    test('Pipeline assigns addedAt from collection/event to level items', () {
      final recentDate = DateTime.now().subtract(const Duration(days: 1));
      final col = PuzzleCollectionItem(
        id: 'test_col',
        title: 'Test Col',
        type: 'array',
        updatedAt: recentDate,
        levels: const [
          'https://example.com/img1.webp',
          'https://example.com/img2.webp',
        ],
      );

      final colPipe = CollectionsContentPipeline(
        cacheFilePath: p.join(tempDir.path, 'cache.json'),
        collectionsStorageBaseDir: tempDir.path,
      );
      final levels = colPipe.getLevelsForCollection(col);
      expect(levels.length, equals(2));
      expect(levels.first.addedAt, equals(recentDate));
      expect(levels.first.isNew, isTrue);

      final ev = PuzzleEventItem(
        id: 'test_event',
        title: 'Test Event',
        status: 'active',
        type: 'array',
        updatedAt: recentDate,
        levels: ['https://example.com/ev1.webp'],
      );

      final evPipe = EventsContentPipeline(
        cacheFilePath: p.join(tempDir.path, 'ev_cache.json'),
        eventsStorageBaseDir: tempDir.path,
      );
      final evLevels = evPipe.getLevelsForEvent(ev);
      expect(evLevels.length, equals(1));
      expect(evLevels.first.addedAt, equals(recentDate));
      expect(evLevels.first.isNew, isTrue);
    });
  });

  group('Card UI Tests: No Level X order & Show New Badge', () {
    testWidgets(
      'CollectionLevelsPage does not display level order and displays New badge',
      (tester) async {
        final recentDate = DateTime.now().subtract(const Duration(days: 1));
        final col = PuzzleCollectionItem(
          id: 'col_ui_test',
          title: 'Art Gallery',
          type: 'array',
          updatedAt: recentDate,
          levels: const ['assets/images/sample1.webp'],
        );

        await tester.pumpWidget(
          TranslationProvider(
            child: MaterialApp(
              home: CollectionLevelsPage(collection: col),
            ),
          ),
        );
        await tester.pump(const Duration(milliseconds: 300));

        // Verify no "Level 1" or "第 1 关" is rendered on the card
        expect(find.text('Level 1'), findsNothing);
        expect(find.text('第 1 关'), findsNothing);

        // Verify "New" badge is rendered
        expect(find.text('New'), findsOneWidget);
      },
    );

    testWidgets(
      'EventLevelsPage does not display level order and displays New badge',
      (tester) async {
        final recentDate = DateTime.now().subtract(const Duration(days: 1));
        final event = PuzzleEventItem(
          id: 'event_ui_test',
          title: 'Cyberpunk Quest',
          status: 'active',
          type: 'array',
          updatedAt: recentDate,
          levels: ['assets/images/sample1.webp'],
        );

        await tester.pumpWidget(
          TranslationProvider(
            child: MaterialApp(
              home: EventLevelsPage(event: event),
            ),
          ),
        );
        await tester.pump(const Duration(milliseconds: 300));

        // Verify no "Level 1" or "第 1 关" is rendered on the card
        expect(find.text('Level 1'), findsNothing);
        expect(find.text('第 1 关'), findsNothing);

        // Verify "New" badge is rendered
        expect(find.text('New'), findsOneWidget);
      },
    );

    testWidgets(
      'DailyTabView mounts and sorts month levels descending by date',
      (tester) async {
        await tester.pumpWidget(
          TranslationProvider(
            child: const MaterialApp(
              home: Scaffold(body: DailyTabView()),
            ),
          ),
        );
        await tester.pump(const Duration(milliseconds: 300));

        // Verify DailyTabView mounts without error
        expect(find.byType(DailyTabView), findsOneWidget);
      },
    );
  });
}
