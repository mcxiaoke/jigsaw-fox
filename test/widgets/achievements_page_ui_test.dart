import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jigsawpuzzle/data/game_repository.dart';
import 'package:jigsawpuzzle/data/storage_manager.dart';
import 'package:jigsawpuzzle/l10n/gen/strings.g.dart';
import 'package:jigsawpuzzle/pages/achievements_page.dart';
import 'package:jigsawpuzzle/services/achievement_store.dart';
import 'package:jigsawpuzzle/services/economy_service.dart';
import 'package:jigsawpuzzle/services/locale_service.dart';
import '../test_helper.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late StorageManager sm;

  setUpAll(() async {
    sm = await initTestAppStorage();
    await GameRepository.instance.init();
    await EconomyService.instance.init();
    await AchievementStore.instance.init();
    await LocaleService.instance.init();
  });

  tearDownAll(() async {
    await tearDownTestStorage(sm);
  });

  testWidgets('AchievementsPage renders vertical KPI metrics without overflow in English', (tester) async {
    await LocaleService.instance.setLanguage(AppLanguage.en);

    await tester.pumpWidget(
      TranslationProvider(
        child: MaterialApp(
          home: MediaQuery(
            data: const MediaQueryData(size: Size(360, 640)),
            child: const AchievementsPage(),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    // Verify KPI metric labels
    expect(find.text('Total Stars'), findsOneWidget);
    expect(find.text('3-Star Clears'), findsOneWidget);
    expect(find.text('Solved'), findsOneWidget);
    expect(find.text('Coins'), findsOneWidget);
    expect(find.text('Snaps'), findsOneWidget);
    expect(find.text('Play Time'), findsOneWidget);
  });

  testWidgets('AchievementsPage renders vertical KPI metrics without overflow in Chinese', (tester) async {
    await LocaleService.instance.setLanguage(AppLanguage.zh);

    await tester.pumpWidget(
      TranslationProvider(
        child: MaterialApp(
          home: MediaQuery(
            data: const MediaQueryData(size: Size(360, 640)),
            child: const AchievementsPage(),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    // Verify Chinese KPI metric labels
    expect(find.text('总星数'), findsOneWidget);
    expect(find.text('满星通关'), findsOneWidget);
    expect(find.text('已通关'), findsOneWidget);
    expect(find.text('拥有金币'), findsOneWidget);
    expect(find.text('吸附碎片'), findsOneWidget);
    expect(find.text('游玩时长'), findsOneWidget);
  });
}
