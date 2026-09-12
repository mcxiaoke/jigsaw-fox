import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:jigsawpuzzle/main.dart' as app;
import 'package:jigsawpuzzle/pages/achievements_page.dart';
import 'package:jigsawpuzzle/pages/main_screen.dart';
import 'package:jigsawpuzzle/pages/settings_page.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('full app navigation across 4 tabs, achievements and settings', (
    tester,
  ) async {
    final originalOnError = FlutterError.onError;
    FlutterError.onError = (details) {
      final err = details.exceptionAsString();
      if (err.contains('Failed to load network thumbnail') ||
          err.contains('NetworkImageLoadException') ||
          err.contains('HttpException')) {
        return;
      }
      originalOnError?.call(details);
    };

    try {
      // Launch full app (runZonedGuarded, LocaleService, StorageManager, etc.)
      app.main();
      await tester.pumpAndSettle(const Duration(milliseconds: 500));
      for (var i = 0; i < 20; i++) {
        await tester.pump(const Duration(milliseconds: 500));
        if (find.byType(MainScreen).evaluate().isNotEmpty) break;
      }

      expect(
        find.byType(MainScreen),
        findsOneWidget,
        reason: 'App should show MainScreen after launch',
      );
      expect(find.byType(Scaffold), findsWidgets);
      expect(find.byType(ErrorWidget), findsNothing);

      // 1. Tab 0: Home
      expect(find.byKey(const Key('main_tab_0')), findsOneWidget);

      // 2. Tab 1: Daily
      await tester.tap(find.byKey(const Key('main_tab_1')));
      await tester.pump(const Duration(milliseconds: 500));
      await tester.pump(const Duration(milliseconds: 500));
      expect(find.byType(ErrorWidget), findsNothing);

      // 3. Tab 2: Collections
      await tester.tap(find.byKey(const Key('main_tab_2')));
      await tester.pump(const Duration(milliseconds: 500));
      await tester.pump(const Duration(milliseconds: 500));
      expect(find.byType(ErrorWidget), findsNothing);

      // 4. Tab 3: My Center
      await tester.tap(find.byKey(const Key('main_tab_3')));
      await tester.pump(const Duration(milliseconds: 500));
      await tester.pump(const Duration(milliseconds: 500));
      expect(find.byType(ErrorWidget), findsNothing);

      // 5. Open Achievements page via Trophy icon
      expect(find.byKey(const Key('main_trophy_button')), findsOneWidget);
      await tester.tap(find.byKey(const Key('main_trophy_button')));
      await tester.pump(const Duration(milliseconds: 500));
      await tester.pump(const Duration(milliseconds: 500));
      expect(find.byType(AchievementsPage), findsOneWidget);
      expect(find.byType(ErrorWidget), findsNothing);

      // Close Achievements page
      final backFinder1 = find.byType(BackButton);
      if (backFinder1.evaluate().isNotEmpty) {
        await tester.tap(backFinder1.first);
      } else {
        Navigator.of(tester.element(find.byType(AchievementsPage))).pop();
      }
      await tester.pump(const Duration(milliseconds: 500));
      await tester.pump(const Duration(milliseconds: 500));
      expect(find.byType(MainScreen), findsOneWidget);
      expect(find.byType(ErrorWidget), findsNothing);

      // 6. Open Settings page via Settings icon (visible in My tab)
      expect(find.byKey(const Key('main_settings_button')), findsOneWidget);
      await tester.tap(find.byKey(const Key('main_settings_button')));
      await tester.pump(const Duration(milliseconds: 500));
      await tester.pump(const Duration(milliseconds: 500));
      expect(find.byType(SettingsPage), findsOneWidget);
      expect(find.byType(ErrorWidget), findsNothing);

      // Close Settings page
      final backFinder2 = find.byType(BackButton);
      if (backFinder2.evaluate().isNotEmpty) {
        await tester.tap(backFinder2.first);
      } else {
        Navigator.of(tester.element(find.byType(SettingsPage))).pop();
      }
      await tester.pump(const Duration(milliseconds: 500));
      await tester.pump(const Duration(milliseconds: 500));
      expect(find.byType(MainScreen), findsOneWidget);
      expect(find.byType(ErrorWidget), findsNothing);

      // 7. Back to Tab 0 (Home)
      await tester.tap(find.byKey(const Key('main_tab_0')));
      await tester.pump(const Duration(milliseconds: 500));
      expect(find.byType(MainScreen), findsOneWidget);
      expect(find.byType(ErrorWidget), findsNothing);
    } finally {
      FlutterError.onError = originalOnError;
    }
  });
}
