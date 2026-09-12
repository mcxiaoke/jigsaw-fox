import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jigsawpuzzle/data/game_repository.dart';
import 'package:jigsawpuzzle/data/storage_manager.dart';
import 'package:jigsawpuzzle/l10n/gen/strings.g.dart';
import 'package:jigsawpuzzle/pages/tabs/my_center_tab_view.dart';
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

  testWidgets(
    'MyCenterTabView renders tabs without truncation in English and Chinese on 360dp width',
    (tester) async {
      // English test
      await LocaleService.instance.setLanguage(AppLanguage.en);

      await tester.pumpWidget(
        TranslationProvider(
          child: const MaterialApp(
            home: MediaQuery(
              data: MediaQueryData(size: Size(360, 640)),
              child: Scaffold(body: MyCenterTabView()),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // Verify TabBar has isScrollable: true
      final tabBar = tester.widget<TabBar>(find.byType(TabBar));
      expect(tabBar.isScrollable, isTrue);

      // Verify English tab texts exist in full without truncation
      expect(find.text('Active (0)'), findsOneWidget);
      expect(find.text('Saved (0)'), findsOneWidget);
      expect(find.text('Done (0)'), findsOneWidget);
      expect(find.text('Custom (3)'), findsOneWidget);

      // Chinese test
      await LocaleService.instance.setLanguage(AppLanguage.zh);

      await tester.pumpWidget(
        TranslationProvider(
          child: const MaterialApp(
            home: MediaQuery(
              data: MediaQueryData(size: Size(360, 640)),
              child: Scaffold(body: MyCenterTabView()),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('进行中 (0)'), findsOneWidget);
      expect(find.text('收藏 (0)'), findsOneWidget);
      expect(find.text('已完成 (0)'), findsOneWidget);
      expect(find.text('自制 (3)'), findsOneWidget);
    },
  );
}
