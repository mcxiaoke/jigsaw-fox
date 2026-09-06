import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jigsawpuzzle/data/game_repository.dart';
import 'package:jigsawpuzzle/data/storage_manager.dart';
import 'package:jigsawpuzzle/l10n/gen/strings.g.dart';
import 'package:jigsawpuzzle/pages/settings_page.dart';
import 'package:jigsawpuzzle/services/economy_service.dart';
import 'package:jigsawpuzzle/services/locale_service.dart';
import 'package:phosphoricons_flutter/phosphoricons_flutter.dart';
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

  testWidgets('SettingsPage renders compactly in English without overflow', (tester) async {
    LocaleSettings.setLocale(AppLocale.en);
    await LocaleService.instance.setLanguage(AppLanguage.en);

    await tester.pumpWidget(
      TranslationProvider(
        child: MaterialApp(
          home: MediaQuery(
            data: const MediaQueryData(size: Size(360, 640)),
            child: const SettingsPage(),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    // Verify Scatter Mode compact toggle exists
    expect(find.text('Scatter Mode'), findsOneWidget);
    expect(find.text('Tray'), findsOneWidget);
    expect(find.text('Tabletop'), findsOneWidget);

    // Tap Tabletop to toggle mode
    await tester.tap(find.text('Tabletop'));
    await tester.pumpAndSettle();
    expect(GameRepository.instance.pieceScatterMode, equals('tabletop'));

    // Tap Tray to toggle back
    await tester.tap(find.text('Tray'));
    await tester.pumpAndSettle();
    expect(GameRepository.instance.pieceScatterMode, equals('tray'));

    // Scroll to Language tile
    final langTileFinder = find.byIcon(PhosphorIconsBold.translate);
    await tester.scrollUntilVisible(langTileFinder, 100);
    await tester.pumpAndSettle();

    // Verify Language tile exists and tap it
    expect(langTileFinder, findsOneWidget);
    await tester.tap(langTileFinder);
    await tester.pumpAndSettle();

    // Bottom sheet is opened: verify bottom sheet exists
    expect(find.byType(BottomSheet), findsOneWidget);
  });

  testWidgets('SettingsPage renders compactly in Chinese without overflow', (tester) async {
    LocaleSettings.setLocale(AppLocale.zh);
    await LocaleService.instance.setLanguage(AppLanguage.zh);

    await tester.pumpWidget(
      TranslationProvider(
        child: MaterialApp(
          home: MediaQuery(
            data: const MediaQueryData(size: Size(360, 640)),
            child: const SettingsPage(),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('棋盘模式'), findsOneWidget);
    expect(find.text('托盘'), findsOneWidget);
    expect(find.text('桌面'), findsOneWidget);

    final langTileFinder = find.byIcon(PhosphorIconsBold.translate);
    await tester.scrollUntilVisible(langTileFinder, 100);
    await tester.pumpAndSettle();
    expect(langTileFinder, findsOneWidget);
  });
}
