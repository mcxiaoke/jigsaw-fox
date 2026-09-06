import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jigsawpuzzle/data/game_repository.dart';
import 'package:jigsawpuzzle/data/storage_manager.dart';
import 'package:jigsawpuzzle/l10n/gen/strings.g.dart';
import 'package:jigsawpuzzle/pages/achievements_page.dart';
import 'package:jigsawpuzzle/pages/main_screen.dart';
import 'package:jigsawpuzzle/pages/settings_page.dart';
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

  for (final lang in [AppLanguage.zh, AppLanguage.en]) {
    testWidgets('MainScreen smoke navigation in  at 360dp width', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(360, 780);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(() {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      });

      final errors = <FlutterErrorDetails>[];
      final originalOnError = FlutterError.onError;
      FlutterError.onError = (details) {
        errors.add(details);
        originalOnError?.call(details);
      };

      try {
        await LocaleService.instance.setLanguage(lang);

        await tester.pumpWidget(
          TranslationProvider(child: const MaterialApp(home: MainScreen())),
        );
        await tester.pump(const Duration(milliseconds: 500));

        expect(find.byType(MainScreen), findsOneWidget);
        expect(find.byKey(const Key('main_tab_0')), findsOneWidget);

        // 1. Daily Tab
        await tester.tap(find.byKey(const Key('main_tab_1')));
        await tester.pump(const Duration(milliseconds: 500));
        expect(find.byKey(const Key('main_tab_1')), findsOneWidget);

        // 2. Collections Tab
        await tester.tap(find.byKey(const Key('main_tab_2')));
        await tester.pump(const Duration(milliseconds: 500));
        expect(find.byKey(const Key('main_tab_2')), findsOneWidget);

        // 3. My Center Tab
        await tester.tap(find.byKey(const Key('main_tab_3')));
        await tester.pump(const Duration(milliseconds: 500));
        expect(find.byKey(const Key('main_tab_3')), findsOneWidget);

        // 4. Open Achievements
        final trophyBtn = find.byKey(const Key('main_trophy_button'));
        expect(trophyBtn, findsOneWidget);
        await tester.tap(trophyBtn);
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 600));
        expect(find.byType(AchievementsPage), findsOneWidget);

        // Close Achievements
        Navigator.of(tester.element(find.byType(AchievementsPage))).pop();
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 600));
        expect(find.byType(MainScreen), findsOneWidget);

        // 5. Open Settings (from My tab AppBar)
        final settingsBtn = find.byKey(const Key('main_settings_button'));
        expect(settingsBtn, findsOneWidget);
        await tester.tap(settingsBtn);
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 600));
        expect(find.byType(SettingsPage), findsOneWidget);

        // Close Settings
        Navigator.of(tester.element(find.byType(SettingsPage))).pop();
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 600));
        expect(find.byType(MainScreen), findsOneWidget);

        // 6. Return to Home Tab
        await tester.tap(find.byKey(const Key('main_tab_0')));
        await tester.pump(const Duration(milliseconds: 500));
        expect(find.byType(MainScreen), findsOneWidget);

        // Assert 0 overflow errors
        final overflows = errors.where(
          (e) => e.toString().contains('A RenderFlex overflowed'),
        );
        expect(
          overflows,
          isEmpty,
          reason: 'There should be no RenderFlex overflows in ',
        );
      } finally {
        FlutterError.onError = originalOnError;
      }
    });
  }
}
