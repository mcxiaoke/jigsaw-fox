import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jigsawpuzzle/data/game_repository.dart';
import 'package:jigsawpuzzle/data/storage_manager.dart';
import 'package:jigsawpuzzle/pages/tabs/daily_tab_view.dart';

import 'test_helper.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
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
  });
}
