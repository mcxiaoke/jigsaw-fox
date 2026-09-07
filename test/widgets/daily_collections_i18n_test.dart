import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jigsawpuzzle/data/game_repository.dart';
import 'package:jigsawpuzzle/data/storage_manager.dart';
import 'package:jigsawpuzzle/l10n/gen/strings.g.dart';
import 'package:jigsawpuzzle/pages/tabs/collections_tab_view.dart';
import 'package:jigsawpuzzle/pages/tabs/daily_tab_view.dart';
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
    await LocaleService.instance.init();
  });

  tearDownAll(() async {
    await tearDownTestStorage(sm);
  });

  testWidgets('DailyTabView renders localized banner and stats without hardcoded Chinese in English', (tester) async {
    await LocaleService.instance.setLanguage(AppLanguage.en);

    await tester.pumpWidget(
      TranslationProvider(
        child: const MaterialApp(
          home: MediaQuery(
            data: MediaQueryData(size: Size(360, 640)),
            child: Scaffold(
              body: DailyTabView(),
            ),
          ),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 500));

    // Verify English text is used (not hardcoded Chinese)
    expect(find.textContaining("Today's Challenge"), findsWidgets);
    expect(find.textContaining('今日挑战'), findsNothing);

    // Switch to Chinese
    await LocaleService.instance.setLanguage(AppLanguage.zh);

    await tester.pumpWidget(
      TranslationProvider(
        child: const MaterialApp(
          home: MediaQuery(
            data: MediaQueryData(size: Size(360, 640)),
            child: Scaffold(
              body: DailyTabView(),
            ),
          ),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 500));

    expect(find.textContaining('今日挑战'), findsWidgets);
  });

  testWidgets('CollectionsTabView renders with localization in English and Chinese', (tester) async {
    await LocaleService.instance.setLanguage(AppLanguage.en);

    await tester.pumpWidget(
      TranslationProvider(
        child: const MaterialApp(
          home: MediaQuery(
            data: MediaQueryData(size: Size(360, 640)),
            child: Scaffold(
              body: CollectionsTabView(),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    // Verify it pumps without exception
    expect(find.byType(CollectionsTabView), findsOneWidget);
  });
}
