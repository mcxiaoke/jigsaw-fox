import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jigsawpuzzle/data/game_repository.dart';
import 'package:jigsawpuzzle/data/storage_manager.dart';
import 'package:jigsawpuzzle/pages/tabs/daily_tab_view.dart';
import 'package:jigsawpuzzle/services/locale_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'test_helper.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() => LocaleService.instance.setOverrideForTest('zh'));
  tearDownAll(() => LocaleService.instance.setOverrideForTest(null));
  late StorageManager sm;

  setUp(() async {
    sm = await initTestAppStorage();
    await GameRepository.instance.init();
  });

  tearDown(() async {
    await tearDownTestStorage(sm);
  });

  group('DailyTabView Month Folding Tests', () {
    testWidgets('Toggles month fold expansion upon clicking header', (
      tester,
    ) async {
      await tester.pumpWidget(
        const MaterialApp(home: Scaffold(body: DailyTabView())),
      );

      await tester.pump(const Duration(milliseconds: 300));

      // 验证存在月份 Header
      final now = DateTime.now();
      final curMonthTitle = '${now.year}年${now.month}月';
      expect(find.text(curMonthTitle), findsOneWidget);

      // 点击当月 Header 折叠
      await tester.tap(find.text(curMonthTitle));
      await tester.pump(const Duration(milliseconds: 300));

      // 再次点击展开
      await tester.tap(find.text(curMonthTitle));
      await tester.pump(const Duration(milliseconds: 300));
    });

    testWidgets(
      'Does not display or attempt to load undeclared months (e.g. 2026-07)',
      (tester) async {
        final prefs = await SharedPreferences.getInstance();
        // 模拟用户设备残留的无效历史展开偏好
        await prefs.setStringList('jigsaw_daily_fold_v1', [
          '2026-07',
          '2026-09',
        ]);

        await tester.pumpWidget(
          const MaterialApp(home: Scaffold(body: DailyTabView())),
        );
        await tester.pump(const Duration(milliseconds: 300));

        final now = DateTime.now();
        final curMonthTitle = '${now.year}年${now.month}月';
        expect(find.text(curMonthTitle), findsOneWidget);

        // 验证前2个月 (如 9 月时的 7 月) 绝不会凭空展示
        final twoMonthsAgo = DateTime(now.year, now.month - 2);
        final twoMonthsAgoTitle = '${twoMonthsAgo.year}年${twoMonthsAgo.month}月';

        expect(find.text(twoMonthsAgoTitle), findsNothing);
        expect(find.textContaining('数据加载失败'), findsNothing);
        expect(find.textContaining('加载失败'), findsNothing);
      },
    );
  });
}
