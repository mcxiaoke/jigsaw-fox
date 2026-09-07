import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jigsawpuzzle/data/game_repository.dart';
import 'package:jigsawpuzzle/data/storage_manager.dart';
import 'package:jigsawpuzzle/l10n/gen/strings.g.dart';
import 'package:jigsawpuzzle/pages/main_screen.dart';
import 'package:jigsawpuzzle/pages/settings_page.dart';
import 'package:jigsawpuzzle/pages/tabs/collections_tab_view.dart';
import 'package:jigsawpuzzle/pages/tabs/daily_tab_view.dart';
import 'package:jigsawpuzzle/pages/tabs/home_tab_view.dart';
import 'package:jigsawpuzzle/pages/tabs/my_center_tab_view.dart';
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

  testWidgets(
    'Real-time language switching dynamically refreshes all tabs without app restart',
    (tester) async {
      tester.view.physicalSize = const Size(360, 780);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(() {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      });

      // 1. Start in English
      await LocaleService.instance.setLanguage(AppLanguage.en);

      await tester.pumpWidget(
        TranslationProvider(child: const MaterialApp(home: MainScreen())),
      );
      await tester.pump(const Duration(milliseconds: 500));

      expect(find.byType(MainScreen), findsOneWidget);
      expect(find.byType(HomeTabView), findsOneWidget);

      // Home Tab: English AppBar & Navigation
      expect(find.text('Jigsaw Puzzle'), findsOneWidget);
      expect(find.text('Home'), findsOneWidget);
      expect(find.text('Daily'), findsWidgets);
      expect(find.text('Collections'), findsWidgets);
      expect(find.text('My'), findsOneWidget);

      // 2. Switch to Daily Tab (Tab 1)
      await tester.tap(find.byKey(const Key('main_tab_1')));
      await tester.pump(const Duration(milliseconds: 500));
      expect(find.byType(DailyTabView), findsOneWidget);
      expect(find.text('Daily Challenge'), findsOneWidget);
      expect(find.textContaining("Today's Challenge"), findsWidgets);
      expect(find.textContaining('今日挑战'), findsNothing);

      // 3. Switch to Collections Tab (Tab 2)
      await tester.tap(find.byKey(const Key('main_tab_2')));
      await tester.pump(const Duration(milliseconds: 500));
      expect(find.byType(CollectionsTabView), findsOneWidget);
      expect(find.text('Collections'), findsWidgets);
      expect(find.text('No collections yet'), findsOneWidget);
      expect(find.text('Sync'), findsOneWidget);
      expect(find.text('暂无图集内容'), findsNothing);

      // 4. Switch to My Center Tab (Tab 3)
      await tester.tap(find.byKey(const Key('main_tab_3')));
      await tester.pump(const Duration(milliseconds: 500));
      expect(find.byType(MyCenterTabView), findsOneWidget);
      expect(find.textContaining('Active'), findsWidgets);
      expect(find.textContaining('Saved'), findsWidgets);
      expect(find.textContaining('Done'), findsWidgets);
      expect(find.textContaining('Custom'), findsWidgets);
      expect(find.text('Gallery'), findsWidgets);
      expect(find.text('Online'), findsWidgets);
      expect(find.text('Archive'), findsWidgets);
      expect(find.text('Import'), findsWidgets);
      expect(find.textContaining('进行中'), findsNothing);
      expect(find.text('相册选图'), findsNothing);

      // 5. Open Settings from My Tab and switch to Chinese
      final settingsBtn = find.byKey(const Key('main_settings_button'));
      expect(settingsBtn, findsOneWidget);
      await tester.tap(settingsBtn);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 600));
      expect(find.byType(SettingsPage), findsOneWidget);

      // Change language to Chinese inside Settings
      await LocaleService.instance.setLanguage(AppLanguage.zh);
      await tester.pump(const Duration(milliseconds: 300));

      // Pop Settings back to MainScreen
      Navigator.of(tester.element(find.byType(SettingsPage))).pop();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 600));
      expect(find.byType(MainScreen), findsOneWidget);

      // 6. Verify My Center Tab is immediately in Chinese
      expect(find.textContaining('进行中'), findsWidgets);
      expect(find.textContaining('收藏'), findsWidgets);
      expect(find.textContaining('已完成'), findsWidgets);
      expect(find.textContaining('自制'), findsWidgets);
      expect(find.text('相册选图'), findsWidgets);
      expect(find.text('在线搜图'), findsWidgets);
      expect(find.text('素材库'), findsWidgets);
      expect(find.text('导入图包'), findsWidgets);
      expect(find.textContaining('Active'), findsNothing);
      expect(find.text('Archive'), findsNothing);

      // 7. Verify Collections Tab (Tab 2) is immediately in Chinese
      await tester.tap(find.byKey(const Key('main_tab_2')));
      await tester.pump(const Duration(milliseconds: 500));
      expect(find.text('暂无图集内容'), findsOneWidget);
      expect(find.text('刷新同步'), findsOneWidget);
      expect(find.text('No collections yet'), findsNothing);

      // 8. Verify Daily Tab (Tab 1) is immediately in Chinese
      await tester.tap(find.byKey(const Key('main_tab_1')));
      await tester.pump(const Duration(milliseconds: 500));
      expect(find.text('每日挑战'), findsOneWidget);
      expect(find.textContaining('今日挑战'), findsWidgets);
      expect(find.textContaining("Today's Challenge"), findsNothing);

      // 9. Verify Home Tab (Tab 0) is immediately in Chinese
      await tester.tap(find.byKey(const Key('main_tab_0')));
      await tester.pump(const Duration(milliseconds: 500));
      expect(find.text('异形拼图'), findsOneWidget);
      expect(find.text('主页'), findsOneWidget);
      expect(find.text('每日'), findsWidgets);
      expect(find.text('图集'), findsWidgets);
      expect(find.text('我的'), findsOneWidget);

      // 10. Switch back to English via LocaleService while MainScreen is open
      await LocaleService.instance.setLanguage(AppLanguage.en);
      await tester.pump(const Duration(milliseconds: 500));

      // Verify Home immediately returns to English
      expect(find.text('Jigsaw Puzzle'), findsOneWidget);
      expect(find.text('Home'), findsOneWidget);
      expect(find.text('异形拼图'), findsNothing);

      // Verify Daily returns to English
      await tester.tap(find.byKey(const Key('main_tab_1')));
      await tester.pump(const Duration(milliseconds: 500));
      expect(find.textContaining("Today's Challenge"), findsWidgets);
      expect(find.textContaining('今日挑战'), findsNothing);
    },
  );
}
